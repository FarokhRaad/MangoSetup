#!/bin/bash

set -e

# ===========================
# Privilege handling
# ===========================
if [[ $EUID -ne 0 ]]; then
  SUDO="sudo"
else
  SUDO=""
fi

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }

# ===========================
# 1. Udev rule for Logitech Bolt
# ===========================
setup_udev_mouse_wakeup() {
  info "Setting udev rule to disable wake from Logitech Bolt receiver."

  local rules_dir="/etc/udev/rules.d"
  local rules_file="$rules_dir/90-disable-logi-bolt-wake.rules"

  $SUDO mkdir -p "$rules_dir"

  cat << 'EOF' | $SUDO tee "$rules_file" > /dev/null
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="046d", ATTR{idProduct}=="c548", ATTR{power/wakeup}="disabled"
EOF

  $SUDO udevadm control --reload-rules
  $SUDO udevadm trigger

  success "Udev rule created at $rules_file and rules reloaded."
}

# ===========================
# 2. Disable autosuspend of sound cards
# ===========================
setup_audio_powersave() {
  info "Disabling snd_hda_intel power saving."

  local modprobe_dir="/etc/modprobe.d"
  local modprobe_file="$modprobe_dir/disable-hda-autosuspend.conf"

  $SUDO mkdir -p "$modprobe_dir"

  cat << 'EOF' | $SUDO tee "$modprobe_file" > /dev/null
options snd_hda_intel power_save=0
options snd_hda_intel power_save_controller=N
EOF

  success "Modprobe config written to $modprobe_file."
  warn "You should reboot or reload snd_hda_intel for this to fully apply."
}

# ===========================
# 3. logind.conf lid switch behavior
# ===========================
set_logind_option() {
  local key="$1"
  local value="$2"
  local file="/etc/systemd/logind.conf"

  # If uncommented key exists
  if grep -Eq "^[[:space:]]*${key}=" "$file"; then
    $SUDO sed -i "s|^[[:space:]]*${key}=.*|${key}=${value}|" "$file"
  # If commented key exists
  elif grep -Eq "^[[:space:]]*#*[[:space:]]*${key}=" "$file"; then
    $SUDO sed -i "s|^[[:space:]]*#*[[:space:]]*${key}=.*|${key}=${value}|" "$file"
  else
    echo "${key}=${value}" | $SUDO tee -a "$file" > /dev/null
  fi
}

setup_logind_lid_behavior() {
  local file="/etc/systemd/logind.conf"

  info "Configuring lid switch behavior in $file."

  if [[ -f "$file" ]]; then
    local backup="${file}.bak-$(date +%Y%m%d-%H%M%S)"
    $SUDO cp "$file" "$backup"
    info "Backup created at $backup."
  fi

  set_logind_option "HandleLidSwitch" "ignore"
  set_logind_option "HandleLidSwitchExternalPower" "ignore"
  set_logind_option "HandleLidSwitchDocked" "ignore"
  set_logind_option "HoldoffTimeoutSec" "5s"

  success "logind.conf updated."
  warn "You should reboot or restart systemd-logind later:
  sudo systemctl restart systemd-logind"
}

# ===========================
# 4. Pacman improvements
# ===========================

pacman_conf_backup() {
  local file="/etc/pacman.conf"
  if [[ -f "$file" ]]; then
    local backup="${file}.bak-$(date +%Y%m%d-%H%M%S)"
    $SUDO cp "$file" "$backup"
    info "pacman.conf backup created at $backup."
  fi
}

# Flag style options like: Color, CheckSpace, VerbosePkgLists
enable_pacman_flag() {
  local key="$1"
  local file="/etc/pacman.conf"

  # If key exists commented or uncommented, normalize to uncommented "Key"
  if grep -Eq "^[#[:space:]]*${key}[[:space:]]*$" "$file"; then
    $SUDO sed -i "s|^[#[:space:]]*${key}[[:space:]]*$|${key}|" "$file"
  else
    # Append at end if not present
    echo "${key}" | $SUDO tee -a "$file" > /dev/null
  fi
}

# Key = value style options like: ParallelDownloads = 10
set_pacman_kv_option() {
  local key="$1"
  local value="$2"
  local file="/etc/pacman.conf"

  if grep -Eq "^[#[:space:]]*${key}[[:space:]]*=" "$file"; then
    $SUDO sed -i "s|^[#[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "$file"
  else
    echo "${key} = ${value}" | $SUDO tee -a "$file" > /dev/null
  fi
}

setup_pacman_conf() {
  local file="/etc/pacman.conf"

  info "Tweaking pacman.conf options."
  pacman_conf_backup

  # These are safe defaults
  enable_pacman_flag "Color"
  enable_pacman_flag "CheckSpace"
  enable_pacman_flag "VerbosePkgLists"

  # Parallel downloads (tweak number if you prefer)
  set_pacman_kv_option "ParallelDownloads" "10"

  # Optional candy, comment this out if you do not like it
  # enable_pacman_flag "ILoveCandy"

  success "pacman.conf options updated."
}

setup_pacman_cache_hook() {
  info "Adding pacman hook to clean cache automatically."

  local hook_dir="/etc/pacman.d/hooks"
  local hook_file="$hook_dir/clean_cache.hook"

  $SUDO mkdir -p "$hook_dir"

  cat << 'EOF' | $SUDO tee "$hook_file" > /dev/null
[Trigger]
Operation = Upgrade
Operation = Install
Operation = Remove
Type = Package
Target = *

[Action]
Description = Clean pacman cache with paccache
When = PostTransaction
Exec = /usr/bin/paccache -r
EOF

  success "Pacman cache cleaning hook written to $hook_file."
}

# ===========================
# Main
# ===========================
main() {
  info "Starting system setup."

  setup_udev_mouse_wakeup
  setup_audio_powersave
  setup_logind_lid_behavior
  setup_pacman_conf
  setup_pacman_cache_hook

  success "System setup completed. A reboot is recommended."
}

main
