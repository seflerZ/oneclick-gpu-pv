#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    One-click GPU-PV setup for a Windows guest running on a Hyper-V host.

.DESCRIPTION
    Run this script on the Hyper-V Windows HOST (Administrator). It will:
      1. Let you pick a target VM (Out-GridView, or pass -VMName).
      2. Let you pick the NVIDIA display adapter to partition (Out-GridView,
         or pass -CardIndex 1..N).
      3. Stop the VM, disable checkpoints (they break GPU-PV), boot it up.
      4. Wait until the VM responds to PowerShell Direct (no language-dependent
         heartbeat status string).
      5. Open a New-PSSession via VMId and push the host's NVIDIA driver
         package (DriverStore FileRepository dir) into the VM.
      6. Generate C:\GPUPAdditionalSetup.bat inside the VM that runs
         rundll32 advpack.dll,LaunchINFSectionEx to install the driver INF.
      7. Stop the VM, attach the GPU partition adapter with resource quotas,
         set MMIO + GuestControlledCacheTypes, start the VM.

    After the script finishes, RDP into the VM and run
    C:\GPUPAdditionalSetup.bat as Administrator. Reboot when prompted.
    D3D12 / DirectML / CUDA-in-WSL (Linux guest) then get GPU acceleration.

.PARAMETER VMName
    VM to target. If omitted, Out-GridView prompts.

.PARAMETER CardIndex
    1-based index into (Get-PnpDevice -Class Display -Status OK).
    If omitted, Out-GridView prompts.

.PARAMETER Stage
    All / Configure / Verify / Undo. Default: All.

.PARAMETER Force
    Skip interactive y/n confirmations.

.EXAMPLE
    .\win-gpu-pv.ps1
.EXAMPLE
    .\win-gpu-pv.ps1 -VMName Win11-GPUPV -Force
.EXAMPLE
    .\win-gpu-pv.ps1 -VMName Win11-GPUPV -CardIndex 2 -Force
.EXAMPLE
    .\win-gpu-pv.ps1 -Stage Verify
.EXAMPLE
    .\win-gpu-pv.ps1 -Stage Undo

.NOTES
    Author: seflerZ
    Project: https://github.com/seflerZ/oneclick-gpu-pv

    Tested on Windows 10/11 + Hyper-V with consumer NVIDIA GPUs (GeForce
    class). For Linux guests, use the companion ubuntu-gpu-pv.ps1 script
    instead.

    The script does NOT depend on the host's UI language. The original
    version localised the heartbeat service label and status text
    ("HeartBeat" / "OK") which broke on hosts where the heart-beat
    integration service was registered under a localized display name
    (e.g. some non-English Windows installs). This rewrite just probes
    New-PSSession to detect readiness, which is language-agnostic.
#>

[CmdletBinding()]
param(
    [string]$VMName,
    [int]$CardIndex,
    [ValidateSet('All', 'Configure', 'Verify', 'Undo')]
    [string]$Stage     = 'All',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'


# ============================ Output helpers ============================

function Step { param([string]$m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Ok   { param([string]$m) Write-Host "  [OK]  $m" -ForegroundColor Green }
function Warn { param([string]$m) Write-Host "  [!]   $m" -ForegroundColor Yellow }
function Err  { param([string]$m) Write-Host "  [X]   $m" -ForegroundColor Red }

function Confirm {
    if ($Force) { return $true }
    return ((Read-Host "$([System.Environment]::NewLine)$($args[0]) [y/N]") -match '^[yY]$')
}


# ============================ Prerequisites ============================

function Assert-Prerequisites {
    Step 'Prerequisites'

    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        throw 'Get-VM not found. Enable the Hyper-V management tools (Windows Features -> Hyper-V -> Management Tools).'
    }
    Ok 'Hyper-V cmdlets available'

    if (-not (Get-Command Get-WindowsDriver -ErrorAction SilentlyContinue)) {
        throw 'Get-WindowsDriver not found. Run from an elevated PowerShell with Hyper-V + DISM modules installed.'
    }
    Ok 'Get-WindowsDriver available'

    # Sanity check: PowerShell Direct requires Hyper-V host + WinRM in the guest
    if (-not (Get-Command New-PSSession -ErrorAction SilentlyContinue)) {
        throw 'New-PSSession not available.'
    }
    if (-not (Get-Command Copy-Item -ErrorAction SilentlyContinue)) {
        throw 'Copy-Item not available.'
    }
    Ok 'PowerShell Direct primitives available'
}


# ============================ VM picker (out-gridview OR -VMName) ============================

function Resolve-VM {
    param([string]$Name)

    if ($Name) {
        $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
        if (-not $vm) { throw "VM '$Name' not found" }
        return $vm
    }

    if (-not (Get-Command Out-GridView -ErrorAction SilentlyContinue)) {
        throw 'Out-GridView not available in this host PowerShell session. Pass -VMName to bypass.'
    }

    $vm = Get-VM | Out-GridView -Title 'Select the target VM to attach GPU-P to' -OutputMode Single
    if (-not $vm) { throw 'No VM selected' }
    return $vm
}


# ============================ GPU device picker (out-gridview OR -CardIndex) ============================

function Resolve-GpuDevice {
    param([int]$Index)

    $devices = @(Get-PnpDevice -Class Display -Status OK)
    if ($devices.Count -eq 0) {
        throw 'No OK Display adapters found. Reinstall the host NVIDIA driver (WDDM / WSL / Studio) and reboot.'
    }

    if ($devices.Count -eq 1) {
        Warn "Only one Display adapter is OK; using it: $($devices[0].FriendlyName)"
        return $devices[0]
    }

    if ($PSBoundParameters.ContainsKey('Index') -and $Index -ne 0) {
        if ($Index -lt 1 -or $Index -gt $devices.Count) {
            throw "CardIndex $Index out of range (1..$($devices.Count))"
        }
        Write-Host "  Selected GPU [index $Index]: $($devices[$Index - 1].FriendlyName)"
        return $devices[$Index - 1]
    }

    if (-not (Get-Command Out-GridView -ErrorAction SilentlyContinue)) {
        Write-Host '  Available Display adapters:'
        for ($i = 0; $i -lt $devices.Count; $i++) {
            Write-Host ('    [{0,2}] {1}' -f ($i + 1), $devices[$i].FriendlyName)
        }
        $pick = Read-Host '  Pick a number (or pass -CardIndex next time to skip this)'
        if ($pick -match '^\d+$' -and 1..$devices.Count -contains [int]$pick) {
            return $devices[[int]$pick - 1]
        }
        throw 'No valid selection'
    }

    $dev = $devices | Out-GridView -Title 'Select the NVIDIA GPU to partition' -OutputMode Single
    if (-not $dev) { throw 'No GPU selected' }
    return $dev
}


# ============================ Match Display device -> partition path ============================

function Resolve-PartitionPath {
    param($Device)
    $target = $Device.InstanceId.Replace('\', '#').ToLower()
    $candidates = @(Get-VMHostPartitionableGpu)
    if ($candidates.Count -eq 0) {
        throw 'No partitionable GPUs found on this host. Update the NVIDIA driver to a recent version (Studio / Game Ready / DCH) and reboot.'
    }
    foreach ($c in $candidates) {
        if ($c.Name.ToLower().Contains($target)) { return $c.Name }
    }
    throw @"
Could not match the chosen Display device ($($Device.FriendlyName), instance '$target')
to any of the host's partitionable GPUs:
  $($candidates.Name -join "`n  ")

This usually means the GPU driver is not the WDDM / WSL variant. Fix:
  1. Reinstall the NVIDIA driver with the WDDM + WSL components enabled.
  2. Reboot.
  3. Re-run this script.
"@
}


# ============================ Stop VM if running ============================

function Stop-VmIfRunning {
    param([string]$Name)
    $vm = Get-VM -Name $Name
    if ($vm.State -eq 'Off') { return }
    Warn "$Name is currently $($vm.State); GPU partition changes require it to be Off"
    if (-not (Confirm "Power off $Name now?")) { throw 'Cancelled' }
    Stop-VM -Name $Name -Force
    Start-Sleep -Seconds 5
    Ok "$Name powered off"
}


# ============================ Wait for VM to be PowerShell Direct reachable ============================

function Wait-VmReady {
    param([Microsoft.HyperV.PowerShell.VirtualMachine]$vm, [int]$TimeoutSec = 240)

    Write-Host "  Waiting for VM to accept PowerShell Direct (up to $TimeoutSec sec)..."

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $attempt = 0
    while ((Get-Date) -lt $deadline) {
        $attempt++
        try {
            $sess = New-PSSession -VMId $vm.VMId -ErrorAction Stop
            if ($sess -and $sess.State -eq 'Opened') {
                Remove-PSSession $sess -ErrorAction SilentlyContinue
                Ok "PowerShell Direct reachable after $attempt probe(s)"
                return
            }
        } catch {
            $err = $_.Exception.Message
            # Don't spam - just continue
        }
        Start-Sleep -Seconds 3
    }
    throw @"
Timed out waiting for '$($vm.Name)' to accept PowerShell Direct.

Check inside the VM:
  - Is WinRM enabled (Run 'winrm quickconfig' as Administrator)?
  - Are the guest integration services enabled (especially 'Hyper-V Guest Service Interface')?
  - Is the guest firewall blocking TCP 5985 (WinRM)?

Then re-run this script.
"@
}


# ============================ Locate host driver package ============================

function Resolve-HostDriverPackage {
    param($Device)

    $props = $Device | Get-PnpDeviceProperty
    $pnpinf      = ($props | Where-Object { $_.KeyName -eq 'DEVPKEY_Device_DriverInfPath' }).Data
    $infsection  = ($props | Where-Object { $_.KeyName -eq 'DEVPKEY_Device_DriverInfSection' }).Data

    if (-not $pnpinf) {
        throw "Could not extract DEVPKEY_Device_DriverInfPath from device $($Device.FriendlyName). Driver metadata missing."
    }
    if (-not $infsection) {
        throw "Could not extract DEVPKEY_Device_DriverInfSection from device $($Device.FriendlyName). Driver metadata missing."
    }

    $cbsinf = (Get-WindowsDriver -Online | Where-Object { $_.Driver -eq "$pnpinf" }).OriginalFileName
    if (-not $cbsinf) {
        throw @"
Could not locate the CBS driver package for $pnpinf.
Reinstall the NVIDIA driver with WDDM + WSL components enabled, reboot, then re-run.
"@
    }

    $inffile = Get-Item -LiteralPath $cbsinf
    $drvpkg  = $inffile.Directory

    return [pscustomobject]@{
        PnpInf       = $pnpinf
        InfSection   = $infsection
        CbsInfPath   = $cbsinf
        DriverPkgDir = $drvpkg
    }
}


# ============================ Stage: Configure ============================

function Invoke-Configure {
    param([string]$VMName, [int]$CardIndex)

    Step 'Configure GPU-PV end-to-end'

    # 1) Pick VM
    $vm = Resolve-VM $VMName
    $vmName = $vm.Name
    Write-Host "  Selected VM: $vmName"

    # 2) Pick GPU
    $dev = Resolve-GpuDevice $CardIndex
    Write-Host "  Selected GPU: $($dev.FriendlyName)"

    # 3) Resolve driver package + partition path
    $pkg = Resolve-HostDriverPackage $dev
    Ok "Driver package: $($pkg.DriverPkgDir)"
    $path = Resolve-PartitionPath $dev
    Ok "GPU partition path: $path"

    # 4) Stop VM, disable checkpoints
    Stop-VmIfRunning $vmName
    Set-VM -VMName $vmName -CheckpointType Disabled -ErrorAction SilentlyContinue
    Ok 'Checkpoints disabled (they conflict with the GPU partition adapter)'

    # 5) Boot VM, wait for PowerShell Direct
    Start-VM -VMName $vmName
    Ok 'VM started'
    Wait-VmReady $vm 240

    # 6) Open PowerShell Direct and push driver
    $vmsess = $null
    try {
        $vmsess = New-PSSession -VMId $vm.VMId -ErrorAction Stop
        Ok 'PowerShell Direct session opened'

        $hostdrvstorepath = Invoke-Command -Session $vmsess -ScriptBlock {
            New-Item -ItemType Directory "$env:SystemRoot\System32\HostDriverStore\FileRepository" -Force | Out-Null
            "$env:SystemRoot\System32\HostDriverStore\FileRepository"
        } -ErrorAction Stop
        Ok "Created remote dir: $hostdrvstorepath"

        Copy-Item -LiteralPath $pkg.DriverPkgDir.FullName -Destination "$hostdrvstorepath" -Recurse -Force -ToSession $vmsess
        Ok 'Driver package copied into the VM'

        $vminfpath = Join-Path (Join-Path $hostdrvstorepath $pkg.DriverPkgDir.Name) (Split-Path -Leaf $pkg.CbsInfPath)
        Write-Host "  INF in VM: $vminfpath"

        # Build the .bat content
        $batProlog = @"
cd /d %TEMP%
set dirname=gpupaddlsetup%RANDOM%
mkdir %dirname%
cd %dirname%

"@
        $batInstallLine = "start `"" /wait rundll32 advpack.dll,LaunchINFSectionEx $vminfpath,$($pkg.InfSection),,4"
        $batEpilog = @"

cd ..
rmdir /s /q %dirname%

"@

        Invoke-Command -Session $vmsess -ScriptBlock {
            param($prolog, $install, $epilog)
            Set-Content -LiteralPath "$env:SystemDrive\GPUPAdditionalSetup.bat" -Encoding utf8 -Value $prolog
            Add-Content -LiteralPath "$env:SystemDrive\GPUPAdditionalSetup.bat" -Encoding utf8 -Value $install
            Add-Content -LiteralPath "$env:SystemDrive\GPUPAdditionalSetup.bat" -Encoding utf8 -Value $epilog
        } -ArgumentList $batProlog, $batInstallLine, $batEpilog
        Ok 'Wrote C:\GPUPAdditionalSetup.bat inside the VM'
    } finally {
        if ($vmsess) {
            Remove-PSSession $vmsess -ErrorAction SilentlyContinue
        }
    }

    # 7) Stop VM, attach GPU partition adapter
    Stop-VM -VMName $vmName -Force
    Start-Sleep -Seconds 5
    Ok 'VM stopped for partition attach'

    Add-VMGpuPartitionAdapter -VMName $vmName -InstancePath "$path"
    Ok "GPU partition adapter added (path: $path)"

    Set-VMGpuPartitionAdapter -VMName $vmName `
        -MinPartitionVRAM    1 -MaxPartitionVRAM    900000000            -OptimalPartitionVRAM    900000000 `
        -MinPartitionEncode  1 -MaxPartitionEncode  16602000000000000000 -OptimalPartitionEncode  16602000000000000000 `
        -MinPartitionDecode  1 -MaxPartitionDecode  900000000            -OptimalPartitionDecode  900000000 `
        -MinPartitionCompute 1 -MaxPartitionCompute 900000000            -OptimalPartitionCompute 900000000
    Ok 'Partition resource quotas set (VRAM ~900 MB, encode/decode/compute each ~900 MB)'

    Set-VM -VMName $vmName -GuestControlledCacheTypes $true `
                       -LowMemoryMappedIoSpace   1Gb `
                       -HighMemoryMappedIoSpace  32GB
    Ok 'MMIO (1 GiB low + 32 GiB high) + GuestControlledCacheTypes set'

    # 8) Start VM
    Start-VM -VMName $vmName
    Ok 'VM started'

    Step 'Done'
    Write-Host 'Next steps:'
    Write-Host '  1) RDP into the VM'
    Write-Host '  2) Run C:\GPUPAdditionalSetup.bat as Administrator'
    Write-Host '  3) Reboot when prompted'
    Write-Host '  4) Verify: dxdiag, or a D3D12 app (e.g. C:\Windows\System32\d3d12.dll)'
    Write-Host ''
    Write-Host "Driver install is queued in C:\GPUPAdditionalSetup.bat - the VM must be running and reachable by RDP for you to run it."
}


# ============================ Stage: Verify ============================

function Test-GpuPv {
    param([string]$VMName)
    Step 'Verify GPU-PV (host side)'

    $vm = Resolve-VM $VMName
    $vmName = $vm.Name

    Write-Host '  --- VM ---'
    Write-Host ("    Name:    {0}" -f $vm.Name)
    Write-Host ("    State:   {0}" -f $vm.State)
    Write-Host ("    Uptime:  {0:hh\:mm\:ss}" -f $vm.Uptime)
    Write-Host ("    Checkpoints: {0}" -f $vm.CheckpointType)

    Write-Host '  --- GPU partition adapter(s) ---'
    $adapters = @(Get-VMGpuPartitionAdapter -VMName $vmName -ErrorAction SilentlyContinue)
    if ($adapters.Count -eq 0) {
        Err 'No GPU partition adapter attached. Run -Stage Configure (or -Stage All).'
        return
    }
    foreach ($a in $adapters) {
        Write-Host ("    InstancePath: {0}" -f $a.InstancePath)
        Write-Host ("    VRAM (min/max/opt):    {0} / {1} / {2}" -f $a.MinPartitionVRAM,    $a.MaxPartitionVRAM,    $a.OptimalPartitionVRAM)
        Write-Host ("    Encode (min/max/opt):  {0} / {1} / {2}" -f $a.MinPartitionEncode,  $a.MaxPartitionEncode,  $a.OptimalPartitionEncode)
        Write-Host ("    Decode (min/max/opt):  {0} / {1} / {2}" -f $a.MinPartitionDecode,  $a.MaxPartitionDecode,  $a.OptimalPartitionDecode)
        Write-Host ("    Compute (min/max/opt): {0} / {1} / {2}" -f $a.MinPartitionCompute, $a.MaxPartitionCompute, $a.OptimalPartitionCompute)
    }
    Ok "$($adapters.Count) adapter(s) attached"

    Write-Host '  --- MMIO + cache types ---'
    $cfg = Get-VM -Name $vmName
    Write-Host ("    GuestControlledCacheTypes: {0}" -f $cfg.GuestControlledCacheTypes)
    Write-Host ("    LowMemoryMappedIoSpace:    {0}" -f $cfg.LowMemoryMappedIoSpace)
    Write-Host ("    HighMemoryMappedIoSpace:   {0}" -f $cfg.HighMemoryMappedIoSpace)

    if ($cfg.GuestControlledCacheTypes -ne $true) {
        Warn 'GuestControlledCacheTypes is not True. dxgkrnl / D3D12 may fail to initialise inside the guest.'
    }
    if ($cfg.CheckpointType -ne 'Disabled') {
        Warn "Checkpoints are not Disabled. Older checkpoints can break GPU-PV. Disable via: Set-VM -Name '$vmName' -CheckpointType Disabled"
    }
}


# ============================ Stage: Undo ============================

function Undo-GpuPv {
    param([string]$VMName)
    Step "Undo GPU-PV for ${VMName}"

    $vm = Resolve-VM $VMName
    $vmName = $vm.Name
    Stop-VmIfRunning $vmName

    Remove-VMGpuPartitionAdapter -VMName $vmName -ErrorAction SilentlyContinue
    Ok 'GPU partition adapter removed'

    Warn 'In-VM driver is NOT uninstalled by this step. To finish cleanup:'
    Write-Host '    RDP into the VM -> Device Manager -> right-click the NVIDIA adapter -> Uninstall device (also delete driver software)'
    Write-Host '    Or via PowerShell Direct: Get-PnpDevice -Class Display | Where-Object { $_.InstanceId -like "*VEN_10DE*" } | Disable-PnpDevice -Confirm:$false'
}


# ============================ Main flow ============================

Assert-Prerequisites

switch ($Stage) {
    'Configure' { Invoke-Configure $VMName $CardIndex }
    'Verify'    { Test-GpuPv       $VMName }
    'Undo'      { Undo-GpuPv       $VMName }
    'All'       {
        Invoke-Configure $VMName $CardIndex
        Test-GpuPv       $VMName
    }
}

Write-Host ''
Write-Host '============================ Win-side done ============================' -ForegroundColor Green
Write-Host 'Pair this with ubuntu-gpu-pv.ps1 (for Linux Hyper-V guests):'
Write-Host '  https://github.com/seflerZ/oneclick-gpu-pv'
