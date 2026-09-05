#!/usr/bin/env bash
set -u

VM_NAME="${1:?VM name required}"
TOOLS_ISO="${2:?LABTOOLS ISO required}"
RUNTIME_DIR="${3:?runtime directory required}"
DC_IP="${4:?DC IP required}"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

log "Watching ${DC_IP}:389 for completed AD promotion..."
READY=0
for _ in $(seq 1 360); do
  if nc -z -w 2 "$DC_IP" 389 >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 20
done

if (( READY == 0 )); then
  log 'LDAP did not become reachable during the cleanup window.'
  log "Temporary unattended media has been retained for troubleshooting: ${TOOLS_ISO}"
  exit 1
fi

# Give the post-promotion validation stage time to copy/read anything it still needs.
sleep 60

TARGET=''
while read -r type device target source; do
  [[ "$type" == 'file' && "$device" == 'cdrom' && "$source" == "$TOOLS_ISO" ]] && TARGET="$target"
done < <(virsh domblklist "$VM_NAME" --details 2>/dev/null | tail -n +3)

if [[ -n "$TARGET" ]]; then
  log "Ejecting temporary LABTOOLS media from ${VM_NAME} (${TARGET})..."
  virsh change-media "$VM_NAME" "$TARGET" --eject --live >/dev/null 2>&1 || true
  virsh change-media "$VM_NAME" "$TARGET" --eject --config >/dev/null 2>&1 || true
else
  log 'LABTOOLS device was not attached by the time cleanup ran.'
fi

log 'Securely removing generated unattended files from the Kali host...'
if [[ -f "$TOOLS_ISO" ]]; then
  shred -u "$TOOLS_ISO" 2>/dev/null || rm -f "$TOOLS_ISO"
fi
if [[ -d "$RUNTIME_DIR" ]]; then
  find "$RUNTIME_DIR" -type f -exec shred -u {} + 2>/dev/null || true
  rm -rf "$RUNTIME_DIR"
fi

log 'Temporary host-side unattended secrets removed successfully.'
