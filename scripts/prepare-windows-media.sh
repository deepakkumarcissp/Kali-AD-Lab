#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/var/lib/libvirt/boot/Kali-AD-Lab"
SOURCE_ISO="${BASE_DIR}/Windows_Server_2025_Evaluation_x64_source.iso"
INSTALL_ISO="${BASE_DIR}/Windows_Server_2025_Evaluation_x64.iso"
WINDOWS_ISO_URL="https://aka.ms/WinServ2025iso-enus"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

log(){ printf '[Kali-AD-Lab] %s\n' "$*"; }
die(){ printf '[Kali-AD-Lab] ERROR: %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || exec sudo -E bash "$0" "$@"

command -v curl >/dev/null 2>&1 && command -v xorriso >/dev/null 2>&1 || {
  apt-get update
  apt-get install -y curl xorriso
}

mkdir -p "$BASE_DIR"
chmod 711 "$BASE_DIR"

validate_iso(){
  local f="$1" s
  [[ -s "$f" ]] || return 1
  s=$(stat -c%s "$f" 2>/dev/null || echo 0)
  (( s > 3000000000 )) || return 1
  xorriso -indev "$f" -toc >/dev/null 2>&1
}

volume_id(){
  xorriso -indev "$1" -pvd_info 2>/dev/null | awk -F"'" '/Volume id/ {print $2; exit}'
}

# Migrate an older cached Microsoft ISO into the new source-cache location.
if [[ ! -f "$SOURCE_ISO" && -f "$INSTALL_ISO" ]]; then
  VID="$(volume_id "$INSTALL_ISO" || true)"
  if [[ "$VID" != "WS2025_NOPROMPT" ]]; then
    log 'Preserving existing Microsoft ISO as source media...'
    mv "$INSTALL_ISO" "$SOURCE_ISO"
  fi
fi

if ! validate_iso "$SOURCE_ISO"; then
  rm -f "$SOURCE_ISO"
  log 'Downloading Windows Server 2025 Evaluation ISO from Microsoft...'
  curl -fL --retry 5 --retry-delay 3 --connect-timeout 30 --progress-bar \
    "$WINDOWS_ISO_URL" -o "$SOURCE_ISO"
  validate_iso "$SOURCE_ISO" || { rm -f "$SOURCE_ISO"; die 'Downloaded Windows ISO failed validation.'; }
  chmod 644 "$SOURCE_ISO"
fi

# Build or refresh the installer used by setup.sh. It uses Microsoft's
# efisys_noprompt.bin so UEFI boots Windows Setup without any keypress.
if ! validate_iso "$INSTALL_ISO" || [[ "$SOURCE_ISO" -nt "$INSTALL_ISO" ]] || [[ "$(volume_id "$INSTALL_ISO" || true)" != "WS2025_NOPROMPT" ]]; then
  rm -f "$INSTALL_ISO"
  bash "$SCRIPT_DIR/build-noprompt-windows-iso.sh" "$SOURCE_ISO" "$INSTALL_ISO"
fi

validate_iso "$INSTALL_ISO" || die 'Prepared Windows installer failed validation.'
log 'No-prompt Windows installer is ready before VM startup.'
