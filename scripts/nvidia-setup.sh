#!/usr/bin/env bash
# =============================================================================
#  nvidia-setup - verify, and optionally complete, an NVIDIA driver install
# =============================================================================
#  WHY THIS EXISTS
#  The driver is normally installed by archinstall, because it has to be in
#  place BEFORE the first boot into a graphical session: the modules go into
#  the initramfs and the compositor needs them at startup. This script is the
#  safety net for when that did not happen (forgot to tick it, installed from
#  a plain arch-chroot, moved the disk to an NVIDIA machine), and the
#  verification pass you can run any time.
#
#  DO NOT use NVIDIA's .run installer or the datacenter/Tesla driver guide on
#  Arch. That guide does not list Arch as a supported distribution, and the
#  .run installer writes files pacman does not own, conflicts with the packaged
#  driver, and breaks on every kernel update. Everything here uses repo
#  packages only.
#
#  WHAT IT CHECKS / FIXES
#    1. kernel module package    nvidia-open (or -dkms / -lts) matching the
#                                installed kernel(s)
#    2. userspace libraries      nvidia-utils
#    3. 32-bit libraries         lib32-nvidia-utils, ONLY if multilib is on
#    4. initramfs MODULES        nvidia nvidia_modeset nvidia_uvm nvidia_drm
#    5. initramfs freshness      rebuilt after a driver/kernel change
#
#  DELIBERATELY NOT CHECKED: nvidia_drm.modeset=1. On driver 610 modeset and
#  fbdev BOTH DEFAULT TO 1 (verified: `modinfo -p nvidia_drm` says
#  "1 = enable (default)"). The widely repeated "you must set modeset=1" advice
#  is obsolete for this generation, so this script does not add a redundant
#  modprobe.d file. An existing one is left alone.
#
#  Usage:
#    nvidia-setup check      report only, exit 1 if something is wrong
#    nvidia-setup install    install whatever is missing, then fix initramfs
#    nvidia-setup --help
# =============================================================================
set -uo pipefail

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
ok()   { printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"; }
err()  { printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }
step() { printf '\n%s=== %s ===%s\n' "$BOLD" "$*" "$NC"; }

MODE="${1:-check}"
case "$MODE" in
  -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
  check|install) ;;
  *) err "unknown command '$MODE' (try: check | install)"; exit 2 ;;
esac

#  Root handling: mirrors the other scripts. Runs as a normal user with sudo,
#  but must also work when invoked directly as root on a fresh install where
#  sudo may not be installed.
if [[ $EUID -eq 0 ]]; then
  sudo() { "$@"; }
fi

# -----------------------------------------------------------------------------
#  Is there even an NVIDIA GPU?
# -----------------------------------------------------------------------------
step "GPU detection"
if ! command -v lspci >/dev/null 2>&1; then
  err "lspci not found (install pciutils); cannot detect the GPU"
  exit 2
fi
GPU=$(lspci -nn 2>/dev/null | grep -Ei 'vga|3d controller|display' | grep -i nvidia || true)
if [[ -z "$GPU" ]]; then
  ok "no NVIDIA GPU present; nothing to do"
  exit 0
fi
printf '  %s\n' "$GPU"

# -----------------------------------------------------------------------------
#  Which driver package fits? Ampere (RTX 30xx) and newer are fine on the open
#  modules. Arch no longer ships the proprietary `nvidia` package at all: only
#  nvidia-open, nvidia-open-dkms and nvidia-open-lts exist, so there is no
#  proprietary fallback to choose.
#
#  dkms vs prebuilt is decided by the KERNEL, not preference:
#    linux            -> nvidia-open
#    linux-lts        -> nvidia-open-lts
#    anything else    -> nvidia-open-dkms (+ matching headers)
# -----------------------------------------------------------------------------
step "Driver package selection"
WANT_MODULE=""
NEED_HEADERS=""
have_kernel() { pacman -Qq "$1" &>/dev/null; }

kernels=()
for k in linux linux-lts linux-zen linux-hardened; do
  have_kernel "$k" && kernels+=("$k")
done
if ((${#kernels[@]} == 0)); then
  warn "no recognised kernel package found; assuming a custom kernel -> dkms"
  WANT_MODULE="nvidia-open-dkms"
elif ((${#kernels[@]} > 1)); then
  info "multiple kernels installed (${kernels[*]}); dkms covers them all"
  WANT_MODULE="nvidia-open-dkms"
  for k in "${kernels[@]}"; do
    have_kernel "${k}-headers" || NEED_HEADERS+="${k}-headers "
  done
else
  case "${kernels[0]}" in
    linux)     WANT_MODULE="nvidia-open" ;;
    linux-lts) WANT_MODULE="nvidia-open-lts" ;;
    *)         WANT_MODULE="nvidia-open-dkms"
               have_kernel "${kernels[0]}-headers" || NEED_HEADERS+="${kernels[0]}-headers " ;;
  esac
fi
info "kernel: ${kernels[*]:-custom}  ->  $WANT_MODULE"

# -----------------------------------------------------------------------------
#  What is missing?
# -----------------------------------------------------------------------------
step "Package state"
MISSING=()

#  Any of the open module packages satisfies the module requirement; only
#  suggest the preferred one when NONE is installed.
module_installed=""
for m in nvidia-open nvidia-open-dkms nvidia-open-lts nvidia-dkms nvidia; do
  if pacman -Qi "$m" &>/dev/null; then module_installed="$m"; break; fi
done
if [[ -n "$module_installed" ]]; then
  ok "kernel module package: $module_installed"
  if [[ "$module_installed" != "$WANT_MODULE" ]]; then
    info "(this script would have picked $WANT_MODULE; leaving your choice alone)"
  fi
else
  err "no NVIDIA kernel module package installed"
  MISSING+=("$WANT_MODULE")
fi

if pacman -Qi nvidia-utils &>/dev/null; then
  ok "userspace libraries: nvidia-utils"
else
  err "nvidia-utils missing (no libGL/EGL/Vulkan ICD; the desktop will not start)"
  MISSING+=(nvidia-utils)
fi

#  32-bit libs only make sense with multilib enabled. Checking the repo rather
#  than just the package avoids proposing something pacman cannot resolve.
if pacman -Sl multilib &>/dev/null; then
  if pacman -Qi lib32-nvidia-utils &>/dev/null; then
    ok "32-bit libraries: lib32-nvidia-utils"
  else
    warn "lib32-nvidia-utils missing (only matters for Steam/Wine/32-bit games)"
    MISSING+=(lib32-nvidia-utils)
  fi
else
  info "multilib disabled; skipping 32-bit libraries (enable [multilib] in"
  info "/etc/pacman.conf first if you want Steam/Wine)"
fi

for h in $NEED_HEADERS; do
  if pacman -Qi "$h" &>/dev/null; then ok "kernel headers: $h"
  else err "$h missing (dkms cannot build without it)"; MISSING+=("$h"); fi
done

# -----------------------------------------------------------------------------
#  initramfs
# -----------------------------------------------------------------------------
step "initramfs"
MKI=/etc/mkinitcpio.conf
MODULES_OK=false
MODULES_LINE=""
if [[ -f "$MKI" ]]; then
  MODULES_LINE=$(grep '^MODULES=' "$MKI" | head -1)
  count=$(grep -o 'nvidia_drm' <<<"$MODULES_LINE" | wc -l)
  if (( count == 1 )); then
    ok "MODULES line has the nvidia modules"
    MODULES_OK=true
  elif (( count > 1 )); then
    err "MODULES has DUPLICATED nvidia entries (breaks the initramfs)"
    info "  $MODULES_LINE"
  else
    err "MODULES is missing the nvidia modules"
    info "  $MODULES_LINE"
    info "  without them KMS starts late: flicker, or a black screen on boot"
  fi
else
  warn "$MKI not found; skipping the initramfs check"
  MODULES_OK=true
fi

# -----------------------------------------------------------------------------
#  Report / act
# -----------------------------------------------------------------------------
if [[ "$MODE" == "check" ]]; then
  step "Summary"
  if ((${#MISSING[@]} == 0)) && $MODULES_OK; then
    ok "NVIDIA driver stack looks complete"
    exit 0
  fi
  ((${#MISSING[@]})) && err "missing packages: ${MISSING[*]}"
  $MODULES_OK || err "initramfs MODULES needs fixing"
  info "run '${BASH_SOURCE[0]##*/} install' to fix all of the above"
  exit 1
fi

# --- install mode ------------------------------------------------------------
if ((${#MISSING[@]} == 0)) && $MODULES_OK; then
  step "Summary"
  ok "nothing to do; the driver stack is already complete"
  exit 0
fi

step "Installing"
if ((${#MISSING[@]})); then
  info "will install: ${MISSING[*]}"
  #  --needed so anything already present is skipped rather than reinstalled.
  if ! sudo pacman -S --needed --noconfirm "${MISSING[@]}"; then
    err "package installation failed; not touching the initramfs"
    exit 1
  fi
  ok "packages installed"
fi

if ! $MODULES_OK && [[ -f "$MKI" ]]; then
  backup="${MKI}.bak-$(date +%Y%m%d-%H%M%S)"
  sudo cp "$MKI" "$backup"
  info "backed up $MKI -> $backup"
  #  Rewrite the whole line rather than appending: repeated sed edits are what
  #  produce the duplicated-entry breakage this also repairs.
  fixed="MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)"
  sudo sed -i "s|^MODULES=.*|$fixed|" "$MKI"
  ok "set: $fixed"
  info "regenerating the initramfs (this takes a moment)"
  if sudo mkinitcpio -P; then
    ok "initramfs regenerated"
  else
    err "mkinitcpio FAILED. Your previous initramfs is still in place, but do"
    err "NOT reboot until this succeeds. Restore with:"
    err "  sudo cp $backup $MKI && sudo mkinitcpio -P"
    exit 1
  fi
elif ((${#MISSING[@]})); then
  #  New kernel modules but an untouched MODULES line still means the initramfs
  #  predates the driver.
  info "regenerating the initramfs so it contains the new driver"
  sudo mkinitcpio -P || { err "mkinitcpio failed"; exit 1; }
  ok "initramfs regenerated"
fi

step "Summary"
ok "NVIDIA driver stack completed"
warn "REBOOT before starting a graphical session: the kernel modules and the"
warn "initramfs only take effect on the next boot."
