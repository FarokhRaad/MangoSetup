#!/usr/bin/env bash
# =============================================================================
#  30-system-tweaks.sh - pick which system tweaks to apply, interactively
# =============================================================================
#  Every tweak here is OPT-IN and INDEPENDENT. Nothing is applied until you
#  select it. Each one is:
#    - detected first (already applied? applicable to this hardware at all?)
#    - shown with what it does and where it writes
#    - applied only if you tick it
#    - reversible with --revert (which is also a picker)
#
#  Tweak payloads live in ../system/ as real reviewable files, NOT as heredocs
#  buried in this script, so you can read exactly what lands on your system:
#
#    system/sysctl/99-cifs-writeback-smoothing.conf   -> /etc/sysctl.d/
#    system/nm-dispatcher/99-disable-eee-realtek      -> /etc/NetworkManager/dispatcher.d/
#    system/udev/90-disable-logi-bolt-wake.rules      -> /etc/udev/rules.d/
#    system/modprobe/disable-hda-autosuspend.conf     -> /etc/modprobe.d/
#
#  HARDWARE GATING: tweaks that only make sense on specific hardware are
#  detected, not assumed. A tweak whose hardware is absent is shown as
#  "n/a" and cannot be selected, so running this on a machine without a
#  Realtek NIC (or without an NVIDIA GPU) will not offer irrelevant fixes.
#
#  The mkinitcpio duplicate-modules repair is also a selectable item rather
#  than something that happens automatically, but it is only offered when the
#  duplication is actually detected.
#
#  Usage:
#    ./30-system-tweaks.sh              interactive picker
#    ./30-system-tweaks.sh --status     show state of every tweak, change nothing
#    ./30-system-tweaks.sh --revert     picker to REMOVE previously applied tweaks
#    ./30-system-tweaks.sh --dry-run    show what applying would do, change nothing
#                                       (combines with the others, e.g.
#                                        --all --dry-run, --revert --dry-run)
#    ./30-system-tweaks.sh --all        apply every applicable tweak, no prompt
#                                       (combines with --revert to undo all)
#                                       (for unattended installs; still skips
#                                        anything already applied or n/a)
#
#  Requires sudo for anything under /etc. Reads 00-preflight.sh's facts file
#  when present, but does NOT require it: hardware is re-detected here so this
#  script stands alone.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SYS_DIR="$REPO_DIR/system"

#  MODE (what to do), DRY (whether to write) and ALL (skip the picker) are all
#  INDEPENDENT, so --all --dry-run and --revert --all both work. Folding them
#  into one variable was a real bug twice: --dry-run fell through to the picker,
#  and --revert --all silently APPLIED instead of reverting.
MODE="pick"
DRY=false
ALL=false
for arg in "$@"; do
  case "$arg" in
    --status)  MODE="status" ;;
    --revert)  MODE="revert" ;;
    --all)     ALL=true ;;
    --dry-run) DRY=true ;;
    -h|--help) sed -n '2,47p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf 'unknown option: %s (try --help)\n' "$arg" >&2; exit 2 ;;
  esac
done

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
ok()   { printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"; }
err()  { printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }
step() { printf '\n%s=== %s ===%s\n' "$BOLD" "$*" "$NC"; }

run() {
  if $DRY; then printf '%s[DRY]%s %s\n' "$YELLOW" "$NC" "$*"; else "$@"; fi
}

# -----------------------------------------------------------------------------
#  Privilege handling. Everything applied here lives under /etc, so it needs
#  root. Designed to run as a NORMAL user with sudo (matching the other
#  scripts), but must also work when invoked directly as root on a fresh
#  install where sudo may not even be installed yet.
#
#  Deliberately NOT enforced for --status/--dry-run/--help: those write nothing,
#  so requiring root would make the read-only paths needlessly privileged.
# -----------------------------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
  #  Already root: make `sudo x` mean `x` so a missing sudo package is a non-issue.
  sudo() { "$@"; }
fi
need_root_or_die() {
  $DRY && return 0
  [[ "$MODE" == "status" ]] && return 0
  [[ $EUID -eq 0 ]] && return 0
  if ! command -v sudo >/dev/null 2>&1; then
    err "root is required to write under /etc, but sudo is not installed."
    err "Either install it (as root: pacman -S sudo) or run this script as root."
    exit 1
  fi
  #  Prime the sudo timestamp up front so the picker is not interrupted by a
  #  password prompt in the middle of applying tweaks.
  if ! sudo -n true 2>/dev/null; then
    info "root access is needed to write under /etc"
    sudo -v || { err "could not obtain sudo privileges"; exit 1; }
  fi
  return 0
}

# -----------------------------------------------------------------------------
#  Tweak registry.
#
#  One row per tweak, pipe-separated:
#    id|label|applicable_fn|applied_fn|apply_fn|revert_fn|description
#
#  applicable_fn : 0 = hardware/OS supports it, 1 = n/a on this machine
#  applied_fn    : 0 = already in place, 1 = not applied yet
#  Keeping these as functions (not precomputed strings) means --status,
#  the picker, and the post-apply verification all consult the SAME check,
#  so they can never disagree.
# -----------------------------------------------------------------------------

#  --- writeback smoothing ---------------------------------------------------
WB_SRC="$SYS_DIR/sysctl/99-cifs-writeback-smoothing.conf"
WB_DST="/etc/sysctl.d/99-cifs-writeback-smoothing.conf"
wb_applicable() { [[ -f "$WB_SRC" ]]; }
wb_applied() {
  #  Primary evidence is the file: that is what this tweak installs and what
  #  survives a reboot. The live values are checked only as a secondary signal
  #  and deliberately do NOT gate the result, because /proc/sys may be
  #  read-only (container) or the values may not be applied until next boot.
  [[ -f "$WB_DST" ]]
}
wb_apply() {
  run sudo install -m 644 -o root -g root "$WB_SRC" "$WB_DST" || return 1
  #  Reload is best-effort and deliberately NOT fatal: `sysctl --system` reads
  #  every file under /etc/sysctl.d, so an unrelated broken file elsewhere (or
  #  a read-only /proc/sys in a container) makes it exit nonzero even though
  #  OUR file installed correctly. The setting applies on next boot regardless.
  if ! run sudo sysctl --system >/dev/null 2>&1; then
    warn "config installed, but 'sysctl --system' reported an error"
    warn "(often an unrelated file in /etc/sysctl.d). It applies on next boot;"
    warn "check with: sysctl vm.dirty_bytes vm.dirty_background_bytes"
  fi
  return 0
}
wb_revert() {
  run sudo rm -f "$WB_DST"
  run sudo sysctl --system >/dev/null
  warn "dirty_* limits revert to RAM-percentage defaults on next boot;"
  warn "to restore defaults now: sudo sysctl vm.dirty_ratio=20 vm.dirty_background_ratio=10"
}

#  --- Realtek EEE ------------------------------------------------------------
EEE_SRC="$SYS_DIR/nm-dispatcher/99-disable-eee-realtek"
EEE_DST="/etc/NetworkManager/dispatcher.d/99-disable-eee-realtek"
#  Older host-specific scripts (99-disable-eee-<iface>) did the same job with a
#  hardcoded interface name. Detect them so we neither report "not applied"
#  while one is live, nor leave two dispatcher scripts fighting over the same
#  interface after installing the generalized one.
eee_legacy_files() {
  local f
  for f in /etc/NetworkManager/dispatcher.d/99-disable-eee-*; do
    [[ -e "$f" ]] || continue
    [[ "$f" == "$EEE_DST" ]] && continue
    printf '%s\n' "$f"
  done
}
realtek_ifaces() {
  local n d
  for n in /sys/class/net/*/device/driver; do
    [[ -e "$n" ]] || continue
    d=$(basename "$(readlink -f "$n")")
    case "$d" in r8169|r8168|r8125|r8126) basename "$(dirname "$(dirname "$n")")" ;; esac
  done
}
eee_applicable() {
  [[ -f "$EEE_SRC" ]] || return 1
  [[ -n "$(realtek_ifaces)" ]] || return 1
  command -v ethtool >/dev/null 2>&1 || return 1
  return 0
}
eee_applied() { [[ -x "$EEE_DST" ]]; }
eee_apply() {
  run sudo install -m 755 -o root -g root "$EEE_SRC" "$EEE_DST" || return 1
  #  Retire any legacy hardcoded-interface script this one supersedes.
  local f
  while read -r f; do
    [[ -n "$f" ]] || continue
    warn "superseding legacy script: $f"
    run sudo mv "$f" "${f}.superseded-by-99-disable-eee-realtek"
  done < <(eee_legacy_files)
  #  Apply immediately to already-up interfaces instead of waiting for a
  #  link event, so the fix takes effect in this session too. Best-effort:
  #  failure here (no live NIC, no udev, container) does not undo the install.
  local i
  for i in $(realtek_ifaces); do
    if run sudo "$EEE_DST" "$i" up; then
      info "applied to $i now (also runs automatically on every link up)"
    else
      warn "could not apply to $i right now; will run on the next link up"
    fi
  done
  return 0
}
eee_revert() {
  run sudo rm -f "$EEE_DST"
  info "EEE will return to its default (enabled) on the next link up/reboot"
  local f
  while read -r f; do
    [[ -n "$f" ]] || continue
    info "note: a superseded legacy script is still parked at $f"
  done < <(eee_legacy_files)
}

#  --- logind lid switch ------------------------------------------------------
LID_SRC="$SYS_DIR/logind/99-lid-ignore.conf"
LID_DST=/etc/systemd/logind.conf.d/99-lid-ignore.conf
#  Laptops only: on a desktop there is no lid, so the tweak is meaningless.
#  hostnamectl is the reliable check; fall back to the ACPI lid button node.
lid_applicable() {
  [[ -f "$LID_SRC" ]] || return 1
  [[ "$(hostnamectl chassis 2>/dev/null)" == laptop ]] && return 0
  compgen -G '/proc/acpi/button/lid/*' >/dev/null 2>&1
}
lid_applied() { [[ -f "$LID_DST" ]]; }
lid_apply() {
  run sudo install -d -m 755 /etc/systemd/logind.conf.d || return 1
  run sudo install -m 644 -o root -g root "$LID_SRC" "$LID_DST" || return 1
  #  Deliberately NOT restarting systemd-logind: it kills the graphical
  #  session with it. The drop-in is on disk and applies at next boot.
  info "takes effect after a reboot (restarting logind would end your session)"
  return 0
}
lid_revert() {
  run sudo rm -f "$LID_DST"
  run sudo rmdir --ignore-fail-on-non-empty /etc/systemd/logind.conf.d 2>/dev/null || true
  return 0
}

#  --- disable DDC/CI entirely (external monitor wake) ------------------------
#  Supersedes an earlier per-bus udev approach. See
#  system/modprobe/disable-i2c-dev-ddc.conf for the full reasoning; in short,
#  blocking the i2c-dev module is the universal fix (no per-machine bus
#  detection, immune to /dev/i2c-N renumbering, stops every DDC consumer at
#  once) and the cost is software brightness on external monitors, which the
#  monitors' physical buttons cover.
DDC_SRC="$SYS_DIR/modprobe/disable-i2c-dev-ddc.conf"
DDC_DST=/etc/modprobe.d/disable-i2c-dev-ddc.conf
#  Masks for the modules-load.d entries that would otherwise make
#  systemd-modules-load fail on every boot trying to load a blocked module.
DDC_MASK_SRC="$SYS_DIR/modules-load"
DDC_MASKS=(ddcutil.conf i2c-tools.conf)
#  Only offer this where DDC could actually run: an i2c bus belonging to a
#  display adapter must exist. On a machine with no such bus there is nothing
#  to disable.
ddc_applicable() {
  [[ -f "$DDC_SRC" ]] || return 1
  compgen -G '/sys/bus/i2c/devices/i2c-*' >/dev/null 2>&1
}
ddc_applied() { [[ -f "$DDC_DST" ]]; }
ddc_apply() {
  run sudo install -m 644 -o root -g root "$DDC_SRC" "$DDC_DST" || return 1
  #  Mask the package-shipped modules-load entries. Only mask a name the
  #  system actually ships, so we do not litter /etc with pointless files.
  local m
  for m in "${DDC_MASKS[@]}"; do
    [[ -f "/usr/lib/modules-load.d/$m" ]] || continue
    [[ -f "$DDC_MASK_SRC/$m" ]] || continue
    run sudo install -d -m 755 /etc/modules-load.d
    run sudo install -m 644 -o root -g root "$DDC_MASK_SRC/$m" "/etc/modules-load.d/$m" \
      && info "masked /usr/lib/modules-load.d/$m"
  done
  #  Unload now so the fix takes effect without a reboot. Best-effort: the
  #  module is busy only if something holds a /dev/i2c-* fd right now.
  #
  #  NOT `lsmod | grep -q`: grep -q exits on the FIRST match, closing the pipe,
  #  so lsmod dies with SIGPIPE (141) and `set -o pipefail` propagates 141 as
  #  the pipeline status. The test then reads FALSE exactly when the module IS
  #  loaded - inverted logic, and it silently skipped this whole block.
  #  awk consumes all input and exits on its own, so there is no SIGPIPE.
  if lsmod | awk '$1=="i2c_dev"{found=1} END{exit !found}'; then
    if run sudo modprobe -r i2c_dev 2>/dev/null; then
      ok "i2c-dev unloaded; DDC probing has stopped now"
    else
      warn "i2c-dev is in use and could not be unloaded; effective after reboot"
    fi
  fi
  return 0
}
ddc_revert() {
  run sudo rm -f "$DDC_DST"
  local m
  for m in "${DDC_MASKS[@]}"; do
    run sudo rm -f "/etc/modules-load.d/$m"
  done
  run sudo rmdir --ignore-fail-on-non-empty /etc/modules-load.d 2>/dev/null || true
  if ! $DRY; then
    sudo modprobe i2c_dev 2>/dev/null \
      && ok "i2c-dev reloaded; DDC/CI is available again" \
      || warn "could not reload i2c-dev now; it returns after a reboot"
  fi
  return 0
}

#  --- Logitech Bolt wake ----------------------------------------------------
LOGI_SRC="$SYS_DIR/udev/90-disable-logi-bolt-wake.rules"
LOGI_DST="/etc/udev/rules.d/90-disable-logi-bolt-wake.rules"
#  Detect the receiver from sysfs ONLY: /sys is always present, whereas lsusb
#  comes from usbutils which is NOT in Arch's base install. An earlier version
#  fell back to a loose `grep -l c548` across idProduct files, which returned
#  success even with no matching device (grep -l over several files, plus a
#  substring match), so the tweak was offered on hardware that does not have it.
#  Match vendor AND product exactly, on the same device.
logi_bolt_present() {
  local d
  for d in /sys/bus/usb/devices/*; do
    [[ -r "$d/idVendor" && -r "$d/idProduct" ]] || continue
    [[ "$(<"$d/idVendor")"  == "046d" ]] || continue
    [[ "$(<"$d/idProduct")" == "c548" ]] || continue
    return 0
  done
  return 1
}
logi_applicable() {
  [[ -f "$LOGI_SRC" ]] || return 1
  logi_bolt_present
}
logi_applied() { [[ -f "$LOGI_DST" ]]; }
logi_apply() {
  run sudo install -m 644 -o root -g root "$LOGI_SRC" "$LOGI_DST" || return 1
  #  Best-effort reload: udev may not be running (container/chroot). The rule
  #  is on disk and takes effect on the next boot or device re-plug either way.
  run sudo udevadm control --reload-rules >/dev/null 2>&1 \
    || warn "rule installed, but udev reload failed; effective after reboot/re-plug"
  run sudo udevadm trigger --subsystem-match=usb >/dev/null 2>&1 || true
  return 0
}
logi_revert() {
  run sudo rm -f "$LOGI_DST"
  run sudo udevadm control --reload-rules
}

#  --- HDA autosuspend -------------------------------------------------------
HDA_SRC="$SYS_DIR/modprobe/disable-hda-autosuspend.conf"
HDA_DST="/etc/modprobe.d/disable-hda-autosuspend.conf"
hda_applicable() {
  [[ -f "$HDA_SRC" ]] || return 1
  [[ -d /sys/module/snd_hda_intel ]] || \
    grep -qs snd_hda_intel /proc/modules || return 1
  return 0
}
hda_applied() { [[ -f "$HDA_DST" ]]; }
hda_apply() {
  run sudo install -m 644 -o root -g root "$HDA_SRC" "$HDA_DST" || return 1
  info "takes effect on next boot (or: sudo modprobe -r snd_hda_intel && sudo modprobe snd_hda_intel)"
}
hda_revert() { run sudo rm -f "$HDA_DST"; }

#  --- pacman.conf niceties --------------------------------------------------
pac_applicable() { [[ -f /etc/pacman.conf ]]; }
pac_applied() { grep -qE '^\s*ParallelDownloads\s*=' /etc/pacman.conf 2>/dev/null; }
pac_apply() {
  if $DRY; then
    info "[DRY] would enable Color + VerbosePkgLists + ParallelDownloads=10 in /etc/pacman.conf"
    return 0
  fi
  sudo cp /etc/pacman.conf "/etc/pacman.conf.bak-$(date +%Y%m%d-%H%M%S)" || return 1
  #  Uncomment the stock commented-out options if present, else append.
  sudo sed -i -E 's/^#\s*(Color)\s*$/\1/; s/^#\s*(VerbosePkgLists)\s*$/\1/' /etc/pacman.conf
  grep -qE '^\s*Color\s*$'           /etc/pacman.conf || sudo sed -i '/^\[options\]/a Color' /etc/pacman.conf
  grep -qE '^\s*VerbosePkgLists\s*$' /etc/pacman.conf || sudo sed -i '/^\[options\]/a VerbosePkgLists' /etc/pacman.conf
  if grep -qE '^\s*#\s*ParallelDownloads' /etc/pacman.conf; then
    sudo sed -i -E 's/^\s*#\s*ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf
  else
    sudo sed -i '/^\[options\]/a ParallelDownloads = 10' /etc/pacman.conf
  fi
  ok "pacman.conf tuned (backup saved alongside it)"
}
pac_revert() {
  warn "not auto-reverted: pacman.conf is hand-edited by many things."
  warn "Restore from one of: /etc/pacman.conf.bak-*"
}

#  --- mkinitcpio duplicate modules repair -----------------------------------
mki_nvidia_count() {
  grep '^MODULES=' /etc/mkinitcpio.conf 2>/dev/null \
    | grep -o 'nvidia_drm' | wc -l
}
mki_applicable() { [[ -f /etc/mkinitcpio.conf ]] && (( $(mki_nvidia_count) > 1 )); }
mki_applied()    { [[ -f /etc/mkinitcpio.conf ]] && (( $(mki_nvidia_count) <= 1 )); }
mki_apply() {
  local fixed="MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)"
  info "current: $(grep '^MODULES=' /etc/mkinitcpio.conf)"
  info "fixed:   $fixed"
  if $DRY; then
    info "[DRY] would rewrite MODULES= and run: sudo mkinitcpio -P"
    return 0
  fi
  sudo cp /etc/mkinitcpio.conf "/etc/mkinitcpio.conf.bak-$(date +%Y%m%d-%H%M%S)" || return 1
  #  Rebuilt from scratch, NOT another sed append, which is what duplicated
  #  the modules in the first place.
  sudo sed -i "s|^MODULES=.*|${fixed}|" /etc/mkinitcpio.conf || return 1
  sudo mkinitcpio -P || return 1
  warn "initramfs regenerated; takes effect on next boot"
}
mki_revert() { warn "not auto-reverted; restore from /etc/mkinitcpio.conf.bak-*"; }

# -----------------------------------------------------------------------------
#  Registry table
# -----------------------------------------------------------------------------
TWEAKS=(
  "writeback|CIFS/SMB writeback smoothing|wb|Caps dirty page cache to absolute bytes so copies to network shares stream steadily instead of burst-then-stall. Writes /etc/sysctl.d/. Safe with no shares: never limits fast local disks."
  "eee|Disable Realtek EEE (link flapping)|eee|Energy Efficient Ethernet on r8169-family NICs renegotiates the link, causing TCP retransmit storms that tank SMB throughput. Installs a NetworkManager dispatcher script (interface auto-detected, not hardcoded)."
  "deadddc|Disable DDC/CI (fixes slow monitor wake)|ddc|An external monitor whose DDC never answers makes every brightness probe burn ~2.5s on the DisplayPort AUX channel - the same channel used for link training - so it wakes slowly or not at all. Blocks the i2c-dev module, which stops every DDC consumer at once (DMS probes all buses every 30s and has no off-switch). Monitor DETECTION and laptop backlight are unaffected. COSTS: software brightness on external monitors (use their buttons), and ddcutil/i2c-tools stop working."
  "lid|Ignore laptop lid switch|lid|Closing the lid no longer suspends, on battery or AC or docked, and the holdoff drops 30s -> 5s. Written as a logind.conf.d drop-in, NOT an edit to the package-owned logind.conf (which would generate a .pacnew on every systemd upgrade). The machine stays awake with the lid shut, so it can overheat in a bag. Applies at next boot."
  "logibolt|Logitech Bolt: no wake from suspend|logi|Stops the Bolt receiver (046d:c548) waking the machine on mouse movement. Writes /etc/udev/rules.d/."
  "hda|Keep HDA audio codec powered|hda|Prevents the Intel HDA codec autosuspending, which clicks/pops and clips the start of notification sounds. Writes /etc/modprobe.d/."
  "pacman|pacman.conf niceties|pac|Color, VerbosePkgLists, ParallelDownloads=10. Backs up pacman.conf first."
  "mkinitcpio|Repair duplicated nvidia mkinitcpio MODULES|mki|Rebuilds a MODULES= line that repeated sed edits duplicated (a duplicated nvidia_drm breaks the initramfs). Only offered when the duplication is detected."
)

state_of() { # prefix -> APPLIED | AVAILABLE | NA
  local p="$1"
  if ! "${p}_applicable"; then echo NA; return; fi
  if "${p}_applied";      then echo APPLIED; return; fi
  echo AVAILABLE
}

print_status() {
  local row id label pfx st w=0
  #  Reserve the widest label rather than a hardcoded width, so the STATE
  #  column stays aligned when a label is long or a new tweak is added.
  for row in "${TWEAKS[@]}"; do
    IFS='|' read -r _ label _ _ <<<"$row"
    (( ${#label} > w )) && w=${#label}
  done
  printf '%s%-*s  %s%s\n' "$BOLD" "$w" "TWEAK" "STATE" "$NC"
  for row in "${TWEAKS[@]}"; do
    IFS='|' read -r id label pfx _ <<<"$row"
    st=$(state_of "$pfx")
    case "$st" in
      APPLIED)   printf '%s%-*s  %s%s\n' "$GREEN"  "$w" "$label" "applied"   "$NC" ;;
      AVAILABLE) printf '%s%-*s  %s%s\n' "$YELLOW" "$w" "$label" "available" "$NC" ;;
      NA)        printf '%s%-*s  %s%s\n' "$DIM"    "$w" "$label" "n/a here"  "$NC" ;;
    esac
  done
}

if [[ "$MODE" == "status" ]]; then
  step "System tweaks"
  print_status
  #  Extra signal for the writeback tweak: the file being installed is not the
  #  same as the values being live (they apply at boot, and /proc/sys can be
  #  read-only in a container), so show both.
  if wb_applied; then
    live_db=$(sysctl -n vm.dirty_bytes 2>/dev/null || echo "?")
    if [[ "$live_db" == "0" || "$live_db" == "?" ]]; then
      warn "writeback config is installed but NOT active yet (vm.dirty_bytes=$live_db)"
      warn "it takes effect on the next boot, or run: sudo sysctl --system"
    fi
  fi
  echo
  info "nothing was modified. Run without --status to choose tweaks to apply."
  exit 0
fi

# -----------------------------------------------------------------------------
#  Build the selectable list
# -----------------------------------------------------------------------------
step "System tweaks"
print_status
echo

CAND_LABELS=(); CAND_PFX=(); CAND_ID=()
for row in "${TWEAKS[@]}"; do
  IFS='|' read -r id label pfx _ <<<"$row"
  st=$(state_of "$pfx")
  if [[ "$MODE" == "revert" ]]; then
    [[ "$st" == "APPLIED" ]] || continue
  else
    [[ "$st" == "AVAILABLE" ]] || continue
  fi
  CAND_LABELS+=("$label"); CAND_PFX+=("$pfx"); CAND_ID+=("$id")
done

if ((${#CAND_LABELS[@]} == 0)); then
  if [[ "$MODE" == "revert" ]]; then
    ok "no applied tweaks to revert"
  else
    ok "nothing to do: every applicable tweak is already applied"
  fi
  exit 0
fi

SELECTED=()
#  Interactivity check. gum needs a real terminal: with stdin/stdout redirected
#  (a pipe, a cron job, CI) it either errors out or BLOCKS FOREVER waiting on a
#  TTY it will never get. Detect that up front and refuse with instructions
#  instead of hanging.
if ! $ALL && { [[ ! -t 0 ]] || [[ ! -t 1 ]]; }; then
  err "this picker needs an interactive terminal (stdin/stdout are not a TTY)."
  err "For unattended use, pass --all to apply every applicable tweak:"
  err "  bash ./30-system-tweaks.sh --all"
  err "Or inspect without changing anything:"
  err "  bash ./30-system-tweaks.sh --status"
  exit 1
fi

if $ALL; then
  SELECTED=("${!CAND_PFX[@]}")
  info "--all: selecting all ${#CAND_LABELS[@]} candidate(s) for $([[ "$MODE" == revert ]] && echo REVERT || echo apply)"
elif command -v gum >/dev/null 2>&1; then
  verb="apply"; [[ "$MODE" == "revert" ]] && verb="REVERT"
  #  Nothing is pre-selected: every tweak is a deliberate choice.
  mapfile -t picked < <(printf '%s\n' "${CAND_LABELS[@]}" \
    | gum choose --no-limit --height 12 \
        --header "Which tweaks to ${verb}?  (space = toggle, enter = confirm, no selection = quit)")
  for p in "${picked[@]}"; do
    for i in "${!CAND_LABELS[@]}"; do
      [[ "${CAND_LABELS[$i]}" == "$p" ]] && SELECTED+=("$i")
    done
  done
else
  #  gum-less fallback so this script never becomes unusable.
  warn "gum not installed; falling back to y/N prompts"
  for i in "${!CAND_LABELS[@]}"; do
    printf '\n%s%s%s\n' "$BOLD" "${CAND_LABELS[$i]}" "$NC"
    #  Look the description up by PREFIX, not by index: CAND_* is a filtered
    #  subset of TWEAKS, so TWEAKS[$i] would be the wrong row.
    for row in "${TWEAKS[@]}"; do
      IFS='|' read -r _ _ rpfx rdesc <<<"$row"
      [[ "$rpfx" == "${CAND_PFX[$i]}" ]] && printf '%s  %s%s\n' "$DIM" "$rdesc" "$NC"
    done
    r=n
    read -rp "$( [[ "$MODE" == revert ]] && echo Revert || echo Apply ) this? [y/N] " r || r=n
    [[ "$r" == y || "$r" == Y ]] && SELECTED+=("$i")
  done
fi

if ((${#SELECTED[@]} == 0)); then
  info "nothing selected; no changes made"
  exit 0
fi

#  Obtain privileges once, AFTER the user has chosen, so a read-only browse of
#  the picker never prompts for a password.
need_root_or_die

# -----------------------------------------------------------------------------
#  Apply / revert
# -----------------------------------------------------------------------------
DONE=0; FAILED=()
for i in "${SELECTED[@]}"; do
  pfx="${CAND_PFX[$i]}"; label="${CAND_LABELS[$i]}"
  step "$( [[ "$MODE" == revert ]] && echo Reverting || echo Applying ): $label"
  if [[ "$MODE" == "revert" ]]; then
    if "${pfx}_revert"; then ok "reverted"; ((DONE++)); else err "failed"; FAILED+=("$label"); fi
  else
    if "${pfx}_apply"; then
      #  Re-check with the SAME predicate the picker used, so a silent
      #  no-op cannot be reported as success.
      if $DRY; then
        info "[DRY] not verified (nothing was written)"
      elif "${pfx}_applied"; then
        ok "applied and verified"
      else
        warn "apply reported success but the state check still says not applied"
        warn "(expected for tweaks that only take effect after a reboot)"
      fi
      ((DONE++))
    else
      err "failed"; FAILED+=("$label")
    fi
  fi
done

step "Summary"
$DRY && info "DRY RUN: nothing was actually changed"
ok "$( [[ "$MODE" == revert ]] && echo reverted || echo processed ): $DONE"
((${#FAILED[@]})) && { err "failed: ${FAILED[*]}"; exit 1; }
echo
info "Re-check any time with: ./30-system-tweaks.sh --status"
info "Undo any of them with:  ./30-system-tweaks.sh --revert"
exit 0
