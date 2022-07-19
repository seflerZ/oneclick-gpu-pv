# onenclick-gpu-pv
Enable GPU-PV easily

##
GPU Partition is a new Microsoft GPU virtualization technology avaiable in latest Win10 and Win11. However it is not configurable in a easy way( no GUI avaiable). This repository provides scripts for both Windows and Linux to enable GPU-PV easily.

## For Windows 10+
Depending on your system local. If it is English based or zh-CN, just download 'win-gpu-pv.ps1' and execute with Administrator priviledge. Otherwise you should implement your own check label located in the script.

_This script was inspired by [dantmnf](https://gist.github.com/dantmnf/9bf9972c1ad49029cbdc2e40f1b7ac51)_

## For Ubuntu
Downdload the 'ubuntu-gpu-pv.ps1' and 'dxgkrnl-dkms.zip' to Windows host folder. Execute 'ubuntu-gpu-pv.ps1' with Administrator. You must configured WSLg first. That is to say you must have a WSL being able to use the GPU. Due to limitation of SSH, you'll be asked for password many times.
