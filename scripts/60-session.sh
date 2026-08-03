#!/usr/bin/env bash
# =============================================================================
#  60-session.sh - switch the display manager from SDDM to Noctalia Greeter
# =============================================================================
#  Reversible. Does NOT disable/remove SDDM by default; it only enables
#  greetd and points systemd's display-manager.service at it. SDDM stays
#  installed and can be switched back to at any time (see --revert).
#
#  Run this AFTER 10-packages.sh (which installs noctalia-greeter) and
#  BEFORE your first mango login, or any time later to switch greeters.
#
#  Facts used below (verified against noctalia-dev/noctalia-greeter README,
#  2026-07-30):
#    - greetd's session command must be the FULL PATH from
#      `which noctalia-greeter-session`, not assumed to be /usr/bin.
#    - the greeter needs a `user` in greetd's config matching a real,
#      dedicated system account (conventionally "greeter").
#    - session names for [session].default come from `noctalia-greeter
#      sessions`, which reads wayland-sessions/*.desktop files.
#    - multi-monitor layout is set in /var/lib/noctalia-greeter/greeter.toml,
#      not in /etc/greetd/config.toml.
#
#  Usage:
#    ./60-session.sh              switch SDDM -> greetd + Noctalia Greeter
#    ./60-session.sh --dry-run    show what would happen
#    ./60-session.sh --revert     switch back to SDDM
# =============================================================================
set -uo pipefail

MODE="switch"
for arg in "$@"; do
  case "$arg" in
    --dry-run) MODE="dry-run" ;;
    --revert)  MODE="revert" ;;
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

if [[ "$MODE" == "revert" ]]; then
  step "Reverting to SDDM"
  if ! pacman -Qi sddm &>/dev/null; then
    err "sddm is not installed; cannot revert. Install it first: sudo pacman -S sddm"
    exit 1
  fi
  run sudo systemctl disable greetd.service 2>/dev/null
  run sudo systemctl enable sddm.service
  ok "greetd disabled, sddm enabled. Takes effect on next reboot."
  exit 0
fi

step "Preconditions"
if ! command -v noctalia-greeter-session &>/dev/null; then
  err "noctalia-greeter-session not found. Run 10-packages.sh first"
  err "(it installs the 'noctalia-greeter' AUR package)."
  exit 1
fi
GREETER_SESSION_PATH="$(command -v noctalia-greeter-session)"
ok "noctalia-greeter-session found: $GREETER_SESSION_PATH"

if ! pacman -Qi greetd &>/dev/null; then
  err "greetd is not installed (should have come in with noctalia-greeter)."
  exit 1
fi
ok "greetd installed"

# -----------------------------------------------------------------------------
#  greetd needs a dedicated system user to run the greeter session as.
# -----------------------------------------------------------------------------
step "greetd system user"
if id greeter &>/dev/null; then
  ok "'greeter' user already exists"
else
  info "creating system user 'greeter' (standard greetd convention)"
  run sudo useradd -M -G video -s /usr/bin/nologin greeter
  ok "'greeter' user created"
fi

# -----------------------------------------------------------------------------
#  Available Wayland sessions (informational; mango needs a .desktop entry
#  under wayland-sessions for the greeter's session picker to offer it)
# -----------------------------------------------------------------------------
step "Session picker entries"
if command -v noctalia-greeter &>/dev/null; then
  info "sessions currently visible to the greeter:"
  noctalia-greeter sessions 2>/dev/null | sed 's/^/    /' || warn "could not list sessions (greeter binary present, listing failed)"
fi
if [[ ! -f /usr/share/wayland-sessions/mango.desktop ]] \
   && [[ ! -f /usr/local/share/wayland-sessions/mango.desktop ]]; then
  warn "no mango.desktop found under wayland-sessions/"
  warn "the mangowm/mangowm-git AUR package should install one; if it is"
  warn "missing, create /usr/share/wayland-sessions/mango.desktop pointing"
  warn "Exec= at the mango binary before relying on the session picker."
fi

# -----------------------------------------------------------------------------
#  /etc/greetd/config.toml
# -----------------------------------------------------------------------------
step "Configuring greetd"
GREETD_CONF="/etc/greetd/config.toml"
BACKUP="${GREETD_CONF}.bak-$(date +%Y%m%d-%H%M%S)"

NEW_CONF="[terminal]
vt = 1

[default_session]
command = \"${GREETER_SESSION_PATH}\"
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
  echo "$NEW_CONF" | sudo tee "$GREETD_CONF" >/dev/null
  ok "$GREETD_CONF written"
fi

# -----------------------------------------------------------------------------
#  Run the shipped system setup helper if the package provides one
# -----------------------------------------------------------------------------
step "Greeter system setup"
if command -v setup_greeter_system.sh &>/dev/null; then
  info "running the package's own setup_greeter_system.sh (prepares state dirs)"
  run sudo setup_greeter_system.sh
elif [[ -x /usr/share/noctalia-greeter/scripts/setup_greeter_system.sh ]]; then
  run sudo /usr/share/noctalia-greeter/scripts/setup_greeter_system.sh
else
  info "no packaged setup script found; ensuring state dir exists manually"
  run sudo install -d -o greeter -g greeter /var/lib/noctalia-greeter
fi

# -----------------------------------------------------------------------------
#  Multi-monitor layout (optional, matches configs/.config/mango/conf/monitors.conf)
# -----------------------------------------------------------------------------
step "Multi-monitor layout (optional)"
info "This machine has three outputs: eDP-1, DP-2 (rotated), HDMI-A-1."
info "The greeter mirrors on all monitors by default, which is fine to start."
info "To match the mango layout instead, after first boot into the greeter run:"
info "  noctalia-greeter outputs"
info "and set [output].layout in /var/lib/noctalia-greeter/greeter.toml, e.g.:"
info '  output.layout = "eDP-1:0,640; DP-2:2048,0; HDMI-A-1:3248,360"'
info "(coordinates are LOGICAL pixels; see monitors.conf for the reasoning"
info "behind these numbers, particularly the eDP-1 1.25 scale factor)."
info "If you have Noctalia v5 running already, Settings -> Shell -> Security"
info "-> Noctalia Greeter -> Sync Now copies wallpaper/palette/layout for you."

# -----------------------------------------------------------------------------
#  Switch the enabled service
# -----------------------------------------------------------------------------
step "Switching display manager"
if [[ "$MODE" == "dry-run" ]]; then
  info "[DRY] would run: sudo systemctl disable sddm.service"
  info "[DRY] would run: sudo systemctl enable greetd.service"
else
  sudo systemctl disable sddm.service 2>/dev/null || true
  sudo systemctl enable greetd.service
  ok "greetd enabled, sddm disabled (SDDM stays installed, not removed)"
fi

step "Summary"
ok "Session switch prepared."
info "SDDM is NOT removed; revert any time with: $0 --revert"
warn "Reboot to take effect. Before rebooting, confirm mango + Noctalia"
warn "already work (log in manually with 'mango' from a TTY once first if unsure)."
