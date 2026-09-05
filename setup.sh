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

if [[ ${EUID} -ne 0 ]]; then exec sudo -E bash "$0" "$@"; fi

log(){ printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn(){ printf '\nWARNING: %s\n\n' "$*" >&2; }
die(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }

prompt_default(){ local p="$1" d="$2" v; read -r -p "${p} [${d}]: " v; printf '%s' "${v:-$d}"; }
confirm(){ local p="$1" d="${2:-N}" a; if [[ "$d" == Y ]]; then read -r -p "$p [Y/n]: " a; a="${a:-Y}"; else read -r -p "$p [y/N]: " a; a="${a:-N}"; fi; [[ "$a" =~ ^[Yy]$ ]]; }
read_secret_twice(){
  local label="$1" p1 p2
  while true; do
    read -r -s -p "${label}: " p1; printf '\n' >&2
    read -r -s -p "Confirm ${label}: " p2; printf '\n' >&2
    [[ "$p1" == "$p2" ]] || { warn 'Passwords did not match.'; continue; }
    (( ${#p1} >= 12 )) || { warn 'Use at least 12 characters.'; continue; }
    [[ "$p1" =~ [A-Z] && "$p1" =~ [a-z] && "$p1" =~ [0-9] && "$p1" =~ [^A-Za-z0-9] ]] || { warn 'Use uppercase, lowercase, a number, and a special character.'; continue; }
    printf '%s' "$p1"; return
  done
}

validate_vm_name(){ [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,14}$ && ! "$1" =~ -$ ]]; }
validate_domain(){ python3 - "$1" <<'PY'
import re,sys
n=sys.argv[1].strip().lower()
if len(n)>253 or '.' not in n: raise SystemExit(1)
for x in n.split('.'):
    if not (1<=len(x)<=63) or not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]*[a-z0-9])?',x): raise SystemExit(1)
PY
}
validate_private_24(){ python3 - "$1" <<'PY'
import ipaddress,sys
try:
 n=ipaddress.ip_network(sys.argv[1],strict=True); ok=n.version==4 and n.prefixlen==24 and n.is_private
except Exception: ok=False
raise SystemExit(0 if ok else 1)
PY
}
derive_network_values(){ python3 - "$1" <<'PY'
import ipaddress,sys
n=ipaddress.ip_network(sys.argv[1]); print(n.network_address+1); print(n.network_address+10); print(n.network_address+100); print(n.network_address+200); print(n.prefixlen)
PY
}
subnet_conflicts(){ python3 - "$1" <<'PY'
import ipaddress,subprocess,sys,xml.etree.ElementTree as ET
w=ipaddress.ip_network(sys.argv[1]); found=[]
try:
 for line in subprocess.check_output(['ip','-o','-4','route','show'],text=True,stderr=subprocess.DEVNULL).splitlines():
  first=line.split()[0]
  if first=='default': continue
  try: n=ipaddress.ip_network(first,strict=False)
  except Exception: continue
  if w.overlaps(n): found.append(('host route',str(n)))
except Exception: pass
try:
 for name in subprocess.check_output(['virsh','net-list','--all','--name'],text=True,stderr=subprocess.DEVNULL).split():
  try:
   root=ET.fromstring(subprocess.check_output(['virsh','net-dumpxml',name],text=True,stderr=subprocess.DEVNULL))
   for node in root.findall('ip'):
    a=node.get('address'); m=node.get('netmask') or node.get('prefix')
    if not a or not m: continue
    try: n=ipaddress.ip_network(f'{a}/{m}',strict=False)
    except Exception: continue
    if w.overlaps(n): found.append((f'libvirt:{name}',str(n)))
  except Exception: pass
except Exception: pass
if found:
 for s,n in found: print(f'{s} -> {n}')
 raise SystemExit(0)
raise SystemExit(1)
PY
}
suggest_free_subnet(){ python3 <<'PY'
import ipaddress,subprocess,xml.etree.ElementTree as ET
used=[]
try:
 for line in subprocess.check_output(['ip','-o','-4','route','show'],text=True,stderr=subprocess.DEVNULL).splitlines():
  f=line.split()[0]
  if f=='default': continue
  try: used.append(ipaddress.ip_network(f,strict=False))
  except Exception: pass
except Exception: pass
try:
 for name in subprocess.check_output(['virsh','net-list','--all','--name'],text=True,stderr=subprocess.DEVNULL).split():
  try:
   root=ET.fromstring(subprocess.check_output(['virsh','net-dumpxml',name],text=True,stderr=subprocess.DEVNULL))
   for node in root.findall('ip'):
    a=node.get('address'); m=node.get('netmask') or node.get('prefix')
    if a and m:
     try: used.append(ipaddress.ip_network(f'{a}/{m}',strict=False))
     except Exception: pass
  except Exception: pass
except Exception: pass
for c in ['192.168.77.0/24','192.168.88.0/24','192.168.99.0/24','10.77.0.0/24','10.88.0.0/24','10.99.0.0/24','172.27.77.0/24','172.28.88.0/24']:
 n=ipaddress.ip_network(c)
 if not any(n.overlaps(u) for u in used): print(c); break
PY
}
net_cidr(){
  python3 - "$1" <<'PYNET'
import ipaddress,subprocess,sys,xml.etree.ElementTree as ET
r=ET.fromstring(subprocess.check_output(['virsh','net-dumpxml',sys.argv[1]],text=True))
n=r.find('ip')
if n is None: raise SystemExit(1)
print(ipaddress.ip_network(f"{n.get('address')}/{n.get('netmask') or n.get('prefix')}",strict=False))
PYNET
}
net_mode(){
  python3 - "$1" <<'PYNET'
import subprocess,sys,xml.etree.ElementTree as ET
r=ET.fromstring(subprocess.check_output(['virsh','net-dumpxml',sys.argv[1]],text=True))
f=r.find('forward')
print(f.get('mode','nat') if f is not None else 'isolated')
PYNET
}
cleanup_mount(){ if [[ -n "${ISO_MOUNT:-}" ]] && mountpoint -q "$ISO_MOUNT"; then umount "$ISO_MOUNT" || true; fi; [[ -n "${ISO_MOUNT:-}" ]] && rmdir "$ISO_MOUNT" 2>/dev/null || true; }
trap cleanup_mount EXIT

cat <<'BANNER'
============================================================
 Kali-AD-Lab | One-command Windows Server AD lab builder
============================================================
BANNER

while true; do VM_NAME="$(prompt_default 'Windows server / VM name' "$DEFAULT_VM_NAME")"; validate_vm_name "$VM_NAME" && break; warn 'Computer name must be 1-15 characters using letters, numbers, or hyphens.'; done
while true; do DOMAIN_FQDN="$(prompt_default 'Active Directory DNS domain' "$DEFAULT_DOMAIN" | tr '[:upper:]' '[:lower:]')"; validate_domain "$DOMAIN_FQDN" || { warn 'Use a DNS-style domain such as adlab.test.'; continue; }; if [[ "$DOMAIN_FQDN" == *.local ]]; then warn '.local can conflict with mDNS. .test is recommended.'; confirm 'Use .local anyway?' N || continue; fi; break; done
NETBIOS_NAME="$(printf '%s' "${DOMAIN_FQDN%%.*}" | tr '[:lower:]' '[:upper:]' | cut -c1-15)"
NETBIOS_NAME="$(prompt_default 'NetBIOS domain name' "$NETBIOS_NAME")"
while true; do LAB_SUBNET="$(prompt_default 'Lab IPv4 subnet (private /24)' "$DEFAULT_SUBNET")"; validate_private_24 "$LAB_SUBNET" && break; warn 'Use a private /24 such as 192.168.77.0/24.'; done
while true; do NETWORK_MODE="$(prompt_default 'Network mode: nat (Internet outbound) or isolated' 'nat' | tr '[:upper:]' '[:lower:]')"; [[ "$NETWORK_MODE" == nat || "$NETWORK_MODE" == isolated ]] && break; warn 'Enter nat or isolated.'; done
printf '\nWindows Server edition:\n  1) Standard Evaluation - Desktop Experience [recommended]\n  2) Datacenter Evaluation - Desktop Experience\n'
read -r -p 'Choose edition [1]: ' EDITION_CHOICE; EDITION_CHOICE="${EDITION_CHOICE:-1}"; [[ "$EDITION_CHOICE" == 1 || "$EDITION_CHOICE" == 2 ]] || die 'Edition choice must be 1 or 2.'
printf '\nPasswords are used only for this local lab and are never committed to Git.\n'
ADMIN_PASSWORD="$(read_secret_twice 'Windows/Domain Administrator password')"
DSRM_PASSWORD="$(read_secret_twice 'Directory Services Restore Mode (DSRM) password')"

log 'Checking CPU virtualization support...'
grep -Eq '(vmx|svm)' /proc/cpuinfo || die 'Intel VT-x/AMD-V is not visible. Enable it in BIOS/UEFI.'
log 'Installing/validating KVM, libvirt and image tooling...'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients virtinst virt-manager ovmf dnsmasq-base xorriso curl python3 wimtools netcat-openbsd libosinfo-bin
systemctl enable --now libvirtd
[[ -e /dev/kvm ]] || die '/dev/kvm is unavailable. Check BIOS virtualization settings.'

QEMU_USER=''
for c in libvirt-qemu qemu; do getent passwd "$c" >/dev/null 2>&1 && { QEMU_USER="$c"; break; }; done
[[ -n "$QEMU_USER" ]] || die 'Could not identify the libvirt/QEMU runtime account.'
QEMU_GROUP="$(id -gn "$QEMU_USER")"
log "Detected QEMU runtime account: ${QEMU_USER}:${QEMU_GROUP}"

mkdir -p "$BASE_DIR" "$IMAGE_DIR"
chmod 711 "$BASE_DIR" "$IMAGE_DIR"

HOST_RAM_MB=$(( $(awk '/MemTotal:/ {print $2}' /proc/meminfo) / 1024 ))
HOST_CPUS=$(nproc); VM_RAM_MB=$DEFAULT_RAM_MB; VM_VCPUS=4
(( HOST_CPUS < VM_VCPUS )) && VM_VCPUS=$HOST_CPUS
(( HOST_RAM_MB < 10000 )) && VM_RAM_MB=4096
AVAILABLE_GB=$(df --output=avail -BG "$IMAGE_DIR" | tail -1 | tr -dc '0-9')
(( AVAILABLE_GB >= 20 )) || die 'Less than 20 GB free disk space is available.'

if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
 warn "VM '${VM_NAME}' already exists."
 read -r -p 'Type REBUILD to delete and recreate it, or press Enter to stop: ' REBUILD
 [[ "$REBUILD" == REBUILD ]] || exit 0
 virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
 virsh undefine "$VM_NAME" --nvram --remove-all-storage >/dev/null 2>&1 || virsh undefine "$VM_NAME" --remove-all-storage >/dev/null 2>&1 || true
fi

NETWORK_NAME="$DEFAULT_NETWORK_NAME"; REUSE_NETWORK=0
if virsh net-info "$NETWORK_NAME" >/dev/null 2>&1; then
 EC="$(net_cidr "$NETWORK_NAME" 2>/dev/null || true)"; EM="$(net_mode "$NETWORK_NAME" 2>/dev/null || true)"
 if [[ "$EC" == "$LAB_SUBNET" && "$EM" == "$NETWORK_MODE" ]]; then REUSE_NETWORK=1; log "Reusing existing network ${NETWORK_NAME}."; else NETWORK_NAME="$(prompt_default 'Existing ad-lab network differs; use network name' "ad-lab-${VM_NAME,,}")"; virsh net-info "$NETWORK_NAME" >/dev/null 2>&1 && die "Network ${NETWORK_NAME} already exists."; fi
fi

if (( REUSE_NETWORK == 0 )) && CONFLICTS="$(subnet_conflicts "$LAB_SUBNET" 2>/dev/null)"; then
 warn "Requested subnet overlaps an existing network:\n${CONFLICTS}"
 FREE_SUBNET="$(suggest_free_subnet)"; [[ -n "$FREE_SUBNET" ]] || die 'Could not find a free private /24.'
 while true; do LAB_SUBNET="$(prompt_default 'Choose a non-conflicting lab subnet' "$FREE_SUBNET")"; validate_private_24 "$LAB_SUBNET" || continue; subnet_conflicts "$LAB_SUBNET" >/dev/null 2>&1 || break; warn 'That subnet also conflicts.'; done
fi

mapfile -t N < <(derive_network_values "$LAB_SUBNET")
GATEWAY_IP="${N[0]}"; DC_IP="${N[1]}"; DHCP_START="${N[2]}"; DHCP_END="${N[3]}"; PREFIX_LEN="${N[4]}"

validate_iso(){ local s; [[ -s "$1" ]] || return 1; s=$(stat -c%s "$1" 2>/dev/null || echo 0); (( s > 3000000000 )) || return 1; xorriso -indev "$1" -toc >/dev/null 2>&1; }
if validate_iso "$WINDOWS_ISO"; then log "Using existing validated Windows ISO: ${WINDOWS_ISO}"; else rm -f "$WINDOWS_ISO"; log 'Downloading Windows Server 2025 Evaluation ISO from Microsoft...'; curl -fL --retry 5 --retry-delay 3 --connect-timeout 30 --progress-bar -C - "$WINDOWS_ISO_URL" -o "$WINDOWS_ISO"; validate_iso "$WINDOWS_ISO" || { rm -f "$WINDOWS_ISO"; die 'Downloaded Windows ISO failed validation.'; }; fi
chmod 644 "$WINDOWS_ISO"

ISO_MOUNT="$(mktemp -d /tmp/kali-adlab-iso.XXXXXX)"; mount -o loop,ro "$WINDOWS_ISO" "$ISO_MOUNT"
WIM_PATH=''; [[ -f "$ISO_MOUNT/sources/install.wim" ]] && WIM_PATH="$ISO_MOUNT/sources/install.wim"; [[ -f "$ISO_MOUNT/sources/install.esd" ]] && WIM_PATH="$ISO_MOUNT/sources/install.esd"; [[ -n "$WIM_PATH" ]] || die 'Windows ISO has no install.wim/install.esd.'
wiminfo "$WIM_PATH" > "${BASE_DIR}/windows-images.txt"
if [[ "$EDITION_CHOICE" == 1 ]]; then IMAGE_INDEX=$(awk 'BEGIN{IGNORECASE=1} /^Index:/ {i=$2} /^(Name|Display Name):/ && /Standard/ && /Desktop Experience/ {print i; exit}' "${BASE_DIR}/windows-images.txt"); IMAGE_INDEX="${IMAGE_INDEX:-2}"; EDITION_LABEL='Standard Evaluation - Desktop Experience'; else IMAGE_INDEX=$(awk 'BEGIN{IGNORECASE=1} /^Index:/ {i=$2} /^(Name|Display Name):/ && /Datacenter/ && /Desktop Experience/ {print i; exit}' "${BASE_DIR}/windows-images.txt"); IMAGE_INDEX="${IMAGE_INDEX:-4}"; EDITION_LABEL='Datacenter Evaluation - Desktop Experience'; fi
cleanup_mount; ISO_MOUNT=''

if (( REUSE_NETWORK == 0 )); then
 NETWORK_XML="$(mktemp /tmp/kali-adlab-network.XXXXXX.xml)"; [[ "$NETWORK_MODE" == nat ]] && FORWARD_XML="  <forward mode='nat'/>" || FORWARD_XML=''
 cat > "$NETWORK_XML" <<EOF2
<network><name>${NETWORK_NAME}</name>
${FORWARD_XML}
<domain name='${DOMAIN_FQDN}' localOnly='yes'/><ip address='${GATEWAY_IP}' netmask='255.255.255.0'><dhcp><range start='${DHCP_START}' end='${DHCP_END}'/></dhcp></ip></network>
EOF2
 virsh net-define "$NETWORK_XML" >/dev/null; virsh net-start "$NETWORK_NAME" >/dev/null; virsh net-autostart "$NETWORK_NAME" >/dev/null; rm -f "$NETWORK_XML"
else virsh net-start "$NETWORK_NAME" >/dev/null 2>&1 || true
fi

RUNTIME_DIR="${BASE_DIR}/runtime-${VM_NAME}"; MEDIA_DIR="${RUNTIME_DIR}/media"; TOOLS_ISO="${BASE_DIR}/${VM_NAME}-LABTOOLS.iso"
rm -rf "$RUNTIME_DIR"; mkdir -p "$MEDIA_DIR/ADLab"; chmod 700 "$RUNTIME_DIR" "$MEDIA_DIR" "$MEDIA_DIR/ADLab"
cp "$REPO_DIR/windows/SetupComplete.cmd" "$REPO_DIR/windows/Stage1.ps1" "$REPO_DIR/windows/Stage2.ps1" "$REPO_DIR/windows/Stage3.ps1" "$MEDIA_DIR/ADLab/"
DSRM_B64="$(printf '%s' "$DSRM_PASSWORD" | base64 -w0)"
cat > "$MEDIA_DIR/ADLab/config.ps1" <<EOF2
\$LabConfig = @{ VmName='${VM_NAME}'; DomainFqdn='${DOMAIN_FQDN}'; NetbiosName='${NETBIOS_NAME}'; DcIp='${DC_IP}'; PrefixLength=${PREFIX_LEN}; Gateway='${GATEWAY_IP}'; NetworkMode='${NETWORK_MODE}'; DsrmPasswordB64='${DSRM_B64}' }
EOF2
chmod 600 "$MEDIA_DIR/ADLab/config.ps1"
ADMIN_PASSWORD="$ADMIN_PASSWORD" python3 - "$REPO_DIR/templates/Autounattend.xml.template" "$MEDIA_DIR/Autounattend.xml" "$VM_NAME" "$IMAGE_INDEX" <<'PY'
import html,os,pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text(); s=s.replace('@@VM_NAME@@',html.escape(sys.argv[3])).replace('@@IMAGE_INDEX@@',html.escape(sys.argv[4])).replace('@@ADMIN_PASSWORD_XML@@',html.escape(os.environ['ADMIN_PASSWORD'])); pathlib.Path(sys.argv[2]).write_text(s)
PY
chmod 600 "$MEDIA_DIR/Autounattend.xml"
rm -f "$TOOLS_ISO"; xorriso -as mkisofs -quiet -V LABTOOLS -J -R -o "$TOOLS_ISO" "$MEDIA_DIR"; chown "$QEMU_USER:$QEMU_GROUP" "$TOOLS_ISO"; chmod 600 "$TOOLS_ISO"
unset ADMIN_PASSWORD DSRM_PASSWORD DSRM_B64

DISK_PATH="${IMAGE_DIR}/${VM_NAME}.qcow2"
[[ ! -e "$DISK_PATH" ]] || { warn "Removing orphan disk left by a failed prior install: ${DISK_PATH}"; rm -f "$DISK_PATH"; }
qemu-img create -f qcow2 "$DISK_PATH" "${DEFAULT_DISK_GB}G" >/dev/null; chown "$QEMU_USER:$QEMU_GROUP" "$DISK_PATH"; chmod 600 "$DISK_PATH"
runuser -u "$QEMU_USER" -- sh -c "test -r '$WINDOWS_ISO' && test -r '$TOOLS_ISO' && test -r '$DISK_PATH' && test -w '$DISK_PATH'" || { rm -f "$DISK_PATH"; die "QEMU account ${QEMU_USER} cannot access VM media/storage."; }

OS_VARIANT='win2k22'; osinfo-query os --fields=short-id 2>/dev/null | grep -q win2k25 && OS_VARIANT='win2k25'
cat <<EOF2

---------------- Deployment plan ----------------
VM               : ${VM_NAME}
Windows edition  : ${EDITION_LABEL}
AD domain        : ${DOMAIN_FQDN} (${NETBIOS_NAME})
Lab network      : ${NETWORK_NAME} / ${LAB_SUBNET}
Network mode     : ${NETWORK_MODE}
Domain Controller: ${DC_IP}
Resources        : ${VM_RAM_MB} MB RAM, ${VM_VCPUS} vCPU, ${DEFAULT_DISK_GB} GB disk
-------------------------------------------------
EOF2

log 'Creating and starting the Windows Server VM...'
if ! virt-install --connect qemu:///system --name "$VM_NAME" --memory "$VM_RAM_MB" --vcpus "$VM_VCPUS" --cpu host-passthrough --machine q35 --boot uefi \
 --disk "path=${DISK_PATH},format=qcow2,bus=sata,cache=none,discard=unmap" \
 --cdrom "$WINDOWS_ISO" --disk "path=${TOOLS_ISO},device=cdrom,bus=sata,readonly=on" \
 --network "network=${NETWORK_NAME},model=e1000e" --graphics spice,listen=127.0.0.1 --video vga --os-variant "$OS_VARIANT" --noautoconsole; then
 virsh destroy "$VM_NAME" >/dev/null 2>&1 || true; virsh undefine "$VM_NAME" --nvram >/dev/null 2>&1 || virsh undefine "$VM_NAME" >/dev/null 2>&1 || true
 rm -f "$DISK_PATH"
 die 'VM creation failed. The partial VM/disk was cleaned up; rerun after reviewing the error above.'
fi

CLEANUP_LOG="${BASE_DIR}/${VM_NAME}-secret-cleanup.log"
nohup bash "$REPO_DIR/scripts/cleanup-secrets.sh" "$VM_NAME" "$TOOLS_ISO" "$RUNTIME_DIR" "$DC_IP" >"$CLEANUP_LOG" 2>&1 &

cat <<EOF2

============================================================
 Automated deployment started successfully.
============================================================
No Windows installation clicks should be required.

VM: ${VM_NAME}
Domain: ${DOMAIN_FQDN}
DC IP: ${DC_IP}

View console: virt-manager
Check state : sudo virsh list --all
Success file: C:\\ADLab\\SUCCESS.txt
Cleanup log: ${CLEANUP_LOG}
============================================================
EOF2
