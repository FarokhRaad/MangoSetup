#!/usr/bin/env bash
# =============================================================================
#  00-preflight.sh - survey the system before touching anything
# =============================================================================
#  This machine already has a WORKING, CONFIGURED KDE Plasma install:
#  fstab, NVIDIA driver, mkinitcpio, modprobe tweaks, and the personalized
#  system tweaks (udev, audio power save, lid switch, pacman.conf) are all
#  already applied. This script's job is to CONFIRM that and flag the one
#  known bug, NOT to redo any of it.
#
#  Every later script in this directory checks state before acting and
#  skips anything already correct. This one just makes that state visible
#  and writes a fact file the others can read.
#
#  Usage: ./00-preflight.sh
#  Writes: ~/.local/state/mango-migration/preflight-facts.env
# =============================================================================
set -uo pipefail

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
ok()   { printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"; }
err()  { printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }
step() { printf '\n%s=== %s ===%s\n' "$BOLD" "$*" "$NC"; }

STATE_DIR="$HOME/.local/state/mango-migration"
mkdir -p "$STATE_DIR"
FACTS="$STATE_DIR/preflight-facts.env"
: > "$FACTS"
fact() { printf '%s=%q\n' "$1" "$2" >> "$FACTS"; }

step "Bootloader"
if [[ -f /boot/limine.conf ]]; then
  ok "limine detected (/boot/limine.conf)"
  fact BOOTLOADER limine
elif [[ -d /boot/loader/entries ]]; then
  ok "systemd-boot detected"
  fact BOOTLOADER systemd-boot
elif [[ -f /etc/default/grub ]]; then
  ok "GRUB detected"
  fact BOOTLOADER grub
else
  warn "no known bootloader detected"
  fact BOOTLOADER unknown
fi

step "Filesystem / snapshots"
#  snapper list-configs works unprivileged; listing snapshots needs sudo.
#  Checking with plain `snapper -c root list` reports a false negative on
#  permission denied, so check config existence instead.
if command -v snapper >/dev/null 2>&1 && snapper list-configs 2>/dev/null | grep -qE '^\s*root\s'; then
  ok "snapper configured for the root subvolume"
  fact HAS_SNAPPER 1
else
  warn "snapper not configured; 70-remove-plasma.sh will skip the safety snapshot"
  fact HAS_SNAPPER 0
fi
if pacman -Qi limine-snapper-sync &>/dev/null; then
  ok "limine-snapper-sync installed: snapshots appear as boot entries"
fi

step "GPU / NVIDIA"
GPU_LINE=$(lspci -nn 2>/dev/null | grep -Ei 'vga|3d|display' | grep -i nvidia)
if [[ -n "$GPU_LINE" ]]; then
  ok "NVIDIA GPU: $GPU_LINE"
  fact HAS_NVIDIA 1
  if pacman -Qi nvidia-open-dkms &>/dev/null; then
    ok "nvidia-open-dkms already installed, driver stack NOT being reinstalled"
    fact NVIDIA_DRIVER nvidia-open-dkms
  elif pacman -Qi nvidia-dkms &>/dev/null; then
    ok "nvidia-dkms (proprietary) already installed"
    fact NVIDIA_DRIVER nvidia-dkms
  else
    warn "NVIDIA GPU present but no driver package found installed"
    fact NVIDIA_DRIVER none
  fi

  #  The known mkinitcpio bug: an earlier script's sed ran twice and
  #  duplicated the nvidia modules. Detect it precisely rather than assume.
  MODULES_LINE=$(grep '^MODULES=' /etc/mkinitcpio.conf 2>/dev/null || true)
  info "mkinitcpio MODULES= $MODULES_LINE"
  nvidia_count=$(grep -o 'nvidia_drm' <<<"$MODULES_LINE" | wc -l)
  if (( nvidia_count > 1 )); then
    err "mkinitcpio.conf has DUPLICATED nvidia modules ($nvidia_count copies of nvidia_drm)"
    err "-> fix with 30-system-tweaks.sh (it rewrites MODULES= cleanly, does not append again)"
    fact MKINITCPIO_DUPLICATE_BUG 1
  elif (( nvidia_count == 1 )); then
    ok "mkinitcpio nvidia modules present, no duplication"
    fact MKINITCPIO_DUPLICATE_BUG 0
  else
    warn "mkinitcpio.conf has no nvidia modules at all"
    fact MKINITCPIO_DUPLICATE_BUG 0
  fi

  if [[ -f /etc/modprobe.d/nvidia.conf ]] && grep -q 'modeset=1' /etc/modprobe.d/nvidia.conf; then
    ok "modprobe nvidia.conf already sets modeset=1 (KMS enabled)"
    fact NVIDIA_MODESET_OK 1
  else
    warn "modprobe nvidia.conf missing or lacks modeset=1"
    fact NVIDIA_MODESET_OK 0
  fi

  if [[ -f /etc/modprobe.d/nouveau.conf ]] || [[ -f /etc/modprobe.d/blacklist.conf ]] \
     && grep -rq 'blacklist nouveau' /etc/modprobe.d/ 2>/dev/null; then
    ok "nouveau already blacklisted"
    fact NOUVEAU_BLACKLISTED 1
  else
    warn "nouveau not blacklisted (only matters if this is a hybrid/Optimus laptop)"
    fact NOUVEAU_BLACKLISTED 0
  fi
else
  info "no NVIDIA GPU detected"
  fact HAS_NVIDIA 0
fi

step "Personalized system tweaks (from the previous setup)"
#  Each of these was applied by the OLD Improvements/personalized_improvements.sh.
#  Report state; 30-system-tweaks.sh will only touch what is missing.
if [[ -f /etc/udev/rules.d/90-disable-logi-bolt-wake.rules ]]; then
  ok "Logitech Bolt wake-disable udev rule present"
  fact TWEAK_UDEV_LOGI 1
else
  info "Logitech Bolt udev rule NOT present"
  fact TWEAK_UDEV_LOGI 0
fi

if [[ -f /etc/modprobe.d/disable-hda-autosuspend.conf ]]; then
  ok "snd_hda_intel autosuspend already disabled"
  fact TWEAK_HDA_POWERSAVE 1
else
  info "snd_hda_intel autosuspend tweak NOT present"
  fact TWEAK_HDA_POWERSAVE 0
fi

if grep -qE '^HandleLidSwitch=ignore' /etc/systemd/logind.conf 2>/dev/null; then
  ok "logind lid-switch handling already set to ignore"
  fact TWEAK_LOGIND_LID 1
else
  info "logind lid-switch handling NOT customized (systemd default applies)"
  fact TWEAK_LOGIND_LID 0
fi

if grep -qE '^\s*ParallelDownloads\s*=' /etc/pacman.conf 2>/dev/null; then
  ok "pacman.conf already tuned (ParallelDownloads, Color, etc.)"
  fact TWEAK_PACMAN_CONF 1
else
  info "pacman.conf NOT tuned"
  fact TWEAK_PACMAN_CONF 0
fi

step "fstab"
#  The OLD fstab.sh targeted a hardcoded //10.0.0.3 SMB host. This system
#  actually mounts //hydra.lan via a credentials file, already working.
#  fstab.sh is NOT included in this repo: there is nothing to generate.
if grep -q 'hydra.lan' /etc/fstab 2>/dev/null; then
  ok "fstab already has working hydra.lan CIFS mounts; nothing to do here"
  fact FSTAB_OK 1
else
  warn "fstab does not reference hydra.lan; if network storage changed, handle manually"
  fact FSTAB_OK 0
fi

step "Display manager"
current_dm=$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null | xargs -r basename)
info "current display manager: ${current_dm:-none detected}"
fact CURRENT_DM "${current_dm:-none}"

step "Current session"
info "XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-unset}  XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-unset}"
fact CURRENT_DESKTOP "${XDG_CURRENT_DESKTOP:-unset}"

step "Summary"
ok "facts written to $FACTS"
if grep -q '^MKINITCPIO_DUPLICATE_BUG=1' "$FACTS"; then
  warn "ACTION NEEDED: run 30-system-tweaks.sh to fix the duplicated mkinitcpio modules"
fi
info "Nothing on this system was modified by this script. It only reads state."
