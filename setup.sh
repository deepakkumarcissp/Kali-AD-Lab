#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="Kali-AD-Lab"
WINDOWS_ISO_URL="https://aka.ms/WinServ2025iso-enus"
BASE_DIR="/var/lib/libvirt/boot/${PROJECT}"
IMAGE_DIR="/var/lib/libvirt/images/${PROJECT}"
WINDOWS_ISO="${BASE_DIR}/Windows_Server_2025_Evaluation_x64.iso"
DEFAULT_SUBNET="192.168.77.0/24"
DEFAULT_DOMAIN="adlab.test"
DEFAULT_VM_NAME="DC01"
DEFAULT_NETWORK_NAME="ad-lab"
DEFAULT_RAM_MB=6144
DEFAULT_DISK_GB=80

if [[ ${EUID} -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '\nWARNING: %s\n\n' "$*" >&2; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

prompt_default() {
  local prompt="$1" default="$2" value
  read -r -p "${prompt} [${default}]: " value
  printf '%s' "${value:-$default}"
}

confirm() {
  local prompt="$1" default="${2:-N}" answer
  if [[ "$default" == "Y" ]]; then
    read -r -p "${prompt} [Y/n]: " answer
    answer="${answer:-Y}"
  else
    read -r -p "${prompt} [y/N]: " answer
    answer="${answer:-N}"
  fi
  [[ "$answer" =~ ^[Yy]$ ]]
}

read_secret_twice() {
  local label="$1" p1 p2
  while true; do
    read -r -s -p "${label}: " p1; printf '\n'
    read -r -s -p "Confirm ${label}: " p2; printf '\n'
    if [[ "$p1" != "$p2" ]]; then
      warn "Passwords did not match. Please try again."
      continue
    fi
    if (( ${#p1} < 12 )); then
      warn "Use at least 12 characters. Windows Server password complexity also applies."
      continue
    fi
    if [[ ! "$p1" =~ [A-Z] || ! "$p1" =~ [a-z] || ! "$p1" =~ [0-9] || ! "$p1" =~ [^A-Za-z0-9] ]]; then
      warn "Use uppercase, lowercase, a number, and a special character."
      continue
    fi
    printf '%s' "$p1"
    return 0
  done
}

validate_vm_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,14}$ && ! "$1" =~ -$ ]]
}

validate_netbios() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,14}$ && ! "$1" =~ -$ ]]
}

validate_domain() {
  python3 - "$1" <<'PY'
import re, sys
name=sys.argv[1].strip().lower()
if len(name) > 253 or '.' not in name:
    raise SystemExit(1)
labels=name.split('.')
for label in labels:
    if not (1 <= len(label) <= 63): raise SystemExit(1)
    if not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]*[a-z0-9])?', label): raise SystemExit(1)
raise SystemExit(0)
PY
}

validate_private_24() {
  python3 - "$1" <<'PY'
import ipaddress, sys
try:
    n=ipaddress.ip_network(sys.argv[1], strict=True)
    ok=n.version==4 and n.prefixlen==24 and n.is_private
except Exception:
    ok=False
raise SystemExit(0 if ok else 1)
PY
}

derive_network_values() {
  python3 - "$1" <<'PY'
import ipaddress, sys
n=ipaddress.ip_network(sys.argv[1], strict=True)
print(n.network_address + 1)
print(n.network_address + 10)
print(n.network_address + 100)
print(n.network_address + 200)
print(n.prefixlen)
PY
}

subnet_conflicts() {
  python3 - "$1" <<'PY'
import ipaddress, subprocess, sys, xml.etree.ElementTree as ET
wanted=ipaddress.ip_network(sys.argv[1], strict=True)
found=[]
try:
    out=subprocess.check_output(['ip','-o','-4','route','show'], text=True, stderr=subprocess.DEVNULL)
    for line in out.splitlines():
        first=line.split()[0]
        if first=='default': continue
        try: n=ipaddress.ip_network(first, strict=False)
        except Exception: continue
        if wanted.overlaps(n): found.append(('host route', str(n)))
except Exception: pass
try:
    names=subprocess.check_output(['virsh','net-list','--all','--name'], text=True, stderr=subprocess.DEVNULL).split()
    for name in names:
        try:
            xml=subprocess.check_output(['virsh','net-dumpxml',name], text=True, stderr=subprocess.DEVNULL)
            root=ET.fromstring(xml)
            for ip in root.findall('ip'):
                addr=ip.get('address'); mask=ip.get('netmask') or ip.get('prefix')
                if not addr: continue
                try:
                    n=ipaddress.ip_network(f'{addr}/{mask}', strict=False)
                except Exception: continue
                if wanted.overlaps(n): found.append((f'libvirt:{name}', str(n)))
        except Exception: pass
if found:
    for src,net in found: print(f'{src} -> {net}')
    raise SystemExit(0)
raise SystemExit(1)
PY
}

suggest_free_subnet() {
  python3 <<'PY'
import ipaddress, subprocess, xml.etree.ElementTree as ET
used=[]
try:
    for line in subprocess.check_output(['ip','-o','-4','route','show'], text=True, stderr=subprocess.DEVNULL).splitlines():
        first=line.split()[0]
        if first=='default': continue
        try: used.append(ipaddress.ip_network(first, strict=False))
        except Exception: pass
except Exception: pass
try:
    for name in subprocess.check_output(['virsh','net-list','--all','--name'], text=True, stderr=subprocess.DEVNULL).split():
        try:
            root=ET.fromstring(subprocess.check_output(['virsh','net-dumpxml',name], text=True, stderr=subprocess.DEVNULL))
            for node in root.findall('ip'):
                a=node.get('address'); m=node.get('netmask') or node.get('prefix')
                if a and m:
                    try: used.append(ipaddress.ip_network(f'{a}/{m}', strict=False))
                    except Exception: pass
        except Exception: pass
except Exception: pass
candidates=['192.168.77.0/24','192.168.88.0/24','192.168.99.0/24','10.77.0.0/24','10.88.0.0/24','10.99.0.0/24','172.27.77.0/24','172.28.88.0/24']
for c in candidates:
    n=ipaddress.ip_network(c)
    if not any(n.overlaps(u) for u in used):
        print(c); break
PY
}

get_libvirt_network_cidr() {
  python3 - "$1" <<'PY'
import ipaddress, subprocess, sys, xml.etree.ElementTree as ET
root=ET.fromstring(subprocess.check_output(['virsh','net-dumpxml',sys.argv[1]], text=True))
ip=root.find('ip')
if ip is None: raise SystemExit(1)
a=ip.get('address'); m=ip.get('netmask') or ip.get('prefix')
print(ipaddress.ip_network(f'{a}/{m}', strict=False))
PY
}

get_libvirt_network_mode() {
  python3 - "$1" <<'PY'
import subprocess, sys, xml.etree.ElementTree as ET
root=ET.fromstring(subprocess.check_output(['virsh','net-dumpxml',sys.argv[1]], text=True))
f=root.find('forward')
print(f.get('mode','nat') if f is not None else 'isolated')
PY
}

cleanup_mount() {
  if [[ -n "${ISO_MOUNT:-}" ]] && mountpoint -q "$ISO_MOUNT"; then umount "$ISO_MOUNT" || true; fi
  [[ -n "${ISO_MOUNT:-}" ]] && rmdir "$ISO_MOUNT" 2>/dev/null || true
}
trap cleanup_mount EXIT

cat <<'EOF'
============================================================
 Kali-AD-Lab | One-command Windows Server AD lab builder
============================================================
This installer keeps the VM behind a libvirt NAT or isolated
lab network. It never bridges the Domain Controller to your LAN.
EOF

# ---- Collect only meaningful user choices ----
while true; do
  VM_NAME="$(prompt_default 'Windows server / VM name' "$DEFAULT_VM_NAME")"
  validate_vm_name "$VM_NAME" && break
  warn 'Computer name must be 1-15 characters using letters, numbers, or hyphens.'
done

while true; do
  DOMAIN_FQDN="$(prompt_default 'Active Directory DNS domain' "$DEFAULT_DOMAIN" | tr '[:upper:]' '[:lower:]')"
  validate_domain "$DOMAIN_FQDN" || { warn 'Enter a valid DNS-style domain such as adlab.test.'; continue; }
  if [[ "$DOMAIN_FQDN" == *.local ]]; then
    warn '.local is used by multicast DNS on many networks and can create avoidable name-resolution conflicts. The recommended lab suffix is .test.'
    confirm 'Use .local anyway?' N || continue
  fi
  break
done

DERIVED_NETBIOS="$(printf '%s' "${DOMAIN_FQDN%%.*}" | tr '[:lower:]' '[:upper:]' | cut -c1-15)"
while true; do
  NETBIOS_NAME="$(prompt_default 'NetBIOS domain name' "$DERIVED_NETBIOS" | tr '[:lower:]' '[:upper:]')"
  validate_netbios "$NETBIOS_NAME" && break
  warn 'NetBIOS name must be 1-15 characters using letters, numbers, or hyphens.'
done

while true; do
  LAB_SUBNET="$(prompt_default 'Lab IPv4 subnet (private /24)' "$DEFAULT_SUBNET")"
  validate_private_24 "$LAB_SUBNET" && break
  warn 'Use a private /24 network such as 192.168.77.0/24, 10.77.0.0/24, or 172.27.77.0/24.'
done

while true; do
  NETWORK_MODE="$(prompt_default 'Network mode: nat (Internet outbound) or isolated' 'nat' | tr '[:upper:]' '[:lower:]')"
  [[ "$NETWORK_MODE" == 'nat' || "$NETWORK_MODE" == 'isolated' ]] && break
  warn 'Enter nat or isolated.'
done

printf '\nWindows Server edition:\n  1) Standard Evaluation - Desktop Experience [recommended]\n  2) Datacenter Evaluation - Desktop Experience\n'
read -r -p 'Choose edition [1]: ' EDITION_CHOICE
EDITION_CHOICE="${EDITION_CHOICE:-1}"
[[ "$EDITION_CHOICE" == '1' || "$EDITION_CHOICE" == '2' ]] || die 'Edition choice must be 1 or 2.'

printf '\nPasswords are used only to build this local lab and are never committed to GitHub.\n'
ADMIN_PASSWORD="$(read_secret_twice 'Windows/Domain Administrator password')"
DSRM_PASSWORD="$(read_secret_twice 'Directory Services Restore Mode (DSRM) password')"

# ---- Host pre-flight ----
log 'Checking CPU virtualization support...'
grep -Eq '(vmx|svm)' /proc/cpuinfo || die 'Hardware virtualization (Intel VT-x/AMD-V) is not visible. Enable it in BIOS/UEFI. If Kali itself is a VM, enable nested virtualization.'

if lsmod | grep -Eq '^(vboxdrv|vmmon|vmnet)'; then
  warn 'VirtualBox/VMware host modules appear active. KVM often works alongside them, but an active VM from another hypervisor can lock hardware virtualization on some hosts.'
  confirm 'Continue with KVM/libvirt setup?' N || exit 0
fi

log 'Installing/validating KVM, libvirt, ISO and Windows-image tooling...'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients virtinst virt-manager ovmf dnsmasq-base xorriso curl python3 wimtools netcat-openbsd libosinfo-bin
systemctl enable --now libvirtd
modprobe kvm 2>/dev/null || true
if grep -q vmx /proc/cpuinfo; then modprobe kvm_intel 2>/dev/null || true; fi
if grep -q svm /proc/cpuinfo; then modprobe kvm_amd 2>/dev/null || true; fi
[[ -e /dev/kvm ]] || die '/dev/kvm was not created. Check BIOS virtualization settings and conflicting hypervisors.'

mkdir -p "$BASE_DIR" "$IMAGE_DIR"
chmod 700 "$BASE_DIR" "$IMAGE_DIR"

HOST_RAM_MB=$(( $(awk '/MemTotal:/ {print $2}' /proc/meminfo) / 1024 ))
HOST_CPUS=$(nproc)
VM_RAM_MB=$DEFAULT_RAM_MB
VM_VCPUS=4
(( HOST_CPUS < VM_VCPUS )) && VM_VCPUS=$HOST_CPUS
(( VM_VCPUS < 2 )) && die 'At least 2 logical CPUs are recommended for this automated lab.'
if (( HOST_RAM_MB < 10000 )); then
  VM_RAM_MB=4096
  warn "This host has about ${HOST_RAM_MB} MB RAM. The VM default has been reduced to 4096 MB."
  confirm 'Continue with 4096 MB for the Windows Server VM?' Y || exit 0
fi

AVAILABLE_GB=$(df --output=avail -BG "$IMAGE_DIR" | tail -1 | tr -dc '0-9')
(( AVAILABLE_GB >= 20 )) || die "Less than 20 GB free space is available under ${IMAGE_DIR}. Free disk space before continuing."
if (( AVAILABLE_GB < 35 )); then
  warn "Only about ${AVAILABLE_GB} GB is currently free. The VM disk is sparse, but Windows, updates, and snapshots will grow over time."
  confirm 'Continue anyway?' N || exit 0
fi

# ---- VM collision safety ----
if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
  warn "A libvirt VM named '${VM_NAME}' already exists. This installer will never overwrite it silently."
  read -r -p "Type REBUILD to permanently delete that VM and its storage, or anything else to stop: " REBUILD
  [[ "$REBUILD" == 'REBUILD' ]] || exit 0
  virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
  virsh undefine "$VM_NAME" --nvram --remove-all-storage >/dev/null 2>&1 || virsh undefine "$VM_NAME" --remove-all-storage >/dev/null 2>&1 || true
fi

NETWORK_NAME="$DEFAULT_NETWORK_NAME"
REUSE_NETWORK=0
if virsh net-info "$NETWORK_NAME" >/dev/null 2>&1; then
  EXISTING_CIDR="$(get_libvirt_network_cidr "$NETWORK_NAME" 2>/dev/null || true)"
  EXISTING_MODE="$(get_libvirt_network_mode "$NETWORK_NAME" 2>/dev/null || true)"
  if [[ "$EXISTING_CIDR" == "$LAB_SUBNET" && "$EXISTING_MODE" == "$NETWORK_MODE" ]]; then
    log "Reusing existing compatible libvirt network '${NETWORK_NAME}'."
    REUSE_NETWORK=1
  else
    warn "The libvirt network '${NETWORK_NAME}' already exists as ${EXISTING_CIDR:-unknown}/${EXISTING_MODE:-unknown}, which does not match your requested ${LAB_SUBNET}/${NETWORK_MODE}."
    NETWORK_NAME="$(prompt_default 'Use a different libvirt network name' "${DEFAULT_NETWORK_NAME}-${VM_NAME,,}")"
    virsh net-info "$NETWORK_NAME" >/dev/null 2>&1 && die "Network '${NETWORK_NAME}' also already exists. Choose a unique name and rerun."
  fi
fi

if (( REUSE_NETWORK == 0 )) && CONFLICTS="$(subnet_conflicts "$LAB_SUBNET" 2>/dev/null)"; then
  warn "The requested subnet overlaps something already present on this host:\n${CONFLICTS}"
  FREE_SUBNET="$(suggest_free_subnet)"
  [[ -n "$FREE_SUBNET" ]] || die 'Could not automatically find a free default subnet.'
  while true; do
    LAB_SUBNET="$(prompt_default 'Choose a non-conflicting lab subnet' "$FREE_SUBNET")"
    validate_private_24 "$LAB_SUBNET" || { warn 'Use a private /24 network.'; continue; }
    if MORE="$(subnet_conflicts "$LAB_SUBNET" 2>/dev/null)"; then
      warn "That subnet also overlaps:\n${MORE}"
      continue
    fi
    break
  done
fi

mapfile -t NET_VALUES < <(derive_network_values "$LAB_SUBNET")
GATEWAY_IP="${NET_VALUES[0]}"
DC_IP="${NET_VALUES[1]}"
DHCP_START="${NET_VALUES[2]}"
DHCP_END="${NET_VALUES[3]}"
PREFIX_LEN="${NET_VALUES[4]}"

# ---- Official Windows Server Evaluation download ----
validate_iso() {
  local iso="$1"
  [[ -s "$iso" ]] || return 1
  local size
  size=$(stat -c%s "$iso" 2>/dev/null || echo 0)
  (( size > 3000000000 )) || return 1
  xorriso -indev "$iso" -toc >/dev/null 2>&1 || return 1
}

if validate_iso "$WINDOWS_ISO"; then
  log "Using existing validated Windows Server ISO: ${WINDOWS_ISO}"
else
  [[ -e "$WINDOWS_ISO" ]] && rm -f "$WINDOWS_ISO"
  log 'Downloading Windows Server 2025 Evaluation ISO from Microsoft...'
  log "Official redirect: ${WINDOWS_ISO_URL}"
  curl -fL --retry 5 --retry-delay 3 --connect-timeout 30 --progress-bar -C - "$WINDOWS_ISO_URL" -o "$WINDOWS_ISO"
  validate_iso "$WINDOWS_ISO" || { rm -f "$WINDOWS_ISO"; die 'The downloaded file did not validate as a Windows-sized ISO image.'; }
fi

# ---- Inspect image and select Desktop Experience index ----
ISO_MOUNT="$(mktemp -d /tmp/kali-adlab-iso.XXXXXX)"
mount -o loop,ro "$WINDOWS_ISO" "$ISO_MOUNT"
WIM_PATH=''
[[ -f "$ISO_MOUNT/sources/install.wim" ]] && WIM_PATH="$ISO_MOUNT/sources/install.wim"
[[ -f "$ISO_MOUNT/sources/install.esd" ]] && WIM_PATH="$ISO_MOUNT/sources/install.esd"
[[ -n "$WIM_PATH" ]] || die 'Windows ISO does not contain sources/install.wim or install.esd.'
wiminfo "$WIM_PATH" > "${BASE_DIR}/windows-images.txt"

if [[ "$EDITION_CHOICE" == '1' ]]; then
  IMAGE_INDEX=$(awk 'BEGIN{IGNORECASE=1} /^Index:/ {i=$2} /^(Name|Display Name):/ && /Standard/ && /Desktop Experience/ {print i; exit}' "${BASE_DIR}/windows-images.txt")
  IMAGE_INDEX="${IMAGE_INDEX:-2}"
  EDITION_LABEL='Windows Server 2025 Standard Evaluation (Desktop Experience)'
else
  IMAGE_INDEX=$(awk 'BEGIN{IGNORECASE=1} /^Index:/ {i=$2} /^(Name|Display Name):/ && /Datacenter/ && /Desktop Experience/ {print i; exit}' "${BASE_DIR}/windows-images.txt")
  IMAGE_INDEX="${IMAGE_INDEX:-4}"
  EDITION_LABEL='Windows Server 2025 Datacenter Evaluation (Desktop Experience)'
fi
cleanup_mount
ISO_MOUNT=''

# ---- Define/reuse lab network ----
if (( REUSE_NETWORK == 0 )); then
  NETWORK_XML="$(mktemp /tmp/kali-adlab-network.XXXXXX.xml)"
  if [[ "$NETWORK_MODE" == 'nat' ]]; then
    FORWARD_XML="  <forward mode='nat'/>"
  else
    FORWARD_XML=''
  fi
  cat > "$NETWORK_XML" <<EOF
<network>
  <name>${NETWORK_NAME}</name>
${FORWARD_XML}
  <domain name='${DOMAIN_FQDN}' localOnly='yes'/>
  <ip address='${GATEWAY_IP}' netmask='255.255.255.0'>
    <dhcp>
      <range start='${DHCP_START}' end='${DHCP_END}'/>
    </dhcp>
  </ip>
</network>
EOF
  virsh net-define "$NETWORK_XML" >/dev/null
  virsh net-start "$NETWORK_NAME" >/dev/null
  virsh net-autostart "$NETWORK_NAME" >/dev/null
  rm -f "$NETWORK_XML"
else
  virsh net-start "$NETWORK_NAME" >/dev/null 2>&1 || true
fi

# ---- Generate per-lab unattended media. Secrets never enter Git. ----
RUNTIME_DIR="${BASE_DIR}/runtime-${VM_NAME}"
MEDIA_DIR="${RUNTIME_DIR}/media"
TOOLS_ISO="${BASE_DIR}/${VM_NAME}-LABTOOLS.iso"
rm -rf "$RUNTIME_DIR"
mkdir -p "$MEDIA_DIR/ADLab"
chmod 700 "$RUNTIME_DIR" "$MEDIA_DIR" "$MEDIA_DIR/ADLab"

cp "$REPO_DIR/windows/SetupComplete.cmd" "$MEDIA_DIR/ADLab/"
cp "$REPO_DIR/windows/Stage1.ps1" "$MEDIA_DIR/ADLab/"
cp "$REPO_DIR/windows/Stage2.ps1" "$MEDIA_DIR/ADLab/"
cp "$REPO_DIR/windows/Stage3.ps1" "$MEDIA_DIR/ADLab/"

DSRM_B64="$(printf '%s' "$DSRM_PASSWORD" | base64 -w0)"
cat > "$MEDIA_DIR/ADLab/config.ps1" <<EOF
\$LabConfig = @{
    VmName = '${VM_NAME}'
    DomainFqdn = '${DOMAIN_FQDN}'
    NetbiosName = '${NETBIOS_NAME}'
    DcIp = '${DC_IP}'
    PrefixLength = ${PREFIX_LEN}
    Gateway = '${GATEWAY_IP}'
    NetworkMode = '${NETWORK_MODE}'
    DsrmPasswordB64 = '${DSRM_B64}'
}
EOF
chmod 600 "$MEDIA_DIR/ADLab/config.ps1"

ADMIN_PASSWORD="$ADMIN_PASSWORD" python3 - "$REPO_DIR/templates/Autounattend.xml.template" "$MEDIA_DIR/Autounattend.xml" "$VM_NAME" "$IMAGE_INDEX" <<'PY'
import html, os, pathlib, sys
src=pathlib.Path(sys.argv[1]).read_text()
out=src.replace('@@VM_NAME@@', html.escape(sys.argv[3]))
out=out.replace('@@IMAGE_INDEX@@', html.escape(sys.argv[4]))
out=out.replace('@@ADMIN_PASSWORD_XML@@', html.escape(os.environ['ADMIN_PASSWORD']))
pathlib.Path(sys.argv[2]).write_text(out, encoding='utf-8')
PY
chmod 600 "$MEDIA_DIR/Autounattend.xml"

rm -f "$TOOLS_ISO"
xorriso -as mkisofs -quiet -V LABTOOLS -J -R -o "$TOOLS_ISO" "$MEDIA_DIR"
chmod 600 "$TOOLS_ISO"

unset ADMIN_PASSWORD DSRM_PASSWORD DSRM_B64

DISK_PATH="${IMAGE_DIR}/${VM_NAME}.qcow2"
[[ ! -e "$DISK_PATH" ]] || die "Orphan disk already exists at ${DISK_PATH}. Move/remove it explicitly before rerunning."

OS_VARIANT='win2k22'
if osinfo-query os --fields=short-id 2>/dev/null | grep -q 'win2k25'; then OS_VARIANT='win2k25'; fi

cat <<EOF

---------------- Deployment plan ----------------
VM               : ${VM_NAME}
Windows edition  : ${EDITION_LABEL}
AD domain        : ${DOMAIN_FQDN} (${NETBIOS_NAME})
Lab network      : ${NETWORK_NAME} / ${LAB_SUBNET}
Network mode     : ${NETWORK_MODE}
Domain Controller: ${DC_IP}
Resources        : ${VM_RAM_MB} MB RAM, ${VM_VCPUS} vCPU, ${DEFAULT_DISK_GB} GB sparse disk
-------------------------------------------------
EOF

log 'Creating and starting the Windows Server VM...'
virt-install \
  --connect qemu:///system \
  --name "$VM_NAME" \
  --memory "$VM_RAM_MB" \
  --vcpus "$VM_VCPUS" \
  --cpu host-passthrough \
  --machine q35 \
  --boot uefi \
  --disk "path=${DISK_PATH},size=${DEFAULT_DISK_GB},format=qcow2,bus=sata,cache=none,discard=unmap" \
  --cdrom "$WINDOWS_ISO" \
  --disk "path=${TOOLS_ISO},device=cdrom,bus=sata,readonly=on" \
  --network "network=${NETWORK_NAME},model=e1000e" \
  --graphics spice,listen=127.0.0.1 \
  --video vga \
  --os-variant "$OS_VARIANT" \
  --noautoconsole

CLEANUP_LOG="${BASE_DIR}/${VM_NAME}-secret-cleanup.log"
nohup bash "$REPO_DIR/scripts/cleanup-secrets.sh" "$VM_NAME" "$TOOLS_ISO" "$RUNTIME_DIR" "$DC_IP" >"$CLEANUP_LOG" 2>&1 &

cat <<EOF

============================================================
 Automated deployment has started.
============================================================
No Windows setup clicks are required. Windows Setup will use the
answer media, configure ${DC_IP}, install AD DS/DNS, create the
${DOMAIN_FQDN} forest, reboot as required, validate AD services,
and remove its copied secret configuration.

The host-side LABTOOLS ISO contains the temporary unattended secret.
A cleanup watcher will eject and securely remove that ISO after LDAP
is reachable on ${DC_IP}:389.

Watch the console:
  virt-manager

Check VM state:
  sudo virsh list --all

After completion, sign in as:
  ${NETBIOS_NAME}\\Administrator

Windows-side status file:
  C:\\ADLab\\SUCCESS.txt

Cleanup watcher log:
  ${CLEANUP_LOG}
============================================================
EOF
