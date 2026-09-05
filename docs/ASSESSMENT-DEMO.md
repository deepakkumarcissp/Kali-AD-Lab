# Security Assessment Demo Profile

The `assessment-demo` profile turns the otherwise clean Windows Server 2025 domain into an intentionally insecure, assessment-ready Active Directory training environment.

> **Safety:** this profile is for isolated training only. The AD engine refuses to seed the assessment profile unless the domain ends in `.test`, `.lab`, `.example`, or `.invalid`, and it runs only after the server is already a Domain Controller. Never use this profile against a production or business domain.

## Purpose

The profile supports defensive Active Directory security assessments, control validation, scanner demonstrations, remediation exercises, and before/after reporting. It creates synthetic users, groups, computer objects, OUs, GPOs, delegation relationships, ACL weaknesses, Kerberos conditions, protocol-hardening gaps, and DNS weaknesses so an assessment has meaningful findings instead of scanning a pristine domain.

## Synthetic organization

The profile creates a realistic Tier 0 / Tier 1 / Tier 2 structure with 24 synthetic users and 10 computer objects:

```text
adlab.test
├── Tier0
│   └── Admins
├── Tier1
│   ├── Server-Admins
│   └── Servers
├── Tier2
│   ├── Users
│   └── Workstations
├── Helpdesk
├── Service-Accounts
├── Legacy
├── Disabled-Accounts
└── Security-Groups
```

## Expected assessment coverage

The core single-DC profile currently targets **47 controlled findings** across these families:

| ID range | Assessment family | Examples |
|---|---|---|
| ADL-001–009 | Privileged access / tiering | nested Tier-1 admins in Domain Admins, direct legacy Domain Admin, Enterprise/Schema Admin overuse, Backup Operators, Account Operators, DNSAdmins, missing Protected Users coverage, delegatable privileged users |
| ADL-010–022 | Identity / Kerberos / account hygiene | password-never-expires service accounts, SPNs, RC4-only service identity, constrained delegation, AS-REP roastable account, DES-only account, reversible encryption, password-not-required, expired-but-enabled account, adminCount anomaly, retained privileged account |
| ADL-023–028 | Password / workstation hygiene | weak domain password policy, no lockout, excessive MachineAccountQuota, weak fine-grained service-account policy, unconstrained delegation, synthetic workstation password/LAPS gaps |
| ADL-029–033 | ACL / shadow-admin / replication paths | Helpdesk GenericAll on service-account OU, domain-root WriteDACL, AdminSDHolder control, Tier0 OU write access, delegated replication/DCSync-equivalent rights |
| ADL-034–038 | Group Policy | Helpdesk can modify linked GPO, LLMNR enabled, NTLMv1 compatibility, SMB signing not required, orphaned GPO |
| ADL-039–045 | DC protocol hardening | LDAP signing disabled, LDAP channel binding disabled, NTLMv1 compatibility, weak anonymous restrictions, LM-hash protection disabled, SMB signing not required, Print Spooler enabled on DC |
| ADL-046–047 | DNS | nonsecure dynamic updates, unrestricted zone transfer |

Windows writes the complete expected-finding list to:

```text
C:\ADLab\EXPECTED-FINDINGS.txt
```

and writes the profile completion marker to:

```text
C:\ADLab\ASSESSMENT-DEMO-READY.txt
```

## Recommended assessment demonstration

Use the profile for a complete defensive lifecycle:

```text
Build lab
   ↓
Seed known assessment conditions
   ↓
Run AD security assessment
   ↓
Compare findings with EXPECTED-FINDINGS.txt
   ↓
Prioritize Critical / High issues
   ↓
Remediate selected controls
   ↓
Re-run assessment
   ↓
Demonstrate measurable risk reduction
```

The expected-finding list is intentionally tool-neutral. It can be used with commercial or open-source AD assessment products without endorsing a specific vendor.

## Coverage areas represented in the core profile

The single-DC profile includes practical assessment material for:

- Tier 0 / Tier 1 / Tier 2 separation
- privileged-group membership and nested privileges
- Protected Users coverage
- service-account governance
- password policy and fine-grained password policy
- stale, expired, retained, and anomalous accounts
- Kerberos pre-authentication and encryption settings
- SPNs and delegated authentication
- unconstrained and constrained delegation
- machine-account quota
- workstation/computer-account hygiene
- LDAP signing and channel binding
- NTLM/LM compatibility
- anonymous enumeration restrictions
- SMB signing
- Print Spooler on a Domain Controller
- DNS dynamic updates and zone transfers
- OU ACLs and shadow-admin paths
- AdminSDHolder permissions
- domain-root WriteDACL
- delegated directory replication / DCSync-equivalent rights
- GPO permissions and weak legacy security policy
- orphaned/unlinked GPO detection

## Advanced profiles that need additional infrastructure

Some major AD assessment categories cannot be represented honestly on one Domain Controller. These should remain separate advanced modules rather than fake findings:

- **AD CS / PKI:** Enterprise CA, certificate templates, enrollment rights, web enrollment, and ESC-class assessment cases.
- **Trust security:** child domain, second forest, SID filtering, selective authentication, transitive trust, and cross-domain privilege paths.
- **Multi-DC / replication:** second Domain Controller, replication topology, site/subnet design, stale replication, and configuration drift.
- **RODC:** password replication policy, cached privileged credentials, delegated RODC administration, and branch-office security.
- **Hybrid identity:** Entra Connect / cloud sync, synchronization account privilege, hybrid admin separation, and cloud-to-AD identity paths.
- **Enterprise endpoint tiering:** real member servers and workstations are required to assess local administrators, interactive logon exposure, LAPS deployment, PAW controls, and cross-tier credential paths realistically.

These modules can be added later as optional profiles so the base assessment lab stays reproducible and lightweight.

## Isolation warning

The assessment-demo profile intentionally weakens authentication, delegation, ACLs, GPOs, LDAP/SMB policy, and DNS settings. Keep the lab behind the libvirt lab network. Do not bridge it to a corporate or home LAN, do not reuse production credentials, and destroy the lab when testing is finished.
