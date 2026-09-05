#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_ISO="${1:?source Windows ISO required}"
OUTPUT_ISO="${2:?output ISO required}"

log(){ printf '[Kali-AD-Lab] %s\n' "$*"; }
die(){ printf '[Kali-AD-Lab] ERROR: %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || exec sudo -E bash "$0" "$@"
[[ -f "$SOURCE_ISO" ]] || die "Source ISO not found: ${SOURCE_ISO}"
command -v xorriso >/dev/null 2>&1 || die 'xorriso is required.'

validate_iso(){
  local f="$1" s
  [[ -s "$f" ]] || return 1
  s=$(stat -c%s "$f" 2>/dev/null || echo 0)
  (( s > 3000000000 )) || return 1
  xorriso -indev "$f" -toc >/dev/null 2>&1
}

if validate_iso "$OUTPUT_ISO" && [[ "$OUTPUT_ISO" -nt "$SOURCE_ISO" ]]; then
  log "Using cached no-prompt Windows ISO: ${OUTPUT_ISO}"
  exit 0
fi

WORK_DIR="$(mktemp -d /var/tmp/kali-adlab-noprompt.XXXXXX)"
MOUNT_DIR="$WORK_DIR/mnt"
TREE_DIR="$WORK_DIR/tree"
TMP_ISO="${OUTPUT_ISO}.partial"
mkdir -p "$MOUNT_DIR" "$TREE_DIR"

cleanup(){
  if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then umount "$MOUNT_DIR" || true; fi
  rm -rf "$WORK_DIR"
  rm -f "$TMP_ISO"
}
trap cleanup EXIT

log 'Preparing unattended no-prompt Windows boot media...'
mount -o loop,ro "$SOURCE_ISO" "$MOUNT_DIR"

[[ -f "$MOUNT_DIR/boot/etfsboot.com" ]] || die 'Windows ISO is missing boot/etfsboot.com.'
[[ -f "$MOUNT_DIR/efi/microsoft/boot/efisys_noprompt.bin" ]] || die 'Windows ISO is missing efi/microsoft/boot/efisys_noprompt.bin.'

# Copy the Microsoft media unchanged, then rebuild only the El Torito boot
# catalog so UEFI uses Microsoft's own efisys_noprompt.bin. This removes the
# "Press any key to boot from CD or DVD" gate without third-party boot files.
cp -a "$MOUNT_DIR/." "$TREE_DIR/"
umount "$MOUNT_DIR"

mkdir -p "$(dirname "$OUTPUT_ISO")"
rm -f "$TMP_ISO"

xorriso -as mkisofs \
  -iso-level 3 \
  -J -joliet-long -R \
  -V 'WS2025_NOPROMPT' \
  -b boot/etfsboot.com \
  -no-emul-boot -boot-load-size 8 -boot-info-table \
  -eltorito-alt-boot \
  -e efi/microsoft/boot/efisys_noprompt.bin \
  -no-emul-boot \
  -o "$TMP_ISO" \
  "$TREE_DIR"

validate_iso "$TMP_ISO" || die 'Generated no-prompt Windows ISO failed validation.'
mv -f "$TMP_ISO" "$OUTPUT_ISO"
chmod 644 "$OUTPUT_ISO"
log "No-prompt Windows ISO ready: ${OUTPUT_ISO}"
