# Security Assessment Demo Profile

The `assessment-demo` profile turns the otherwise clean Windows Server 2025 domain into an intentionally insecure, assessment-ready Active Directory training environment.

> **Safety:** this profile is for isolated training only. The seed script refuses to run unless the domain ends in `.test`, `.lab`, `.example`, or `.invalid`, and it must run on a Domain Controller. Never use it against a production or business domain.

## Purpose

The profile is designed to support defensive Active Directory security assessments, control validation, scanner demonstrations, remediation exercises, and before/after reporting. It creates synthetic users, groups, computer objects, OUs, GPOs, delegation relationships, ACL weaknesses, protocol-hardening gaps, and DNS weaknesses so an assessment has meaningful findings instead of scanning a pristine domain.

## Synthetic organization

The profile creates a realistic Tier 0 / Tier 1 / Tier 2 structure with approximately 24 users and 10 computer objects:

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

The seed currently targets 46 controlled findings across these families:

| ID range | Assessment family | Examples |
|---|---|---|
| ADL-001–009 | Privileged access / tiering | nested Tier-1 admins in Domain Admins, direct legacy Domain Admin, Enterprise/Schema Admin overuse, Backup Operators, Account Operators, DNSAdmins, missing Protected Users coverage, delegatable privileged users |
| ADL-010–022 | Identity / Kerberos / account hygiene | password-never-expires service accounts, SPNs, RC4-only service identity, constrained delegation, AS-REP roastable account, DES-only account, reversible encryption, password-not-required, expired-but-enabled account, adminCount anomaly, retained privileged account |
| ADL-023–028 | Password / workstation hygiene | weak domain password policy, no lockout, excessive MachineAccountQuota, weak fine-grained service-account policy, unconstrained delegation, synthetic workstation password/LAPS gaps |
| ADL-029–032 | ACL / shadow-admin paths | Helpdesk GenericAll on service-account OU, application admins with domain-root WriteDACL, control of AdminSDHolder, Helpdesk GenericWrite on Tier0 OU |
| ADL-033–037 | Group Policy | Helpdesk can modify linked GPO, LLMNR enabled, NTLMv1 compatibility, SMB signing not required, orphaned GPO |
| ADL-038–044 | DC protocol hardening | LDAP signing disabled, LDAP channel binding disabled, NTLMv1 compatibility, weak anonymous restrictions, LM-hash protection disabled, SMB signing not required, Print Spooler enabled on DC |
| ADL-045–046 | DNS | nonsecure dynamic updates, unrestricted zone transfer |

Windows also writes the expected-finding list to:

```text
C:\ADLab\EXPECTED-FINDINGS.txt
```

and a profile marker to:

```text
C:\ADLab\ASSESSMENT-DEMO-READY.txt
```

## Recommended assessment demonstration

Use the profile for a complete defensive lifecycle:

```text
Build lab
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

## Advanced profiles that need additional infrastructure

Some important AD security-assessment categories cannot be represented honestly on a single-DC lab and are intentionally not faked in the core profile. These should become separate advanced modules:

- **AD CS / PKI:** certificate-template and enrollment-control weaknesses, including ESC-class findings, require an Enterprise CA and certificate templates.
- **Trust security:** SID filtering, selective authentication, transitive trust, cross-domain privilege paths, and forest trust cases require at least a second domain/forest.
- **Replication / DC resilience:** lingering objects, replication topology, DC isolation, and multi-DC configuration drift require another Domain Controller.
- **RODC:** password replication policy, cached privileged credentials, and RODC delegation require an RODC.
- **Hybrid identity:** Entra Connect / cloud sync / hybrid privilege paths require a separate hybrid identity module and cloud tenant.

These are intentionally separated so the base assessment profile remains reproducible and does not pretend to test controls that are not actually present.

## Isolation warning

The assessment-demo profile intentionally weakens authentication, delegation, ACLs, GPOs, LDAP/SMB policy, and DNS settings. Keep the lab behind the libvirt lab network. Do not bridge it to a corporate or home LAN, do not reuse production credentials, and destroy the lab when testing is finished.
