@echo off
setlocal EnableExtensions EnableDelayedExpansion

if not exist C:\ADLab mkdir C:\ADLab
if not exist C:\ADLab\Logs mkdir C:\ADLab\Logs
set LOG=C:\ADLab\Logs\Bootstrap.log
set TASK=Kali-AD-Lab-Orchestrator

echo [%date% %time%] Kali-AD-Lab post-setup bootstrap invoked.>>"%LOG%"

set CFG=
set ENGINE=
set ORCH=
set SEED=
set SPICE=

if exist C:\ADLab\config.ps1 set CFG=C:\ADLab\config.ps1
if exist C:\ADLab\Configure-AD.ps1 set ENGINE=C:\ADLab\Configure-AD.ps1
if exist C:\ADLab\Run-Lab.ps1 set ORCH=C:\ADLab\Run-Lab.ps1
if exist C:\ADLab\Seed-Assessment-Lab.ps1 set SEED=C:\ADLab\Seed-Assessment-Lab.ps1
if exist C:\ADLab\spice-guest-tools-latest.exe set SPICE=C:\ADLab\spice-guest-tools-latest.exe

for /L %%I in (1,1,120) do (
  for %%D in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if not defined CFG if exist %%D:\ADLab\config.ps1 set CFG=%%D:\ADLab\config.ps1
    if not defined ENGINE if exist %%D:\sources\$OEM$\$1\ADLab\Configure-AD.ps1 set ENGINE=%%D:\sources\$OEM$\$1\ADLab\Configure-AD.ps1
    if not defined ENGINE if exist %%D:\ADLab\Configure-AD.ps1 set ENGINE=%%D:\ADLab\Configure-AD.ps1
    if not defined ORCH if exist %%D:\sources\$OEM$\$1\ADLab\Run-Lab.ps1 set ORCH=%%D:\sources\$OEM$\$1\ADLab\Run-Lab.ps1
    if not defined ORCH if exist %%D:\ADLab\Run-Lab.ps1 set ORCH=%%D:\ADLab\Run-Lab.ps1
    if not defined SEED if exist %%D:\sources\$OEM$\$1\ADLab\Seed-Assessment-Lab.ps1 set SEED=%%D:\sources\$OEM$\$1\ADLab\Seed-Assessment-Lab.ps1
    if not defined SEED if exist %%D:\ADLab\Seed-Assessment-Lab.ps1 set SEED=%%D:\ADLab\Seed-Assessment-Lab.ps1
    if not defined SPICE if exist %%D:\ADLab\spice-guest-tools-latest.exe set SPICE=%%D:\ADLab\spice-guest-tools-latest.exe
  )
  if defined CFG if defined ENGINE if defined ORCH if defined SEED goto :found
  timeout /t 2 /nobreak >nul
)

echo [%date% %time%] ERROR: Could not locate required Kali-AD-Lab runtime files.>>"%LOG%"
echo Required runtime files were not found.>C:\ADLab\FAILED-Bootstrap.txt
exit /b 0

:found
echo [%date% %time%] Runtime config: %CFG%>>"%LOG%"
echo [%date% %time%] AD engine: %ENGINE%>>"%LOG%"
echo [%date% %time%] Orchestrator: %ORCH%>>"%LOG%"
echo [%date% %time%] Assessment seed: %SEED%>>"%LOG%"

if /I not "%CFG%"=="C:\ADLab\config.ps1" copy /Y "%CFG%" C:\ADLab\config.ps1 >>"%LOG%" 2>&1
if errorlevel 1 goto :copyfail
if /I not "%ENGINE%"=="C:\ADLab\Configure-AD.ps1" copy /Y "%ENGINE%" C:\ADLab\Configure-AD.ps1 >>"%LOG%" 2>&1
if errorlevel 1 goto :copyfail
if /I not "%ORCH%"=="C:\ADLab\Run-Lab.ps1" copy /Y "%ORCH%" C:\ADLab\Run-Lab.ps1 >>"%LOG%" 2>&1
if errorlevel 1 goto :copyfail
if /I not "%SEED%"=="C:\ADLab\Seed-Assessment-Lab.ps1" copy /Y "%SEED%" C:\ADLab\Seed-Assessment-Lab.ps1 >>"%LOG%" 2>&1
if errorlevel 1 goto :copyfail

rem Install the official Windows SPICE guest tools silently as SYSTEM.
rem This enables host/guest clipboard integration once the VM's spicevmc channel is active.
if defined SPICE (
  if /I not "%SPICE%"=="C:\ADLab\spice-guest-tools-latest.exe" copy /Y "%SPICE%" C:\ADLab\spice-guest-tools-latest.exe >>"%LOG%" 2>&1
  if exist C:\ADLab\spice-guest-tools-latest.exe (
    echo [%date% %time%] Installing SPICE guest tools for shared clipboard.>>"%LOG%"
    start /wait "" C:\ADLab\spice-guest-tools-latest.exe /S >>"%LOG%" 2>&1
    if errorlevel 1 (
      echo [%date% %time%] WARNING: SPICE guest tools returned an error; AD deployment will continue.>>"%LOG%"
    ) else (
      sc query vdservice >>"%LOG%" 2>&1
      echo [%date% %time%] SPICE guest tools installation completed.>>"%LOG%"
    )
  )
) else (
  echo [%date% %time%] WARNING: SPICE guest tools media was not found; AD deployment will continue.>>"%LOG%"
)

if not exist C:\ADLab\config.ps1 goto :copyfail
if not exist C:\ADLab\Configure-AD.ps1 goto :copyfail
if not exist C:\ADLab\Run-Lab.ps1 goto :copyfail
if not exist C:\ADLab\Seed-Assessment-Lab.ps1 goto :copyfail

rem Remove any task name used by older builds to prevent duplicate workers.
schtasks /Delete /TN "Kali-AD-Lab-ConfigureAD" /F >>"%LOG%" 2>&1

rem Register one resilient orchestrator with two safe triggers:
rem   1) one-time delayed launch after SetupComplete has returned;
rem   2) delayed startup trigger so Windows/AD reboots resume automatically.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $a=New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument '-NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\ADLab\Run-Lab.ps1'; $once=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(3); $boot=New-ScheduledTaskTrigger -AtStartup; $boot.Delay='PT2M'; $p=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest; Unregister-ScheduledTask -TaskName '%TASK%' -Confirm:$false -ErrorAction SilentlyContinue; Register-ScheduledTask -TaskName '%TASK%' -Action $a -Trigger @($once,$boot) -Principal $p -Force | Out-Null" >>"%LOG%" 2>&1
if errorlevel 1 (
  echo [%date% %time%] ERROR: Failed to register Kali-AD-Lab orchestrator.>>"%LOG%"
  echo Failed to register Kali-AD-Lab orchestrator.>C:\ADLab\FAILED-Bootstrap.txt
  exit /b 0
)

echo Bootstrap staged successfully. Windows/AD configuration and assessment seeding are deferred until Setup has fully exited.>C:\ADLab\BOOTSTRAP-READY.txt
del /Q C:\ADLab\FAILED-Bootstrap.txt >nul 2>&1
echo [%date% %time%] Kali-AD-Lab orchestrator scheduled.>>"%LOG%"
exit /b 0

:copyfail
echo [%date% %time%] ERROR: Failed to copy Kali-AD-Lab runtime files locally.>>"%LOG%"
echo Failed to copy Kali-AD-Lab runtime files locally.>C:\ADLab\FAILED-Bootstrap.txt
exit /b 0
