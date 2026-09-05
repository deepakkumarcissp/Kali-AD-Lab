#!/usr/bin/env bash
set -Eeuo pipefail

VM_NAME="${1:?VM name required}"

log(){ printf '[Kali-AD-Lab] %s\n' "$*"; }
die(){ printf '[Kali-AD-Lab] ERROR: %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || exec sudo -E bash "$0" "$@"
virsh dominfo "$VM_NAME" >/dev/null 2>&1 || die "VM not found: ${VM_NAME}"

TMP_XML="$(mktemp /tmp/kali-adlab-boot.XXXXXX.xml)"
cleanup(){ rm -f "$TMP_XML"; }
trap cleanup EXIT

virsh dumpxml --inactive "$VM_NAME" > "$TMP_XML"

python3 - "$TMP_XML" <<'PY'
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
tree = ET.parse(path)
root = tree.getroot()

# Do not mix legacy <os><boot dev=...> and per-device boot order.
os_node = root.find('os')
if os_node is not None:
    for node in list(os_node.findall('boot')):
        os_node.remove(node)

devices = root.find('devices')
if devices is None:
    raise SystemExit('VM XML has no <devices> section')

for node in devices:
    boot = node.find('boot')
    if boot is not None:
        node.remove(boot)

os_disk = None
windows_cdrom = None
for disk in devices.findall('disk'):
    device = disk.get('device')
    if device == 'disk' and os_disk is None:
        os_disk = disk
    elif device == 'cdrom':
        source = disk.find('source')
        source_path = ''
        if source is not None:
            source_path = source.get('file') or source.get('dev') or ''
        if 'Windows_Server_2025' in source_path:
            windows_cdrom = disk

if os_disk is None:
    raise SystemExit('Could not identify the Windows virtual hard disk')

ET.SubElement(os_disk, 'boot', {'order': '1'})
if windows_cdrom is not None:
    ET.SubElement(windows_cdrom, 'boot', {'order': '2'})

tree.write(path, encoding='unicode')
PY

virsh define "$TMP_XML" >/dev/null
log "Next boot for ${VM_NAME}: hard disk first, Windows installer second."
