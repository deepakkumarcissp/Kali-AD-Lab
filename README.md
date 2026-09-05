# Kali-AD-Lab

Build a complete Windows Server Active Directory lab on Kali Linux with a simple guided installer.

The project installs and configures KVM/QEMU + libvirt, downloads the official Microsoft Windows Server 2025 Evaluation ISO, creates a safe virtual network, performs an unattended Windows installation, configures a static IP, installs AD DS/DNS, creates a new forest, validates the Domain Controller, and removes temporary unattended secrets.

> Designed for cybersecurity learning, administration practice, defensive testing, and authorized lab research.

## Quick Start

### After Kali-AD-Lab is installed

Run just:

```bash
sudo kali-ad-lab
```

The launcher updates Kali-AD-Lab automatically and starts the guided setup.

### First-time install after this repository is public

Users will be able to copy and paste one command:

```bash
curl -fsSL https://raw.githubusercontent.com/deepakkumarcissp/Kali-AD-Lab/main/bootstrap.sh | sudo bash
```

That command installs Kali-AD-Lab and immediately starts the setup wizard. After that, future runs only require:

```bash
sudo kali-ad-lab
```

### Testing while this repository is private

GitHub authentication is required to obtain a private repository. From an already authenticated clone, run:

```bash
sudo ./kali-ad-lab
```

## What the installer asks

The installer uses sensible defaults and only asks for settings that are environment-specific or security-sensitive:

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

Press **Enter** to accept any recommended default.

### Why `adlab.test` instead of `adlab.local`?

`.local` is commonly used by multicast DNS and can cause unnecessary name-resolution conflicts. The default therefore uses `.test`, which is better suited to an isolated training environment.

## What is fully automated

After the prompts, the project automatically:

1. Checks Intel VT-x / AMD-V support.
2. Installs KVM/QEMU, libvirt, virt-manager, OVMF and supporting tools.
3. Checks available host RAM, CPU and disk space.
4. Detects an existing VM with the same name and refuses to overwrite it silently.
5. Checks the requested lab subnet against host and libvirt networks.
6. Suggests another private subnet if the requested range overlaps.
7. Creates a libvirt NAT or fully isolated network.
8. Downloads the Windows Server 2025 Evaluation ISO from Microsoft's official download redirect.
9. Validates the downloaded ISO and identifies the required Windows image.
10. Creates temporary unattended installation media.
11. Creates and starts the Windows Server VM.
12. Performs Windows installation without Windows Setup clicks.
13. Configures the Domain Controller static IP.
14. Installs Active Directory Domain Services and DNS.
15. Creates the AD forest.
16. Reboots automatically as required.
17. Validates AD services.
18. Removes temporary unattended secrets and setup media after successful promotion.

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

The Domain Controller can make outbound Internet connections through libvirt NAT for Windows Evaluation activation and updates. It is **not bridged directly to your physical LAN**.

### Isolated mode

No Internet forwarding is configured for the lab network. Use this when you want a completely disconnected AD lab.

## Default VM resources

| Resource | Default |
|---|---|
| Memory | 6 GB |
| vCPU | 4 |
| Disk | 80 GB sparse QCOW2 |
| Firmware | UEFI / OVMF |
| Network adapter | Emulated Intel adapter for Windows compatibility |
| Display | SPICE/VGA |

## Windows Server evaluation media

The project uses **Windows Server 2025 Evaluation**, downloaded directly from Microsoft. The Microsoft ISO is never stored in this GitHub repository.

## Password handling

Administrator and Directory Services Restore Mode passwords are entered with hidden terminal prompts and are never committed to Git.

During unattended Windows installation, credentials temporarily exist only in locally generated setup media. Kali-AD-Lab removes the generated secret configuration and temporary LABTOOLS ISO after successful AD promotion.

Do not use production or corporate passwords in a lab.

## Collision and safety behavior

Kali-AD-Lab is deliberately conservative:

- Existing VM names are never silently overwritten.
- Existing network ranges are checked before creation.
- Compatible existing lab networks can be reused.
- The Domain Controller is not bridged directly to the physical LAN.
- Temporary setup secrets are cleaned up automatically after successful promotion.

## Using the lab

After successful AD promotion, sign in to the Windows Server VM as:

```text
ADLAB\Administrator
```

Use the Administrator password you entered during setup.

Windows writes a success marker at:

```text
C:\ADLab\SUCCESS.txt
```

## Remove the lab

The repository includes a safe teardown script that removes the selected VM and lab network without uninstalling KVM/libvirt from the Kali host.

## Repository layout

```text
Kali-AD-Lab/
├── bootstrap.sh
├── kali-ad-lab
├── setup.sh
├── templates/
│   └── Autounattend.xml.template
├── windows/
│   ├── SetupComplete.cmd
│   ├── Stage1.ps1
│   ├── Stage2.ps1
│   └── Stage3.ps1
├── scripts/
│   ├── cleanup-secrets.sh
│   └── destroy-lab.sh
├── .gitignore
├── LICENSE
└── README.md
```

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

This repository is currently licensed under the **GNU General Public License v3.0 (GPL-3.0)**. See `LICENSE`.
