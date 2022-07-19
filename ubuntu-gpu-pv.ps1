$vmIpAddr = Read-Host "Input the vm IP address, should be reachable within WSL" 
$userName = Read-Host "Input vm admin user name, should have sudoers group" 

$vmobject = Get-VM | Out-GridView -Title "Select VM to setup GPU-P" -OutputMode Single
$vmName = $vmobject.Name

$dev = Get-PnpDevice -Class Display -Status OK | Out-GridView -Title "Select Card to setup GPU-P" -OutputMode Single

$props = $dev | Get-PnpDeviceProperty
$pnpinf = ($props | where {$_.KeyName -eq "DEVPKEY_Device_DriverInfPath"}).Data
$infsection = ($props | where {$_.KeyName -eq "DEVPKEY_Device_DriverInfSection"}).Data
$cbsinf = (Get-WindowsDriver -Online | where {$_.Driver -eq "$pnpinf"}).OriginalFileName
If (-not $cbsinf) {
	Write-Host "Device not supported: $dev, inf: $pnpinf, cbs: $cbsinf"
	return;
}

$gpuName = $dev.FriendlyName
$path = $dev.InstanceId.replace('\', '#').ToLower()

Stop-VM $vmName
Start-Sleep -m 10000

#Configure GPU for VM
Add-VMGpuPartitionAdapter $vmName -InstancePath "$path"
Set-VM -GuestControlledCacheTypes $true -VMName $vmName
Set-VM -LowMemoryMappedIoSpace 1Gb -VMName $vmName
Set-VM -HighMemoryMappedIoSpace 32GB -VMName $vmName

Start-VM $vmName
Start-Sleep -m 10000

$remoteAddr="$userName@$vmIpAddr"

echo ""
echo "Onclick GPU-PV for Ubuntu: using $remoteAddr"
echo "------------------------"


#Copy drivers
wsl ssh $remoteAddr "sudo -S mkdir -p $(echo /usr/lib/wsl/drivers/)"
wsl scp -r /usr/lib/wsl/lib $remoteAddr\:~
wsl scp -r /usr/lib/wsl/drivers $remoteAddr\:~
wsl ssh $remoteAddr "sudo -S mv ~/lib/* /usr/lib;sudo -S ln -s /lib/libd3d12core.so /lib/libD3D12Core.so;sudo -S mv ~/drivers/* /usr/lib/wsl/drivers"


#Install dxgknrl module
wsl scp -r ./dxgkrnl-dkms.zip $remoteAddr\:~
wsl ssh $remoteAddr "unzip ~/dxgkrnl-dkms.zip"
wsl ssh $remoteAddr "chmod +x ~/dxgkrnl-dkms/install.sh;sudo -S ~/dxgkrnl-dkms/install.sh"

echo "ALL DONE, ENJOY"