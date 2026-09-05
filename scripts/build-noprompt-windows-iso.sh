#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_ISO="${1:?source Windows ISO required}"
OUTPUT_ISO="${2:?output ISO required}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
MEDIA_VERSION='WS25_ADLAB_V2'
VERSION_FILE="${OUTPUT_ISO}.version"

log(){ printf '[Kali-AD-Lab] %s\n' "$*"; }
die(){ printf '[Kali-AD-Lab] ERROR: %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || exec sudo -E bash "$0" "$@"
[[ -f "$SOURCE_ISO" ]] || die "Source ISO not found: ${SOURCE_ISO}"
command -v xorriso >/dev/null 2>&1 || die 'xorriso is required.'

for f in \
  "$REPO_DIR/windows/SetupComplete.cmd" \
  "$REPO_DIR/windows/Stage1.ps1" \
  "$REPO_DIR/windows/Stage2.ps1" \
  "$REPO_DIR/windows/Stage3.ps1"; do
  [[ -f "$f" ]] || die "Required bootstrap file is missing: $f"
done

validate_iso(){
  local f="$1" s
  [[ -s "$f" ]] || return 1
  s=$(stat -c%s "$f" 2>/dev/null || echo 0)
  (( s > 3000000000 )) || return 1
  xorriso -indev "$f" -toc >/dev/null 2>&1
}

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

cp -a "$MOUNT_DIR/." "$TREE_DIR/"
umount "$MOUNT_DIR"

# Embed static bootstrap files using Windows' supported $OEM$ mechanism.
OEM_DIR="$TREE_DIR/sources/\$OEM\$"
mkdir -p "$OEM_DIR/\$1/ADLab" "$OEM_DIR/\$\$/Setup/Scripts"
cp "$REPO_DIR/windows/Stage1.ps1" "$OEM_DIR/\$1/ADLab/Stage1.ps1"
cp "$REPO_DIR/windows/Stage2.ps1" "$OEM_DIR/\$1/ADLab/Stage2.ps1"
cp "$REPO_DIR/windows/Stage3.ps1" "$OEM_DIR/\$1/ADLab/Stage3.ps1"
cp "$REPO_DIR/windows/SetupComplete.cmd" "$OEM_DIR/\$\$/Setup/Scripts/SetupComplete.cmd"
printf '%s\n' "$MEDIA_VERSION" > "$OEM_DIR/\$1/ADLab/media-version.txt"

mkdir -p "$(dirname "$OUTPUT_ISO")"
rm -f "$TMP_ISO"

xorriso -as mkisofs \
  -iso-level 3 \
  -J -joliet-long -R \
  -V "$MEDIA_VERSION" \
  -b boot/etfsboot.com \
  -no-emul-boot -boot-load-size 8 -boot-info-table \
  -eltorito-alt-boot \
  -e efi/microsoft/boot/efisys_noprompt.bin \
  -no-emul-boot \
  -o "$TMP_ISO" \
  "$TREE_DIR"

validate_iso "$TMP_ISO" || die 'Generated unattended Windows ISO failed validation.'
mv -f "$TMP_ISO" "$OUTPUT_ISO"
chmod 644 "$OUTPUT_ISO"
printf '%s\n' "$MEDIA_VERSION" > "$VERSION_FILE"
chmod 644 "$VERSION_FILE"
log "Unattended Windows ISO ready: ${OUTPUT_ISO}"
