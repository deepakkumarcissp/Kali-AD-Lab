param(
    [Parameter(Mandatory=$true)][string]$ExpectedDomain
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = 'C:\ADLab'
$LogDir = Join-Path $Root 'Logs'
$LogFile = Join-Path $LogDir 'Seed-Assessment-Lab.log'
$MarkerFile = Join-Path $Root 'ASSESSMENT-DEMO-READY.txt'
$ExpectedFile = Join-Path $Root 'EXPECTED-FINDINGS.txt'

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
Start-Transcript -Path $LogFile -Append

function Stop-TranscriptSafe { try { Stop-Transcript | Out-Null } catch {} }
function Ensure-OU {
    param([string]$Name,[string]$Path)
    $dn = "OU=$Name,$Path"
    if (-not (Get-ADOrganizationalUnit -Identity $dn -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $false | Out-Null
    }
    return $dn
}
function Ensure-Group {
    param([string]$Name,[string]$Path,[ValidateSet('Global','DomainLocal','Universal')][string]$Scope='Global')
    $g = Get-ADGroup -Filter "SamAccountName -eq '$Name'" -ErrorAction SilentlyContinue
    if (-not $g) {
        $g = New-ADGroup -Name $Name -SamAccountName $Name -GroupCategory Security -GroupScope $Scope -Path $Path -PassThru
    }
    return $g
}
function Ensure-User {
    param([string]$Sam,[string]$Display,[string]$Path,[securestring]$Password)
    $u = Get-ADUser -Filter "SamAccountName -eq '$Sam'" -ErrorAction SilentlyContinue
    if (-not $u) {
        $u = New-ADUser -Name $Display -DisplayName $Display -SamAccountName $Sam -UserPrincipalName "$Sam@$ExpectedDomain" -Path $Path -AccountPassword $Password -Enabled $true -ChangePasswordAtLogon $false -Description '[Kali-AD-Lab] assessment demo account' -PassThru
    }
    return $u
}
function Ensure-ComputerObject {
    param([string]$Name,[string]$Path)
    $c = Get-ADComputer -Filter "Name -eq '$Name'" -ErrorAction SilentlyContinue
    if (-not $c) {
        $c = New-ADComputer -Name $Name -SamAccountName "${Name}$" -Path $Path -Enabled $true -Description '[Kali-AD-Lab] synthetic assessment object' -PassThru
    }
    return $c
}
function Ensure-Member {
    param([string]$Group,[string]$Member)
    try {
        $members = Get-ADGroupMember -Identity $Group -Recursive:$false -ErrorAction Stop
        if (-not ($members | Where-Object { $_.SamAccountName -eq $Member -or $_.Name -eq $Member })) {
            Add-ADGroupMember -Identity $Group -Members $Member
        }
    } catch {
        Add-ADGroupMember -Identity $Group -Members $Member -ErrorAction Stop
    }
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
    if ($domain.DNSRoot -notmatch '\.(test|lab|example|invalid)$') {
        throw "Safety stop: assessment-demo seeding is permitted only in .test, .lab, .example, or .invalid training domains."
    }
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.DomainRole -lt 4) { throw 'Safety stop: this machine is not a domain controller.' }

    Write-Host '[AssessmentDemo] Creating synthetic organization and assessment scenarios...'
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

    $groups = @(
        'GG-Tier0-Admins','GG-Tier1-ServerAdmins','GG-Helpdesk','GG-AppAdmins',
        'GG-Workstation-LocalAdmins','GG-Legacy-Admins','GG-Password-Resetters','GG-Delegation-Operators'
    )
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

    foreach ($n in @('APP01','FILE01','SQL01','WEB01')) { Ensure-ComputerObject $n $ouServers | Out-Null }
    foreach ($n in @('WS001','WS002','WS003','WS004','WS005','WS006')) { Ensure-ComputerObject $n $ouWorkstations | Out-Null }

    Ensure-Member 'GG-Tier0-Admins' 't0.admin1'
    Ensure-Member 'GG-Tier0-Admins' 't0.admin2'
    Ensure-Member 'GG-Tier1-ServerAdmins' 't1.serveradmin1'
    Ensure-Member 'GG-Tier1-ServerAdmins' 't1.serveradmin2'
    Ensure-Member 'GG-Helpdesk' 'helpdesk1'
    Ensure-Member 'GG-Helpdesk' 'helpdesk2'
    Ensure-Member 'GG-Helpdesk' 'helpdesk3'
    Ensure-Member 'GG-AppAdmins' 'app.operator'
    Ensure-Member 'GG-Legacy-Admins' 't0.legacyadmin'

    # Privileged-group and tiering assessment cases.
    Ensure-Member 'Domain Admins' 'GG-Tier1-ServerAdmins'
    Ensure-Member 'Domain Admins' 't0.legacyadmin'
    Ensure-Member 'Enterprise Admins' 't0.admin2'
    Ensure-Member 'Schema Admins' 't0.legacyadmin'
    Ensure-Member 'Backup Operators' 'svc.backup'
    Ensure-Member 'Account Operators' 'helpdesk1'
    Ensure-Member 'DNSAdmins' 'user07'
    Ensure-Member 'Protected Users' 't0.admin1'
    Set-ADAccountControl -Identity 't0.admin2' -AccountNotDelegated $false
    Set-ADAccountControl -Identity 't0.legacyadmin' -AccountNotDelegated $false

    # Account/password/Kerberos assessment cases.
    Set-ADUser 'svc.backup' -PasswordNeverExpires $true
    Set-ADUser 'svc.web' -PasswordNeverExpires $true -ServicePrincipalNames @{Replace=@("HTTP/web01.$ExpectedDomain")}
    Set-ADUser 'svc.web' -Replace @{'msDS-SupportedEncryptionTypes'=4}
    Set-ADUser 'svc.sql' -PasswordNeverExpires $true -ServicePrincipalNames @{Replace=@("MSSQLSvc/sql01.${ExpectedDomain}:1433")}
    Set-ADUser 'svc.sql' -Replace @{'msDS-AllowedToDelegateTo'=@("cifs/file01.$ExpectedDomain")}
    Set-ADAccountControl -Identity 'svc.sql' -TrustedToAuthForDelegation $true
    Set-ADAccountControl -Identity 'svc.legacy' -DoesNotRequirePreAuth $true -UseDESKeyOnly $true -PasswordNeverExpires $true
    Set-ADUser 'user06' -AllowReversiblePasswordEncryption $true
    Set-ADAccountControl -Identity 'contractor.old' -PasswordNotRequired $true
    Set-ADAccountExpiration -Identity 'contractor.old' -DateTime (Get-Date).AddDays(-30)
    Enable-ADAccount 'contractor.old'
    Set-ADUser 'user05' -ChangePasswordAtLogon $true
    Set-ADUser 'user08' -Replace @{adminCount=1}
    Set-ADUser 'admin.stale' -PasswordNeverExpires $true -Description '[Kali-AD-Lab] intentionally retained privileged account for assessment'
    Ensure-Member 'Domain Admins' 'admin.stale'

    # Weak domain and service-account password policy.
    Set-ADDefaultDomainPasswordPolicy -Identity $ExpectedDomain -MinPasswordLength 6 -PasswordHistoryCount 3 -ComplexityEnabled $false -LockoutThreshold 0 -MaxPasswordAge (New-TimeSpan -Days 365)
    Set-ADObject -Identity $base -Replace @{'ms-DS-MachineAccountQuota'=25}
    $psos = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'Legacy-Service-Account-Policy'" -ErrorAction SilentlyContinue
    if (-not $psos) {
        New-ADFineGrainedPasswordPolicy -Name 'Legacy-Service-Account-Policy' -Precedence 50 -ComplexityEnabled $false -Description '[Kali-AD-Lab] intentionally weak assessment policy' -DisplayName 'Legacy Service Account Policy' -LockoutDuration (New-TimeSpan -Minutes 1) -LockoutObservationWindow (New-TimeSpan -Minutes 1) -LockoutThreshold 0 -MaxPasswordAge (New-TimeSpan -Days 730) -MinPasswordAge (New-TimeSpan -Days 0) -MinPasswordLength 6 -PasswordHistoryCount 1 -ReversibleEncryptionEnabled $true | Out-Null
    }
    foreach ($sam in @('svc.backup','svc.web','svc.sql','svc.legacy')) { Add-ADFineGrainedPasswordPolicySubject -Identity 'Legacy-Service-Account-Policy' -Subjects $sam -ErrorAction SilentlyContinue }

    # Delegation and synthetic computer hygiene cases.
    Set-ADAccountControl -Identity 'APP01$' -TrustedForDelegation $true
    foreach ($c in @('WS001','WS002','WS003','WS004','WS005','WS006')) { Set-ADComputer $c -Replace @{pwdLastSet=0} }

    # Shadow-admin / dangerous ACL cases.
    Grant-AdRight $ouSvc 'GG-Helpdesk' ([System.DirectoryServices.ActiveDirectoryRights]::GenericAll)
    Grant-AdRight $base 'GG-AppAdmins' ([System.DirectoryServices.ActiveDirectoryRights]::WriteDacl)
    $adminSdHolder = "CN=AdminSDHolder,CN=System,$base"
    Grant-AdRight $adminSdHolder 'GG-Legacy-Admins' ([System.DirectoryServices.ActiveDirectoryRights]::GenericAll)
    Grant-AdRight $ouTier0 'GG-Helpdesk' ([System.DirectoryServices.ActiveDirectoryRights]::GenericWrite)

    # GPO assessment cases.
    Import-Module GroupPolicy
    $legacyGpo = Ensure-Gpo 'Workstation-Legacy-Compatibility'
    try { New-GPLink -Name $legacyGpo.DisplayName -Target $ouWorkstations -LinkEnabled Yes -ErrorAction Stop | Out-Null } catch {}
    Set-GPRegistryValue -Name $legacyGpo.DisplayName -Key 'HKLM\Software\Policies\Microsoft\Windows NT\DNSClient' -ValueName 'EnableMulticast' -Type DWord -Value 1
    Set-GPRegistryValue -Name $legacyGpo.DisplayName -Key 'HKLM\System\CurrentControlSet\Control\Lsa' -ValueName 'LmCompatibilityLevel' -Type DWord -Value 1
    Set-GPRegistryValue -Name $legacyGpo.DisplayName -Key 'HKLM\System\CurrentControlSet\Services\LanmanWorkstation\Parameters' -ValueName 'RequireSecuritySignature' -Type DWord -Value 0
    Set-GPPermission -Name $legacyGpo.DisplayName -TargetName 'GG-Helpdesk' -TargetType Group -PermissionLevel GpoEditDeleteModifySecurity -Replace
    Ensure-Gpo 'Legacy-Unlinked-GPO' | Out-Null

    # DC protocol hardening assessment cases.
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters' -Name LDAPServerIntegrity -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters' -Name LdapEnforceChannelBinding -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name LmCompatibilityLevel -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name RestrictAnonymous -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name RestrictAnonymousSAM -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name EveryoneIncludesAnonymous -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name NoLMHash -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -Name RequireSecuritySignature -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -Name EnableSecuritySignature -PropertyType DWord -Value 0 -Force | Out-Null
    Set-Service Spooler -StartupType Automatic
    Start-Service Spooler -ErrorAction SilentlyContinue

    # DNS assessment cases.
    try {
        Import-Module DnsServer
        Set-DnsServerPrimaryZone -Name $ExpectedDomain -DynamicUpdate NonsecureAndSecure -ErrorAction Stop
        Set-DnsServerPrimaryZone -Name $ExpectedDomain -SecureSecondaries TransferAnyServer -ErrorAction Stop
    } catch {
        Write-Warning "DNS assessment scenario could not be fully applied: $($_.Exception.Message)"
    }

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
ADL-020 User forced to change password / pwdLastSet hygiene case
ADL-021 AdminCount anomaly on non-privileged user
ADL-022 Retained legacy privileged account
ADL-023 Weak default domain password policy
ADL-024 No account lockout
ADL-025 Excess MachineAccountQuota
ADL-026 Weak fine-grained service-account password policy
ADL-027 Unconstrained delegation on APP01
ADL-028 Synthetic workstation password-age / LAPS coverage gaps
ADL-029 Helpdesk GenericAll over service-account OU
ADL-030 Application admins can write domain-root DACL
ADL-031 Legacy admins control AdminSDHolder
ADL-032 Helpdesk GenericWrite on Tier0 OU
ADL-033 Helpdesk can edit/delete/modify security on linked GPO
ADL-034 Weak workstation GPO enables LLMNR
ADL-035 Weak workstation GPO allows NTLMv1 compatibility
ADL-036 Weak workstation GPO does not require SMB signing
ADL-037 Unlinked/orphaned legacy GPO
ADL-038 DC LDAP signing not required
ADL-039 DC LDAP channel binding disabled
ADL-040 DC NTLMv1 compatibility enabled
ADL-041 Anonymous enumeration restrictions weakened
ADL-042 LM hash storage protection disabled
ADL-043 SMB server signing not required
ADL-044 Print Spooler enabled on Domain Controller
ADL-045 DNS zone permits nonsecure dynamic updates
ADL-046 DNS zone transfer permitted to any server

Advanced infrastructure-dependent coverage intentionally not fabricated in the single-DC profile:
- AD CS / certificate-template ESC scenarios
- cross-domain or cross-forest trust weaknesses
- multi-DC replication / lingering-object scenarios
- RODC-specific password replication policy cases
These require additional lab VMs/roles and should be separate advanced profiles.
'@ | Out-File $ExpectedFile -Encoding utf8

    @"
Kali-AD-Lab Security Assessment Demo is ready.
Domain: $ExpectedDomain
Synthetic users: $($users.Count)
Synthetic computers: 10
Expected assessment scenarios: 46
WARNING: This domain is intentionally insecure. Keep it isolated from production networks.
Generated: $(Get-Date -Format o)
"@ | Out-File $MarkerFile -Encoding utf8

    Write-Host '[AssessmentDemo] 46 controlled assessment scenarios are ready.'
    Stop-TranscriptSafe
    exit 0
}
catch {
    $msg = "[$(Get-Date -Format o)] $($_.Exception.Message)"
    $msg | Out-File (Join-Path $Root 'FAILED-Assessment-Demo.txt') -Append -Encoding utf8
    Write-Error $msg
    Stop-TranscriptSafe
    exit 1
}
