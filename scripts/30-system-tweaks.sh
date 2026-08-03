#!/usr/bin/env bash
# =============================================================================
#  30-system-tweaks.sh - repair mkinitcpio, report optional host tweaks
# =============================================================================
#  Deliberately minimal and conservative: it does NOT install drivers, write
#  fstab, or apply system tweaks on your behalf. Run 00-preflight.sh first;
#  this script sources its facts file and acts on exactly one thing it can
#  safely repair:
#
#    - a duplicated MODULES= line in /etc/mkinitcpio.conf. Repeated sed-based
#      edits (a common hand-rolled pattern) can match both the empty-parens
#      and the populated-parens form and append the nvidia modules twice.
#      The line is rebuilt from scratch with each module exactly once, then
#      the initramfs is regenerated.
#
#  Everything else is reported only. These optional host tweaks are listed
#  for visibility and left entirely alone whether present or not:
#    - Logitech Bolt wake-disable udev rule
#    - snd_hda_intel autosuspend disable
#    - logind lid-switch handling (ignore)
#    - pacman.conf tuning (Color / ParallelDownloads)
#
#  Because the non-mkinitcpio sections are pure reporting, this script is
#  safe to run repeatedly on any host; most of it will simply do nothing.
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

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/mangosetup"
FACTS="$STATE_DIR/preflight-facts.env"
if [[ ! -f "$FACTS" ]]; then
  err "no preflight facts found. Run ./00-preflight.sh first."
  exit 1
fi
# shellcheck source=/dev/null
source "$FACTS"

# -----------------------------------------------------------------------------
#  1. mkinitcpio duplicate modules (the only thing this script repairs)
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
#  2. Everything else: report state only, do not touch
# -----------------------------------------------------------------------------
step "Optional host tweaks (report only)"

check_already_done() {
  local label="$1" flag="$2"
  if [[ "${!flag:-0}" == "1" ]]; then
    ok "$label: present, skipping"
  else
    info "$label: not present"
    info "  (optional; not applied by this script - add it by hand if you want it)"
  fi
}

check_already_done "Logitech Bolt wake-disable udev rule" TWEAK_UDEV_LOGI
check_already_done "snd_hda_intel autosuspend disable"    TWEAK_HDA_POWERSAVE
check_already_done "logind lid-switch handling"           TWEAK_LOGIND_LID
check_already_done "pacman.conf tuning"                   TWEAK_PACMAN_CONF

step "NVIDIA driver and KMS"
if [[ "${HAS_NVIDIA:-0}" == "1" ]]; then
  info "driver: ${NVIDIA_DRIVER:-unknown} (detected; this script never installs drivers)"
  [[ "${NVIDIA_MODESET_OK:-0}" == "1" ]] && ok "modeset=1 already set" \
    || warn "modeset not confirmed; check /etc/modprobe.d/nvidia.conf manually"
  [[ "${NOUVEAU_BLACKLISTED:-0}" == "1" ]] && ok "nouveau already blacklisted" \
    || info "nouveau not blacklisted (fine on a desktop-only NVIDIA GPU)"
else
  info "no NVIDIA GPU detected"
fi

step "fstab"
if [[ "${FSTAB_OK:-0}" == "1" ]]; then
  ok "network mounts already declared in fstab, not touched"
else
  info "no known network mounts in fstab; this script never modifies fstab"
fi

step "Summary"
ok "System tweaks pass complete."
if [[ "${MKINITCPIO_DUPLICATE_BUG:-0}" == "1" ]] && ! $DRY_RUN; then
  warn "mkinitcpio.conf was changed and initramfs regenerated."
  warn "This takes effect on next boot; no reboot is required for mango itself."
fi
