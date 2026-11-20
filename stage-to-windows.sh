#!/usr/bin/env bash
# Stage the PoC kit + target installer onto the native Windows (NTFS) volume.
# Requires root (mount). Usage:
#   sudo ./stage-to-windows.sh [MOUNTPOINT] [INSTALLER_PATH]
# Override the partition with DEV=/dev/nvme0n1pX
set -euo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
MNT="${1:-/mnt/win11}"
INST="${2:-$HOME/Downloads/AcroRdrDCx642600322110_en_US.exe}"
DEV="${DEV:-/dev/nvme0n1p5}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo $0 [$MNT] [$INST]" >&2
  exit 1
fi
if [ ! -f "$INST" ]; then
  echo "Installer not found: $INST" >&2
  exit 1
fi

mkdir -p "$MNT"
if ! mountpoint -q "$MNT"; then
  if ! mount -o rw "$DEV" "$MNT"; then
    echo "Failed to mount $DEV (BitLocker? dirty NTFS/Fast Startup?). Use a USB drive instead." >&2
    exit 1
  fi
fi

cp -r "$KIT" "$MNT/poc-kit"
cp "$INST" "$MNT/poc-kit/AcroRdrDCx642600322110_en_US.exe"
sync
umount "$MNT"
echo "Staged to $MNT/poc-kit (kit + installer). Reboot into Windows and run scripts\\Run-All.ps1 as Administrator."
