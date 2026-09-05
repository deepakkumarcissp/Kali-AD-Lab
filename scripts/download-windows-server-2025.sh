#!/usr/bin/env bash
set -euo pipefail

# Kali-AD-Lab - Windows Server 2025 Evaluation ISO helper
# Downloads only from Microsoft's official go.microsoft.com redirect.

DOWNLOAD_DIR="${HOME}/Downloads"
OUTPUT="${DOWNLOAD_DIR}/Windows_Server_2025_Evaluation_x64.iso"
MICROSOFT_URL="https://go.microsoft.com/fwlink/?linkid=2293312&clcid=0x409&culture=en-us&country=us"

mkdir -p "${DOWNLOAD_DIR}"

echo "============================================================"
echo " Kali-AD-Lab | Windows Server 2025 Evaluation ISO"
echo "============================================================"
echo
echo "Source : Microsoft Evaluation Center"
echo "Target : ${OUTPUT}"
echo

echo "[1/3] Checking download tools..."
if command -v curl >/dev/null 2>&1; then
  DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
  DOWNLOADER="wget"
else
  echo "curl/wget not found. Installing curl..."
  sudo apt update
  sudo apt install -y curl
  DOWNLOADER="curl"
fi

echo "[2/3] Downloading the Microsoft evaluation ISO..."
if [[ "${DOWNLOADER}" == "curl" ]]; then
  curl -fL --retry 3 --retry-delay 3 --progress-bar \
    "${MICROSOFT_URL}" -o "${OUTPUT}"
else
  wget --show-progress -O "${OUTPUT}" "${MICROSOFT_URL}"
fi

echo "[3/3] Basic validation..."
if [[ ! -s "${OUTPUT}" ]]; then
  echo "ERROR: The downloaded file is empty."
  exit 1
fi

SIZE_BYTES=$(stat -c%s "${OUTPUT}")
if (( SIZE_BYTES < 1000000000 )); then
  echo "WARNING: The downloaded file is unexpectedly small (${SIZE_BYTES} bytes)."
  echo "Microsoft may have changed its download redirect."
  echo "Use the official Evaluation Center instead:"
  echo "https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025"
  exit 1
fi

echo
echo "Download completed successfully."
echo "ISO: ${OUTPUT}"
echo
echo "Next step for Kali-AD-Lab:"
echo "  sudo bash setup.sh --iso \"${OUTPUT}\""
