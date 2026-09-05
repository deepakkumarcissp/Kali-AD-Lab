$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = 'C:\ADLab'
$LogDir = Join-Path $Root 'Logs'
$LogFile = Join-Path $LogDir 'Configure-AD.log'
$FailureFile = Join-Path $Root 'FAILED-Configure-AD.txt'
$SuccessFile = Join-Path $Root 'SUCCESS.txt'
$TaskName = 'Kali-AD-Lab-ConfigureAD'
$AttemptFile = Join-Path $Root 'configure-attempts.txt'

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
Start-Transcript -Path $LogFile -Append

function Stop-TranscriptSafe {
    try { Stop-Transcript | Out-Null } catch {}
}

function Wait-WindowsSetupComplete {
    Write-Host '[Configure-AD] Waiting for Windows Setup/OOBE to finish before configuring AD...'
    for ($i = 0; $i -lt 180; $i++) {
        $setup = Get-ItemProperty 'HKLM:\SYSTEM\Setup' -ErrorAction SilentlyContinue
        $systemSetup = 0
        $oobe = 0
        if ($null -ne $setup) {
            if ($null -ne $setup.SystemSetupInProgress) { $systemSetup = [int]$setup.SystemSetupInProgress }
            if ($null -ne $setup.OOBEInProgress) { $oobe = [int]$setup.OOBEInProgress }
        }
        if ($systemSetup -eq 0 -and $oobe -eq 0) {
            Write-Host '[Configure-AD] Windows Setup is complete.'
            return
        }
        Start-Sleep -Seconds 10
    }
    throw 'Windows Setup/OOBE did not complete within 30 minutes.'
}

function Get-PrimaryAdapter {
    for ($i = 0; $i -lt 24; $i++) {
        $a = Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Up' -and $_.HardwareInterface } |
            Sort-Object ifIndex |
            Select-Object -First 1
        if ($a) { return $a }
        Start-Sleep -Seconds 5
    }
    throw 'No active hardware network adapter was found.'
}

function Ensure-Network {
    param($Config)

    $adapter = Get-PrimaryAdapter
    Write-Host "[Configure-AD] Ensuring $($adapter.Name) uses $($Config.DcIp)/$($Config.PrefixLength)..."

    Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Dhcp Disabled -ErrorAction SilentlyContinue

    $desired = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $Config.DcIp }

    if (-not $desired) {
        Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object {
                $_.PrefixOrigin -ne 'WellKnown' -and
                $_.IPAddress -ne $Config.DcIp -and
                $_.IPAddress -notlike '169.254.*'
            } |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

        Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' } |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

        if ($Config.NetworkMode -eq 'nat') {
            New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $Config.DcIp -PrefixLength $Config.PrefixLength -DefaultGateway $Config.Gateway | Out-Null
        }
        else {
            New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $Config.DcIp -PrefixLength $Config.PrefixLength | Out-Null
        }
    }
    elseif ($Config.NetworkMode -eq 'nat') {
        $defaultRoute = Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Where-Object { $_.NextHop -eq $Config.Gateway } |
            Select-Object -First 1
        if (-not $defaultRoute) {
            New-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -NextHop $Config.Gateway -ErrorAction SilentlyContinue | Out-Null
        }
    }

    return $adapter
}

function Complete-Lab {
    param($Config)

    Write-Host '[Configure-AD] Domain controller detected. Validating AD services...'
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        $ntds = Get-Service NTDS -ErrorAction SilentlyContinue
        $adws = Get-Service ADWS -ErrorAction SilentlyContinue
        $dns = Get-Service DNS -ErrorAction SilentlyContinue
        if ($ntds.Status -eq 'Running' -and $adws.Status -eq 'Running' -and $dns.Status -eq 'Running') {
            $ready = $true
            break
        }
        Start-Sleep -Seconds 10
    }
    if (-not $ready) { throw 'AD DS/DNS services did not reach Running state.' }

    Import-Module ActiveDirectory
    $domain = Get-ADDomain
    $forest = Get-ADForest
    if ($domain.DNSRoot -ne $Config.DomainFqdn) {
        throw "Domain mismatch. Expected $($Config.DomainFqdn), found $($domain.DNSRoot)."
    }

    if ($Config.NetworkMode -eq 'nat') {
        try {
            Import-Module DnsServer
            $forwarders = Get-DnsServerForwarder -ErrorAction SilentlyContinue
            if (-not ($forwarders.IPAddress.IPAddressToString -contains $Config.Gateway)) {
                Add-DnsServerForwarder -IPAddress $Config.Gateway -PassThru | Out-Null
            }
        }
        catch {
            Write-Warning "DNS forwarder could not be added automatically: $($_.Exception.Message)"
        }
    }

    $profile = 'clean'
    if ($Config.ContainsKey('AssessmentProfile') -and $Config.AssessmentProfile) {
        $profile = [string]$Config.AssessmentProfile
    }
    if ($profile -eq 'assessment-demo') {
        $seed = Join-Path $Root 'Seed-Assessment-Lab.ps1'
        if (-not (Test-Path $seed)) { throw 'Assessment-demo profile selected but C:\ADLab\Seed-Assessment-Lab.ps1 is missing.' }
        Write-Host '[Configure-AD] Seeding comprehensive security-assessment demo scenarios...'
        $args = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$seed,'-ExpectedDomain',$Config.DomainFqdn)
        $proc = Start-Process -FilePath 'PowerShell.exe' -ArgumentList $args -Wait -PassThru
        if ($proc.ExitCode -ne 0) { throw "Assessment-demo seeding failed with exit code $($proc.ExitCode)." }
        if (-not (Test-Path (Join-Path $Root 'ASSESSMENT-DEMO-READY.txt'))) { throw 'Assessment-demo seeding did not create its ready marker.' }
    }

    @"
Kali-AD-Lab deployment completed successfully.
Computer: $env:COMPUTERNAME
Domain: $($domain.DNSRoot)
NetBIOS: $($domain.NetBIOSName)
Forest: $($forest.Name)
DC IP: $($Config.DcIp)
Profile: $profile
Completed: $(Get-Date -Format o)
"@ | Out-File $SuccessFile -Encoding utf8

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Root 'config.ps1') -Force -ErrorAction SilentlyContinue
    Remove-Item $AttemptFile -Force -ErrorAction SilentlyContinue
    Remove-Item $FailureFile -Force -ErrorAction SilentlyContinue
    Write-Host "[Configure-AD] Active Directory lab is ready. Profile: $profile"
}

try {
    Wait-WindowsSetupComplete
    Start-Sleep -Seconds 15

    $attempt = 0
    if (Test-Path $AttemptFile) {
        $attempt = [int](Get-Content $AttemptFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    }
    $attempt++
    $attempt | Out-File $AttemptFile -Encoding ascii
    Write-Host "[Configure-AD] Resume attempt $attempt"

    $ConfigFile = Join-Path $Root 'config.ps1'
    if (-not (Test-Path $ConfigFile)) { throw 'Runtime configuration C:\ADLab\config.ps1 is missing.' }
    . $ConfigFile

    $computerSystem = Get-CimInstance Win32_ComputerSystem
    if ($computerSystem.DomainRole -ge 4) {
        Complete-Lab -Config $LabConfig
        Stop-TranscriptSafe
        exit 0
    }

    $adapter = Ensure-Network -Config $LabConfig

    # Use the NAT gateway as DNS until the server is ready to promote.
    if ($LabConfig.NetworkMode -eq 'nat') {
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @($LabConfig.Gateway)
    }

    $feature = Get-WindowsFeature AD-Domain-Services
    if (-not $feature.Installed) {
        Write-Host '[Configure-AD] Installing Active Directory Domain Services and management tools...'
        $result = Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
        if (-not $result.Success) { throw 'AD-Domain-Services feature installation failed.' }
        if ($result.RestartNeeded -eq 'Yes') {
            Write-Host '[Configure-AD] Windows requires a reboot before domain promotion. Resuming automatically after restart...'
            Stop-TranscriptSafe
            Restart-Computer -Force
            exit 0
        }
    }

    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @($LabConfig.DcIp)

    # Re-check in case another invocation completed promotion while this task was starting.
    $computerSystem = Get-CimInstance Win32_ComputerSystem
    if ($computerSystem.DomainRole -ge 4) {
        Complete-Lab -Config $LabConfig
        Stop-TranscriptSafe
        exit 0
    }

    Write-Host "[Configure-AD] Promoting $env:COMPUTERNAME as the first DC for $($LabConfig.DomainFqdn)..."
    $dsrmPlain = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($LabConfig.DsrmPasswordB64))
    $dsrmSecure = ConvertTo-SecureString $dsrmPlain -AsPlainText -Force

    Import-Module ADDSDeployment
    Install-ADDSForest `
        -DomainName $LabConfig.DomainFqdn `
        -DomainNetbiosName $LabConfig.NetbiosName `
        -InstallDns `
        -CreateDnsDelegation:$false `
        -SafeModeAdministratorPassword $dsrmSecure `
        -NoRebootOnCompletion:$false `
        -Force
}
catch {
    $msg = "[$(Get-Date -Format o)] $($_.Exception.Message)"
    Write-Error $msg
    $msg | Out-File $FailureFile -Append -Encoding utf8

    # Keep the startup task in place for transient boot/service timing failures,
    # but stop endless loops after five unsuccessful resumptions.
    $attempt = 1
    if (Test-Path $AttemptFile) {
        try { $attempt = [int](Get-Content $AttemptFile | Select-Object -First 1) } catch {}
    }
    if ($attempt -ge 5) {
        Disable-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null
        Write-Error '[Configure-AD] Five attempts failed; automatic retry has been disabled.'
    }
    Stop-TranscriptSafe
    exit 1
}
