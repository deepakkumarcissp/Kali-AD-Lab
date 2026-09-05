#!/usr/bin/env bash
set -Eeuo pipefail

VM_NAME="${1:?VM name required}"

log(){ printf '[Kali-AD-Lab] %s\n' "$*"; }

# The Microsoft evaluation ISO uses the standard "Press any key to boot from
# CD or DVD" gate. With --noautoconsole there is no human at the console to
# press it, so send harmless boot keys during the early firmware/ISO window.
# Repeated keys make this tolerant of different UEFI and host boot timings.
log "Triggering unattended Windows DVD boot for ${VM_NAME}..."

for _ in $(seq 1 60); do
  if virsh domstate "$VM_NAME" 2>/dev/null | grep -qi running; then
    break
  fi
  sleep 0.25
done

# Give OVMF a moment to enumerate the CD-ROM devices.
sleep 1

# ENTER handles the UEFI boot-device menu if it is shown; SPACE satisfies the
# Windows DVD prompt. During this short period Windows PE is still loading, so
# the repeated keys do not alter the unattended installation configuration.
for _ in $(seq 1 24); do
  virsh send-key "$VM_NAME" KEY_ENTER >/dev/null 2>&1 || true
  sleep 0.25
  virsh send-key "$VM_NAME" KEY_SPACE >/dev/null 2>&1 || true
  sleep 0.25
done

log 'Windows DVD boot trigger completed.'
