$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = 'C:\ADLab'
$LogDir = Join-Path $Root 'Logs'
$LogFile = Join-Path $LogDir 'Configure-AD.log'
$FailureFile = Join-Path $Root 'FAILED-Configure-AD.txt'
$SuccessFile = Join-Path $Root 'SUCCESS.txt'
$AssessmentMarker = Join-Path $Root 'ASSESSMENT-DEMO-READY.txt'
$ExpectedFile = Join-Path $Root 'EXPECTED-FINDINGS.txt'
$TaskName = 'Kali-AD-Lab-ConfigureAD'
$AttemptFile = Join-Path $Root 'configure-attempts.txt'

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
Start-Transcript -Path $LogFile -Append

function Stop-TranscriptSafe { try { Stop-Transcript | Out-Null } catch {} }

function Wait-WindowsSetupComplete {
    Write-Host '[Configure-AD] Waiting for Windows Setup/OOBE to finish before configuring AD...'
    for ($i = 0; $i -lt 180; $i++) {
        $setup = Get-ItemProperty 'HKLM:\SYSTEM\Setup' -ErrorAction SilentlyContinue
        $systemSetup = if ($setup -and $null -ne $setup.SystemSetupInProgress) { [int]$setup.SystemSetupInProgress } else { 0 }
        $oobe = if ($setup -and $null -ne $setup.OOBEInProgress) { [int]$setup.OOBEInProgress } else { 0 }
        if ($systemSetup -eq 0 -and $oobe -eq 0) { Write-Host '[Configure-AD] Windows Setup is complete.'; return }
        Start-Sleep -Seconds 10
    }
    throw 'Windows Setup/OOBE did not complete within 30 minutes.'
}

function Get-PrimaryAdapter {
    for ($i = 0; $i -lt 24; $i++) {
        $a = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.HardwareInterface } | Sort-Object ifIndex | Select-Object -First 1
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
    $desired = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $Config.DcIp }
    if (-not $desired) {
        Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -ne 'WellKnown' -and $_.IPAddress -ne $Config.DcIp -and $_.IPAddress -notlike '169.254.*' } | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' } | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        if ($Config.NetworkMode -eq 'nat') { New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $Config.DcIp -PrefixLength $Config.PrefixLength -DefaultGateway $Config.Gateway | Out-Null }
        else { New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $Config.DcIp -PrefixLength $Config.PrefixLength | Out-Null }
    } elseif ($Config.NetworkMode -eq 'nat') {
        $defaultRoute = Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -eq $Config.Gateway } | Select-Object -First 1
        if (-not $defaultRoute) { New-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -NextHop $Config.Gateway -ErrorAction SilentlyContinue | Out-Null }
    }
    return $adapter
}

function Ensure-OU([string]$Name,[string]$Path) {
    $dn = "OU=$Name,$Path"
    if (-not (Get-ADOrganizationalUnit -Identity $dn -ErrorAction SilentlyContinue)) { New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $false | Out-Null }
    return $dn
}
function Ensure-Group([string]$Name,[string]$Path) {
    if (-not (Get-ADGroup -Filter "SamAccountName -eq '$Name'" -ErrorAction SilentlyContinue)) { New-ADGroup -Name $Name -SamAccountName $Name -GroupCategory Security -GroupScope Global -Path $Path | Out-Null }
}
function Ensure-User([string]$Sam,[string]$Display,[string]$Path,[securestring]$Password,[string]$Domain) {
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$Sam'" -ErrorAction SilentlyContinue)) {
        New-ADUser -Name $Display -DisplayName $Display -SamAccountName $Sam -UserPrincipalName "$Sam@$Domain" -Path $Path -AccountPassword $Password -Enabled $true -ChangePasswordAtLogon $false -Description '[Kali-AD-Lab] synthetic assessment account' | Out-Null
    }
}
function Ensure-ComputerObject([string]$Name,[string]$Path) {
    if (-not (Get-ADComputer -Filter "Name -eq '$Name'" -ErrorAction SilentlyContinue)) { New-ADComputer -Name $Name -SamAccountName "${Name}$" -Path $Path -Enabled $true -Description '[Kali-AD-Lab] synthetic assessment object' | Out-Null }
}
function Ensure-Member([string]$Group,[string]$Member) {
    $present = Get-ADGroupMember -Identity $Group -ErrorAction SilentlyContinue | Where-Object { $_.SamAccountName -eq $Member -or $_.Name -eq $Member }
    if (-not $present) { Add-ADGroupMember -Identity $Group -Members $Member }
}
function Grant-AdRight([string]$TargetDn,[string]$Principal,[System.DirectoryServices.ActiveDirectoryRights]$Rights) {
    $sid = (Get-ADGroup -Identity $Principal).SID
    $entry = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$TargetDn")
    $acl = $entry.ObjectSecurity
    $rules = $acl.GetAccessRules($true,$true,[System.Security.Principal.SecurityIdentifier])
    if (-not ($rules | Where-Object { $_.IdentityReference -eq $sid -and ($_.ActiveDirectoryRights -band $Rights) -eq $Rights -and $_.AccessControlType -eq 'Allow' })) {
        $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sid,$Rights,[System.Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule) | Out-Null; $entry.ObjectSecurity = $acl; $entry.CommitChanges()
    }
}
function Grant-ExtendedRight([string]$TargetDn,[string]$Principal,[Guid]$ObjectType) {
    $sid = (Get-ADGroup -Identity $Principal).SID
    $entry = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$TargetDn")
    $acl = $entry.ObjectSecurity
    $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sid,[System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,[System.Security.AccessControl.AccessControlType]::Allow,$ObjectType)
    $acl.AddAccessRule($rule) | Out-Null; $entry.ObjectSecurity = $acl; $entry.CommitChanges()
}
function Ensure-Gpo([string]$Name) {
    Import-Module GroupPolicy
    $g = Get-GPO -Name $Name -ErrorAction SilentlyContinue
    if (-not $g) { $g = New-GPO -Name $Name }
    return $g
}

function Invoke-AssessmentDemo {
    param($Config)
    if (Test-Path $AssessmentMarker) { Write-Host '[AssessmentDemo] Existing assessment-demo marker found; skipping reseed.'; return }
    if ($Config.DomainFqdn -notmatch '\.(test|lab|example|invalid)$') { throw 'Safety stop: assessment-demo is allowed only in .test, .lab, .example, or .invalid domains.' }
    Write-Host '[AssessmentDemo] Creating comprehensive AD security-assessment scenarios...'
    Import-Module ActiveDirectory
    $domain = Get-ADDomain; $base = $domain.DistinguishedName

    $ouTier0 = Ensure-OU 'Tier0' $base; $ouTier0Admins = Ensure-OU 'Admins' $ouTier0
    $ouTier1 = Ensure-OU 'Tier1' $base; $ouTier1Admins = Ensure-OU 'Server-Admins' $ouTier1; $ouServers = Ensure-OU 'Servers' $ouTier1
    $ouTier2 = Ensure-OU 'Tier2' $base; $ouUsers = Ensure-OU 'Users' $ouTier2; $ouWorkstations = Ensure-OU 'Workstations' $ouTier2
    $ouHelpdesk = Ensure-OU 'Helpdesk' $base; $ouSvc = Ensure-OU 'Service-Accounts' $base; $ouLegacy = Ensure-OU 'Legacy' $base
    $ouDisabled = Ensure-OU 'Disabled-Accounts' $base; $ouGroups = Ensure-OU 'Security-Groups' $base

    foreach ($g in @('GG-Tier0-Admins','GG-Tier1-ServerAdmins','GG-Helpdesk','GG-AppAdmins','GG-Workstation-LocalAdmins','GG-Legacy-Admins','GG-Password-Resetters','GG-Delegation-Operators')) { Ensure-Group $g $ouGroups }
    $generated = 'Lab-' + [guid]::NewGuid().ToString('N').Substring(0,18) + '!Aa1'; $pwd = ConvertTo-SecureString $generated -AsPlainText -Force
    $users = @(
        @('t0.admin1','Tier0 Admin One',$ouTier0Admins),@('t0.admin2','Tier0 Admin Two',$ouTier0Admins),@('t0.legacyadmin','Legacy Domain Admin',$ouLegacy),
        @('t1.serveradmin1','Tier1 Server Admin One',$ouTier1Admins),@('t1.serveradmin2','Tier1 Server Admin Two',$ouTier1Admins),@('helpdesk1','Helpdesk One',$ouHelpdesk),
        @('helpdesk2','Helpdesk Two',$ouHelpdesk),@('helpdesk3','Helpdesk Three',$ouHelpdesk),@('svc.backup','Backup Service',$ouSvc),@('svc.web','Web Service',$ouSvc),
        @('svc.sql','SQL Service',$ouSvc),@('svc.legacy','Legacy Service',$ouSvc),@('user01','Business User 01',$ouUsers),@('user02','Business User 02',$ouUsers),
        @('user03','Business User 03',$ouUsers),@('user04','Business User 04',$ouUsers),@('user05','Business User 05',$ouUsers),@('user06','Business User 06',$ouUsers),
        @('user07','Business User 07',$ouUsers),@('user08','Business User 08',$ouUsers),@('contractor.old','Old Contractor',$ouLegacy),@('admin.stale','Stale Privileged Admin',$ouLegacy),
        @('app.operator','Application Operator',$ouTier1Admins),@('audit.reader','Audit Reader',$ouUsers)
    )
    foreach ($u in $users) { Ensure-User $u[0] $u[1] $u[2] $pwd $Config.DomainFqdn }
    foreach ($n in @('APP01','FILE01','SQL01','WEB01')) { Ensure-ComputerObject $n $ouServers }
    foreach ($n in @('WS001','WS002','WS003','WS004','WS005','WS006')) { Ensure-ComputerObject $n $ouWorkstations }

    Ensure-Member 'GG-Tier0-Admins' 't0.admin1'; Ensure-Member 'GG-Tier0-Admins' 't0.admin2'
    Ensure-Member 'GG-Tier1-ServerAdmins' 't1.serveradmin1'; Ensure-Member 'GG-Tier1-ServerAdmins' 't1.serveradmin2'
    Ensure-Member 'GG-Helpdesk' 'helpdesk1'; Ensure-Member 'GG-Helpdesk' 'helpdesk2'; Ensure-Member 'GG-Helpdesk' 'helpdesk3'
    Ensure-Member 'GG-AppAdmins' 'app.operator'; Ensure-Member 'GG-Legacy-Admins' 't0.legacyadmin'; Ensure-Member 'GG-Delegation-Operators' 'audit.reader'

    # Privileged access and tiering cases.
    Ensure-Member 'Domain Admins' 'GG-Tier1-ServerAdmins'; Ensure-Member 'Domain Admins' 't0.legacyadmin'; Ensure-Member 'Domain Admins' 'admin.stale'
    Ensure-Member 'Enterprise Admins' 't0.admin2'; Ensure-Member 'Schema Admins' 't0.legacyadmin'; Ensure-Member 'Backup Operators' 'svc.backup'
    Ensure-Member 'Account Operators' 'helpdesk1'; Ensure-Member 'DNSAdmins' 'user07'; Ensure-Member 'Protected Users' 't0.admin1'
    Set-ADAccountControl 't0.admin2' -AccountNotDelegated $false; Set-ADAccountControl 't0.legacyadmin' -AccountNotDelegated $false

    # Account, password and Kerberos cases.
    Set-ADAccountControl 'svc.backup' -PasswordNeverExpires $true
    Set-ADAccountControl 'svc.web' -PasswordNeverExpires $true; Set-ADUser 'svc.web' -ServicePrincipalNames @{Replace=@("HTTP/web01.$($Config.DomainFqdn)")} -Replace @{'msDS-SupportedEncryptionTypes'=4}
    Set-ADAccountControl 'svc.sql' -PasswordNeverExpires $true -TrustedToAuthForDelegation $true; Set-ADUser 'svc.sql' -ServicePrincipalNames @{Replace=@("MSSQLSvc/sql01.$($Config.DomainFqdn):1433")} -Replace @{'msDS-AllowedToDelegateTo'=@("cifs/file01.$($Config.DomainFqdn)")}
    Set-ADAccountControl 'svc.legacy' -DoesNotRequirePreAuth $true -UseDESKeyOnly $true -PasswordNeverExpires $true
    Set-ADAccountControl 'user06' -AllowReversiblePasswordEncryption $true; Set-ADAccountControl 'contractor.old' -PasswordNotRequired $true
    Set-ADAccountExpiration 'contractor.old' -DateTime (Get-Date).AddDays(-30); Enable-ADAccount 'contractor.old'
    Set-ADUser 'user05' -ChangePasswordAtLogon $true; Set-ADUser 'user08' -Replace @{adminCount=1}; Set-ADAccountControl 'admin.stale' -PasswordNeverExpires $true

    # Password policy and machine-account cases.
    Set-ADDefaultDomainPasswordPolicy -Identity $Config.DomainFqdn -MinPasswordLength 6 -PasswordHistoryCount 3 -ComplexityEnabled $false -LockoutThreshold 0 -MaxPasswordAge (New-TimeSpan -Days 365)
    Set-ADObject -Identity $base -Replace @{'ms-DS-MachineAccountQuota'=25}
    if (-not (Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'Legacy-Service-Account-Policy'" -ErrorAction SilentlyContinue)) {
        New-ADFineGrainedPasswordPolicy -Name 'Legacy-Service-Account-Policy' -Precedence 50 -ComplexityEnabled $false -Description '[Kali-AD-Lab] intentionally weak assessment policy' -DisplayName 'Legacy Service Account Policy' -LockoutDuration (New-TimeSpan -Minutes 1) -LockoutObservationWindow (New-TimeSpan -Minutes 1) -LockoutThreshold 0 -MaxPasswordAge (New-TimeSpan -Days 730) -MinPasswordAge (New-TimeSpan -Days 0) -MinPasswordLength 6 -PasswordHistoryCount 1 -ReversibleEncryptionEnabled $true | Out-Null
    }
    foreach ($sam in @('svc.backup','svc.web','svc.sql','svc.legacy')) { Add-ADFineGrainedPasswordPolicySubject -Identity 'Legacy-Service-Account-Policy' -Subjects $sam -ErrorAction SilentlyContinue }

    # Delegation / computer hygiene cases.
    Set-ADAccountControl 'APP01$' -TrustedForDelegation $true
    foreach ($c in @('WS001','WS002','WS003','WS004','WS005','WS006')) { Set-ADComputer $c -Replace @{pwdLastSet=0} }

    # Shadow-admin ACL cases, including DCSync-equivalent replication rights.
    Grant-AdRight $ouSvc 'GG-Helpdesk' ([System.DirectoryServices.ActiveDirectoryRights]::GenericAll)
    Grant-AdRight $base 'GG-AppAdmins' ([System.DirectoryServices.ActiveDirectoryRights]::WriteDacl)
    Grant-AdRight "CN=AdminSDHolder,CN=System,$base" 'GG-Legacy-Admins' ([System.DirectoryServices.ActiveDirectoryRights]::GenericAll)
    Grant-AdRight $ouTier0 'GG-Helpdesk' ([System.DirectoryServices.ActiveDirectoryRights]::GenericWrite)
    Grant-ExtendedRight $base 'GG-Delegation-Operators' ([Guid]'1131f6aa-9c07-11d1-f79f-00c04fc2dcd2')
    Grant-ExtendedRight $base 'GG-Delegation-Operators' ([Guid]'1131f6ad-9c07-11d1-f79f-00c04fc2dcd2')
    Grant-ExtendedRight $base 'GG-Delegation-Operators' ([Guid]'89e95b76-444d-4c62-991a-0facbeda640c')

    # Group Policy cases.
    Import-Module GroupPolicy
    $legacyGpo = Ensure-Gpo 'Workstation-Legacy-Compatibility'; try { New-GPLink -Name $legacyGpo.DisplayName -Target $ouWorkstations -LinkEnabled Yes -ErrorAction Stop | Out-Null } catch {}
    Set-GPRegistryValue -Name $legacyGpo.DisplayName -Key 'HKLM\Software\Policies\Microsoft\Windows NT\DNSClient' -ValueName 'EnableMulticast' -Type DWord -Value 1
    Set-GPRegistryValue -Name $legacyGpo.DisplayName -Key 'HKLM\System\CurrentControlSet\Control\Lsa' -ValueName 'LmCompatibilityLevel' -Type DWord -Value 1
    Set-GPRegistryValue -Name $legacyGpo.DisplayName -Key 'HKLM\System\CurrentControlSet\Services\LanmanWorkstation\Parameters' -ValueName 'RequireSecuritySignature' -Type DWord -Value 0
    Set-GPPermission -Name $legacyGpo.DisplayName -TargetName 'GG-Helpdesk' -TargetType Group -PermissionLevel GpoEditDeleteModifySecurity -Replace
    Ensure-Gpo 'Legacy-Unlinked-GPO' | Out-Null

    # Domain Controller protocol-hardening cases.
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters' -Name LDAPServerIntegrity -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters' -Name LdapEnforceChannelBinding -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name LmCompatibilityLevel -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name RestrictAnonymous -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name RestrictAnonymousSAM -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name EveryoneIncludesAnonymous -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name NoLMHash -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -Name RequireSecuritySignature -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -Name EnableSecuritySignature -PropertyType DWord -Value 0 -Force | Out-Null
    Set-Service Spooler -StartupType Automatic; Start-Service Spooler -ErrorAction SilentlyContinue

    # DNS cases.
    try { Import-Module DnsServer; Set-DnsServerPrimaryZone -Name $Config.DomainFqdn -DynamicUpdate NonsecureAndSecure; Set-DnsServerPrimaryZone -Name $Config.DomainFqdn -SecureSecondaries TransferAnyServer } catch { Write-Warning "DNS scenario warning: $($_.Exception.Message)" }

    @'
Kali-AD-Lab assessment-demo expected finding families
ADL-001 Nested Tier-1 administrators in Domain Admins
ADL-002 Legacy direct Domain Admin membership
ADL-003 Excess Enterprise Admin membership
ADL-004 Excess Schema Admin membership
ADL-005 Service account in Backup Operators
ADL-006 Helpdesk user in Account Operators
ADL-007 Standard user in DNSAdmins
ADL-008 Privileged accounts missing Protected Users coverage
ADL-009 Privileged accounts delegatable
ADL-010 Password-never-expires service accounts
ADL-011 Kerberoastable HTTP service account
ADL-012 RC4-only service account
ADL-013 Kerberoastable SQL service account
ADL-014 Constrained delegation with protocol transition
ADL-015 AS-REP roastable service account
ADL-016 DES-only Kerberos account
ADL-017 Reversible password encryption enabled
ADL-018 Password-not-required account
ADL-019 Expired but enabled contractor account
ADL-020 Password-change / pwdLastSet hygiene case
ADL-021 AdminCount anomaly on non-privileged user
ADL-022 Retained privileged account
ADL-023 Weak default domain password policy
ADL-024 No account lockout
ADL-025 Excess MachineAccountQuota
ADL-026 Weak fine-grained service-account password policy
ADL-027 Unconstrained delegation on APP01
ADL-028 Synthetic workstation password/LAPS coverage gaps
ADL-029 Helpdesk GenericAll over service-account OU
ADL-030 Application admins can write domain-root DACL
ADL-031 Legacy admins control AdminSDHolder
ADL-032 Helpdesk GenericWrite on Tier0 OU
ADL-033 Replication/DCSync rights delegated to non-admin group
ADL-034 Helpdesk can edit/delete/modify security on linked GPO
ADL-035 Weak workstation GPO enables LLMNR
ADL-036 Weak workstation GPO allows NTLMv1 compatibility
ADL-037 Weak workstation GPO does not require SMB signing
ADL-038 Unlinked/orphaned legacy GPO
ADL-039 DC LDAP signing not required
ADL-040 DC LDAP channel binding disabled
ADL-041 DC NTLMv1 compatibility enabled
ADL-042 Anonymous enumeration restrictions weakened
ADL-043 LM hash storage protection disabled
ADL-044 SMB server signing not required
ADL-045 Print Spooler enabled on Domain Controller
ADL-046 DNS zone permits nonsecure dynamic updates
ADL-047 DNS zone transfer permitted to any server

Advanced infrastructure-dependent categories intentionally remain separate profiles: AD CS/PKI, cross-domain/forest trusts, multi-DC replication, RODC, and hybrid identity.
'@ | Out-File $ExpectedFile -Encoding utf8

    @"
Kali-AD-Lab Security Assessment Demo is ready.
Domain: $($Config.DomainFqdn)
Synthetic users: 24
Synthetic computers: 10
Expected assessment scenarios: 47
WARNING: This domain is intentionally insecure and must remain isolated from production networks.
Generated: $(Get-Date -Format o)
"@ | Out-File $AssessmentMarker -Encoding utf8
    Write-Host '[AssessmentDemo] 47 controlled assessment scenarios are ready.'
}

function Complete-Lab {
    param($Config)
    Write-Host '[Configure-AD] Domain controller detected. Validating AD services...'
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        $ntds = Get-Service NTDS -ErrorAction SilentlyContinue; $adws = Get-Service ADWS -ErrorAction SilentlyContinue; $dns = Get-Service DNS -ErrorAction SilentlyContinue
        if ($ntds.Status -eq 'Running' -and $adws.Status -eq 'Running' -and $dns.Status -eq 'Running') { $ready = $true; break }
        Start-Sleep -Seconds 10
    }
    if (-not $ready) { throw 'AD DS/DNS services did not reach Running state.' }
    Import-Module ActiveDirectory
    $domain = Get-ADDomain; $forest = Get-ADForest
    if ($domain.DNSRoot -ne $Config.DomainFqdn) { throw "Domain mismatch. Expected $($Config.DomainFqdn), found $($domain.DNSRoot)." }
    if ($Config.NetworkMode -eq 'nat') {
        try { Import-Module DnsServer; $forwarders = Get-DnsServerForwarder -ErrorAction SilentlyContinue; if (-not ($forwarders.IPAddress.IPAddressToString -contains $Config.Gateway)) { Add-DnsServerForwarder -IPAddress $Config.Gateway -PassThru | Out-Null } } catch { Write-Warning "DNS forwarder could not be added automatically: $($_.Exception.Message)" }
    }
    $profile = if ($Config.ContainsKey('AssessmentProfile') -and $Config.AssessmentProfile) { [string]$Config.AssessmentProfile } else { 'assessment-demo' }
    if ($profile -eq 'assessment-demo') { Invoke-AssessmentDemo -Config $Config }
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
    Remove-Item $AttemptFile -Force -ErrorAction SilentlyContinue; Remove-Item $FailureFile -Force -ErrorAction SilentlyContinue
    Write-Host "[Configure-AD] Active Directory lab is ready. Profile: $profile"
}

try {
    Wait-WindowsSetupComplete; Start-Sleep -Seconds 15
    $attempt = 0; if (Test-Path $AttemptFile) { $attempt = [int](Get-Content $AttemptFile -ErrorAction SilentlyContinue | Select-Object -First 1) }; $attempt++; $attempt | Out-File $AttemptFile -Encoding ascii
    Write-Host "[Configure-AD] Resume attempt $attempt"
    $ConfigFile = Join-Path $Root 'config.ps1'; if (-not (Test-Path $ConfigFile)) { throw 'Runtime configuration C:\ADLab\config.ps1 is missing.' }; . $ConfigFile
    $computerSystem = Get-CimInstance Win32_ComputerSystem
    if ($computerSystem.DomainRole -ge 4) { Complete-Lab -Config $LabConfig; Stop-TranscriptSafe; exit 0 }
    $adapter = Ensure-Network -Config $LabConfig
    if ($LabConfig.NetworkMode -eq 'nat') { Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @($LabConfig.Gateway) }
    $feature = Get-WindowsFeature AD-Domain-Services
    if (-not $feature.Installed) {
        Write-Host '[Configure-AD] Installing Active Directory Domain Services and management tools...'
        $result = Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
        if (-not $result.Success) { throw 'AD-Domain-Services feature installation failed.' }
        if ($result.RestartNeeded -eq 'Yes') { Write-Host '[Configure-AD] Windows requires a reboot before domain promotion. Resuming automatically after restart...'; Stop-TranscriptSafe; Restart-Computer -Force; exit 0 }
    }
    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @($LabConfig.DcIp)
    $computerSystem = Get-CimInstance Win32_ComputerSystem
    if ($computerSystem.DomainRole -ge 4) { Complete-Lab -Config $LabConfig; Stop-TranscriptSafe; exit 0 }
    Write-Host "[Configure-AD] Promoting $env:COMPUTERNAME as the first DC for $($LabConfig.DomainFqdn)..."
    $dsrmPlain = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($LabConfig.DsrmPasswordB64)); $dsrmSecure = ConvertTo-SecureString $dsrmPlain -AsPlainText -Force
    Import-Module ADDSDeployment
    Install-ADDSForest -DomainName $LabConfig.DomainFqdn -DomainNetbiosName $LabConfig.NetbiosName -InstallDns -CreateDnsDelegation:$false -SafeModeAdministratorPassword $dsrmSecure -NoRebootOnCompletion:$false -Force
}
catch {
    $msg = "[$(Get-Date -Format o)] $($_.Exception.Message)"; Write-Error $msg; $msg | Out-File $FailureFile -Append -Encoding utf8
    $attempt = 1; if (Test-Path $AttemptFile) { try { $attempt = [int](Get-Content $AttemptFile | Select-Object -First 1) } catch {} }
    if ($attempt -ge 5) { Disable-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null; Write-Error '[Configure-AD] Five attempts failed; automatic retry has been disabled.' }
    Stop-TranscriptSafe; exit 1
}
