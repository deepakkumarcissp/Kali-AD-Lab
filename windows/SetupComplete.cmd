@echo off
setlocal EnableExtensions EnableDelayedExpansion

if not exist C:\ADLab mkdir C:\ADLab
set LOG=C:\ADLab\SetupComplete.log
set TASK=Kali-AD-Lab-ConfigureAD

echo [%date% %time%] Kali-AD-Lab SetupComplete started.>>"%LOG%"

if not exist C:\ADLab\Configure-AD.ps1 (
  echo [%date% %time%] ERROR: C:\ADLab\Configure-AD.ps1 is missing from Windows installation media.>>"%LOG%"
  echo Static AD bootstrap was not copied from Windows installation media.>C:\ADLab\FAILED-Bootstrap.txt
  exit /b 0
)

set CFG=
for /L %%I in (1,1,120) do (
  for %%D in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist %%D:\ADLab\config.ps1 set CFG=%%D:\ADLab\config.ps1
  )
  if defined CFG goto :found
  timeout /t 2 /nobreak >nul
)

echo [%date% %time%] ERROR: LABCONFIG config.ps1 was not found.>>"%LOG%"
echo Runtime config media was not found.>C:\ADLab\FAILED-Bootstrap.txt
exit /b 0

:found
echo [%date% %time%] Found runtime config at %CFG%.>>"%LOG%"
copy /Y "%CFG%" C:\ADLab\config.ps1 >>"%LOG%" 2>&1
if errorlevel 1 (
  echo [%date% %time%] ERROR: Failed to copy runtime configuration.>>"%LOG%"
  exit /b 0
)

schtasks /Delete /TN "%TASK%" /F >>"%LOG%" 2>&1
schtasks /Create /TN "%TASK%" /SC ONSTART /RU SYSTEM /RL HIGHEST /TR "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\ADLab\Configure-AD.ps1" /F >>"%LOG%" 2>&1
if errorlevel 1 (
  echo [%date% %time%] ERROR: Failed to register Configure-AD startup task.>>"%LOG%"
  echo Failed to register Configure-AD scheduled task.>C:\ADLab\FAILED-Bootstrap.txt
  exit /b 0
)

echo [%date% %time%] Starting Configure-AD task now.>>"%LOG%"
schtasks /Run /TN "%TASK%" >>"%LOG%" 2>&1
if errorlevel 1 (
  echo [%date% %time%] Immediate task start failed; rebooting so ONSTART can resume automatically.>>"%LOG%"
  shutdown.exe /r /t 10 /f
) else (
  echo [%date% %time%] Configure-AD task launched successfully.>>"%LOG%"
)

exit /b 0
