$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

New-Item -ItemType Directory -Path 'C:\ADLab\Logs' -Force | Out-Null
Start-Transcript -Path 'C:\ADLab\Logs\Stage1.log' -Append

try {
    Unregister-ScheduledTask -TaskName 'Kali-AD-Lab-Stage1' -Confirm:$false -ErrorAction SilentlyContinue
    . 'C:\ADLab\config.ps1'

    Write-Host '[Stage1] Detecting primary network adapter...'
    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.HardwareInterface } | Sort-Object ifIndex | Select-Object -First 1
    if (-not $adapter) { throw 'No active hardware network adapter was found.' }

    Write-Host "[Stage1] Configuring $($adapter.Name) as $($LabConfig.DcIp)/$($LabConfig.PrefixLength)..."
    Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.PrefixOrigin -ne 'WellKnown' } |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' } |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

    if ($LabConfig.NetworkMode -eq 'nat') {
        New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $LabConfig.DcIp -PrefixLength $LabConfig.PrefixLength -DefaultGateway $LabConfig.Gateway | Out-Null
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @($LabConfig.Gateway)
    }
    else {
        New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $LabConfig.DcIp -PrefixLength $LabConfig.PrefixLength | Out-Null
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @($LabConfig.DcIp)
    }

    Write-Host '[Stage1] Installing Active Directory Domain Services and management tools...'
    $featureResult = Install-WindowsFeature AD-Domain-Services -IncludeManagementTools

    # AD DNS will listen on the DC address after promotion.
    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @($LabConfig.DcIp)

    if ($featureResult.RestartNeeded -eq 'Yes') {
        Write-Host '[Stage1] Windows requires a reboot before promotion. Registering Stage2 for next startup...'
        $action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument '-NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\ADLab\Stage2.ps1'
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName 'Kali-AD-Lab-Stage2' -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
        Stop-Transcript
        Restart-Computer -Force
        exit 0
    }

    Write-Host '[Stage1] AD DS role is ready. Continuing directly to domain promotion...'
    Stop-Transcript
    & PowerShell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File 'C:\ADLab\Stage2.ps1'
    exit $LASTEXITCODE
}
catch {
    Write-Error $_
    $_ | Out-File 'C:\ADLab\FAILED-Stage1.txt' -Append
    try { Stop-Transcript } catch {}
    exit 1
}
