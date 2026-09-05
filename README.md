# Kali-AD-Lab

Build a complete Windows Server Active Directory lab on Kali Linux with one command.

The project installs and configures KVM/QEMU + libvirt, downloads the official Microsoft Windows Server 2025 Evaluation ISO, creates a safe virtual network, performs an unattended Windows installation, configures a static IP, installs AD DS/DNS, creates a new forest, validates the Domain Controller, and removes temporary unattended secrets.

> Designed for cybersecurity learning, administration practice, defensive testing, and authorized lab research.

## One-command deployment

```bash
git clone https://github.com/deepakkumarcissp/Kali-AD-Lab.git
cd Kali-AD-Lab
sudo bash setup.sh
```

If the repository is still private, clone it using your authenticated GitHub method. After the repository becomes public, the HTTPS command above will work directly for everyone.

## What the script asks

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

You can simply press **Enter** to accept a default.

### Why `adlab.test` instead of `adlab.local`?

`.local` is commonly used by multicast DNS and can cause unnecessary name-resolution conflicts. The default therefore uses `.test`, which is better suited to an isolated training environment.

## What is fully automated

After the prompts, the script automatically:

1. Checks Intel VT-x / AMD-V support.
2. Detects potentially conflicting VirtualBox/VMware host modules.
3. Installs KVM/QEMU, libvirt, virt-manager, OVMF and supporting tools.
4. Checks available host RAM, CPU and disk space.
5. Detects an existing VM with the same name and refuses to overwrite it silently.
6. Checks the requested lab subnet against:
   - Kali host routes
   - Docker/container routes visible to the host
   - active libvirt networks
   - inactive libvirt network definitions
7. Suggests another private subnet if the requested range overlaps.
8. Creates a libvirt NAT or fully isolated network.
9. Downloads the Windows Server 2025 Evaluation ISO from Microsoft's official download redirect.
10. Validates that the download is a usable ISO and inspects its Windows image metadata.
11. Creates temporary unattended installation media.
12. Creates the Windows Server VM.
13. Performs the Windows installation without Windows Setup clicks.
14. Configures the Domain Controller's static IP.
15. Installs Active Directory Domain Services and DNS.
16. Creates the AD forest.
17. Reboots automatically as required.
18. Validates that AD services are running.
19. Configures the libvirt DNS forwarder when NAT mode is used.
20. Removes the copied secret configuration inside Windows.
21. Ejects and securely removes the temporary host-side unattended ISO after LDAP becomes available.

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

On a lower-memory Kali host, the installer can automatically reduce the VM to 4 GB after warning you.

## Windows Server evaluation media

The project uses **Windows Server 2025 Evaluation**, downloaded directly from Microsoft.

Official Microsoft Evaluation Center:

https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025

Microsoft states that the evaluation is valid for 180 days and requires online activation during the initial evaluation period.

The Microsoft ISO is never stored in this GitHub repository.

## Password handling

Administrator and Directory Services Restore Mode passwords are entered with hidden terminal prompts.

The project intentionally does **not** place credentials in Git.

During unattended Windows installation, credentials must temporarily exist in locally generated answer media. Kali-AD-Lab therefore:

- stores generated files under a root-only libvirt directory;
- gives them restrictive filesystem permissions;
- copies only what Windows requires;
- removes the Windows-side configuration after AD promotion;
- watches for LDAP availability from Kali;
- ejects the temporary `LABTOOLS` ISO;
- securely removes generated unattended files from the Kali host.

Do not use production or corporate passwords in a lab.

## Collision and safety behavior

Kali-AD-Lab is deliberately conservative.

### Existing VM

If `DC01` already exists, the script stops and requires the user to explicitly type `REBUILD` before any existing VM/storage is removed.

### Existing network range

If `192.168.77.0/24` is already in use, the script detects the overlap and proposes another private `/24` network. The user can accept the suggestion or type another subnet.

### Existing libvirt network name

If `ad-lab` already exists with matching settings, it is safely reused. If its subnet/mode is different, the installer asks for another network name rather than changing an unrelated network.

### Other hypervisors

If VirtualBox or VMware host modules are detected, the installer warns before continuing because another running hypervisor may already be using hardware virtualization.

### Production isolation

The installer does not configure a bridged NIC for the Domain Controller. This helps prevent accidental placement of the lab DC directly onto a corporate/home LAN.

## Watch deployment

The deployment itself is unattended, but you can view the console at any time:

```bash
virt-manager
```

Check VM status:

```bash
sudo virsh list --all
```

Check the lab network:

```bash
sudo virsh net-info ad-lab
```

After successful AD promotion, Windows writes:

```text
C:\ADLab\SUCCESS.txt
```

The default login becomes:

```text
ADLAB\Administrator
```

Use the Administrator password you entered during setup.

## Teardown

To remove the default VM and lab network safely:

```bash
sudo bash scripts/destroy-lab.sh
```

The script requires the exact confirmation text:

```text
DELETE-LAB
```

The downloaded Microsoft ISO is intentionally retained so another lab can be rebuilt without downloading it again.

For a custom VM/network name:

```bash
sudo bash scripts/destroy-lab.sh MY-DC my-lab-network
```

## Repository layout

```text
Kali-AD-Lab/
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

- Windows 11 domain-joined client automation
- second Domain Controller option
- configurable users, groups and OUs
- Group Policy lab scenarios
- snapshot / restore automation
- vulnerable and hardened AD lab profiles
- AD tiering / PAW lab examples
- Purple Team scenarios
- automated health/reporting dashboard

## Important usage note

Use this project only in systems and networks you own or are explicitly authorized to administer and test. Keep training credentials and data separate from production environments.

## License

This repository is currently licensed under the **GNU General Public License v3.0 (GPL-3.0)**. See `LICENSE`.
