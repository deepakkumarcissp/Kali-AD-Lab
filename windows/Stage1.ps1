$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

New-Item -ItemType Directory -Path 'C:\ADLab\Logs' -Force | Out-Null
Start-Transcript -Path 'C:\ADLab\Logs\Stage1.log' -Append

try {
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
    Install-WindowsFeature AD-Domain-Services -IncludeManagementTools | Out-Null

    # AD DNS will listen on the DC address after promotion.
    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @($LabConfig.DcIp)

    Write-Host '[Stage1] Registering domain-promotion stage...'
    $action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument '-NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\ADLab\Stage2.ps1'
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName 'Kali-AD-Lab-Stage2' -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null

    Write-Host '[Stage1] Restarting Windows to continue AD configuration...'
    Stop-Transcript
    Restart-Computer -Force
}
catch {
    Write-Error $_
    $_ | Out-File 'C:\ADLab\FAILED-Stage1.txt' -Append
    Stop-Transcript
    exit 1
}
