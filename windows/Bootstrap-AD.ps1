$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = 'C:\ADLab'
$LogDir = Join-Path $Root 'Logs'
$LogFile = Join-Path $LogDir 'Bootstrap-AD.log'
$TaskName = 'Kali-AD-Lab-ConfigureAD'

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
Start-Transcript -Path $LogFile -Append

function Stop-TranscriptSafe {
    try { Stop-Transcript | Out-Null } catch {}
}

try {
    Write-Host '[Bootstrap-AD] Windows OOBE completed. Locating LABCONFIG media...'

    $mediaRoot = $null
    for ($i = 0; $i -lt 120; $i++) {
        foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
            if (-not $drive.IsReady) { continue }
            $root = $drive.RootDirectory.FullName
            $cfg = Join-Path $root 'ADLab\config.ps1'
            $engine = Join-Path $root 'ADLab\Configure-AD.ps1'
            if ((Test-Path $cfg) -and (Test-Path $engine)) {
                $mediaRoot = $root
                break
            }
        }
        if ($mediaRoot) { break }
        Start-Sleep -Seconds 2
    }

    if (-not $mediaRoot) {
        throw 'LABCONFIG media containing config.ps1 and Configure-AD.ps1 was not found.'
    }

    Write-Host "[Bootstrap-AD] LABCONFIG media found at $mediaRoot"
    Copy-Item (Join-Path $mediaRoot 'ADLab\config.ps1') (Join-Path $Root 'config.ps1') -Force
    Copy-Item (Join-Path $mediaRoot 'ADLab\Configure-AD.ps1') (Join-Path $Root 'Configure-AD.ps1') -Force

    if (-not (Test-Path (Join-Path $Root 'config.ps1'))) { throw 'Failed to copy config.ps1 locally.' }
    if (-not (Test-Path (Join-Path $Root 'Configure-AD.ps1'))) { throw 'Failed to copy Configure-AD.ps1 locally.' }

    $action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument '-NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\ADLab\Configure-AD.ps1'
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null

    # Remove any remaining one-time auto-logon material before AD promotion.
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value '0' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $winlogon -Name DefaultPassword -ErrorAction SilentlyContinue

    'Post-OOBE bootstrap completed successfully.' | Out-File (Join-Path $Root 'BOOTSTRAP-READY.txt') -Encoding ascii

    Write-Host '[Bootstrap-AD] Starting resumable AD configuration engine...'
    Start-ScheduledTask -TaskName $TaskName

    Stop-TranscriptSafe
    exit 0
}
catch {
    $msg = "[$(Get-Date -Format o)] $($_.Exception.Message)"
    Write-Error $msg
    $msg | Out-File (Join-Path $Root 'FAILED-Bootstrap.txt') -Append -Encoding utf8
    Stop-TranscriptSafe
    exit 1
}
