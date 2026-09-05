#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/deepakkumarcissp/Kali-AD-Lab.git"
INSTALL_DIR="/opt/Kali-AD-Lab"

if [[ ${EUID} -ne 0 ]]; then
  exec sudo -E bash
fi

printf '\n============================================================\n'
printf ' Kali-AD-Lab | One-command launcher\n'
printf '============================================================\n\n'

if ! command -v git >/dev/null 2>&1; then
  apt-get update
  apt-get install -y git
fi

if [[ -d "${INSTALL_DIR}/.git" ]]; then
  printf '[Kali-AD-Lab] Updating existing installation...\n'
  git -C "$INSTALL_DIR" fetch origin main
  git -C "$INSTALL_DIR" reset --hard origin/main
else
  if [[ -e "$INSTALL_DIR" ]]; then
    printf 'ERROR: %s exists but is not a Kali-AD-Lab Git checkout.\n' "$INSTALL_DIR" >&2
    exit 1
  fi
  printf '[Kali-AD-Lab] Installing into %s...\n' "$INSTALL_DIR"
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

chmod +x "$INSTALL_DIR/kali-ad-lab" "$INSTALL_DIR/setup.sh"
ln -sf "$INSTALL_DIR/kali-ad-lab" /usr/local/bin/kali-ad-lab

printf '[Kali-AD-Lab] Launcher installed as: kali-ad-lab\n\n'
exec "$INSTALL_DIR/kali-ad-lab"
