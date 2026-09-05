$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

New-Item -ItemType Directory -Path 'C:\ADLab\Logs' -Force | Out-Null
Start-Transcript -Path 'C:\ADLab\Logs\Stage3.log' -Append

. 'C:\ADLab\config.ps1'

Write-Host '[Stage3] Waiting for Active Directory services...'
$ready = $false
for ($i = 0; $i -lt 40; $i++) {
    $ntds = Get-Service NTDS -ErrorAction SilentlyContinue
    $adws = Get-Service ADWS -ErrorAction SilentlyContinue
    if ($ntds.Status -eq 'Running' -and $adws.Status -eq 'Running') {
        $ready = $true
        break
    }
    Start-Sleep -Seconds 15
}

if (-not $ready) {
    'AD services did not reach Running state during validation.' | Out-File 'C:\ADLab\FAILED-Stage3.txt'
    Stop-Transcript
    exit 1
}

try {
    Import-Module ActiveDirectory
    $domain = Get-ADDomain
    $forest = Get-ADForest

    if ($LabConfig.NetworkMode -eq 'nat') {
        try {
            Import-Module DnsServer
            $existing = Get-DnsServerForwarder -ErrorAction SilentlyContinue
            if (-not ($existing.IPAddress.IPAddressToString -contains $LabConfig.Gateway)) {
                Add-DnsServerForwarder -IPAddress $LabConfig.Gateway -PassThru | Out-Null
            }
        }
        catch {
            Write-Warning "Could not configure DNS forwarder automatically: $($_.Exception.Message)"
        }
    }

    @"
Kali-AD-Lab deployment completed successfully.
Computer: $env:COMPUTERNAME
Domain: $($domain.DNSRoot)
NetBIOS: $($domain.NetBIOSName)
Forest: $($forest.Name)
DC IP: $($LabConfig.DcIp)
Completed: $(Get-Date -Format o)
"@ | Out-File 'C:\ADLab\SUCCESS.txt' -Encoding utf8

    Unregister-ScheduledTask -TaskName 'Kali-AD-Lab-Stage3' -Confirm:$false -ErrorAction SilentlyContinue

    # Remove the runtime secret configuration from inside Windows after successful promotion.
    Remove-Item 'C:\ADLab\config.ps1' -Force -ErrorAction SilentlyContinue

    Write-Host '[Stage3] Active Directory lab is ready.'
}
catch {
    Write-Error $_
    $_ | Out-File 'C:\ADLab\FAILED-Stage3.txt' -Append
}

Stop-Transcript
