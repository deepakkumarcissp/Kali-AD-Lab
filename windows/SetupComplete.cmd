@echo off
setlocal
if not exist C:\ADLab\Stage1.ps1 exit /b 2
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\ADLab\Stage1.ps1 >> C:\ADLab\SetupComplete.log 2>&1
exit /b 0
