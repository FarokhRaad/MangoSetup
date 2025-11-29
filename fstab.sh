#!/usr/bin/env bash
set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Parse args for dry run
DRY_RUN=false
for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
done

# Privilege helper
if [[ $EUID -ne 0 ]]; then
  SUDO="sudo"
else
  SUDO=""
fi

FSTAB="/etc/fstab"

# Check fstab exists
if [[ ! -f "$FSTAB" ]]; then
  error "$FSTAB not found."
  exit 1
fi

# Prompt for SMB credentials
echo
info "Configuring CIFS shares for //10.0.0.3"
read -rp "SMB username: " SMB_USER
read -rsp "SMB password (input hidden): " SMB_PASS
echo

# Get current user uid/gid for mount options
UID_VAL=$(id -u)
GID_VAL=$(id -g)

# CIFS shares definition: "share_name mount_point"
CIFS_SHARES=(
  "Movies /mnt/Movies"
  "Series /mnt/Series"
  "Others /mnt/Others"
  "Personal /mnt/Personal"
)

CIFS_OPTS_BASE="vers=3.0,uid=${UID_VAL},gid=${GID_VAL},nofail,x-systemd.automount,x-systemd.requires=network-online.target,x-systemd.after=network-online.target"

# NTFS line
NTFS_UUID="01DB8CCB44FBBD40"
NTFS_MOUNT="/mnt/Data"
NTFS_OPTS="nofail,users,uid=${UID_VAL},gid=${GID_VAL}"

# Show summary in dry run mode
if $DRY_RUN; then
  MASKED_PASS="********"
  echo
  info "Dry run: would append the following lines to $FSTAB (password masked):"
  echo
  for entry in "${CIFS_SHARES[@]}"; do
    share_name=${entry%% *}
    mount_point=${entry##* }
    echo "//10.0.0.3/${share_name}  ${mount_point}  cifs  ${CIFS_OPTS_BASE},user=${SMB_USER},password=${MASKED_PASS}  0 0"
  done
  echo "UUID=${NTFS_UUID}  ${NTFS_MOUNT}  ntfs  ${NTFS_OPTS}  0 0"
  echo
  warn "No changes were made because --dry-run is enabled."
  exit 0
fi

# Append CIFS entries if missing
info "Adding CIFS entries to $FSTAB if they are not already present..."

for entry in "${CIFS_SHARES[@]}"; do
  share_name=${entry%% *}
  mount_point=${entry##* }
  marker="//10.0.0.3/${share_name}"

  if grep -q "$marker" "$FSTAB"; then
    warn "Entry for ${marker} already exists in $FSTAB. Skipping."
    continue
  fi

  line="//10.0.0.3/${share_name}  ${mount_point}  cifs  ${CIFS_OPTS_BASE},user=${SMB_USER},password=${SMB_PASS}  0 0"

  info "Adding entry for ${marker} -> ${mount_point}"
  echo "$line" | $SUDO tee -a "$FSTAB" >/dev/null
done

# Append NTFS entry if missing
info "Adding NTFS entry for UUID=${NTFS_UUID} if not already present..."

if grep -q "UUID=${NTFS_UUID}" "$FSTAB"; then
  warn "NTFS entry for UUID=${NTFS_UUID} already exists. Skipping."
else
  ntfs_line="UUID=${NTFS_UUID}  ${NTFS_MOUNT}  ntfs  ${NTFS_OPTS}  0 0"
  info "Adding NTFS entry for ${NTFS_MOUNT}"
  echo "$ntfs_line" | $SUDO tee -a "$FSTAB" >/dev/null
fi

success "fstab entries configured. You can test mounts with:"
echo "  sudo systemctl daemon-reload"
echo "  sudo mount -a"
