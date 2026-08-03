#!/usr/bin/env bash
# =============================================================================
#  30-system-tweaks.sh - fix the one known bug, skip everything else
# =============================================================================
#  This system already has a working KDE Plasma install with fstab, NVIDIA,
#  mkinitcpio and modprobe all configured, and the old
#  Improvements/personalized_improvements.sh tweaks already applied:
#    - Logitech Bolt wake-disable udev rule       : present
#    - snd_hda_intel autosuspend disabled          : present
#    - logind lid-switch handling (ignore)         : present
#    - pacman.conf tuning (Color/ParallelDownloads): present
#
#  This script does NOT redo any of that. Run 00-preflight.sh first; this
#  script reads its fact file and only acts on the ONE thing preflight
#  found actually broken: a duplicated MODULES= line in mkinitcpio.conf
#  (an old sed-based script matched both the empty-parens and the
#  populated-parens pattern and ran twice).
#
#  Everything else is a no-op with a confirmation printed, so this is safe
#  to run on this machine even though most of it will do nothing.
#
#  Usage: ./30-system-tweaks.sh [--dry-run]
# =============================================================================
set -uo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
ok()   { printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"; }
err()  { printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }
step() { printf '\n%s=== %s ===%s\n' "$BOLD" "$*" "$NC"; }
run() { if $DRY_RUN; then printf '%s[DRY]%s %s\n' "$YELLOW" "$NC" "$*"; else "$@"; fi; }

STATE_DIR="$HOME/.local/state/mango-migration"
FACTS="$STATE_DIR/preflight-facts.env"
if [[ ! -f "$FACTS" ]]; then
  err "no preflight facts found. Run ./00-preflight.sh first."
  exit 1
fi
# shellcheck source=/dev/null
source "$FACTS"

# -----------------------------------------------------------------------------
#  1. mkinitcpio duplicate modules (the one real bug)
# -----------------------------------------------------------------------------
step "mkinitcpio MODULES="
if [[ "${MKINITCPIO_DUPLICATE_BUG:-0}" == "1" ]]; then
  current=$(grep '^MODULES=' /etc/mkinitcpio.conf)
  info "current: $current"
  #  Rebuild the line from scratch with each module exactly once, instead of
  #  another sed pass that could duplicate it a third time.
  fixed="MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)"
  info "fixed:   $fixed"
  if ! $DRY_RUN; then
    sudo cp /etc/mkinitcpio.conf "/etc/mkinitcpio.conf.bak-$(date +%Y%m%d-%H%M%S)"
    sudo sed -i "s/^MODULES=.*/${fixed//\//\\/}/" /etc/mkinitcpio.conf
    ok "mkinitcpio.conf fixed (backup saved alongside it)"
    info "regenerating initramfs..."
    sudo mkinitcpio -P
    ok "initramfs regenerated for all installed kernels"
  else
    info "[DRY] would rewrite MODULES= and run: sudo mkinitcpio -P"
  fi
else
  ok "mkinitcpio modules already correct, nothing to do"
fi

# -----------------------------------------------------------------------------
#  2. Everything else: confirm already applied, do not touch
# -----------------------------------------------------------------------------
step "Previously-applied tweaks (confirm only)"

check_already_done() {
  local label="$1" flag="$2"
  if [[ "${!flag:-0}" == "1" ]]; then
    ok "$label: already applied, skipping"
  else
    warn "$label: NOT applied on this system"
    warn "  (not touched by this script; see NOTES.md if you want it added)"
  fi
}

check_already_done "Logitech Bolt wake-disable udev rule" TWEAK_UDEV_LOGI
check_already_done "snd_hda_intel autosuspend disable"    TWEAK_HDA_POWERSAVE
check_already_done "logind lid-switch handling"           TWEAK_LOGIND_LID
check_already_done "pacman.conf tuning"                   TWEAK_PACMAN_CONF

step "NVIDIA driver and KMS"
if [[ "${HAS_NVIDIA:-0}" == "1" ]]; then
  info "driver: ${NVIDIA_DRIVER:-unknown} (already installed, not reinstalling)"
  [[ "${NVIDIA_MODESET_OK:-0}" == "1" ]] && ok "modeset=1 already set" \
    || warn "modeset not confirmed; check /etc/modprobe.d/nvidia.conf manually"
  [[ "${NOUVEAU_BLACKLISTED:-0}" == "1" ]] && ok "nouveau already blacklisted" \
    || info "nouveau not blacklisted (fine on a desktop-only NVIDIA GPU)"
else
  info "no NVIDIA GPU on this system"
fi

step "fstab"
if [[ "${FSTAB_OK:-0}" == "1" ]]; then
  ok "fstab already has working network mounts, not touched"
else
  warn "fstab state unclear; check manually, this script will not modify fstab"
fi

step "Summary"
ok "System tweaks pass complete."
if [[ "${MKINITCPIO_DUPLICATE_BUG:-0}" == "1" ]] && ! $DRY_RUN; then
  warn "mkinitcpio.conf was changed and initramfs regenerated."
  warn "This takes effect on next boot; no reboot is required for mango itself."
fi
