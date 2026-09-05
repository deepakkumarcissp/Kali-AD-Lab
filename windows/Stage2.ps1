$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

New-Item -ItemType Directory -Path 'C:\ADLab\Logs' -Force | Out-Null
Start-Transcript -Path 'C:\ADLab\Logs\Stage2.log' -Append

try {
    . 'C:\ADLab\config.ps1'

    $computerSystem = Get-CimInstance Win32_ComputerSystem
    if ($computerSystem.DomainRole -ge 4) {
        Write-Host '[Stage2] This machine is already a domain controller. Skipping promotion.'
        Unregister-ScheduledTask -TaskName 'Kali-AD-Lab-Stage2' -Confirm:$false -ErrorAction SilentlyContinue
        Stop-Transcript
        exit 0
    }

    Write-Host "[Stage2] Promoting $env:COMPUTERNAME to the first DC for $($LabConfig.DomainFqdn)..."

    $dsrmPlain = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($LabConfig.DsrmPasswordB64))
    $dsrmSecure = ConvertTo-SecureString $dsrmPlain -AsPlainText -Force

    $action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument '-NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\ADLab\Stage3.ps1'
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName 'Kali-AD-Lab-Stage3' -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Unregister-ScheduledTask -TaskName 'Kali-AD-Lab-Stage2' -Confirm:$false -ErrorAction SilentlyContinue

    Import-Module ADDSDeployment
    Install-ADDSForest `
        -DomainName $LabConfig.DomainFqdn `
        -DomainNetbiosName $LabConfig.NetbiosName `
        -InstallDns `
        -SafeModeAdministratorPassword $dsrmSecure `
        -NoRebootOnCompletion:$false `
        -Force
}
catch {
    Write-Error $_
    $_ | Out-File 'C:\ADLab\FAILED-Stage2.txt' -Append
    Stop-Transcript
    exit 1
}
