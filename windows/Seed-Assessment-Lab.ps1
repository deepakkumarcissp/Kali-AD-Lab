param(
    [Parameter(Mandatory=$true)][string]$ExpectedDomain
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = 'C:\ADLab'
$LogDir = Join-Path $Root 'Logs'
$LogFile = Join-Path $LogDir 'Seed-Assessment-Lab.log'
$MarkerFile = Join-Path $Root 'ASSESSMENT-DEMO-READY.txt'
$IdentityMarker = Join-Path $Root 'ASSESSMENT-IDENTITIES-READY.txt'
$ExpectedFile = Join-Path $Root 'EXPECTED-FINDINGS.txt'
$WarningFile = Join-Path $Root 'SCENARIO-WARNINGS.txt'

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
Start-Transcript -Path $LogFile -Append

$script:ScenarioWarnings = New-Object System.Collections.Generic.List[string]

function Stop-TranscriptSafe { try { Stop-Transcript | Out-Null } catch {} }
function Invoke-Scenario {
    param([string]$Id,[string]$Description,[scriptblock]$Action)
    try {
        & $Action
        Write-Host "[AssessmentDemo] $Id OK - $Description"
    }
    catch {
        $line = "$Id | $Description | $($_.Exception.Message)"
        $script:ScenarioWarnings.Add($line)
        Write-Warning "[AssessmentDemo] $line"
    }
}
function Ensure-OU {
    param([string]$Name,[string]$Path)
    $existing = Get-ADOrganizationalUnit -Filter "Name -eq '$Name'" -SearchBase $Path -SearchScope OneLevel -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $existing) {
        $existing = New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $false -PassThru
    }
    return $existing.DistinguishedName
}
function Ensure-Group {
    param([string]$Name,[string]$Path,[ValidateSet('Global','DomainLocal','Universal')][string]$Scope='Global')
    $g = Get-ADGroup -Identity $Name -ErrorAction SilentlyContinue
    if (-not $g) {
        $g = New-ADGroup -Name $Name -SamAccountName $Name -GroupCategory Security -GroupScope $Scope -Path $Path -PassThru
    }
    return $g
}
function Ensure-User {
    param([string]$Sam,[string]$Display,[string]$Path,[securestring]$Password)
    $u = Get-ADUser -Identity $Sam -ErrorAction SilentlyContinue
    if (-not $u) {
        $u = New-ADUser -Name $Display -DisplayName $Display -SamAccountName $Sam -UserPrincipalName "$Sam@$ExpectedDomain" -Path $Path -AccountPassword $Password -Enabled $true -ChangePasswordAtLogon $false -Description '[Kali-AD-Lab] synthetic assessment account' -PassThru
    }
    return $u
}
function Ensure-ComputerObject {
    param([string]$Name,[string]$Path)
    $c = Get-ADComputer -Identity $Name -ErrorAction SilentlyContinue
    if (-not $c) {
        $c = New-ADComputer -Name $Name -SamAccountName "${Name}$" -Path $Path -Enabled $true -Description '[Kali-AD-Lab] synthetic assessment object' -PassThru
    }
    return $c
}
function Ensure-Member {
    param([string]$Group,[string]$Member)
    $present = Get-ADGroupMember -Identity $Group -ErrorAction SilentlyContinue | Where-Object { $_.SamAccountName -eq $Member -or $_.Name -eq $Member }
    if (-not $present) { Add-ADGroupMember -Identity $Group -Members $Member }
}
function Grant-AdRight {
    param([string]$TargetDn,[string]$Principal,[System.DirectoryServices.ActiveDirectoryRights]$Rights)
    $sid = (Get-ADGroup -Identity $Principal).SID
    $entry = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$TargetDn")
    $acl = $entry.ObjectSecurity
    $rules = $acl.GetAccessRules($true,$true,[System.Security.Principal.SecurityIdentifier])
    $exists = $rules | Where-Object { $_.IdentityReference -eq $sid -and ($_.ActiveDirectoryRights -band $Rights) -eq $Rights -and $_.AccessControlType -eq 'Allow' }
    if (-not $exists) {
        $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sid,$Rights,[System.Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule) | Out-Null
        $entry.ObjectSecurity = $acl
        $entry.CommitChanges()
    }
}
function Grant-ExtendedRight {
    param([string]$TargetDn,[string]$Principal,[Guid]$ObjectType)
    $sid = (Get-ADGroup -Identity $Principal).SID
    $entry = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$TargetDn")
    $acl = $entry.ObjectSecurity
    $rules = $acl.GetAccessRules($true,$true,[System.Security.Principal.SecurityIdentifier])
    $exists = $rules | Where-Object { $_.IdentityReference -eq $sid -and $_.ObjectType -eq $ObjectType -and $_.AccessControlType -eq 'Allow' }
    if (-not $exists) {
        $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sid,[System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,[System.Security.AccessControl.AccessControlType]::Allow,$ObjectType)
        $acl.AddAccessRule($rule) | Out-Null
        $entry.ObjectSecurity = $acl
        $entry.CommitChanges()
    }
}
function Ensure-Gpo {
    param([string]$Name)
    Import-Module GroupPolicy
    $gpo = Get-GPO -Name $Name -ErrorAction SilentlyContinue
    if (-not $gpo) { $gpo = New-GPO -Name $Name }
    return $gpo
}

try {
    Import-Module ActiveDirectory
    $domain = Get-ADDomain
    if ($domain.DNSRoot -ne $ExpectedDomain) { throw "Safety stop: expected $ExpectedDomain but found $($domain.DNSRoot)." }
    if ($domain.DNSRoot -notmatch '\.(test|lab|example|invalid)$') { throw 'Safety stop: assessment seeding is allowed only in .test, .lab, .example, or .invalid training domains.' }
    if ((Get-CimInstance Win32_ComputerSystem).DomainRole -lt 4) { throw 'Safety stop: this machine is not a domain controller.' }

    Write-Host '[AssessmentDemo] Creating the core synthetic organization first...'
    $base = $domain.DistinguishedName

    $ouTier0 = Ensure-OU 'Tier0' $base
    $ouTier0Admins = Ensure-OU 'Admins' $ouTier0
    $ouTier1 = Ensure-OU 'Tier1' $base
    $ouTier1Admins = Ensure-OU 'Server-Admins' $ouTier1
    $ouServers = Ensure-OU 'Servers' $ouTier1
    $ouTier2 = Ensure-OU 'Tier2' $base
    $ouUsers = Ensure-OU 'Users' $ouTier2
    $ouWorkstations = Ensure-OU 'Workstations' $ouTier2
    $ouHelpdesk = Ensure-OU 'Helpdesk' $base
    $ouSvc = Ensure-OU 'Service-Accounts' $base
    $ouLegacy = Ensure-OU 'Legacy' $base
    $ouDisabled = Ensure-OU 'Disabled-Accounts' $base
    $ouGroups = Ensure-OU 'Security-Groups' $base

    $groups = @('GG-Tier0-Admins','GG-Tier1-ServerAdmins','GG-Helpdesk','GG-AppAdmins','GG-Workstation-LocalAdmins','GG-Legacy-Admins','GG-Password-Resetters','GG-Delegation-Operators')
    foreach ($g in $groups) { Ensure-Group $g $ouGroups | Out-Null }

    $plain = 'Lab-' + [guid]::NewGuid().ToString('N').Substring(0,18) + '!Aa1'
    $pwd = ConvertTo-SecureString $plain -AsPlainText -Force

    $users = @(
        @{Sam='t0.admin1';Name='Tier0 Admin One';Path=$ouTier0Admins},
        @{Sam='t0.admin2';Name='Tier0 Admin Two';Path=$ouTier0Admins},
        @{Sam='t0.legacyadmin';Name='Legacy Domain Admin';Path=$ouLegacy},
        @{Sam='t1.serveradmin1';Name='Tier1 Server Admin One';Path=$ouTier1Admins},
        @{Sam='t1.serveradmin2';Name='Tier1 Server Admin Two';Path=$ouTier1Admins},
        @{Sam='helpdesk1';Name='Helpdesk One';Path=$ouHelpdesk},
        @{Sam='helpdesk2';Name='Helpdesk Two';Path=$ouHelpdesk},
        @{Sam='helpdesk3';Name='Helpdesk Three';Path=$ouHelpdesk},
        @{Sam='svc.backup';Name='Backup Service';Path=$ouSvc},
        @{Sam='svc.web';Name='Web Service';Path=$ouSvc},
        @{Sam='svc.sql';Name='SQL Service';Path=$ouSvc},
        @{Sam='svc.legacy';Name='Legacy Service';Path=$ouSvc},
        @{Sam='user01';Name='Business User 01';Path=$ouUsers},
        @{Sam='user02';Name='Business User 02';Path=$ouUsers},
        @{Sam='user03';Name='Business User 03';Path=$ouUsers},
        @{Sam='user04';Name='Business User 04';Path=$ouUsers},
        @{Sam='user05';Name='Business User 05';Path=$ouUsers},
        @{Sam='user06';Name='Business User 06';Path=$ouUsers},
        @{Sam='user07';Name='Business User 07';Path=$ouUsers},
        @{Sam='user08';Name='Business User 08';Path=$ouUsers},
        @{Sam='contractor.old';Name='Old Contractor';Path=$ouLegacy},
        @{Sam='admin.stale';Name='Stale Privileged Admin';Path=$ouLegacy},
        @{Sam='app.operator';Name='Application Operator';Path=$ouTier1Admins},
        @{Sam='audit.reader';Name='Audit Reader';Path=$ouUsers}
    )
    foreach ($u in $users) { Ensure-User $u.Sam $u.Name $u.Path $pwd | Out-Null }

    $serverNames = @('APP01','FILE01','SQL01','WEB01')
    $workstationNames = @('WS001','WS002','WS003','WS004','WS005','WS006')
    foreach ($n in $serverNames) { Ensure-ComputerObject $n $ouServers | Out-Null }
    foreach ($n in $workstationNames) { Ensure-ComputerObject $n $ouWorkstations | Out-Null }

    $expectedUsers = @($users | ForEach-Object { $_.Sam })
    $expectedComputers = @($serverNames + $workstationNames)
    $missingUsers = @($expectedUsers | Where-Object { -not (Get-ADUser -Identity $_ -ErrorAction SilentlyContinue) })
    $missingComputers = @($expectedComputers | Where-Object { -not (Get-ADComputer -Identity $_ -ErrorAction SilentlyContinue) })
    if ($missingUsers.Count -gt 0) { throw "Core user creation failed. Missing: $($missingUsers -join ', ')" }
    if ($missingComputers.Count -gt 0) { throw "Core computer creation failed. Missing: $($missingComputers -join ', ')" }

    @"
Core assessment identities are ready.
Synthetic users: 24
Synthetic computers: 10
Created/verified: $(Get-Date -Format o)
"@ | Out-File $IdentityMarker -Encoding utf8
    Write-Host '[AssessmentDemo] Core dataset verified: 24 users and 10 computers.'

    # Baseline group membership used by multiple scenarios.
    Ensure-Member 'GG-Tier0-Admins' 't0.admin1'
    Ensure-Member 'GG-Tier0-Admins' 't0.admin2'
    Ensure-Member 'GG-Tier1-ServerAdmins' 't1.serveradmin1'
    Ensure-Member 'GG-Tier1-ServerAdmins' 't1.serveradmin2'
    Ensure-Member 'GG-Helpdesk' 'helpdesk1'
    Ensure-Member 'GG-Helpdesk' 'helpdesk2'
    Ensure-Member 'GG-Helpdesk' 'helpdesk3'
    Ensure-Member 'GG-AppAdmins' 'app.operator'
    Ensure-Member 'GG-Legacy-Admins' 't0.legacyadmin'
    Ensure-Member 'GG-Delegation-Operators' 'audit.reader'

    Invoke-Scenario 'ADL-001' 'Nested Tier-1 administrators in Domain Admins' { Ensure-Member 'Domain Admins' 'GG-Tier1-ServerAdmins' }
    Invoke-Scenario 'ADL-002' 'Legacy direct Domain Admin membership' { Ensure-Member 'Domain Admins' 't0.legacyadmin' }
    Invoke-Scenario 'ADL-003' 'Excess Enterprise Admin membership' { Ensure-Member 'Enterprise Admins' 't0.admin2' }
    Invoke-Scenario 'ADL-004' 'Excess Schema Admin membership' { Ensure-Member 'Schema Admins' 't0.legacyadmin' }
    Invoke-Scenario 'ADL-005' 'Service account in Backup Operators' { Ensure-Member 'Backup Operators' 'svc.backup' }
    Invoke-Scenario 'ADL-006' 'Helpdesk user in Account Operators' { Ensure-Member 'Account Operators' 'helpdesk1' }
    Invoke-Scenario 'ADL-007' 'Standard user in DNSAdmins' { Ensure-Member 'DNSAdmins' 'user07' }
    Invoke-Scenario 'ADL-008' 'Privileged accounts missing Protected Users coverage' { Ensure-Member 'Protected Users' 't0.admin1' }
    Invoke-Scenario 'ADL-009' 'Privileged accounts remain delegatable' { Set-ADAccountControl -Identity 't0.admin2' -AccountNotDelegated $false; Set-ADAccountControl -Identity 't0.legacyadmin' -AccountNotDelegated $false }
    Invoke-Scenario 'ADL-010' 'Password-never-expires service accounts' { Set-ADUser 'svc.backup' -PasswordNeverExpires $true; Set-ADUser 'svc.web' -PasswordNeverExpires $true; Set-ADUser 'svc.sql' -PasswordNeverExpires $true }
    Invoke-Scenario 'ADL-011' 'Kerberoastable HTTP service account' { Set-ADUser 'svc.web' -ServicePrincipalNames @{Replace=@("HTTP/web01.$ExpectedDomain")} }
    Invoke-Scenario 'ADL-012' 'RC4-only service account' { Set-ADUser 'svc.web' -Replace @{'msDS-SupportedEncryptionTypes'=4} }
    Invoke-Scenario 'ADL-013' 'Kerberoastable SQL service account' { Set-ADUser 'svc.sql' -ServicePrincipalNames @{Replace=@("MSSQLSvc/sql01.${ExpectedDomain}:1433")} }
    Invoke-Scenario 'ADL-014' 'Constrained delegation with protocol transition' { Set-ADUser 'svc.sql' -Replace @{'msDS-AllowedToDelegateTo'=@("cifs/file01.$ExpectedDomain")}; Set-ADAccountControl -Identity 'svc.sql' -TrustedToAuthForDelegation $true }
    Invoke-Scenario 'ADL-015' 'AS-REP roastable service account' { Set-ADAccountControl -Identity 'svc.legacy' -DoesNotRequirePreAuth $true }
    Invoke-Scenario 'ADL-016' 'DES-only Kerberos account' { Set-ADAccountControl -Identity 'svc.legacy' -UseDESKeyOnly $true -PasswordNeverExpires $true }
    Invoke-Scenario 'ADL-017' 'Reversible password encryption enabled' { Set-ADUser 'user06' -AllowReversiblePasswordEncryption $true }
    Invoke-Scenario 'ADL-018' 'Password-not-required account' { Set-ADAccountControl -Identity 'contractor.old' -PasswordNotRequired $true }
    Invoke-Scenario 'ADL-019' 'Expired but enabled contractor account' { Set-ADAccountExpiration -Identity 'contractor.old' -DateTime (Get-Date).AddDays(-30); Enable-ADAccount 'contractor.old' }
    Invoke-Scenario 'ADL-020' 'Password-change / pwdLastSet hygiene case' { Set-ADUser 'user05' -ChangePasswordAtLogon $true }
    Invoke-Scenario 'ADL-021' 'AdminCount anomaly on non-privileged user' { Set-ADUser 'user08' -Replace @{adminCount=1} }
    Invoke-Scenario 'ADL-022' 'Retained privileged account' { Set-ADUser 'admin.stale' -PasswordNeverExpires $true -Description '[Kali-AD-Lab] intentionally retained privileged account for assessment'; Ensure-Member 'Domain Admins' 'admin.stale' }
    Invoke-Scenario 'ADL-023' 'Weak default domain password policy' { Set-ADDefaultDomainPasswordPolicy -Identity $ExpectedDomain -MinPasswordLength 6 -PasswordHistoryCount 3 -ComplexityEnabled $false -MaxPasswordAge (New-TimeSpan -Days 365) }
    Invoke-Scenario 'ADL-024' 'No account lockout' { Set-ADDefaultDomainPasswordPolicy -Identity $ExpectedDomain -LockoutThreshold 0 }
    Invoke-Scenario 'ADL-025' 'Excess MachineAccountQuota' { Set-ADObject -Identity $base -Replace @{'ms-DS-MachineAccountQuota'=25} }
    Invoke-Scenario 'ADL-026' 'Weak fine-grained service-account password policy' {
        if (-not (Get-ADFineGrainedPasswordPolicy -Identity 'Legacy-Service-Account-Policy' -ErrorAction SilentlyContinue)) {
            New-ADFineGrainedPasswordPolicy -Name 'Legacy-Service-Account-Policy' -Precedence 50 -ComplexityEnabled $false -Description '[Kali-AD-Lab] intentionally weak assessment policy' -DisplayName 'Legacy Service Account Policy' -LockoutDuration (New-TimeSpan -Minutes 1) -LockoutObservationWindow (New-TimeSpan -Minutes 1) -LockoutThreshold 0 -MaxPasswordAge (New-TimeSpan -Days 730) -MinPasswordAge (New-TimeSpan -Days 0) -MinPasswordLength 6 -PasswordHistoryCount 1 -ReversibleEncryptionEnabled $true | Out-Null
        }
        foreach ($sam in @('svc.backup','svc.web','svc.sql','svc.legacy')) { Add-ADFineGrainedPasswordPolicySubject -Identity 'Legacy-Service-Account-Policy' -Subjects $sam -ErrorAction SilentlyContinue }
    }
    Invoke-Scenario 'ADL-027' 'Unconstrained delegation on APP01' { Set-ADAccountControl -Identity 'APP01$' -TrustedForDelegation $true }
    Invoke-Scenario 'ADL-028' 'Synthetic workstation password/LAPS coverage gaps' { foreach ($c in $workstationNames) { Set-ADComputer $c -Replace @{pwdLastSet=0} } }
    Invoke-Scenario 'ADL-029' 'Helpdesk GenericAll over service-account OU' { Grant-AdRight $ouSvc 'GG-Helpdesk' ([System.DirectoryServices.ActiveDirectoryRights]::GenericAll) }
    Invoke-Scenario 'ADL-030' 'Application admins can write domain-root DACL' { Grant-AdRight $base 'GG-AppAdmins' ([System.DirectoryServices.ActiveDirectoryRights]::WriteDacl) }
    Invoke-Scenario 'ADL-031' 'Legacy admins control AdminSDHolder' { Grant-AdRight "CN=AdminSDHolder,CN=System,$base" 'GG-Legacy-Admins' ([System.DirectoryServices.ActiveDirectoryRights]::GenericAll) }
    Invoke-Scenario 'ADL-032' 'Helpdesk GenericWrite on Tier0 OU' { Grant-AdRight $ouTier0 'GG-Helpdesk' ([System.DirectoryServices.ActiveDirectoryRights]::GenericWrite) }
    Invoke-Scenario 'ADL-033' 'Replication/DCSync rights delegated to non-admin group' {
        Grant-ExtendedRight $base 'GG-Delegation-Operators' ([Guid]'1131f6aa-9c07-11d1-f79f-00c04fc2dcd2')
        Grant-ExtendedRight $base 'GG-Delegation-Operators' ([Guid]'1131f6ad-9c07-11d1-f79f-00c04fc2dcd2')
        Grant-ExtendedRight $base 'GG-Delegation-Operators' ([Guid]'89e95b76-444d-4c62-991a-0facbeda640c')
    }

    $legacyGpo = $null
    Invoke-Scenario 'ADL-034' 'Helpdesk can edit/delete/modify security on linked GPO' {
        $legacyGpo = Ensure-Gpo 'Workstation-Legacy-Compatibility'
        try { New-GPLink -Name $legacyGpo.DisplayName -Target $ouWorkstations -LinkEnabled Yes -ErrorAction Stop | Out-Null } catch {}
        Set-GPPermission -Name $legacyGpo.DisplayName -TargetName 'GG-Helpdesk' -TargetType Group -PermissionLevel GpoEditDeleteModifySecurity -Replace
    }
    Invoke-Scenario 'ADL-035' 'Weak workstation GPO enables LLMNR' { if (-not $legacyGpo) { $legacyGpo = Ensure-Gpo 'Workstation-Legacy-Compatibility' }; Set-GPRegistryValue -Name $legacyGpo.DisplayName -Key 'HKLM\Software\Policies\Microsoft\Windows NT\DNSClient' -ValueName 'EnableMulticast' -Type DWord -Value 1 }
    Invoke-Scenario 'ADL-036' 'Weak workstation GPO allows NTLMv1 compatibility' { if (-not $legacyGpo) { $legacyGpo = Ensure-Gpo 'Workstation-Legacy-Compatibility' }; Set-GPRegistryValue -Name $legacyGpo.DisplayName -Key 'HKLM\System\CurrentControlSet\Control\Lsa' -ValueName 'LmCompatibilityLevel' -Type DWord -Value 1 }
    Invoke-Scenario 'ADL-037' 'Weak workstation GPO does not require SMB signing' { if (-not $legacyGpo) { $legacyGpo = Ensure-Gpo 'Workstation-Legacy-Compatibility' }; Set-GPRegistryValue -Name $legacyGpo.DisplayName -Key 'HKLM\System\CurrentControlSet\Services\LanmanWorkstation\Parameters' -ValueName 'RequireSecuritySignature' -Type DWord -Value 0 }
    Invoke-Scenario 'ADL-038' 'Unlinked/orphaned legacy GPO' { Ensure-Gpo 'Legacy-Unlinked-GPO' | Out-Null }
    Invoke-Scenario 'ADL-039' 'DC LDAP signing not required' { New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters' -Name LDAPServerIntegrity -PropertyType DWord -Value 0 -Force | Out-Null }
    Invoke-Scenario 'ADL-040' 'DC LDAP channel binding disabled' { New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters' -Name LdapEnforceChannelBinding -PropertyType DWord -Value 0 -Force | Out-Null }
    Invoke-Scenario 'ADL-041' 'DC NTLMv1 compatibility enabled' { New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name LmCompatibilityLevel -PropertyType DWord -Value 1 -Force | Out-Null }
    Invoke-Scenario 'ADL-042' 'Anonymous enumeration restrictions weakened' { New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name RestrictAnonymous -PropertyType DWord -Value 0 -Force | Out-Null; New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name RestrictAnonymousSAM -PropertyType DWord -Value 0 -Force | Out-Null; New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name EveryoneIncludesAnonymous -PropertyType DWord -Value 1 -Force | Out-Null }
    Invoke-Scenario 'ADL-043' 'LM hash storage protection disabled' { New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name NoLMHash -PropertyType DWord -Value 0 -Force | Out-Null }
    Invoke-Scenario 'ADL-044' 'SMB server signing not required' { New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -Name RequireSecuritySignature -PropertyType DWord -Value 0 -Force | Out-Null; New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -Name EnableSecuritySignature -PropertyType DWord -Value 0 -Force | Out-Null }
    Invoke-Scenario 'ADL-045' 'Print Spooler enabled on Domain Controller' { Set-Service Spooler -StartupType Automatic; Start-Service Spooler -ErrorAction SilentlyContinue }
    Invoke-Scenario 'ADL-046' 'DNS zone permits nonsecure dynamic updates' { Import-Module DnsServer; Set-DnsServerPrimaryZone -Name $ExpectedDomain -DynamicUpdate NonsecureAndSecure }
    Invoke-Scenario 'ADL-047' 'DNS zone transfer permitted to any server' { Import-Module DnsServer; Set-DnsServerPrimaryZone -Name $ExpectedDomain -SecureSecondaries TransferAnyServer }

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
'@ | Out-File $ExpectedFile -Encoding utf8

    if ($script:ScenarioWarnings.Count -gt 0) { $script:ScenarioWarnings | Out-File $WarningFile -Encoding utf8 }
    else { Remove-Item $WarningFile -Force -ErrorAction SilentlyContinue }

    # Host-side completion proof: Kali waits for this DNS record before printing LAB READY.
    Invoke-Scenario 'READY-MARKER' 'Assessment completion DNS marker' {
        Import-Module DnsServer
        $dc = Get-ADDomainController -Identity $env:COMPUTERNAME
        $dcIp = [string]$dc.IPv4Address
        $existing = Get-DnsServerResourceRecord -ZoneName $ExpectedDomain -Name 'assessment-ready' -RRType A -ErrorAction SilentlyContinue
        if ($existing) { Remove-DnsServerResourceRecord -ZoneName $ExpectedDomain -InputObject $existing -Force -ErrorAction SilentlyContinue }
        Add-DnsServerResourceRecordA -ZoneName $ExpectedDomain -Name 'assessment-ready' -IPv4Address $dcIp -TimeToLive ([TimeSpan]::FromMinutes(5)) | Out-Null
    }

    @"
Kali-AD-Lab Security Assessment Demo is ready.
Domain: $ExpectedDomain
Synthetic users verified: 24
Synthetic computers verified: 10
Expected assessment scenarios: 47
Scenario warnings: $($script:ScenarioWarnings.Count)
WARNING: This domain is intentionally insecure and must remain isolated from production networks.
Generated: $(Get-Date -Format o)
"@ | Out-File $MarkerFile -Encoding utf8

    Write-Host "[AssessmentDemo] READY: 24 users, 10 computers, 47 scenario families. Warnings: $($script:ScenarioWarnings.Count)"
    Stop-TranscriptSafe
    exit 0
}
catch {
    $msg = "[$(Get-Date -Format o)] $($_.Exception.Message)"
    Write-Error $msg
    $msg | Out-File (Join-Path $Root 'FAILED-Seed-Assessment-Lab.txt') -Append -Encoding utf8
    Stop-TranscriptSafe
    exit 1
}
