#Requires -Version 5.1
#Requires -RunAsAdministrator
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

.PARAMETER VMName
    Target Hyper-V VM name. If omitted, a CLI numbered picker is shown (no GUI).

.PARAMETER GuestUser
    SSH user on the guest (with sudo). Default: ubuntu.

.PARAMETER GuestIP
    Guest IP (host can reach it directly). Default: 10.0.0.5.

.PARAMETER Stage
    Pipeline stage: All / GpuPv / Drivers / Guest / Verify / Undo / Ssh. Default: All.

.PARAMETER Force
    Skip interactive prompts; auto-select the only VM when there is exactly one.

.EXAMPLE
    .\ubuntu-gpu-pv.ps1
.EXAMPLE
    .\ubuntu-gpu-pv.ps1 -VMName MyGuestVM -GuestIP 10.0.0.5 -Force
.EXAMPLE
    .\ubuntu-gpu-pv.ps1 -Stage Verify
.EXAMPLE
    .\ubuntu-gpu-pv.ps1 -Stage Undo
.EXAMPLE
    .\ubuntu-gpu-pv.ps1 -Stage Ssh

.NOTES
    Adapted from the staralt/dxgkrnl-dkms and ad1107 tutorials.
    Community / experimental. Any of: Windows update, NVIDIA driver bump,
    distro upgrade may break it. Do NOT install an ordinary nvidia-driver-*
    package inside the guest (it conflicts with the bridged NVIDIA libs).
#>

[CmdletBinding()]
param(
    [string]$VMName,
    [string]$GuestUser = 'ubuntu',
    [string]$GuestIP   = '10.0.0.5',
    [ValidateSet('All', 'GpuPv', 'Drivers', 'Guest', 'Verify', 'Undo', 'Ssh')]
    [string]$Stage     = 'All',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$SshOpts = @('-o', 'StrictHostKeyChecking=accept-new')


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
        throw 'Get-VM not found. Please enable the Hyper-V management tools.'
    }
    Ok 'Hyper-V module available'

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
    param([string]$Name)

    Step "Stage 1 / Host GPU-PV for $Name"
    Stop-VmIfRunning $Name

    Remove-VMGpuPartitionAdapter -VMName $Name -ErrorAction SilentlyContinue
    Ok 'Cleared any old GPU partition adapter'

    $gpus = @(Get-VMHostPartitionableGpu)
    if ($gpus.Count -eq 0) {
        throw 'No partitionable GPU on the host, or the GPU does not support GPU-PV.'
    }
    foreach ($g in $gpus) {
        Write-Host "  Found partitionable GPU: $($g.Name)"
        Add-VMGpuPartitionAdapter -VMName $Name -InstancePath $g.Name
    }
    Ok "Added $($gpus.Count) GPU partition adapter(s)"

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
    $nc = Test-NetConnection -ComputerName $IP -Port 22 -WarningAction SilentlyContinue
    if (-not $nc.TcpTestSucceeded) {
        Err "$IP:22 unreachable at the network layer"
        throw @"
  1) Is the guest powered on? (check the Hyper-V console / RDP into it)
  2) Is the SSH service running inside the guest?
       (RDP in) systemctl is-active sshd
       If not installed: sudo apt install openssh-server
  3) Are the host and guest on the same subnet?
       Run ipconfig and compare the vEthernet(bridge) IP with $IP
  4) Firewall?
       New-NetFirewallRule -DisplayName "SSH" -Direction Inbound -LocalPort 22 -Protocol TCP -Action Allow
"@
    }
    Ok "$IP:22 TCP reachable (RTT $($nc.NlatRoundTripTime) ms from $($nc.SourceAddress))"

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
    $sshOut = ssh @SshOpts -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=8 $IP 'echo SshOk' 2>&1
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
    Test-NetConnection -ComputerName $IP -Port 22
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
        & scp -r @SshOpts $d "${User}@${IP}:~/wsl/drivers/"
    }
    if (Test-Path $lxss)   { & scp -r @SshOpts $lxss   "${User}@${IP}:~/wsl/lib/" }
    if (Test-Path $wslLib) { & scp -r @SshOpts $wslLib "${User}@${IP}:~/wsl/lib/" }

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

# Hardening git against HTTP proxy long-connection drops
git config --global http.postBuffer 524288000
git config --global http.lowSpeedLimit 1000
git config --global http.lowSpeedTime 600
git config --global http.version HTTP/1.1

# Pull install.sh locally, then patch two things before running:
#   1. git clone gets --filter=blob:none (microsoft/WSL2-Linux-Kernel is huge, breaks through proxies)
#   2. patch URLs go through raw.githubusercontent.com (adds retry + timeouts)
curl -fsSL --max-time 60 --retry 5 \
    https://content.staralt.dev/dxgkrnl-dkms/main/install.sh -o /tmp/install.sh
chmod +x /tmp/install.sh
sed -i 's|git clone --branch=|git clone --filter=blob:none --branch=|'   /tmp/install.sh
sed -i 's|https://content.staralt.dev/dxgkrnl-dkms/main|https://raw.githubusercontent.com/staralt/dxgkrnl-dkms/main|g' /tmp/install.sh
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
    & scp @SshOpts $tmp "${User}@${IP}:~/gpupv-guest-setup.sh"

    Write-Host '  Executing it on the guest (sudo may prompt for a password)...'
    & ssh -t @SshOpts "${User}@${IP}" 'sudo bash ~/gpupv-guest-setup.sh'

    Ok 'Guest configuration complete'
}


# ============================ Verify ============================

$verifyBash = @'
set -u

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
GALLIUM_DRIVER=d3d12 MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA \
    eglinfo -B 2>/dev/null | grep -iE "d3d12|device|adapter" | head -8 \
    || echo "  No D3D12: apt install mesa-utils"

echo
echo "--- VAAPI (D3D12 backend) ---"
if command -v vainfo >/dev/null 2>&1; then
    LIBVA_DRIVER_NAME=d3d12 MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA \
        vainfo 2>/dev/null | sed -n '1,20p' || echo "  vainfo failed"
else
    echo "  vainfo not installed (apt install mesa-va-drivers vainfo)"
fi

echo
echo "--- Vulkan (D3D12 device) ---"
if command -v vulkaninfo >/dev/null 2>&1; then
    MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA vulkaninfo --summary 2>&1 \
        | grep -iE "deviceName|apiVersion|driverName" | head -8 \
        || echo "  No D3D12 adapter"
else
    echo "  vulkaninfo not installed (apt install vulkan-tools)"
fi

echo
echo "DONE"
'@

function Test-GpuPv {
    param([string]$User, [string]$IP)

    Step "Stage 4 / Verify $User@$IP"

    $tmp = Join-Path $env:TEMP 'gpupv-verify.sh'
    [IO.File]::WriteAllText($tmp, ($verifyBash -replace "`r`n", "`n"))

    & scp @SshOpts $tmp "${User}@${IP}:~/gpupv-verify.sh"
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
}


# ============================ Main flow ============================

Assert-Prerequisites
$vmName = (Resolve-VM $VMName).Name

switch ($Stage) {
    'GpuPv'   { Invoke-GpuPvSetup $vmName }
    'Ssh'     { Test-SshSetup     $GuestUser $GuestIP }
    'Drivers' {
        Test-SshSetup   $GuestUser $GuestIP
        Copy-DriverFiles $vmName $GuestUser $GuestIP
    }
    'Guest'   {
        Test-SshSetup    $GuestUser $GuestIP
        Invoke-GuestSetup $GuestUser $GuestIP
    }
    'Verify'  {
        Test-SshSetup    $GuestUser $GuestIP
        Test-GpuPv        $GuestUser $GuestIP
    }
    'Undo'    { Undo-GpuPv        $vmName }
    'All'     {
        Invoke-GpuPvSetup $vmName
        Wait-GuestOnline  $GuestIP
        Test-SshSetup     $GuestUser $GuestIP
        Copy-DriverFiles  $vmName $GuestUser $GuestIP
        Invoke-GuestSetup $GuestUser $GuestIP
        Test-GpuPv        $GuestUser $GuestIP
    }
}

Write-Host ''
Write-Host '============================ All done ============================' -ForegroundColor Green
Write-Host 'Optional follow-up (graphics + desktop):'
Write-Host '  1) On the guest install tooling: sudo apt install -y vainfo mesa-utils mesa-vulkan-drivers mesa-va-drivers vulkan-tools'
Write-Host '  2) Place in /etc/profile.d/gpupv.sh (DO NOT export LD_LIBRARY_PATH here - it poisons GNOME/X11):'
Write-Host '       export GALLIUM_DRIVER=d3d12'
Write-Host '       export MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA'
Write-Host '       export LIBVA_DRIVER_NAME=d3d12'
Write-Host '       export MESA_LOADER_DRIVER_OVERRIDE=vgem'
Write-Host '       export LD_LIBRARY_PATH=/usr/lib/wsl/lib:$LD_LIBRARY_PATH'
Write-Host '  3) Recommended desktop: GNOME on Ubuntu 24.04+. On 22.04 mutter crashes in this stack;'
Write-Host '     use LXQt / Xfce instead, or upgrade the guest to 24.04 where the fix is upstream.'
Write-Host ''
Write-Host 'Undo: .\ubuntu-gpu-pv.ps1 -Stage Undo' -ForegroundColor DarkGray
