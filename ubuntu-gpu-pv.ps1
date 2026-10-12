#Requires -Version 5.1
<#
.SYNOPSIS
    One-click GPU-PV setup for Hyper-V Linux guests (no WSL distro required).

.DESCRIPTION
    Enables GPU Partitioning (GPU-PV) on a Hyper-V Linux guest so the host's
    NVIDIA driver is bridged into the guest, allowing CUDA workloads and
    Mesa D3D12 desktop acceleration.

    Differs from the original oneclick-gpu-pv: no WSL distro required.
    Drivers are taken directly from the host:
      - C:\Windows\System32\lxss\lib          (WSL driver library, populated by the host NVIDIA driver)
      - C:\Program Files\WSL\lib
      - C:\Windows\System32\DriverStore\FileRepository\nv_dispi.inf_amd64_*
    The kernel module is built from staralt/dxgkrnl-dkms (auto-picks branch
    5.15 / 6.6 / 6.18 based on the running kernel).

    -Stage Env also deploys the four Mesa/D3D12 variables into every place they are
    needed, from one source of truth (see NOTES), as an idempotent marker block.

.PARAMETER VMName
    Target Hyper-V VM name. If omitted, a CLI numbered picker is shown (no GUI).

.PARAMETER GuestUser
    SSH user on the guest (with sudo). Default: ubuntu.

.PARAMETER GuestIP
    Guest IP (host can reach it directly). Default: 10.0.0.5.

.PARAMETER GuestPort
    SSH port on the guest. Default 22. Set it when reaching the guest through a
    port-forward instead of the LAN - e.g. -GuestIP myguest.example.com -GuestPort 2222 lets the
    guest-side stages (Ssh / Drivers / Guest / Env / Verify) run from anywhere.

.PARAMETER Stage
    Pipeline stage: All / GpuPv / Drivers / Guest / Env / Verify / Undo / Ssh. Default: All.
    Env deploys the guest-side GPU-PV environment variables (see NOTES); Verify prints a
    per-chain health check of them plus the D3D12/VAAPI/Vulkan probes.

.PARAMETER Gpu
    One or more partitionable GPUs to attach, by fuzzy name match. If omitted and the
    host has more than one partitionable GPU, a CLI numbered picker is shown. With
    -Force, all partitionable GPUs are attached automatically.

.PARAMETER DesktopRendering
    How the xrdp desktop session renders: Software (default) or Gpu.
    Software pins GALLIUM_DRIVER=llvmpipe + MESA_LOADER_DRIVER_OVERRIDE=swrast in
    /etc/xrdp/startwm.sh. Rationale: the xorgxrdp framebuffer lives in CPU memory, so a
    GPU-composited desktop has to read every frame back across the VMbus before xrdp can
    encode it - pure overhead for a drag-heavy workload. Cost: ~2x slower if that desktop
    also runs heavy GPU apps. Gpu removes the override, so the session inherits the
    d3d12 pair from /etc/environment.

.PARAMETER DesktopApp
    .desktop file name(s) in /usr/share/applications to clone into the user's profile with
    the GPU env prefix on Exec= (so the dock app itself still gets the GPU, even while the
    desktop session renders in software). Example: -DesktopApp 'com.microsoft.Edge.desktop'.
    Omit to skip.

.PARAMETER Force
    Skip interactive prompts; auto-select the only VM / single GPU.

.EXAMPLE
    .\ubuntu-gpu-pv.ps1
.EXAMPLE
    .\ubuntu-gpu-pv.ps1 -VMName MyGuestVM -GuestIP 10.0.0.5 -Force
.EXAMPLE
    .\ubuntu-gpu-pv.ps1 -Stage Env -VMName MyGuestVM
.EXAMPLE
    .\ubuntu-gpu-pv.ps1 -Stage Env -VMName MyGuestVM -DesktopApp 'com.microsoft.Edge.desktop'
.EXAMPLE
    .\ubuntu-gpu-pv.ps1 -Stage Env -VMName MyGuestVM -DesktopRendering Gpu
.EXAMPLE
    .\ubuntu-gpu-pv.ps1 -Stage Env -GuestIP myguest.example.com -GuestPort 2222
.EXAMPLE
    .\ubuntu-gpu-pv.ps1 -Stage Verify
.EXAMPLE
    .\ubuntu-gpu-pv.ps1 -Stage GpuPv -Gpu "discrete GPU"
.EXAMPLE
    .\ubuntu-gpu-pv.ps1 -Stage Undo
.EXAMPLE
    .\ubuntu-gpu-pv.ps1 -Stage Ssh

.NOTES
    Adapted from the staralt/dxgkrnl-dkms and ad1107 tutorials.
    Community / experimental. Any of: Windows update, NVIDIA driver bump,
    distro upgrade may break it. Do NOT install an ordinary nvidia-driver-*
    package inside the guest (it conflicts with the bridged NVIDIA libs).

    Guest environment variables (-Stage Env) - four variables, one source of truth
    ($GpuEnv / $SwEnv below), deployed by marker block so re-running is a no-op:

        GALLIUM_DRIVER                   d3d12     <- the driver switch
        MESA_LOADER_DRIVER_OVERRIDE      d3d12
        MESA_D3D12_DEFAULT_ADAPTER_NAME  NVIDIA     <- which GPU
        LIBVA_DRIVER_NAME                d3d12

    Scope matters, and the four scopes are NOT interchangeable:

        /etc/environment                  PAM (pam_env readenv=1) -> SSH sessions + systemd services
        ~/.zshenv                         terminal started inside the desktop
        /etc/xrdp/startwm.sh              the desktop session itself (llvmpipe/swrast by default)
        ~/.local/share/applications/*.desktop   dock apps (env prefix on Exec=)

    Two rules that cost people hours:

      1. GALLIUM_DRIVER is what selects the driver, and leaving it UNSET is what makes Mesa
         fall back to llvmpipe - not "missing half of a pair". Measured on this guest
         (Mesa 25.2, env -i): unset -> llvmpipe, d3d12 -> GPU, llvmpipe -> software;
         MESA_LOADER_DRIVER_OVERRIDE was inert in all four combinations, and
         MESA_D3D12_DEFAULT_ADAPTER_NAME is what keeps d3d12 off the wrong GPU
         (without it the guest lands on the integrated GPU, not the discrete GPU).
      2. Never export LD_LIBRARY_PATH=/usr/lib/wsl/lib. -Stage Guest already writes
         /etc/ld.so.conf.d/ld.wsl.conf + ldconfig, which covers CUDA/nvidia-smi. Adding
         LD_LIBRARY_PATH on top only shadows system libraries and poisons GNOME/X11.
         (/etc/profile.d is also the wrong scope - the graphical session never reads it.)

    Elevation: only the Hyper-V stages (All / GpuPv / Undo) need an elevated PowerShell
    and -VMName. Ssh / Drivers / Guest / Env / Verify are guest-side (ssh + scp) and run
    from a normal shell.
#>

[CmdletBinding()]
param(
    [string]$VMName,
    [string]$GuestUser = 'ubuntu',
    [string]$GuestIP   = '10.0.0.5',
    [int]$GuestPort    = 22,
    [ValidateSet('All', 'GpuPv', 'Drivers', 'Guest', 'Env', 'Verify', 'Undo', 'Ssh')]
    [string]$Stage     = 'All',
    [string[]]$Gpu     = @(),
    [ValidateSet('Software', 'Gpu')]
    [string]$DesktopRendering = 'Software',
    [string[]]$DesktopApp = @(),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Guest-side stages (Ssh / Drivers / Guest / Env / Verify) reach the guest over SSH, and
# that does not have to be the LAN address: any routable "host -p port" works, e.g.
# -GuestIP myguest.example.com -GuestPort 2222 through a port-forward, which is how you run the
# env stage from outside the house. ssh takes -p, scp takes -P - hence two arrays.
$SshOpts = @('-o', 'StrictHostKeyChecking=accept-new')
$ScpOpts = @('-o', 'StrictHostKeyChecking=accept-new')
if ($GuestPort -ne 22) {
    $SshOpts += @('-p', "$GuestPort")
    $ScpOpts += @('-P', "$GuestPort")
}


# ============================ Guest environment variables ============================
# Single source of truth for the GPU-PV Mesa/D3D12 variables. Everything below
# (/etc/environment, ~/.zshenv, startwm.sh, the .desktop prefix and the Verify probes)
# renders from these two tables - so a variable can never be missing in one place only.
#
# What each variable actually does (measured on Mesa 25.2, Ubuntu 24.04 guest, env -i):
#   GALLIUM_DRIVER                   the driver selector: d3d12 = GPU, llvmpipe = software,
#                                    UNSET = Mesa default (which is llvmpipe on a GPU-PV guest).
#                                    VA-API needs d3d12 here too, not just LIBVA_DRIVER_NAME.
#   MESA_D3D12_DEFAULT_ADAPTER_NAME  picks WHICH GPU the d3d12 driver drives. Without it
#                                    d3d12 can silently land on another adapter - on this
#                                    host the integrated GPU instead of the discrete GPU.
#   MESA_LOADER_DRIVER_OVERRIDE      inert for GL, but LOAD-BEARING for VA-API: only 'vgem'
#                                    initialises the VA d3d12 frontend (it binds the vgem
#                                    DRM device). 'd3d12' and unset both die with
#                                    "d3d12_drv_video.so init failed / resource allocation
#                                    failed". Requires vgem to actually be loaded - see the
#                                    Env/Verify stages. This is the ingredient the upstream
#                                    README always had and that is easy to dismiss as folklore.
#   LIBVA_DRIVER_NAME                VA-API backend selection (d3d12_drv_video.so).
#
# Hardware video decoding therefore needs GALLIUM_DRIVER=d3d12 as well, which is why the
# software-rendered desktop session (startwm.sh: llvmpipe) cannot do VA-API - apps that want
# it must opt in per app (-DesktopApp) or from a terminal (~/.zshenv).
$GpuEnv = [ordered]@{
    GALLIUM_DRIVER                  = 'd3d12'
    MESA_LOADER_DRIVER_OVERRIDE     = 'vgem'
    MESA_D3D12_DEFAULT_ADAPTER_NAME = 'NVIDIA'
    LIBVA_DRIVER_NAME               = 'd3d12'
}
# Desktop session override: software rendering. The xorgxrdp framebuffer is in CPU
# memory, so a GPU-composited desktop pays a VMbus read-back per frame before xrdp can
# encode - pure overhead for drag-heavy work. Measured faster than d3d12 on this setup.
$SwEnv = [ordered]@{
    GALLIUM_DRIVER              = 'llvmpipe'
    MESA_LOADER_DRIVER_OVERRIDE = 'swrast'
}

$envInline   = (($GpuEnv.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')
$envShExport = (($GpuEnv.GetEnumerator() | ForEach-Object { "export $($_.Key)=$($_.Value)" }) -join "`n")
$envPamLines = (($GpuEnv.GetEnumerator() | ForEach-Object { "$($_.Key)=`"$($_.Value)`"" }) -join "`n")
$swShExport  = (($SwEnv.GetEnumerator() | ForEach-Object { "export $($_.Key)=$($_.Value)" }) -join "`n")
$envAppList  = ($DesktopApp -join ' ')
$envKeyRegex = '^(export[[:space:]]+)?(' +
    (((@($GpuEnv.Keys) + @($SwEnv.Keys)) | Select-Object -Unique) -join '|') + ')='

# Block bodies. The guest script adds the BEGIN/END markers; comments live here so there
# is exactly one copy of the reasoning, next to the values it explains.
$envZshBlock = @"
# 从【桌面终端】里启动的程序继承的是 gnome-shell 的环境，而桌面会话被 startwm.sh
# 压成了 llvmpipe/swrast —— 这里覆盖回 d3d12，让终端里起的图形程序也走 GPU。
$envShExport
# 不在 .zshenv 里 export LD_LIBRARY_PATH（会遮蔽系统库、污染 GNOME/X11）
"@

$envStartwmBlock = @"
# GPU-PV：桌面会话压回软件渲染。xrdp 的 shadow framebuffer 在 CPU 内存里，GPU 合成
# 要跨 VMbus 把每帧读回来才能编码 —— 对拖窗这种高频小批次负载是纯开销（实测比 d3d12 流畅）。
# 要改回 GPU：-DesktopRendering Gpu（会摘掉本块，桌面转而继承 /etc/environment 的 d3d12）。
$swShExport
"@


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

function Test-IsAdmin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Prerequisites {
    param([switch]$NeedsHyperV)

    Step 'Prerequisites'

    if ($NeedsHyperV) {
        if (-not (Test-IsAdmin)) {
            throw "Stage '$Stage' touches Hyper-V (Get-VM / Set-VM). Re-run it from an elevated PowerShell."
        }
        if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
            throw 'Get-VM not found. Please enable the Hyper-V management tools.'
        }
        Ok 'Hyper-V module available (elevated)'
    }
    else {
        Ok "Stage '$Stage' is guest-side only - Hyper-V and elevation not required"
    }

    foreach ($cmd in 'ssh', 'scp') {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            throw "$cmd not found. Please install the 'OpenSSH Client' optional feature."
        }
    }
    Ok 'OpenSSH Client available'

    $lxss = 'C:\Windows\System32\lxss\lib'
    if (Test-Path $lxss) { Ok "Driver library present: $lxss" }
    else                 { Warn "Missing $lxss - the host NVIDIA driver may not have selected the WSL component." }
}


# ============================ VM picker ============================

function Resolve-VM {
    param([string]$Name)

    if ($Name) {
        $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
        if (-not $vm) { throw "VM '$Name' not found" }
        return $vm
    }

    $vms = @(Get-VM | Sort-Object Name)
    if ($vms.Count -eq 0) { throw 'No Hyper-V VMs on this host' }

    if ($vms.Count -eq 1 -and $Force) {
        Ok "Force mode: auto-selected the only VM: $($vms[0].Name)"
        return $vms[0]
    }

    Write-Host ''
    Write-Host '  Available VMs:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $vms.Count; $i++) {
        Write-Host ('    [{0,2}] {1}  ({2})' -f ($i + 1), $vms[$i].Name, $vms[$i].State)
    }
    Write-Host ''
    $choice = Read-Host "  Pick a number (1-$($vms.Count)) or type a VM name (Enter to cancel)"

    if ([string]::IsNullOrWhiteSpace($choice)) { throw 'No VM selected' }

    if ($choice -match '^\d+$' -and 1..$vms.Count -contains [int]$choice) {
        return $vms[[int]$choice - 1]
    }

    $exact = Get-VM -Name $choice -ErrorAction SilentlyContinue
    if ($exact) { return $exact }

    $fuzzy = $vms | Where-Object { $_.Name -like "*$choice*" } | Select-Object -First 1
    if ($fuzzy) {
        Warn "Fuzzy match: $($fuzzy.Name)"
        return $fuzzy
    }

    throw "No VM matching '$choice'"
}


# ============================ Stage 1 / Host GPU-PV ============================

function Stop-VmIfRunning {
    param([string]$Name)
    $vm = Get-VM -Name $Name
    if ($vm.State -eq 'Off') { return }
    Warn "$Name is currently $($vm.State), needs to be off first"
    if (-not (Confirm "Power off $Name now?")) { throw 'Cancelled' }
    Stop-VM -Name $Name -Force
    Start-Sleep -Seconds 5
    Ok "$Name powered off"
}

function Invoke-GpuPvSetup {
    param([string]$Name, [string[]]$Gpu = @())

    Step "Stage 1 / Host GPU-PV for $Name"
    Stop-VmIfRunning $Name

    Remove-VMGpuPartitionAdapter -VMName $Name -ErrorAction SilentlyContinue
    Ok 'Cleared any old GPU partition adapter'

    $gpus = @(Get-VMHostPartitionableGpu)
    if ($gpus.Count -eq 0) {
        throw 'No partitionable GPU on the host, or the GPU does not support GPU-PV.'
    }

    # ----- Pick GPU(s) -----
    $selectedIdx = @()

    if ($Gpu.Count -gt 0) {
        # -Gpu parameter overrides: fuzzy match each name against the available list
        foreach ($gn in $Gpu) {
            $hit = -1
            for ($i = 0; $i -lt $gpus.Count; $i++) {
                if ($gpus[$i].Name -like "*$gn*") { $hit = $i; break }
            }
            if ($hit -lt 0) {
                throw "GPU '$gn' not found. Available names:`n$($gpus | ForEach-Object { '  - ' + $_.Name } | Out-String)"
            }
            $selectedIdx += $hit
        }
        Write-Host "  -Gpu 指定: $($Gpu -join ', ')"
    }
    elseif ($gpus.Count -eq 1 -or $Force) {
        $selectedIdx = @(0..($gpus.Count - 1))
        Write-Host "  Force / single GPU mode: auto-selected all $($gpus.Count) GPU(s)"
    }
    else {
        Write-Host "  Available partitionable GPUs:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $gpus.Count; $i++) {
            Write-Host ('    [{0,2}] {1}' -f ($i + 1), $gpus[$i].Name)
        }
        Write-Host "    [A] All"
        $pick = Read-Host "  Pick GPU(s) [1-$($gpus.Count), comma-separated like 1,3, or A]"
        if ([string]::IsNullOrWhiteSpace($pick) -or $pick -eq 'A' -or $pick -eq 'a') {
            $selectedIdx = @(0..($gpus.Count - 1))
        }
        elseif ($pick -match '^\d+(,\d+)*$') {
            $selectedIdx = @($pick.Split(',') | ForEach-Object { [int]$_ - 1 })
        }
        else {
            throw "Invalid selection: '$pick'"
        }
    }

    foreach ($idx in $selectedIdx) {
        $g = $gpus[$idx]
        Write-Host "  Adding GPU partition adapter: $($g.Name)"
        Add-VMGpuPartitionAdapter -VMName $Name -InstancePath $g.Name
    }
    Ok "Added $($selectedIdx.Count) GPU partition adapter(s)"

    Set-VMGpuPartitionAdapter -VMName $Name `
        -MinPartitionVRAM    1 -MaxPartitionVRAM    900000000            -OptimalPartitionVRAM    900000000 `
        -MinPartitionEncode  1 -MaxPartitionEncode  16602000000000000000 -OptimalPartitionEncode  16602000000000000000 `
        -MinPartitionDecode  1 -MaxPartitionDecode  900000000            -OptimalPartitionDecode  900000000 `
        -MinPartitionCompute 1 -MaxPartitionCompute 900000000            -OptimalPartitionCompute 900000000
    Ok 'Partition resource quotas set'

    Set-VM -VMName $Name -GuestControlledCacheTypes $true `
                       -LowMemoryMappedIoSpace   1Gb `
                       -HighMemoryMappedIoSpace  32GB
    Ok 'MMIO space + cache types set'

    Start-VM -Name $Name
    Ok 'VM started'
}


# ============================ Wait for guest online ============================

function Wait-GuestOnline {
    param([string]$IP, [int]$Port = 22, [int]$TimeoutSec = 240)

    Write-Host "  Waiting for ${IP}:${Port} SSH (up to ${TimeoutSec} sec)..."
    $deadline = (Get-Date).AddSeconds($TimeoutSec)

    while ((Get-Date) -lt $deadline) {
        if (Test-NetConnection -ComputerName $IP -Port $Port -WarningAction SilentlyContinue -InformationLevel Quiet) {
            Ok 'SSH is ready'
            return
        }
        Start-Sleep -Seconds 5
    }
    throw "Timed out waiting for SSH (${TimeoutSec} sec)"
}


# ============================ SSH diagnostics ============================

function Test-SshSetup {
    param([string]$User, [string]$IP)

    Step "SSH diagnostics: $User@$IP"

    # 1) Network layer
    $nc = Test-NetConnection -ComputerName $IP -Port $GuestPort -WarningAction SilentlyContinue
    if (-not $nc.TcpTestSucceeded) {
        Err "${IP}:${GuestPort} unreachable at the network layer"
        throw @"
  1) Is the guest powered on? (check the Hyper-V console / RDP into it)
  2) Is the SSH service running inside the guest?
       (RDP in) systemctl is-active sshd
       If not installed: sudo apt install openssh-server
  3) Are the host and guest on the same subnet?
       Run ipconfig and compare the vEthernet(bridge) IP with $IP
  4) Firewall?
       New-NetFirewallRule -DisplayName "SSH" -Direction Inbound -LocalPort $GuestPort -Protocol TCP -Action Allow
"@
    }
    Ok "${IP}:${GuestPort} TCP reachable (resolved to $($nc.RemoteAddress))"

    # 2) Local private key
    $sshDir = "$env:USERPROFILE\.ssh"
    $privKeys = @(Get-ChildItem $sshDir -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(id_rsa|id_ed25519|id_ecdsa|id_dsa)$' -and -not $_.PSIsContainer } |
        Select-Object -ExpandProperty Name)
    if (-not $privKeys) {
        Err "No standard private key found under $sshDir (id_ed25519 / id_rsa etc.)"
        throw @"
  Quick fix (run inside PowerShell):

    # 1) Generate an ed25519 key (press Enter to skip the passphrase)
    ssh-keygen -t ed25519 -f $sshDir\id_ed25519

    # 2) Push the public key for the first time (you'll be prompted for the password once)
    Get-Content $sshDir\id_ed25519.pub | ssh $User@$IP `
      "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

    # 3) Verify: ssh $User@$IP whoami  -> should print $User without asking for a password
"@
    }
    Ok "Found private key(s): $($privKeys -join ', ')"

    # 3) Actual login test (BatchMode forces key-only auth)
    #    Must go through "${User}@${IP}" - without the user, ssh would try the current
    #    Windows account on the guest and fail with Permission denied (publickey).
    $sshOut = ssh @SshOpts -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=8 "${User}@${IP}" 'echo SshOk' 2>&1
    if ($LASTEXITCODE -eq 0 -and ($sshOut -match 'SshOk')) {
        Ok 'SSH key authentication succeeded, password-less'
        return
    }

    Err "SSH login failed. Raw output: $sshOut"

    if ($sshOut -match 'Permission denied \(publickey') {
        $help = @"
  $User@$IP rejected your public key. The three most common reasons:

  (a) The guest's ~/.ssh/authorized_keys does not contain your public key.
      Fix:
        Get-Content $sshDir\id_ed25519.pub | ssh $User@$IP `
          "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

  (b) The guest sshd disabled public-key authentication.
      Fix (inside the guest):
        sudo sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
        sudo systemctl restart sshd

  (c) The ~/.ssh directory permissions are wrong.
      Fix (inside the guest):
        chmod 700 ~/.ssh
        chmod 600 ~/.ssh/authorized_keys

  Verify: ssh $User@$IP whoami   -> should print $User directly
"@
    } elseif ($sshOut -match 'Permission denied') {
        $help = @"
  Authentication was rejected without specifying whether it was key or password.
  Check the guest sshd log:
      sudo journalctl -u sshd -n 30
  Most common case: the guest has 'PasswordAuthentication no' AND no usable key. Use one of the three fixes above.
"@
    } elseif ($sshOut -match 'Connection refused') {
        $help = 'Guest SSH is not running. Inside the guest: sudo systemctl start sshd'
    } elseif ($sshOut -match 'Connection (timed out|reset)') {
        $help = @"
  Network-layer failure. Check:
    Test-NetConnection -ComputerName $IP -Port $GuestPort
    (RDP in) sudo ss -tln | grep :22
"@
    } elseif ($sshOut -match 'No route') {
        $help = "Host and guest are not on the same subnet. Check the vEthernet(bridge) subnet with ipconfig."
    } elseif ($sshOut -match 'Host key verification failed') {
        $help = @"
  The guest was reinstalled and the fingerprint in your known_hosts is stale.
  Fix: ssh-keygen -R $IP
  Then reconnect - you'll be prompted to accept the new fingerprint (type yes).
"@
    } elseif ($sshOut -match 'Could not resolve hostname') {
        $help = "Hostname $IP cannot be resolved. Use the IP directly, or fix DNS."
    } elseif ($sshOut -match 'REMOTE HOST IDENTIFICATION HAS CHANGED') {
        $help = @"
  The guest fingerprint changed (MITM or reinstall).
  Fix: ssh-keygen -R $IP
"@
    } else {
        $help = "Unrecognized error. The guest disk may be full, systemd may be wedged, or sshd may have crashed. RDP in and inspect: sudo journalctl -u sshd -n 50"
    }

    throw "SSH cannot log in to $User@$IP.`n`n$help"
}


# ============================ Stage 2 / Copy drivers ============================

function Get-DriverStorePaths {
    $paths = (Get-CimInstance Win32_VideoController -Property *).InstalledDisplayDrivers |
        Select-String 'C:\\Windows\\System32\\DriverStore\\FileRepository\\[a-zA-Z0-9\\._]+\\' |
        ForEach-Object { $_.Matches.Value.TrimEnd('\') } |
        Select-Object -Unique

    if (-not $paths) { throw 'No NVIDIA driver directory found in DriverStore - cannot copy drivers.' }
    return $paths
}

function Copy-DriverFiles {
    param([string]$Name, [string]$User, [string]$IP)

    Step "Stage 2 / Copy GPU drivers -> $User@$IP"

    $storeDirs = @(Get-DriverStorePaths)
    Write-Host '  Found the following driver directories:'
    $storeDirs | ForEach-Object { Write-Host "    $_" }

    $lxss   = 'C:\Windows\System32\lxss\lib'
    $wslLib = 'C:\Program Files\WSL\lib'
    foreach ($p in $lxss, $wslLib) {
        if (Test-Path $p) { Ok "Present: $p" } else { Warn "Missing: $p" }
    }

    & ssh @SshOpts "${User}@${IP}" 'mkdir -p ~/wsl/lib ~/wsl/drivers'
    foreach ($d in $storeDirs) {
        Write-Host "  scp $d ..."
        & scp -r @ScpOpts $d "${User}@${IP}:~/wsl/drivers/"
    }
    if (Test-Path $lxss)   { & scp -r @ScpOpts $lxss   "${User}@${IP}:~/wsl/lib/" }
    if (Test-Path $wslLib) { & scp -r @ScpOpts $wslLib "${User}@${IP}:~/wsl/lib/" }

    Ok 'Drivers copied'
}


# ============================ Stage 3 / Guest installation ============================

$guestSetupBash = @'
#!/bin/bash
set -euo pipefail

# Resolve the real user's home directory (this bash runs via sudo, so $HOME is /root by default).
if [ -n "${SUDO_USER:-}" ]; then
    UHOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
    UHOME="$HOME"
fi
echo ">>> User home dir: $UHOME"

echo ""
echo ">>> Guest environment overview"
echo "  Kernel:                 $(uname -r)"
echo "  Arch:                   $(uname -m)"
echo "  Distro:                 $(. /etc/os-release && echo "$PRETTY_NAME")"
echo "  /usr/lib/wsl existing:   $(ls /usr/lib/wsl/ 2>/dev/null | wc -l) entries"
echo "  hv_pci vmbus nodes:      $(ls /sys/bus/vmbus/drivers/hv_pci/ 2>/dev/null | wc -l) entries"

echo ""
echo ">>> [1/4] Install dxgkrnl (install.sh auto-picks branch based on kernel)"
echo "      5.15.x   -> linux-msft-wsl-5.15.y   (patches 0001 + 0002-multi-kernel + 0003-fix-gpadl)"
echo "      6.6-6.17 -> linux-msft-wsl-6.6.y    (patches 0001 + 0002-Fix-eventfd + 0003-task_comm + 0004-timer + 0005-pointer + 0006-mmap)"
echo "      6.18+    -> linux-msft-wsl-6.18.y   (patches 0001)"
echo "      Current kernel $(uname -r) will be routed automatically."

# Force HTTP proxy for curl / git / apt (raw.githubusercontent.com + microsoft kernel need it)
# Note: VM-side persistence (git config http.proxy, /etc/sudoers.d/99-gpupv-proxy env_keep,
# ~/.bashrc export) is already in place. We only need to set PROXY_URL here so the bash
# subprocess below has the proxy in env, which sudo will then inherit via the sudoers drop-in.
PROXY_URL="http://proxy.example.com:3128"
NO_PROXY="localhost,127.0.0.0/8,192.168.0.0/16,10.0.0.0/8,*.local"
export http_proxy="$PROXY_URL"
export https_proxy="$PROXY_URL"
export HTTP_PROXY="$PROXY_URL"
export HTTPS_PROXY="$PROXY_URL"
export no_proxy="$NO_PROXY"
export NO_PROXY="$NO_PROXY"
echo "  Proxy: $PROXY_URL"

# Pull install.sh locally, then patch two things before running:
#   1. git clone gets --filter=blob:none (microsoft/WSL2-Linux-Kernel is huge, breaks through proxies)
#   2. patch URLs go through raw.githubusercontent.com (adds retry + timeouts)
curl -fsSL --max-time 60 --retry 5 --proxy "$PROXY_URL" \
    https://raw.githubusercontent.com/staralt/dxgkrnl-dkms/main/install.sh -o /tmp/install.sh
chmod +x /tmp/install.sh
sed -i 's|git clone --branch=|git clone --filter=blob:none --branch=|'   /tmp/install.sh
sed -i 's|https://content.staralt.dev/dxgkrnl-dkms/main|https://raw.githubusercontent.com/staralt/dxgkrnl-dkms/main|g' /tmp/install.sh
# Force every curl inside install.sh to use the proxy too (defense in depth against
# sudo env_reset stripping http_proxy). Use double quotes so bash expands $PROXY_URL
# at substitution time -- install.sh doesn't see PROXY_URL when it runs.
sed -i "s|curl -fsSL|curl -fsSL --proxy ${PROXY_URL}|g" /tmp/install.sh
sudo /tmp/install.sh

echo ""
echo ">>> [2/4] Pre-flight checks"
SRC_LIB="$UHOME/wsl/lib/lib"
SRC_DRIVERS="$UHOME/wsl/drivers"
KVER="$(uname -r)"

if [ ! -d "$SRC_LIB" ]; then
    echo "  [X] $SRC_LIB does not exist - Stage Drivers never scp'd the lxss driver lib"
    echo "      Fix: ./ubuntu-gpu-pv.ps1 -Stage Drivers -VMName \"<vmname>\""
    exit 1
fi

SO_OK="$(find $SRC_LIB -maxdepth 1 -name '*.so*' | wc -l)"
DRV_COUNT="$(ls $SRC_DRIVERS 2>/dev/null | wc -l)"

echo "  Kernel:                       $KVER"
echo "  Source $SRC_LIB:        $(ls $SRC_LIB 2>/dev/null | wc -l) entries (of which $SO_OK .so)"
echo "  Source $SRC_DRIVERS:  $DRV_COUNT entries"
echo "  /usr/lib/wsl existing:        $(ls /usr/lib/wsl/ 2>/dev/null | wc -l) entries (about to be wiped by rm -rf)"

if [ "$SO_OK" -lt 10 ]; then
    echo "  [X] Source lib only has $SO_OK .so files - expected >=21 (libcuda, libd3d12core, libdxcore, nvidia-smi, ...)"
    echo "      Stage Drivers did not complete"
    exit 1
fi
if [ "$DRV_COUNT" -lt 100 ]; then
    echo "  [!] DriverStore directory count is low (expected 200+); drivers may be incomplete"
fi

echo "  dkms status:"
sudo dkms status 2>/dev/null | grep -E '^(dxgkrnl|vgem)' | head -5 | sed 's/^/      /'

if sudo dkms status 2>/dev/null | grep -E '^dxgkrnl.*installed.*'"$KVER" > /dev/null; then
    echo "  OK: dxgkrnl already installed for current kernel $KVER"
elif sudo dkms status 2>/dev/null | grep -E '^dxgkrnl' > /dev/null; then
    echo "  [!] dxgkrnl exists but for a different kernel - [1/4] install.sh will rebuild for $KVER"
else
    echo "  [!] dxgkrnl is not in the dkms tree - if [1/4] did not succeed, no loadable module will be available after this stage"
fi

echo ""
echo ">>> [2/4] Deploy drivers to /usr/lib/wsl"
rm -rf /usr/lib/wsl
mkdir -p /usr/lib/wsl/lib /usr/lib/wsl/drivers
cp -a "$UHOME/wsl/lib/lib/." /usr/lib/wsl/lib/    # flatten (no extra lib/ nesting)
cp -a "$UHOME/wsl/drivers/." /usr/lib/wsl/drivers/

ln -sf /usr/lib/wsl/lib/libd3d12core.so /usr/lib/wsl/lib/libD3D12Core.so || true
ln -sf /usr/lib/wsl/lib/libd3d12.so     /usr/lib/wsl/lib/libD3D12.so     || true

# chown first to take ownership, otherwise the source-side drwx------ lets root traverse-fail
chown -R root:root /usr/lib/wsl
chmod -R 555 /usr/lib/wsl/drivers/
chmod -R 755 /usr/lib/wsl/lib/
chmod +x /usr/lib/wsl/lib/nvidia-smi /usr/lib/wsl/lib/nvidia-ngx-updater 2>/dev/null || true

echo "/usr/lib/wsl/lib" > /etc/ld.so.conf.d/ld.wsl.conf
ldconfig

echo ""
echo ">>> [3/4] Load vgem (graphics acceleration)"
modprobe vgem || echo "  vgem load failed (non-fatal)"

sudo mkdir -p /etc/modules-load.d
{ echo "dxgkrnl"; echo "vgem"; } | sudo tee /etc/modules-load.d/gpupv.conf > /dev/null
echo "  Wrote /etc/modules-load.d/gpupv.conf (loads on every boot)"

echo ""
echo ">>> [4/4] Self-check"
echo "--- /dev/dxg ---"
ls -l /dev/dxg 2>/dev/null || echo "  Missing: dxgkrnl may not have loaded"
echo "--- nvidia-smi ---"
LD_LIBRARY_PATH=/usr/lib/wsl/lib /usr/lib/wsl/lib/nvidia-smi 2>&1 | head -15 \
    || echo "  Failed: check whether the driver files were copied correctly"
echo ""
echo "DONE"
'@

function Invoke-GuestSetup {
    param([string]$User, [string]$IP)

    Step 'Stage 3 / Guest installation'

    $tmp = Join-Path $env:TEMP 'gpupv-guest-setup.sh'
    [IO.File]::WriteAllText($tmp, ($guestSetupBash -replace "`r`n", "`n"))

    Write-Host '  Uploading the guest install script...'
    & scp @ScpOpts $tmp "${User}@${IP}:~/gpupv-guest-setup.sh"

    Write-Host '  Executing it on the guest (sudo may prompt for a password)...'
    & ssh -t @SshOpts "${User}@${IP}" 'sudo bash ~/gpupv-guest-setup.sh'

    Ok 'Guest configuration complete'
}


# ============================ Stage Env / Guest environment variables ============================

$envSetupBash = @'
#!/bin/bash
set -euo pipefail

# Runs via sudo, so $HOME is /root - resolve the real user's home from SUDO_USER.
if [ -n "${SUDO_USER:-}" ]; then
    UHOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    UUID_="$(id -u "$SUDO_USER")"
    UGID="$(id -g "$SUDO_USER")"
else
    UHOME="$HOME"
    UUID_="$(id -u)"
    UGID="$(id -g)"
fi
echo ">>> User home dir: $UHOME"

BEGIN="# >>> gpupv-env BEGIN (managed by ubuntu-gpu-pv.ps1 - do not edit inside) >>>"
END="# <<< gpupv-env END <<<"
KEYRE='@@KEYRE@@'
STAMP="$(date +%Y%m%d-%H%M%S)"

# Idempotent block writer.
#   upsert_block <file> <append|after-shebang|remove> <root|user>   (block body on stdin)
# Drops the previous managed block, folds any stray unmanaged definitions of the same
# keys into the block (so the script stays the single source of truth), then writes it.
# after-shebang is used for startwm.sh: the vars must be set before the session starts,
# and appending after its final `exit` would silently do nothing.
upsert_block() {
    local file="$1" mode="$2" owner="${3:-root}"
    local block body out

    block="$(mktemp)"
    body="$(mktemp)"
    out="$(mktemp)"

    if [ "$mode" != "remove" ]; then
        { printf '%s\n' "$BEGIN"; cat; printf '%s\n' "$END"; } > "$block"
    fi

    if [ -f "$file" ]; then
        awk -v b="$BEGIN" -v e="$END" -v re="$KEYRE" '
            $0 == b { skip = 1; next }
            $0 == e { skip = 0; next }
            skip    { next }
            $0 ~ re { next }
            { print }
        ' "$file" > "$body"
    else
        : > "$body"
    fi

    case "$mode" in
    append)
        cat "$body" > "$out"
        if [ -s "$block" ]; then cat "$block" >> "$out"; fi
        ;;
    after-shebang)
        if head -1 "$body" | grep -q '^#!'; then
            head -1 "$body" > "$out"
            if [ -s "$block" ]; then cat "$block" >> "$out"; fi
            tail -n +2 "$body" >> "$out"
        else
            if [ -s "$block" ]; then cat "$block" >> "$out"; fi
            cat "$body" >> "$out"
        fi
        ;;
    remove)
        cat "$body" > "$out"
        ;;
    esac

    if [ -f "$file" ] && cmp -s "$out" "$file"; then
        echo "  [=]  $file (unchanged)"
        rm -f "$block" "$body" "$out"
        return 0
    fi

    if [ -f "$file" ]; then cp -a "$file" "$file.bak-$STAMP"; fi
    install -m 0644 "$out" "$file"
    if [ "$owner" = "user" ]; then chown "$UUID_:$UGID" "$file"; else chown root:root "$file"; fi
    rm -f "$block" "$body" "$out"
    echo "  [OK] $file updated"
}

echo ""
echo ">>> [Env 1/4] /etc/environment - PAM (pam_env readenv=1): SSH sessions + systemd services"
upsert_block /etc/environment append root <<'EOF'
@@ENVPAM@@
EOF

echo ""
echo ">>> [Env 2/4] ~/.zshenv - terminal started inside the desktop"
upsert_block "$UHOME/.zshenv" append user <<'EOF'
@@ENVZSH@@
EOF

echo ""
echo ">>> [Env 3/4] /etc/xrdp/startwm.sh - the desktop session only"
if [ "@@DESKTOPMODE@@" = "Software" ]; then
    upsert_block /etc/xrdp/startwm.sh after-shebang root <<'EOF'
@@ENVSTARTWM@@
EOF
    echo "  -> desktop session pinned to llvmpipe/swrast"
else
    upsert_block /etc/xrdp/startwm.sh remove root
    echo "  -> no override; the session inherits d3d12 from /etc/environment"
fi

echo ""
echo ">>> [Env 4/4] dock apps - .desktop clone with the GPU env prefix on Exec="
if [ -z "@@APPS@@" ]; then
    echo "  [--] no -DesktopApp given, skipped"
    echo "       (e.g. -DesktopApp 'com.microsoft.Edge.desktop')"
else
    # Tolerate a comma-joined list too: `powershell -File script.ps1 -DesktopApp a,b`
    # hands the whole thing over as one string.
    APPS="$(printf '%s' "@@APPS@@" | tr ',' ' ')"
    mkdir -p "$UHOME/.local/share/applications"
    for app in $APPS; do
        src="/usr/share/applications/$app"
        dst="$UHOME/.local/share/applications/$app"

        if [ ! -f "$src" ]; then
            echo "  [!]  $app: $src not found, skipped"
            continue
        fi
        if [ ! -f "$dst" ]; then
            cp "$src" "$dst"
            chown "$UUID_:$UGID" "$dst"
        fi
        PREFIX="env @@ENVINLINE@@ "

        if grep -qF "Exec=$PREFIX" "$dst"; then
            echo "  [=]  $app already carries the current values"
            continue
        fi

        cp -a "$dst" "$dst.bak-$STAMP"

        if grep -q '^Exec=env ' "$dst"; then
            # Already prefixed but with stale values (e.g. MESA_LOADER_DRIVER_OVERRIDE was
            # d3d12 before vgem was needed) - swap the whole prefix, don't stack a second one.
            sed -i -E "s|^Exec=env ([A-Za-z_][A-Za-z0-9_]*=[^ ]* )+|Exec=$PREFIX|" "$dst"
            echo "  [OK] $app: prefix refreshed to the current values"
        else
            sed -i "s|^Exec=|Exec=$PREFIX|" "$dst"
            echo "  [OK] $app: Exec= prefixed"
        fi

        chown "$UUID_:$UGID" "$dst"
    done

    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$UHOME/.local/share/applications" 2>/dev/null || true
    fi
fi

echo ""
echo ">>> Self-check"
for f in /etc/environment "$UHOME/.zshenv" /etc/xrdp/startwm.sh; do
    if [ -f "$f" ]; then
        n="$(grep -cE "$KEYRE" "$f" || true)"
        echo "  $f: $n managed definition(s)"
    fi
done

GS="$(pgrep -x gnome-shell 2>/dev/null | head -1 || true)"
if [ -n "$GS" ]; then
    echo "  gnome-shell($GS) currently has (still the old session - log out to pick up changes):"
    tr '\0' '\n' < "/proc/$GS/environ" \
        | grep -E '^(GALLIUM_DRIVER|MESA_LOADER_DRIVER_OVERRIDE)=' | sed 's/^/      /'
fi
echo ""
echo "DONE - environment variables deployed"
'@

function Invoke-EnvSetup {
    param([string]$User, [string]$IP, [string]$Rendering, [string[]]$Apps)

    Step 'Stage Env / Guest environment variables'

    $script = $envSetupBash
    $script = $script.Replace('@@ENVPAM@@',      $envPamLines)
    $script = $script.Replace('@@ENVZSH@@',      $envZshBlock)
    $script = $script.Replace('@@ENVSTARTWM@@',  $envStartwmBlock)
    $script = $script.Replace('@@ENVINLINE@@',   $envInline)
    $script = $script.Replace('@@KEYRE@@',       $envKeyRegex)
    $script = $script.Replace('@@DESKTOPMODE@@', $Rendering)
    $script = $script.Replace('@@APPS@@',        ($Apps -join ' '))

    $tmp = Join-Path $env:TEMP 'gpupv-env-setup.sh'
    [IO.File]::WriteAllText($tmp, ($script -replace "`r`n", "`n"))

    Write-Host '  Uploading the env script...'
    & scp @ScpOpts $tmp "${User}@${IP}:~/gpupv-env-setup.sh"

    Write-Host '  Applying it on the guest (sudo)...'
    & ssh -t @SshOpts "${User}@${IP}" 'sudo bash ~/gpupv-env-setup.sh'

    Ok 'Environment variables deployed'
}


# ============================ Verify ============================

$verifyBash = @'
set -u

# The probes below MUST run with the full variable set: GALLIUM_DRIVER alone makes Mesa
# fall back to llvmpipe silently, so a probe without the matching override would report
# a "pass" for a config that does not actually use D3D12. Same source of truth as Env.
ENV_INLINE='@@ENVINLINE@@'

echo "--- Kernel modules ---"
lsmod 2>/dev/null | grep -E "dxgkrnl|vgem" || echo "  dxgkrnl / vgem not found"

echo
echo "--- /dev/dxg ---"
ls -l /dev/dxg 2>/dev/null || echo "  Missing"

echo
echo "--- /dev/dri ---"
ls -l /dev/dri/ 2>/dev/null || echo "  Missing"

echo
echo "--- nvidia-smi ---"
LD_LIBRARY_PATH=/usr/lib/wsl/lib /usr/lib/wsl/lib/nvidia-smi 2>&1 | head -15 || echo "  Failed"

echo
echo "--- D3D12 renderer (OpenGL) ---"
env $ENV_INLINE eglinfo -B 2>/dev/null | grep -iE "d3d12|device|adapter" | head -8 \
    || echo "  No D3D12: apt install mesa-utils"

echo
echo "--- VAAPI (D3D12 backend) ---"
if ! command -v vainfo >/dev/null 2>&1; then
    echo "  vainfo not installed (apt install mesa-va-drivers vainfo)"
else
    # $ENV_INLINE is exactly the known-good VA recipe (GALLIUM_DRIVER=d3d12 +
    # MESA_LOADER_DRIVER_OVERRIDE=vgem + LIBVA_DRIVER_NAME=d3d12), so this is a real
    # check rather than a formality. It also needs the vgem device to exist - if vgem is
    # blacklisted or not loaded, no VA recipe works (see the health check below).
    VA_CARD="$(ls /dev/dri/card* 2>/dev/null | head -1)"
    VA_ARG=""
    if [ -n "$VA_CARD" ]; then VA_ARG="--display drm --device $VA_CARD"; fi

    VA_OUT="$(env $ENV_INLINE vainfo $VA_ARG 2>&1)"

    if echo "$VA_OUT" | grep -q 'va_openDriver() returns 0'; then
        echo "  [OK]  $(echo "$VA_OUT" | grep -o 'for D3D12 ([^)]*)' | head -1)"
        echo "        decode entrypoints: $(echo "$VA_OUT" | grep -c VLD)   encode entrypoints: $(echo "$VA_OUT" | grep -c Enc)"
    else
        echo "  [!]   VA-API did not initialise:"
        echo "$VA_OUT" | grep -E 'error|failed' | head -3 | sed 's/^/        /'
        if lsmod | grep -q '^vgem'; then
            echo "        -> vgem is loaded, so the three variables matter (all three are needed)"
        else
            echo "        -> vgem is NOT loaded. Load it (sudo modprobe vgem) and make sure no"
            echo "           /etc/modprobe.d/blacklist-vgem.conf exists - VA needs the vgem device."
        fi
    fi
fi

echo
echo "--- Vulkan (D3D12 device) ---"
if command -v vulkaninfo >/dev/null 2>&1; then
    env $ENV_INLINE vulkaninfo --summary 2>&1 \
        | grep -iE "deviceName|apiVersion|driverName" | head -8 | sed 's/^/    /' \
        || echo "  No D3D12 adapter"
    echo "    (llvmpipe here = no D3D12 Vulkan ICD selected; the desktop path is EGL/GL, above)"
else
    echo "  vulkaninfo not installed (apt install vulkan-tools)"
fi

echo
echo "================= Environment health check ================="
echo "  Measured behaviour on this stack (Mesa 25.2, 2026-10-12):"
echo "    GALLIUM_DRIVER                   d3d12 = GPU / llvmpipe = software / UNSET = Mesa"
echo "                                     default, which is llvmpipe on a GPU-PV guest"
echo "    MESA_D3D12_DEFAULT_ADAPTER_NAME  which GPU d3d12 drives; without it Mesa lands on"
echo "                                     another adapter (the integrated GPU here)"
echo "    MESA_LOADER_DRIVER_OVERRIDE      inert for GL, but VA-API only initialises with"
echo "                                     'vgem' (needs the vgem device to exist)"
echo

interpret() {
    local label="$1" gallium="$2" adapter="$3"
    case "${gallium:-}" in
    d3d12)
        if [ -n "${adapter:-}" ]; then
            echo "  [OK]  $label: GPU via d3d12 (adapter preference: $adapter)"
        else
            echo "  [!]   $label: d3d12 but no MESA_D3D12_DEFAULT_ADAPTER_NAME"
            echo "        -> Mesa may drive a different GPU than the one you want"
        fi ;;
    llvmpipe)
        echo "  [OK]  $label: software rendering (GALLIUM_DRIVER=llvmpipe)" ;;
    '')
        echo "  [--]  $label: GALLIUM_DRIVER unset -> Mesa default (llvmpipe here)" ;;
    *)
        echo "  [OK]  $label: GALLIUM_DRIVER=$gallium" ;;
    esac
}

# Last definition wins in both /etc/environment and shell rc files.
read_var() {
    if [ -f "$1" ]; then
        sed -n "s/^\(export[[:space:]]*\)\?$2=//p" "$1" | tr -d '"' | tail -1
    fi
}

echo "[1] /etc/environment        (PAM -> SSH sessions + systemd services)"
interpret "/etc/environment" "$(read_var /etc/environment GALLIUM_DRIVER)" \
                             "$(read_var /etc/environment MESA_D3D12_DEFAULT_ADAPTER_NAME)"

echo "[2] ${HOME}/.zshenv         (terminal started inside the desktop)"
interpret "~/.zshenv" "$(read_var "$HOME/.zshenv" GALLIUM_DRIVER)" \
                      "$(read_var "$HOME/.zshenv" MESA_D3D12_DEFAULT_ADAPTER_NAME)"

echo "[3] /etc/xrdp/startwm.sh    (desktop session override; unset = inherit /etc/environment)"
interpret "startwm.sh" "$(read_var /etc/xrdp/startwm.sh GALLIUM_DRIVER)" \
                       "$(read_var /etc/xrdp/startwm.sh MESA_D3D12_DEFAULT_ADAPTER_NAME)"

echo "[4] live desktop process    (the truth for the current session)"
GS="$(pgrep -x gnome-shell 2>/dev/null | head -1)"
if [ -n "$GS" ]; then
    interpret "gnome-shell($GS)" \
        "$(tr '\0' '\n' < "/proc/$GS/environ" | sed -n 's/^GALLIUM_DRIVER=//p')" \
        "$(tr '\0' '\n' < "/proc/$GS/environ" | sed -n 's/^MESA_D3D12_DEFAULT_ADAPTER_NAME=//p')"
    echo "        /dev/dxg handles held = $(ls -l "/proc/$GS/fd" 2>/dev/null | grep -c dxg) (0 for software)"
else
    echo "  [--]  no gnome-shell running (no desktop session)"
fi

echo "[5] who holds /dev/dxg      (own-user processes only; sudo for the full list)"
DXG_FOUND=0
for pid in $(ls /proc | grep -E '^[0-9]+$'); do
    if ls -l "/proc/$pid/fd" 2>/dev/null | grep -q dxg; then
        echo "        pid $pid  $(cat "/proc/$pid/comm" 2>/dev/null || echo '?')"
        DXG_FOUND=1
    fi
done
if [ "$DXG_FOUND" -eq 0 ]; then echo "        (none)"; fi

echo "[6] vgem device             (VA-API / hardware video needs it to exist)"
if lsmod | grep -q '^vgem'; then
    echo "  [OK]  vgem loaded; nodes: $(ls /dev/dri/card0 /dev/dri/renderD128 2>/dev/null | tr '\n' ' ')"
else
    echo "  [!]   vgem is NOT loaded -> no VA recipe can initialise."
    if [ -f /etc/modprobe.d/blacklist-vgem.conf ]; then
        echo "        blocked by /etc/modprobe.d/blacklist-vgem.conf (remove or rename it)"
    fi
    echo "        load it now: sudo modprobe vgem   (persist via /etc/modules-load.d)"
fi

echo
echo "DONE"
'@

function Test-GpuPv {
    param([string]$User, [string]$IP)

    Step "Stage Verify / $User@$IP"

    $script = $verifyBash.Replace('@@ENVINLINE@@', $envInline)

    $tmp = Join-Path $env:TEMP 'gpupv-verify.sh'
    [IO.File]::WriteAllText($tmp, ($script -replace "`r`n", "`n"))

    & scp @ScpOpts $tmp "${User}@${IP}:~/gpupv-verify.sh"
    & ssh @SshOpts "${User}@${IP}" 'bash ~/gpupv-verify.sh'
}


# ============================ Undo ============================

function Undo-GpuPv {
    param([string]$Name)

    Step "Undo / detach GPU-PV for $Name"
    Stop-VmIfRunning $Name

    Remove-VMGpuPartitionAdapter -VMName $Name -ErrorAction SilentlyContinue
    Ok 'GPU partition adapter removed'

    Warn 'In-guest artifacts are NOT cleaned up by this step - handle them manually if needed:'
    Write-Host '    sudo rm -rf /usr/lib/wsl /etc/ld.so.conf.d/ld.wsl.conf && sudo ldconfig'
    Write-Host '    sudo /usr/lib/wsl/../dxgkrnl-dkms/install.sh clean all   # if install.sh is still around'
    Write-Host '    # -Stage Env 写的受管块（三处，连带 BEGIN/END 标记一起删）：'
    Write-Host '    sudo sed -i "/gpupv-env BEGIN/,/gpupv-env END/d" /etc/environment /etc/xrdp/startwm.sh'
    Write-Host '    sed -i "/gpupv-env BEGIN/,/gpupv-env END/d" ~/.zshenv'
    Write-Host '    # 各文件旁边还留了 .bak-<时间戳> 备份，可直接还原'
}


# ============================ Main flow ============================

# The VM is only needed by the Hyper-V stages (GpuPv / Undo). Guest-side stages
# (Ssh / Drivers / Guest / Env / Verify) talk to the guest over SSH only - resolving
# the VM there would need Hyper-V and a -VMName for no reason.
function Resolve-VmNameIfNeeded {
    if ($Stage -in 'GpuPv', 'Undo', 'All') { return (Resolve-VM $VMName).Name }
    return $null
}

Assert-Prerequisites -NeedsHyperV:($Stage -in 'GpuPv', 'Undo', 'All')
$vmName = Resolve-VmNameIfNeeded

switch ($Stage) {
    'GpuPv'   { Invoke-GpuPvSetup $vmName $Gpu }
    'Ssh'     { Test-SshSetup     $GuestUser $GuestIP }
    'Drivers' {
        Test-SshSetup   $GuestUser $GuestIP
        Copy-DriverFiles $vmName $GuestUser $GuestIP
    }
    'Guest'   {
        Test-SshSetup    $GuestUser $GuestIP
        Invoke-GuestSetup $GuestUser $GuestIP
    }
    'Env'     {
        Test-SshSetup    $GuestUser $GuestIP
        Invoke-EnvSetup   $GuestUser $GuestIP $DesktopRendering $DesktopApp
    }
    'Verify'  {
        Test-SshSetup    $GuestUser $GuestIP
        Test-GpuPv        $GuestUser $GuestIP
    }
    'Undo'    { Undo-GpuPv        $vmName }
    'All'     {
        Invoke-GpuPvSetup $vmName $Gpu
        Wait-GuestOnline  $GuestIP -Port $GuestPort
        Test-SshSetup     $GuestUser $GuestIP
        Copy-DriverFiles  $vmName $GuestUser $GuestIP
        Invoke-GuestSetup $GuestUser $GuestIP
        Invoke-EnvSetup   $GuestUser $GuestIP $DesktopRendering $DesktopApp
        Test-GpuPv        $GuestUser $GuestIP
    }
}

Write-Host ''
Write-Host '============================ All done ============================' -ForegroundColor Green
Write-Host 'Optional follow-up:'
Write-Host '  1) Guest tooling: sudo apt install -y vainfo mesa-utils mesa-vulkan-drivers mesa-va-drivers vulkan-tools'
Write-Host '  2) Environment variables were deployed by -Stage Env (idempotent marker block):'
Write-Host '       /etc/environment      -> d3d12            (PAM: SSH sessions + systemd services)'
Write-Host '       ~/.zshenv             -> d3d12            (terminal inside the desktop)'
Write-Host "       /etc/xrdp/startwm.sh  -> llvmpipe/swrast  (desktop session only; -DesktopRendering Gpu to drop it)"
Write-Host '       ~/.local/share/applications/*.desktop      -> d3d12 (dock apps; -DesktopApp <name.desktop>)'
Write-Host '       Re-run any time: .\ubuntu-gpu-pv.ps1 -Stage Env -VMName <vm>; -Stage Verify to health-check.'
Write-Host '     * Never export LD_LIBRARY_PATH=/usr/lib/wsl/lib: -Stage Guest already writes'
Write-Host '       /etc/ld.so.conf.d/ld.wsl.conf + ldconfig. Adding it on top only shadows system'
Write-Host '       libs and poisons GNOME/X11 - and /etc/profile.d is never read by a GUI session.'
Write-Host '     * GALLIUM_DRIVER is the switch (d3d12 = GPU, llvmpipe = software). Leaving it'
Write-Host '       UNSET is what causes a silent llvmpipe fallback - and d3d12 without'
Write-Host '       MESA_D3D12_DEFAULT_ADAPTER_NAME can drive the wrong GPU (the integrated GPU here).'
Write-Host '     * Hardware video (VA-API) needs THREE things at once: GALLIUM_DRIVER=d3d12,'
Write-Host '       MESA_LOADER_DRIVER_OVERRIDE=vgem, and the vgem device loaded. The software-'
Write-Host '       rendered desktop cannot have it - opt in per app (-DesktopApp) or a terminal.'
Write-Host '  3) Recommended desktop: GNOME on Ubuntu 24.04+. On 22.04 mutter crashes in this stack;'
Write-Host '     use LXQt / Xfce instead, or upgrade the guest to 24.04 where the fix is upstream.'
Write-Host ''
Write-Host 'Undo: .\ubuntu-gpu-pv.ps1 -Stage Undo' -ForegroundColor DarkGray
