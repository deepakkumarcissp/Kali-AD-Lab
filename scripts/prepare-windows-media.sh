#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/var/lib/libvirt/boot/Kali-AD-Lab"
SOURCE_ISO="${BASE_DIR}/Windows_Server_2025_Evaluation_x64_source.iso"
INSTALL_ISO="${BASE_DIR}/Windows_Server_2025_Evaluation_x64.iso"
VERSION_FILE="${INSTALL_ISO}.version"
WINDOWS_ISO_URL="https://aka.ms/WinServ2025iso-enus"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
EXPECTED_VERSION='WS25_ADLAB_V2'

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

embedded_version(){
  local iso="$1" mnt v=''
  validate_iso "$iso" || return 1
  mnt="$(mktemp -d /tmp/kali-adlab-version.XXXXXX)"
  if mount -o loop,ro "$iso" "$mnt" >/dev/null 2>&1; then
    v="$(cat "$mnt/sources/\$OEM\$/\$1/ADLab/media-version.txt" 2>/dev/null || true)"
    umount "$mnt" >/dev/null 2>&1 || true
  fi
  rmdir "$mnt" 2>/dev/null || true
  printf '%s' "$v"
}

required_files=(
  "$SCRIPT_DIR/build-noprompt-windows-iso.sh"
  "$REPO_DIR/windows/SetupComplete.cmd"
  "$REPO_DIR/windows/Stage1.ps1"
  "$REPO_DIR/windows/Stage2.ps1"
  "$REPO_DIR/windows/Stage3.ps1"
)
for f in "${required_files[@]}"; do
  [[ -f "$f" ]] || die "Required media/bootstrap file is missing: $f"
done

# Recover cleanly from older layouts. If INSTALL_ISO already contains our
# embedded V2 marker, it is generated unattended media and must not be moved.
INSTALL_EMBEDDED="$(embedded_version "$INSTALL_ISO" 2>/dev/null || true)"
if [[ ! -f "$SOURCE_ISO" && -f "$INSTALL_ISO" && "$INSTALL_EMBEDDED" != "$EXPECTED_VERSION" ]]; then
  log 'Preserving existing Microsoft ISO as source media...'
  mv "$INSTALL_ISO" "$SOURCE_ISO"
  rm -f "$VERSION_FILE"
fi

if ! validate_iso "$SOURCE_ISO"; then
  rm -f "$SOURCE_ISO"
  log 'Downloading Windows Server 2025 Evaluation ISO from Microsoft...'
  curl -fL --retry 5 --retry-delay 3 --connect-timeout 30 --progress-bar \
    "$WINDOWS_ISO_URL" -o "$SOURCE_ISO"
  validate_iso "$SOURCE_ISO" || { rm -f "$SOURCE_ISO"; die 'Downloaded Windows ISO failed validation.'; }
  chmod 644 "$SOURCE_ISO"
fi

# Trust the version embedded inside the ISO, not xorriso volume-label parsing.
# This also lets machines that already built V2 media seed the new sidecar
# marker without rebuilding a multi-gigabyte ISO.
INSTALL_EMBEDDED="$(embedded_version "$INSTALL_ISO" 2>/dev/null || true)"
if validate_iso "$INSTALL_ISO" && [[ "$INSTALL_EMBEDDED" == "$EXPECTED_VERSION" ]]; then
  printf '%s\n' "$EXPECTED_VERSION" > "$VERSION_FILE"
  chmod 644 "$VERSION_FILE"
  log 'Existing unattended Windows installer is current; reusing it.'
else
  rm -f "$INSTALL_ISO" "$VERSION_FILE"
  bash "$SCRIPT_DIR/build-noprompt-windows-iso.sh" "$SOURCE_ISO" "$INSTALL_ISO"
fi

validate_iso "$INSTALL_ISO" || die 'Prepared Windows installer failed validation.'
[[ "$(cat "$VERSION_FILE" 2>/dev/null || true)" == "$EXPECTED_VERSION" ]] || die 'Prepared Windows installer version marker is missing.'
[[ "$(embedded_version "$INSTALL_ISO" 2>/dev/null || true)" == "$EXPECTED_VERSION" ]] || die 'Prepared Windows installer embedded version is invalid.'
log 'Unattended Windows installer is ready before VM startup.'
