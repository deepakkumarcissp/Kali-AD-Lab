#!/usr/bin/env bash
set -Eeuo pipefail

VM_NAME="${1:-DC01}"
NETWORK_NAME="${2:-ad-lab}"
PROJECT='Kali-AD-Lab'
BASE_DIR="/var/lib/libvirt/boot/${PROJECT}"
IMAGE_DIR="/var/lib/libvirt/images/${PROJECT}"

if [[ ${EUID} -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

printf 'Kali-AD-Lab teardown\n'
printf '  VM      : %s\n' "$VM_NAME"
printf '  Network : %s\n\n' "$NETWORK_NAME"

if ! virsh dominfo "$VM_NAME" >/dev/null 2>&1 && ! virsh net-info "$NETWORK_NAME" >/dev/null 2>&1; then
  echo 'Nothing matching those names was found.'
  exit 0
fi

read -r -p "Type DELETE-LAB to permanently remove the VM and lab network: " CONFIRM
[[ "$CONFIRM" == 'DELETE-LAB' ]] || { echo 'Cancelled.'; exit 0; }

if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
  virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
  virsh undefine "$VM_NAME" --nvram --remove-all-storage >/dev/null 2>&1 \
    || virsh undefine "$VM_NAME" --remove-all-storage >/dev/null 2>&1 \
    || true
fi

if virsh net-info "$NETWORK_NAME" >/dev/null 2>&1; then
  virsh net-destroy "$NETWORK_NAME" >/dev/null 2>&1 || true
  virsh net-undefine "$NETWORK_NAME" >/dev/null 2>&1 || true
fi

rm -rf "${BASE_DIR}/runtime-${VM_NAME}"
rm -f "${BASE_DIR}/${VM_NAME}-LABTOOLS.iso" "${BASE_DIR}/${VM_NAME}-secret-cleanup.log"
rm -f "${IMAGE_DIR}/${VM_NAME}.qcow2" 2>/dev/null || true

echo 'Lab VM and selected lab network removed.'
echo 'The downloaded Microsoft Windows Server ISO was intentionally retained for reuse.'
