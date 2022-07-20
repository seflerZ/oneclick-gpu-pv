# onenclick-gpu-pv
Enable GPU-PV easily

##
GPU Partition is a new Microsoft GPU virtualization technology avaiable in latest Win10 and Win11. However it is not configurable in a easy way( no GUI avaiable). This repository provides scripts for both Windows and Linux to enable GPU-PV easily.

## For Windows 10+
Depending on your system local. If it is English based or zh-CN, just download 'win-gpu-pv.ps1' and execute with Administrator priviledge. Otherwise you should implement your own check label located in the script.

_This script was inspired by [dantmnf](https://gist.github.com/dantmnf/9bf9972c1ad49029cbdc2e40f1b7ac51)_

## For Ubuntu(tested on 20.04 and 22.04)
Downdload the 'ubuntu-gpu-pv.ps1' and 'dxgkrnl-dkms.zip' to Windows host folder. Execute 'ubuntu-gpu-pv.ps1' with Administrator. You must configured WSLg first. That is to say you must have a WSL being able to use the GPU. Due to limitation of SSH, you'll be asked for password many times.

_This script was inspired by [OlfillasOdikno](https://gist.github.com/OlfillasOdikno/f87a4444f00984625558dad053255ace)_

![屏幕截图 2022-07-05 144851 PNG](https://user-images.githubusercontent.com/2093588/179666690-01e4252a-9c97-44ca-a5cf-5dc627fb471b.jpg)

### Known issues
* The GNOME desktop will go black when restarting, current workaround is disable GPU-PV temporarily with "Remove-VMGpuPartitionAdapter $vmName" in Powershell and add it back after entering the GNOME desktop.
