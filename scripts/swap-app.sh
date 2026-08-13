#!/usr/bin/env bash
# =============================================================================
#  swap-app.sh - change a default application in ONE command
# =============================================================================
#  Swaps a role (TERMINAL, BROWSER, FILEMANAGER, EDITOR, VISUAL, GUI_EDITOR,
#  MESSENGER, IMAGEVIEWER, DOCVIEWER, ARCHIVEMANAGER) to a different command
#  by editing the env=ROLE,value line in configs/.config/mango/conf/apps.conf
#  (or the deployed copy at ~/.config/mango/conf/apps.conf if this repo is
#  symlinked in, see 20-symlink.sh).
#
#  Why this works: every keybinding and autostart line in this repo spawns
#  $ROLE rather than a literal app name. mango expands $VAR via wordexp()
#  (spawn) or a real shell (spawn_shell/exec-once), so changing the value
#  here and reloading is enough for MOST apps. See apps.conf's header for
#  the one thing this can't cover: window rules matching a literal appid.
#
#  Usage:
#    ./swap-app.sh <role> <command>
#    ./swap-app.sh --list
#    ./swap-app.sh --show <role>
#
#  Examples:
#    ./swap-app.sh TERMINAL kitty
#    ./swap-app.sh FILEMANAGER thunar
#    ./swap-app.sh BROWSER firefox
# =============================================================================
set -uo pipefail

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
ok()   { printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"; }
err()  { printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }

#  Prefer the live deployed config (if 20-symlink.sh has run), fall back to
#  the repo copy so this also works before first deployment.
DEPLOYED="$HOME/.config/mango/conf/apps.conf"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_COPY="$SCRIPT_DIR/../configs/.config/mango/conf/apps.conf"

if [[ -e "$DEPLOYED" ]]; then
  APPS_CONF="$DEPLOYED"
  #  If it's a symlink into the repo (the expected setup, see 20-symlink.sh)
  #  editing it in place already edits the repo copy: nothing extra to do.
  if [[ -L "$DEPLOYED" ]]; then
    info "using deployed config (symlinked into the repo): $DEPLOYED"
  else
    info "using deployed config (NOT symlinked, edits stay local): $DEPLOYED"
    warn "run 20-symlink.sh to keep this in sync with the repo automatically"
  fi
elif [[ -e "$REPO_COPY" ]]; then
  APPS_CONF="$REPO_COPY"
  info "using repo config (not yet deployed): $APPS_CONF"
else
  err "apps.conf not found in either location"
  exit 1
fi

VALID_ROLES=(TERMINAL BROWSER FILEMANAGER EDITOR VISUAL GUI_EDITOR MESSENGER \
             IMAGEVIEWER DOCVIEWER MEDIAPLAYER ARCHIVEMANAGER)

list_roles() {
  printf '%sCurrent app roles:%s\n' "$BOLD" "$NC"
  for role in "${VALID_ROLES[@]}"; do
    val=$(grep -E "^env=${role}," "$APPS_CONF" | head -1 | cut -d, -f2-)
    printf '  %-14s = %s\n' "$role" "${val:-<unset>}"
  done
}

if [[ "${1:-}" == "--list" ]]; then
  list_roles
  exit 0
fi

if [[ "${1:-}" == "--show" ]]; then
  role="${2:-}"
  val=$(grep -E "^env=${role}," "$APPS_CONF" | head -1 | cut -d, -f2-)
  [[ -n "$val" ]] && echo "$val" || { err "role not set: $role"; exit 1; }
  exit 0
fi

if [[ $# -lt 2 ]]; then
  err "usage: $0 <role> <command>   or   $0 --list   or   $0 --show <role>"
  printf '\nvalid roles: %s\n' "${VALID_ROLES[*]}"
  exit 1
fi

ROLE="$1"; shift
COMMAND="$*"

#  Validate the role name so a typo doesn't silently add a dead env var
#  that nothing in the config tree references.
valid=false
for r in "${VALID_ROLES[@]}"; do [[ "$r" == "$ROLE" ]] && valid=true; done
if ! $valid; then
  err "unknown role: $ROLE"
  printf 'valid roles: %s\n' "${VALID_ROLES[*]}"
  exit 1
fi

#  Extract just the binary (first word) to check it resolves.
BIN="${COMMAND%% *}"
if ! command -v "$BIN" &>/dev/null; then
  warn "'$BIN' is not on PATH / not installed."
  #  Without a TTY we cannot prompt; proceed with the swap and warn, rather
  #  than blocking or silently doing nothing. The role change is still valid,
  #  the binding just will not work until the app is installed.
  reply=n
  if [[ -t 0 ]]; then
    read -rp "$(printf '%sInstall it now with pacman/yay?%s [y/N] ' "$BOLD" "$NC")" reply
  else
    warn "(non-interactive: not installing; set the app up yourself)"
  fi
  if [[ "$reply" == "y" || "$reply" == "Y" ]]; then
    if pacman -Si "$BIN" &>/dev/null; then
      sudo pacman -S --needed "$BIN"
    elif command -v yay &>/dev/null; then
      yay -S --needed "$BIN"
    else
      err "could not find '$BIN' in the repos or resolve it via yay"
      exit 1
    fi
  else
    warn "continuing without installing; the binding will fail until it is available"
  fi
fi

#  Show current value, then swap it.
current=$(grep -E "^env=${ROLE}," "$APPS_CONF" | head -1)
if [[ -z "$current" ]]; then
  err "no existing env=${ROLE}, line found in $APPS_CONF; not adding a new one automatically"
  err "add it manually to keep apps.conf's structure and comments intact"
  exit 1
fi

info "current: $current"
new_line="env=${ROLE},${COMMAND}"
sed -i "s|^env=${ROLE},.*|${new_line}|" "$APPS_CONF"
ok "updated: $new_line"

# -----------------------------------------------------------------------------
#  Reminders for things a variable swap cannot cover
# -----------------------------------------------------------------------------
RULES_FILE="$(dirname "$APPS_CONF")/rules-windows.conf"
if [[ -f "$RULES_FILE" ]] && [[ "$ROLE" == "MESSENGER" ]]; then
  warn "rules-windows.conf pins the messenger to a tag by literal appid."
  warn "It still references the OLD app; check and update that rule if the"
  warn "new app's appid differs:"
  grep -n 'appid.*ferdium\|MESSENGER' "$RULES_FILE" 2>/dev/null | sed 's/^/    /'
fi

if command -v mango &>/dev/null && pgrep -x mango &>/dev/null; then
  info "mango is running: reload with SUPER+SHIFT+R, or:"
  info "  mmsg dispatch reload_config"
else
  info "changes take effect on next mango login (or SUPER+SHIFT+R if already running)"
fi
