# Kali-AD-Lab

Build a complete **Windows Server 2025 Active Directory security-assessment lab** on Kali Linux with one guided command.

Kali-AD-Lab installs and configures KVM/QEMU + libvirt, downloads the official Microsoft Windows Server 2025 Evaluation ISO, creates a safe virtual network, performs an unattended Windows installation, configures a static IP, installs AD DS and DNS, creates a new forest, survives required Windows reboots automatically, validates DNS/Kerberos/LDAP, and then seeds a realistic assessment environment with synthetic identities and controlled AD security weaknesses.

> Designed for cybersecurity learning, defensive Active Directory assessment, administration practice, remediation exercises, and authorized lab research.

## Quick start

### First-time install after this repository is public

```bash
curl -fsSL https://raw.githubusercontent.com/deepakkumarcissp/Kali-AD-Lab/main/bootstrap.sh | sudo bash
```

That command installs Kali-AD-Lab and immediately starts the guided deployment.

After installation, future launches are simply:

```bash
sudo kali-ad-lab
```

### While this repository is private

From an authenticated clone:

```bash
sudo ./kali-ad-lab
```

## What the user is asked

Only environment-specific or security-sensitive values are requested:

| Setting | Default |
|---|---|
| Windows Server / VM name | `DC01` |
| Active Directory DNS domain | `adlab.test` |
| NetBIOS domain | Derived from the DNS domain, e.g. `ADLAB` |
| Lab subnet | `192.168.77.0/24` |
| Network mode | `nat` |
| Windows edition | Standard Evaluation - Desktop Experience |
| Administrator password | Prompted securely |
| DSRM password | Prompted securely |

Press **Enter** to accept recommended defaults.

`.test` is used instead of `.local` because `.local` is commonly associated with multicast DNS and can create avoidable name-resolution conflicts. The assessment-demo seeding engine is safety-gated to training domains ending in `.test`, `.lab`, `.example`, or `.invalid`.

## What is automatic

After the prompts, Kali-AD-Lab automatically:

1. Installs/validates KVM, QEMU, libvirt, virt-manager, OVMF, xorriso, wimtools and supporting packages.
2. Checks CPU virtualization, RAM and disk capacity.
3. Detects the QEMU runtime account and fixes libvirt storage permissions before VM creation.
4. Checks the requested subnet for conflicts and creates/reuses the `ad-lab` network.
5. Downloads Windows Server 2025 Evaluation directly from Microsoft's official redirect and caches the source ISO.
6. Builds a cached no-prompt UEFI Windows installer so no `Press any key to boot from CD/DVD` interaction is required.
7. Embeds the reusable Windows bootstrap/AD engine using the supported `$OEM$` setup path.
8. Creates a small per-deployment config ISO containing the generated answer file and runtime AD settings.
9. Creates the QCOW2 disk with permissions already correct for QEMU.
10. Starts Windows Setup automatically.
11. Changes only the persistent next-boot order to hard-disk-first so Windows can reboot without returning to setup media.
12. Completes Windows Setup with no GUI clicks.
13. Registers the AD engine as a SYSTEM startup task without starting AD configuration inside the fragile Windows Setup phase.
14. Configures the DC static IP.
15. Installs AD DS and DNS.
16. Reboots automatically only when Windows requires it.
17. Creates the first forest/domain and resumes automatically after the domain-promotion reboot.
18. Validates AD DS, DNS, Kerberos and LDAP.
19. Seeds the security-assessment demo profile after the Domain Controller is healthy.
20. Creates a Tier 0 / Tier 1 / Tier 2 organization, 24 synthetic users, 10 synthetic computer objects, groups, service identities and GPOs.
21. Introduces **47 controlled assessment findings** covering tiering, privileged access, Kerberos, service accounts, password policy, delegation, ACLs, replication rights, GPOs, LDAP/NTLM/SMB hardening and DNS.
22. Writes a tool-neutral expected-finding manifest to `C:\ADLab\EXPECTED-FINDINGS.txt`.
23. Writes `C:\ADLab\ASSESSMENT-DEMO-READY.txt` when the assessment data is ready.
24. Ejects and securely removes the secret-bearing config ISO only after AD is healthy.
25. Prints a final `LAB READY` summary.

No manual boot-menu selection, manual PowerShell domain promotion, manual user creation, or copy/paste into the Windows guest should be required.

## Assessment-ready Active Directory

The default lab is intentionally useful for an AD security assessment rather than being a pristine empty domain.

It creates this synthetic organization:

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

The 47 expected finding families include:

- Tier-1 administrators incorrectly nested into Domain Admins
- legacy direct Domain Admin / Enterprise Admin / Schema Admin exposure
- service accounts in privileged operator groups
- standard-user membership in DNSAdmins
- incomplete Protected Users coverage
- delegatable privileged accounts
- password-never-expires service accounts
- SPN-bearing service accounts
- RC4-only and DES-only Kerberos identities
- constrained delegation with protocol transition
- AS-REP roastable account condition
- reversible password encryption
- password-not-required and expired-but-enabled accounts
- adminCount anomaly and retained privileged account
- weak domain password policy and no lockout
- excessive `ms-DS-MachineAccountQuota`
- weak fine-grained password policy
- unconstrained delegation
- synthetic workstation/LAPS coverage gaps
- Helpdesk `GenericAll` over the service-account OU
- domain-root `WriteDACL`
- AdminSDHolder control
- Helpdesk write access over the Tier0 OU
- delegated directory replication / DCSync-equivalent rights
- overly permissive GPO editing
- LLMNR enabled by policy
- NTLMv1-compatible policy
- SMB signing not required
- unlinked/orphaned GPO
- LDAP signing not required
- LDAP channel binding disabled
- weak anonymous-enumeration restrictions
- LM-hash protection disabled
- Print Spooler enabled on the Domain Controller
- nonsecure DNS dynamic updates
- unrestricted DNS zone transfer

The complete mapping is documented in [`docs/ASSESSMENT-DEMO.md`](docs/ASSESSMENT-DEMO.md).

### Expected findings on Windows

```text
C:\ADLab\EXPECTED-FINDINGS.txt
```

### Assessment profile marker

```text
C:\ADLab\ASSESSMENT-DEMO-READY.txt
```

A recommended demonstration is:

```text
Build lab
   ↓
Run AD security assessment
   ↓
Compare detected findings with EXPECTED-FINDINGS.txt
   ↓
Remediate selected Critical / High issues
   ↓
Re-run assessment
   ↓
Show measurable risk reduction
```

## Advanced assessment modules

A single Domain Controller cannot honestly represent every Active Directory security-assessment category. The following need additional infrastructure and are planned as separate profiles:

- **AD CS / PKI:** Enterprise CA, certificate templates, enrollment rights and ESC-class assessment cases.
- **Trust security:** second domain/forest, SID filtering, selective authentication and cross-domain privilege paths.
- **Multi-DC / replication:** replication topology, stale replication, site/subnet design and DC configuration drift.
- **RODC:** password replication policy, cached credentials and delegated RODC administration.
- **Hybrid identity:** Entra Connect/cloud sync and hybrid privilege separation.
- **Endpoint tiering:** real member servers/workstations for local-admin, LAPS, PAW and cross-tier logon assessment.

These are separated deliberately rather than generating fake findings for infrastructure that does not exist.

## Default architecture

```text
                       Kali Linux Host
                             |
                    KVM / QEMU / libvirt
                             |
                    +-------------------+
                    |   ad-lab network  |
                    | 192.168.77.0/24   |
                    +-------------------+
                             |
                         192.168.77.10
                             |
                         +--------+
                         |  DC01  |
                         +--------+
                         Windows Server 2025
                         AD DS + DNS
                         adlab.test
```

### NAT mode - default

The DC can make outbound Internet connections through libvirt NAT for Windows evaluation activation/updates. The guest is not bridged directly to the physical LAN.

### Isolated mode

No Internet forwarding is configured for the lab network.

## Default VM resources

| Resource | Default |
|---|---|
| Memory | 6 GB (automatically lowered to 4 GB on smaller hosts) |
| vCPU | Up to 4 |
| Disk | 80 GB sparse QCOW2 |
| Firmware | UEFI / OVMF |
| Network adapter | Emulated Intel adapter for Windows compatibility |
| Display | SPICE/VGA |

## Windows media handling

The Microsoft Windows Server ISO is downloaded directly from Microsoft and is never committed to GitHub.

The first run creates a reusable cached unattended Windows installer and a small per-deployment config ISO. The config ISO contains sensitive setup values and is automatically ejected and securely removed after AD health validation. Do not use production passwords for a lab.

## Resumable AD configuration

Windows uses one idempotent script:

```text
C:\ADLab\Configure-AD.ps1
```

It safely resumes after required reboots. Once the domain is healthy it creates the assessment dataset and writes:

```text
C:\ADLab\SUCCESS.txt
C:\ADLab\ASSESSMENT-DEMO-READY.txt
C:\ADLab\EXPECTED-FINDINGS.txt
```

Detailed Windows-side logs are under:

```text
C:\ADLab\Logs\
```

The Kali-side run log is written under:

```text
/var/log/kali-ad-lab/
```

## Success screen

A successful run ends with a summary similar to:

```text
============================================================
 Kali-AD-Lab | LAB READY
============================================================
VM               : DC01
AD Domain        : adlab.test
Domain Controller: 192.168.77.10
DNS              : READY
Kerberos         : READY
LDAP             : READY
Login            : ADLAB\Administrator
============================================================
```

## Safety behavior

Kali-AD-Lab deliberately avoids destructive surprises:

- training-domain safety gates protect the intentionally insecure assessment profile;
- an unhealthy existing VM is never deleted without confirmation;
- network overlap is checked before creation;
- the DC is not bridged directly to the physical LAN;
- only generated lab media/storage is modified;
- secret-bearing config media is retained if deployment fails so the guest can recover, then removed only after success;
- no production credentials should ever be reused.

The assessment profile intentionally contains insecure controls. Keep it isolated and authorized.

## Repository layout

```text
Kali-AD-Lab/
├── bootstrap.sh
├── kali-ad-lab
├── templates/
│   └── Autounattend.xml.template
├── windows/
│   ├── SetupComplete.cmd
│   ├── Configure-AD.ps1
│   └── Seed-Assessment-Lab.ps1
├── docs/
│   └── ASSESSMENT-DEMO.md
├── scripts/
│   └── destroy-lab.sh
├── .github/workflows/validate.yml
├── .gitignore
├── LICENSE
└── README.md
```

## Remove a lab

The teardown helper removes the selected VM and lab network without uninstalling KVM/libvirt from the Kali host. The cached Microsoft/unattended Windows media is retained so a future lab does not need another multi-gigabyte download/build.

## Validation status

The installer has been iteratively hardened against real deployment issues, including QEMU permission problems, Windows DVD boot prompts, UEFI boot-order loops, interrupted Windows Setup, fragile setup-phase automation, VM shutoff during setup, and manual AD promotion. Automated CI validates script syntax, PowerShell parsing, the unattended XML template, and the presence of every required orchestration stage on every push.

A full end-to-end run (bare Kali host to `LAB READY`) is not exercised by that CI -- it needs nested virtualization, an ~8 GB Windows ISO download, and 60-90 minutes, none of which a hosted runner provides. If a run doesn't complete, check the host-side log under `/var/log/kali-ad-lab/` and the Windows-side log under `C:\ADLab\Logs\`, and open an issue with both attached.

## Planned community roadmap

- AD CS / PKI assessment profile
- second Domain Controller / replication profile
- second forest / trust-security profile
- RODC assessment profile
- Windows client/member-server domain-join automation
- endpoint tiering / LAPS / PAW lab profile
- hardened profile and automated remediation/re-test workflow
- snapshot / restore automation
- hybrid identity assessment profile
- automated health/reporting dashboard

## Important usage note

Use this project only on systems and networks you own or are explicitly authorized to administer and test. Keep training credentials and data separate from production environments.

## License

This repository is licensed under the **GNU General Public License v3.0 (GPL-3.0)**. See `LICENSE`.
