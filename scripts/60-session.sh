#!/usr/bin/env bash
# =============================================================================
#  60-session.sh - switch the display manager to greetd + the DMS greeter
# =============================================================================
#  Reversible. Does NOT remove the previous display manager; it only enables
#  greetd and disables the other unit. The old DM stays installed and can be
#  switched back to at any time with --revert.
#
#  Run this AFTER 10-packages.sh (which installs greetd-dms-greeter-bin) and
#  only ONCE mango + DankMaterialShell are confirmed working, since a broken
#  greeter locks you out of a graphical login.
#
#  Facts verified against the greetd-dms-greeter-bin PKGBUILD, the installed
#  /usr/bin/dms-greeter wrapper, and the DMS source, not assumed:
#    - the greeter binary installs to /usr/bin/dms-greeter, and its QML lives
#      in /usr/share/quickshell/dms-greeter/. greetd's `command` must be the
#      FULL resolved path from `command -v dms-greeter`, never an assumed
#      prefix (/usr/bin vs /usr/local/bin differs by install method).
#    - `--command COMPOSITOR` is MANDATORY. `dms-greeter` with no argument
#      exits with "Error: --command COMPOSITOR is required", which greetd
#      surfaces only as a failed session, i.e. no usable login screen. The
#      wrapper's own --help lists the accepted values: niri, hyprland, sway,
#      scroll, miracle, mango, labwc. `mango` IS supported (it appears both
#      in the usage string and as the example `dms-greeter --command mango`),
#      so this script passes --command mango. The package's post-install
#      message shows `--command niri` because niri is upstream's default
#      example; using it here would launch the WRONG compositor.
#    - the package pre-creates /var/cache/dms-greeter (mode 750) for greeter
#      state. It must be owned by the account greetd runs the greeter as.
#      Overridable with --cache-dir if you ever need to relocate it.
#    - DMS detects an active DMS greeter by checking for the dms-greeter
#      binary OR the string "dms-greeter" in /etc/greetd/config.toml
#      (quickshell/Services/GreeterService.qml:20), so the config below
#      deliberately keeps that literal name in `command`.
#    - greetd conventionally runs the greeter as a dedicated unprivileged
#      system account (here: "greeter"), which must be in the video group.
#
#  Usage:
#    ./60-session.sh              switch to greetd + DMS greeter
#    ./60-session.sh --dry-run    show what would happen, change nothing
#    ./60-session.sh --revert     switch back to the previous display manager
# =============================================================================
set -uo pipefail

MODE="switch"
REVERT_TO=""
FORCE=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) MODE="dry-run" ;;
    --revert)  MODE="revert" ;;
    --revert-to=*) MODE="revert"; REVERT_TO="${arg#*=}" ;;
    --force)   FORCE=true ;;
    -h|--help) sed -n '2,42p' "${BASH_SOURCE[0]}"; exit 0 ;;
  esac
done

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
ok()   { printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"; }
err()  { printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }
step() { printf '\n%s=== %s ===%s\n' "$BOLD" "$*" "$NC"; }
run() { if [[ "$MODE" == "dry-run" ]]; then printf '%s[DRY]%s %s\n' "$YELLOW" "$NC" "$*"; else "$@"; fi; }

[[ $EUID -eq 0 ]] && { err "do not run as root; it uses sudo where needed"; exit 1; }

# -----------------------------------------------------------------------------
#  Detect the currently enabled display manager so --revert has a target and
#  the switch step knows what to disable. display-manager.service is a symlink
#  to whichever DM unit is enabled.
# -----------------------------------------------------------------------------
detect_dm() {
  readlink -f /etc/systemd/system/display-manager.service 2>/dev/null \
    | xargs -r basename 2>/dev/null
}

if [[ "$MODE" == "revert" ]]; then
  step "Reverting away from greetd"
  target="$REVERT_TO"
  if [[ -z "$target" ]]; then
    #  Prefer a DM that is actually installed. sddm and gdm are the usual
    #  suspects; ly/lightdm/greetd-tuigreet also possible.
    for cand in sddm gdm lightdm ly; do
      if pacman -Qi "$cand" &>/dev/null; then target="$cand"; break; fi
    done
  fi
  if [[ -z "$target" ]]; then
    err "no alternative display manager found installed."
    err "install one first (e.g. sudo pacman -S sddm), or pass --revert-to=<unit>"
    exit 1
  fi
  if ! pacman -Qi "$target" &>/dev/null; then
    err "$target is not installed; cannot revert to it"
    exit 1
  fi
  run sudo systemctl disable greetd.service 2>/dev/null
  run sudo systemctl enable "${target}.service"
  ok "greetd disabled, ${target} enabled. Takes effect on next reboot."
  exit 0
fi

step "Preconditions"
#  This script can leave a machine with NO graphical login if it points greetd
#  at something that cannot start, so every precondition below is fatal rather
#  than a warning. Use --force to override the session-file check if you know
#  what you are doing.
if ! command -v mango &>/dev/null; then
  err "the mango compositor is not installed."
  err "Run 10-packages.sh first; switching the display manager before the"
  err "compositor exists would leave you with no way to log in graphically."
  exit 1
fi
ok "mango compositor present"

if ! command -v dms-greeter &>/dev/null; then
  err "dms-greeter not found. Run 10-packages.sh first"
  err "(it installs the 'greetd-dms-greeter-bin' AUR package)."
  exit 1
fi
GREETER_PATH="$(command -v dms-greeter)"
ok "dms-greeter found: $GREETER_PATH"

#  Confirm THIS build actually accepts `mango` rather than trusting the docs.
#  The wrapper prints its supported compositors in --help; if a future version
#  drops mango, fail here instead of writing a greetd config that cannot start.
if dms-greeter --help 2>&1 | grep -qw mango; then
  ok "dms-greeter supports --command mango"
else
  err "this dms-greeter build does not list 'mango' as a supported compositor."
  err "Supported values it reports:"
  dms-greeter --help 2>&1 | grep -iE '^\s*--command' | sed 's/^/    /'
  err "Refusing to write a greetd config that would fail to start."
  exit 1
fi

if ! pacman -Qi greetd &>/dev/null; then
  err "greetd is not installed (should have come in with greetd-dms-greeter-bin)."
  exit 1
fi
ok "greetd installed"

if ! command -v dms &>/dev/null; then
  warn "the dms shell binary is not installed; the greeter will still work,"
  warn "but verify the desktop session itself before rebooting."
fi

CURRENT_DM="$(detect_dm)"
info "currently enabled display manager: ${CURRENT_DM:-none detected}"

# -----------------------------------------------------------------------------
#  greetd needs a dedicated system user to run the greeter session as.
#  It must be able to open the DRM device, hence the video group.
# -----------------------------------------------------------------------------
step "greetd system user"
if id greeter &>/dev/null; then
  ok "'greeter' user exists"
else
  info "creating system user 'greeter' (standard greetd convention)"
  run sudo useradd -M -G video -s /usr/bin/nologin greeter
  ok "'greeter' user created"
fi
if id -nG greeter 2>/dev/null | tr ' ' '\n' | grep -qx video; then
  ok "'greeter' is in the video group"
else
  warn "'greeter' is NOT in the video group; the greeter may fail to start"
  run sudo usermod -aG video greeter
fi

# -----------------------------------------------------------------------------
#  Greeter state directory. The package ships /var/cache/dms-greeter at mode
#  750; it must be owned by the greeter account or the greeter cannot persist
#  its last-session / user selection.
# -----------------------------------------------------------------------------
step "Greeter state directory"
if [[ -d /var/cache/dms-greeter ]]; then
  owner="$(stat -c '%U' /var/cache/dms-greeter 2>/dev/null)"
  if [[ "$owner" == "greeter" ]]; then
    ok "/var/cache/dms-greeter owned by greeter"
  else
    info "/var/cache/dms-greeter owned by '$owner'; reassigning to greeter"
    run sudo chown -R greeter:greeter /var/cache/dms-greeter
  fi
else
  info "creating /var/cache/dms-greeter"
  run sudo install -d -o greeter -g greeter -m 750 /var/cache/dms-greeter
fi

# -----------------------------------------------------------------------------
#  Session picker entries. The greeter reads wayland-sessions/*.desktop, so
#  mango must ship (or you must create) an entry there to be selectable.
# -----------------------------------------------------------------------------
step "Session picker entries"
found_session=false
for d in /usr/share/wayland-sessions /usr/local/share/wayland-sessions; do
  if [[ -f "$d/mango.desktop" ]]; then
    ok "found $d/mango.desktop"
    found_session=true
  fi
done
if ! $found_session; then
  err "no mango.desktop found under wayland-sessions/"
  err "The greeter would start with no mango session to offer, so you could not"
  err "log into the desktop. The mangowm package normally installs this file."
  err "Either reinstall mangowm, or create"
  err "  /usr/share/wayland-sessions/mango.desktop"
  err "with Exec= pointing at the mango binary."
  if $FORCE; then
    warn "--force given: continuing anyway"
  else
    err "Refusing to switch the display manager. Re-run with --force to override."
    exit 1
  fi
fi
info "sessions the greeter will offer:"
#  find, not ls: session filenames come from arbitrary packages.
sessions=$(find /usr/share/wayland-sessions /usr/local/share/wayland-sessions \
                -maxdepth 1 -name '*.desktop' -printf '%f\n' 2>/dev/null | sort -u)
if [[ -n "$sessions" ]]; then
  printf '%s\n' "$sessions" | sed 's/^/    /'
else
  info "    (none found)"
fi

# -----------------------------------------------------------------------------
#  /etc/greetd/config.toml
# -----------------------------------------------------------------------------
step "Configuring greetd"
GREETD_CONF="/etc/greetd/config.toml"
BACKUP="${GREETD_CONF}.bak-$(date +%Y%m%d-%H%M%S)"

#  --command mango is REQUIRED (see the header): without it dms-greeter
#  exits immediately and greetd has no working session.
NEW_CONF="[terminal]
vt = 1

[default_session]
command = \"${GREETER_PATH} --command mango\"
user = \"greeter\"
"

if [[ -f "$GREETD_CONF" ]]; then
  info "current $GREETD_CONF:"
  sed 's/^/    /' "$GREETD_CONF"
  if [[ "$MODE" != "dry-run" ]]; then
    sudo cp "$GREETD_CONF" "$BACKUP"
    info "backed up to $BACKUP"
  fi
fi

info "new config to write:"
printf '%s\n' "$NEW_CONF" | sed 's/^/    /'

if [[ "$MODE" == "dry-run" ]]; then
  info "[DRY] would write the above to $GREETD_CONF"
else
  sudo install -d -m 755 /etc/greetd
  echo "$NEW_CONF" | sudo tee "$GREETD_CONF" >/dev/null
  ok "$GREETD_CONF written"
fi

# -----------------------------------------------------------------------------
#  Appearance / layout
# -----------------------------------------------------------------------------
step "Greeter appearance (optional)"
info "The DMS greeter reads its theme from the DMS config, so it matches the"
info "desktop shell automatically once DMS has been configured."
info "Configure it from the running shell: dms ipc call settings focusOrToggle"
info "  -> Greeter tab, or run: dms doctor  (reports greeter status)"
info "Multi-monitor: the greeter mirrors across outputs by default, which is"
info "safe to start with. Adjust from the Greeter settings tab if needed."

# -----------------------------------------------------------------------------
#  Switch the enabled service
# -----------------------------------------------------------------------------
step "Switching display manager"
#  Guard: if greetd is ALREADY the enabled DM, disabling "$CURRENT_DM" would
#  disable greetd itself and then re-enable it, which is pointless churn and
#  reads as a bug in the log. Only disable a DM that is actually different.
if [[ "$MODE" == "dry-run" ]]; then
  if [[ -n "$CURRENT_DM" && "$CURRENT_DM" != "greetd.service" ]]; then
    info "[DRY] would run: sudo systemctl disable $CURRENT_DM"
  elif [[ "$CURRENT_DM" == "greetd.service" ]]; then
    info "greetd is already the enabled display manager; nothing to disable"
  fi
  info "[DRY] would run: sudo systemctl enable greetd.service"
  info "[DRY] would reload systemd so display-manager.service repoints"
else
  if [[ -n "$CURRENT_DM" && "$CURRENT_DM" != "greetd.service" ]]; then
    sudo systemctl disable "$CURRENT_DM" 2>/dev/null || true
    info "disabled $CURRENT_DM (package NOT removed)"
  elif [[ "$CURRENT_DM" == "greetd.service" ]]; then
    info "greetd was already enabled; only its config changed"
  fi
  sudo systemctl enable greetd.service
  sudo systemctl daemon-reload
  ok "greetd enabled"
fi

step "Summary"
ok "Session switch prepared."
#  Only advertise a revert target that is a DIFFERENT, installed DM. If greetd
#  was already enabled there is nothing meaningful to revert to.
revert_hint=""
for cand in sddm gdm lightdm ly; do
  if pacman -Qi "$cand" &>/dev/null; then revert_hint="$cand"; break; fi
done
if [[ -n "$revert_hint" ]]; then
  info "Revert any time with: $0 --revert   (would enable $revert_hint)"
else
  warn "No alternative display manager is installed, so --revert has no target."
  warn "If you want a fallback, install one now (e.g. sudo pacman -S sddm)"
  warn "BEFORE rebooting, or be ready to log in from a TTY."
fi
warn "Reboot to take effect. Before rebooting, confirm mango +"
warn "DankMaterialShell already work: log in with 'mango' from a TTY once,"
warn "check the bar renders and SUPER+space opens the launcher."
warn "If the greeter fails to start, switch to a TTY (Ctrl+Alt+F2) and run:"
if [[ -n "$revert_hint" ]]; then
  warn "  sudo systemctl disable greetd && sudo systemctl enable $revert_hint"
else
  warn "  sudo systemctl disable greetd    (then log in from the TTY)"
fi
