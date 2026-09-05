# Kali-AD-Lab

Build a complete Windows Server 2025 Active Directory lab on Kali Linux with one guided command.

Kali-AD-Lab installs and configures KVM/QEMU + libvirt, downloads the official Microsoft Windows Server 2025 Evaluation ISO, creates a safe virtual network, performs an unattended Windows installation, configures a static IP, installs AD DS and DNS, creates a new forest, survives required Windows reboots automatically, validates DNS/Kerberos/LDAP, and removes temporary secret-bearing setup media after success.

> Designed for cybersecurity learning, administration practice, defensive testing, and authorized lab research.

## Quick start

### First-time install after this repository is public

Copy and paste one command:

```bash
curl -fsSL https://raw.githubusercontent.com/deepakkumarcissp/Kali-AD-Lab/main/bootstrap.sh | sudo bash
```

That command installs Kali-AD-Lab and immediately starts the guided deployment.

After installation, future launches are simply:

```bash
sudo kali-ad-lab
```

### While this repository is private

GitHub authentication is required to obtain a private repository. From an authenticated clone:

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

`.test` is used instead of `.local` because `.local` is commonly associated with multicast DNS and can create avoidable name-resolution conflicts.

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
11. Changes only the *next* persistent boot order to hard-disk-first so Windows can reboot without returning to setup media.
12. Completes Windows Setup with no GUI clicks.
13. Performs one controlled Administrator auto-logon only after OOBE has completed.
14. Invokes the same idempotent bootstrap after OOBE as a fallback even if Windows already ran `SetupComplete.cmd` automatically.
15. Copies the runtime config and `Configure-AD.ps1` locally, registers a SYSTEM startup task, and disables the one-time auto-logon.
16. Configures the DC static IP.
17. Installs AD DS and DNS.
18. Reboots automatically only when Windows requires it.
19. Creates the first forest/domain and resumes automatically after domain-promotion reboot.
20. Validates AD DS, DNS, Kerberos and LDAP.
21. Automatically restarts the VM a bounded number of times if it unexpectedly powers off during deployment.
22. Ejects and securely removes the secret-bearing config ISO only after AD is healthy.
23. Prints a final `LAB READY` summary with the VM, domain, DC IP and login name.

No manual boot-menu selection, no manual PowerShell domain-promotion command, and no copy/paste into the Windows guest should be required.

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

The first run creates two local media files:

- a reusable cached unattended Windows installer derived from the Microsoft evaluation ISO;
- a small per-deployment config ISO containing only the current lab's answer file and runtime configuration.

The config ISO contains sensitive setup values and is automatically ejected and securely removed after AD health validation. Do not use production passwords for a lab.

## Post-OOBE bootstrap and resumable AD configuration

The installer deliberately does **not** start AD configuration during Windows `specialize`. Windows Setup is allowed to finish completely first.

After OOBE, a one-time Administrator auto-logon invokes the idempotent bootstrap. The bootstrap locates the attached Windows/config media, copies the runtime files to `C:\ADLab`, registers the AD engine as a SYSTEM startup task, disables the one-time auto-logon, and starts the engine.

Windows then uses one idempotent script:

```text
C:\ADLab\Configure-AD.ps1
```

It safely resumes after any required reboot. The script detects whether the machine is still a workgroup server or is already a domain controller, so it does not depend on fragile `Stage1 -> Stage2 -> Stage3` sequencing.

Windows writes:

```text
C:\ADLab\SUCCESS.txt
```

when the domain controller has been validated successfully.

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

- a healthy existing lab is detected and reported instead of rebuilt;
- an unhealthy existing VM is never deleted without confirmation;
- network overlap is checked before creation;
- the DC is not bridged directly to the physical LAN;
- only generated lab media/storage is modified;
- secret-bearing config media is retained if deployment fails so the guest can recover, then removed only after success.

## Repository layout

```text
Kali-AD-Lab/
├── bootstrap.sh                 # first-time installer/launcher
├── kali-ad-lab                  # single deployment orchestrator
├── templates/
│   └── Autounattend.xml.template
├── windows/
│   ├── SetupComplete.cmd        # idempotent post-Setup/OOBE bootstrap
│   └── Configure-AD.ps1         # resumable AD DS/DNS/forest engine
├── scripts/
│   └── destroy-lab.sh           # optional safe teardown helper
├── .gitignore
├── LICENSE
└── README.md
```

## Remove a lab

The optional teardown helper removes the selected VM and lab network without uninstalling KVM/libvirt from the Kali host. The cached Microsoft/unattended Windows media is retained so a future lab does not need another multi-gigabyte download/build.

## Before public release

The installer has been hardened from real deployment troubleshooting, including QEMU permission problems, Windows DVD boot prompts, UEFI boot-order loops, interrupted Windows Setup, fragile specialize-phase automation, VM shutoff during setup, and manual AD promotion. Perform one final clean-machine run of the current `main` branch before changing the repository to public so the exact release candidate is validated end-to-end without guest interaction.

## Planned community roadmap

- Windows client domain-join automation
- second Domain Controller option
- configurable users, groups and OUs
- Group Policy lab scenarios
- snapshot / restore automation
- vulnerable and hardened AD lab profiles
- AD tiering / PAW lab examples
- Purple Team scenarios
- automated health/reporting dashboard

## Important usage note

Use this project only on systems and networks you own or are explicitly authorized to administer and test. Keep training credentials and data separate from production environments.

## License

This repository is licensed under the **GNU General Public License v3.0 (GPL-3.0)**. See `LICENSE`.
