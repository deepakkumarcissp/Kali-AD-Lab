$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = 'C:\ADLab'
$LogDir = Join-Path $Root 'Logs'
$LogFile = Join-Path $LogDir 'Run-Lab.log'
$TaskName = 'Kali-AD-Lab-Orchestrator'
$FinalMarker = Join-Path $Root 'LAB-READY.txt'
$AssessmentMarker = Join-Path $Root 'ASSESSMENT-DEMO-READY.txt'
$ConfigureScript = Join-Path $Root 'Configure-AD.ps1'
$SeedScript = Join-Path $Root 'Seed-Assessment-Lab.ps1'

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
Start-Transcript -Path $LogFile -Append

function Stop-TranscriptSafe { try { Stop-Transcript | Out-Null } catch {} }
function Get-DomainRole { return [int](Get-CimInstance Win32_ComputerSystem).DomainRole }

try {
    Write-Host '[Run-Lab] Resumable lab orchestrator started.'

    if (-not (Test-Path $ConfigureScript)) { throw "Missing $ConfigureScript" }
    if (-not (Test-Path $SeedScript)) { throw "Missing $SeedScript" }

    if (Test-Path $FinalMarker) {
        Write-Host '[Run-Lab] Final lab marker already exists; nothing to do.'
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Stop-TranscriptSafe
        exit 0
    }

    $roleBefore = Get-DomainRole
    if ($roleBefore -lt 4) {
        Write-Host '[Run-Lab] Windows is not yet a domain controller. Running AD configuration engine...'
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$ConfigureScript) -Wait -PassThru -WindowStyle Hidden
        Write-Host "[Run-Lab] Configure-AD exit code: $($p.ExitCode)"

        $roleAfter = Get-DomainRole
        if ($roleAfter -lt 4) {
            Write-Host '[Run-Lab] Domain promotion is not complete yet. The startup trigger will resume after Windows reboots.'
            Stop-TranscriptSafe
            exit 0
        }
    }

    Write-Host '[Run-Lab] Domain controller detected. Starting assessment dataset verification/seeding.'
    Import-Module ActiveDirectory
    $domain = Get-ADDomain

    if (-not (Test-Path $AssessmentMarker)) {
        $seed = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$SeedScript,'-ExpectedDomain',$domain.DNSRoot) -Wait -PassThru -WindowStyle Hidden
        Write-Host "[Run-Lab] Seed-Assessment-Lab exit code: $($seed.ExitCode)"
        if ($seed.ExitCode -ne 0) { throw 'Assessment seeding returned a non-zero exit code.' }
    }

    if (-not (Test-Path $AssessmentMarker)) { throw 'Assessment marker was not created.' }

    $expectedUsers = @(
        't0.admin1','t0.admin2','t0.legacyadmin','t1.serveradmin1','t1.serveradmin2',
        'helpdesk1','helpdesk2','helpdesk3','svc.backup','svc.web','svc.sql','svc.legacy',
        'user01','user02','user03','user04','user05','user06','user07','user08',
        'contractor.old','admin.stale','app.operator','audit.reader'
    )
    $expectedComputers = @('APP01','FILE01','SQL01','WEB01','WS001','WS002','WS003','WS004','WS005','WS006')

    $missingUsers = @($expectedUsers | Where-Object { -not (Get-ADUser -Identity $_ -ErrorAction SilentlyContinue) })
    $missingComputers = @($expectedComputers | Where-Object { -not (Get-ADComputer -Identity $_ -ErrorAction SilentlyContinue) })
    if ($missingUsers.Count -gt 0) { throw "Assessment user verification failed. Missing: $($missingUsers -join ', ')" }
    if ($missingComputers.Count -gt 0) { throw "Assessment computer verification failed. Missing: $($missingComputers -join ', ')" }

    @"
Kali-AD-Lab is fully ready.
Domain: $($domain.DNSRoot)
Synthetic users verified: 24
Synthetic computers verified: 10
Assessment profile: assessment-demo
Completed: $(Get-Date -Format o)
"@ | Out-File $FinalMarker -Encoding utf8

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host '[Run-Lab] LAB READY: AD + assessment dataset verified.'
    Stop-TranscriptSafe
    exit 0
}
catch {
    $msg = "[$(Get-Date -Format o)] $($_.Exception.Message)"
    Write-Error $msg
    $msg | Out-File (Join-Path $Root 'FAILED-Run-Lab.txt') -Append -Encoding utf8
    Stop-TranscriptSafe
    exit 1
}
