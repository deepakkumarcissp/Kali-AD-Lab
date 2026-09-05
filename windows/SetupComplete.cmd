@echo off
setlocal EnableExtensions EnableDelayedExpansion

if not exist C:\ADLab mkdir C:\ADLab
set LOG=C:\ADLab\SetupComplete.log

echo [%date% %time%] Kali-AD-Lab SetupComplete started.>>"%LOG%"

set CFG=
for /L %%I in (1,1,90) do (
  for %%D in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist %%D:\ADLab\config.ps1 set CFG=%%D:\ADLab\config.ps1
  )
  if defined CFG goto :found
  timeout /t 2 /nobreak >nul
)

echo [%date% %time%] ERROR: LABTOOLS config.ps1 was not found.>>"%LOG%"
echo LABTOOLS config.ps1 was not found.>C:\ADLab\FAILED-Bootstrap.txt
exit /b 0

:found
echo [%date% %time%] Found runtime config at %CFG%.>>"%LOG%"
copy /Y "%CFG%" C:\ADLab\config.ps1 >>"%LOG%" 2>&1

if not exist C:\ADLab\Stage1.ps1 (
  echo [%date% %time%] ERROR: C:\ADLab\Stage1.ps1 is missing.>>"%LOG%"
  echo Static bootstrap files were not copied from Windows installation media.>C:\ADLab\FAILED-Bootstrap.txt
  exit /b 0
)

schtasks /Create /TN "Kali-AD-Lab-Stage1" /SC ONSTART /RU SYSTEM /RL HIGHEST /TR "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\ADLab\Stage1.ps1" /F >>"%LOG%" 2>&1
if errorlevel 1 (
  echo [%date% %time%] ERROR: Failed to register Stage1 scheduled task.>>"%LOG%"
  echo Failed to register Stage1 scheduled task.>C:\ADLab\FAILED-Bootstrap.txt
  exit /b 0
)

echo [%date% %time%] Stage1 registered. Rebooting to begin AD configuration.>>"%LOG%"
shutdown.exe /r /t 5 /f
exit /b 0
