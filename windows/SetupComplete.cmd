@echo off
setlocal EnableExtensions EnableDelayedExpansion

if not exist C:\ADLab mkdir C:\ADLab
if not exist C:\ADLab\Logs mkdir C:\ADLab\Logs
set LOG=C:\ADLab\Logs\Bootstrap.log
set TASK=Kali-AD-Lab-ConfigureAD

echo [%date% %time%] Kali-AD-Lab bootstrap invoked.>>"%LOG%"

if exist C:\ADLab\BOOTSTRAP-READY.txt (
  echo [%date% %time%] Bootstrap already completed; starting/resuming task.>>"%LOG%"
  schtasks /Run /TN "%TASK%" >>"%LOG%" 2>&1
  exit /b 0
)

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

schtasks /Delete /TN "%TASK%" /F >>"%LOG%" 2>&1
schtasks /Create /TN "%TASK%" /SC ONSTART /RU SYSTEM /RL HIGHEST /TR "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\ADLab\Configure-AD.ps1" /F >>"%LOG%" 2>&1
if errorlevel 1 (
  echo [%date% %time%] ERROR: Failed to register Configure-AD startup task.>>"%LOG%"
  echo Failed to register Configure-AD scheduled task.>C:\ADLab\FAILED-Bootstrap.txt
  exit /b 0
)

rem Disable the one-time Administrator auto-logon before AD promotion.
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 0 /f >>"%LOG%" 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultPassword /f >>"%LOG%" 2>&1

echo Bootstrap completed successfully.>C:\ADLab\BOOTSTRAP-READY.txt
del /Q C:\ADLab\FAILED-Bootstrap.txt >nul 2>&1

echo [%date% %time%] Starting Configure-AD task.>>"%LOG%"
schtasks /Run /TN "%TASK%" >>"%LOG%" 2>&1
if errorlevel 1 (
  echo [%date% %time%] Immediate task start failed; startup trigger remains registered.>>"%LOG%"
  shutdown.exe /r /t 10 /f
) else (
  echo [%date% %time%] Configure-AD task launched successfully.>>"%LOG%"
)
exit /b 0

:copyfail
echo [%date% %time%] ERROR: Failed to copy AD runtime files locally.>>"%LOG%"
echo Failed to copy AD runtime files locally.>C:\ADLab\FAILED-Bootstrap.txt
exit /b 0
