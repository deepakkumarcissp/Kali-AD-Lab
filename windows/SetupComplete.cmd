@echo off
setlocal EnableExtensions EnableDelayedExpansion

if not exist C:\ADLab mkdir C:\ADLab
if not exist C:\ADLab\Logs mkdir C:\ADLab\Logs
set LOG=C:\ADLab\Logs\Bootstrap.log
set TASK=Kali-AD-Lab-ConfigureAD

echo [%date% %time%] Kali-AD-Lab post-setup bootstrap invoked.>>"%LOG%"

set CFG=
set ENGINE=

if exist C:\ADLab\config.ps1 set CFG=C:\ADLab\config.ps1
if exist C:\ADLab\Configure-AD.ps1 set ENGINE=C:\ADLab\Configure-AD.ps1

for /L %%I in (1,1,120) do (
  for %%D in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if not defined CFG if exist %%D:\ADLab\config.ps1 set CFG=%%D:\ADLab\config.ps1
    if not defined ENGINE if exist %%D:\sources\$OEM$\$1\ADLab\Configure-AD.ps1 set ENGINE=%%D:\sources\$OEM$\$1\ADLab\Configure-AD.ps1
    if not defined ENGINE if exist %%D:\ADLab\Configure-AD.ps1 set ENGINE=%%D:\ADLab\Configure-AD.ps1
  )
  if defined CFG if defined ENGINE goto :found
  timeout /t 2 /nobreak >nul
)

echo [%date% %time%] ERROR: Could not locate runtime config and AD engine media.>>"%LOG%"
echo Runtime config or Configure-AD.ps1 media was not found.>C:\ADLab\FAILED-Bootstrap.txt
exit /b 0

:found
echo [%date% %time%] Runtime config: %CFG%>>"%LOG%"
echo [%date% %time%] AD engine: %ENGINE%>>"%LOG%"

if /I not "%CFG%"=="C:\ADLab\config.ps1" copy /Y "%CFG%" C:\ADLab\config.ps1 >>"%LOG%" 2>&1
if errorlevel 1 goto :copyfail
if /I not "%ENGINE%"=="C:\ADLab\Configure-AD.ps1" copy /Y "%ENGINE%" C:\ADLab\Configure-AD.ps1 >>"%LOG%" 2>&1
if errorlevel 1 goto :copyfail

if not exist C:\ADLab\config.ps1 goto :copyfail
if not exist C:\ADLab\Configure-AD.ps1 goto :copyfail

rem Register one task with two safe triggers:
rem   1) one-time delayed launch after SetupComplete has returned;
rem   2) delayed startup trigger so required AD reboots resume automatically.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $a=New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument '-NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\ADLab\Configure-AD.ps1'; $once=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(3); $boot=New-ScheduledTaskTrigger -AtStartup; $boot.Delay='PT2M'; $p=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest; Unregister-ScheduledTask -TaskName '%TASK%' -Confirm:$false -ErrorAction SilentlyContinue; Register-ScheduledTask -TaskName '%TASK%' -Action $a -Trigger @($once,$boot) -Principal $p -Force | Out-Null" >>"%LOG%" 2>&1
if errorlevel 1 (
  echo [%date% %time%] ERROR: Failed to register delayed Configure-AD task.>>"%LOG%"
  echo Failed to register delayed Configure-AD scheduled task.>C:\ADLab\FAILED-Bootstrap.txt
  exit /b 0
)

echo Bootstrap staged successfully. AD configuration is intentionally deferred until Windows Setup has fully exited.>C:\ADLab\BOOTSTRAP-READY.txt
del /Q C:\ADLab\FAILED-Bootstrap.txt >nul 2>&1
echo [%date% %time%] Configure-AD scheduled for delayed post-setup execution.>>"%LOG%"
exit /b 0

:copyfail
echo [%date% %time%] ERROR: Failed to copy AD runtime files locally.>>"%LOG%"
echo Failed to copy AD runtime files locally.>C:\ADLab\FAILED-Bootstrap.txt
exit /b 0
