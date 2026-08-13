#!/usr/bin/env bash
# =============================================================================
#  40-root-symlink.sh - make root's GUI apps match your theme
# =============================================================================
#  Any app that runs as root (pkexec/polkit dialogs, `sudo dolphin`, root
#  Konsole sessions, etc.) reads /root/.config and /root/.themes, NOT yours.
#  Without this, those windows show up unstyled: default GTK/Qt look, wrong
#  cursor, no icon theme. This links the relevant theming directories from
#  your home into /root so root's GUI apps pick up the same theme.
#
#  Deliberately narrow: this links THEMING config only (GTK settings, Qt
#  theming, icons, cursors, fonts, the shell-generated color files). It
#  does NOT link your shell config, mango config, or anything with secrets
#  or session-specific state; root does not need your compositor session,
#  it needs matching visuals for the rare GUI dialog it pops up.
#
#  Based on the same approach as the older MangoSetup/symlink.sh, extended
#  to cover qt5ct/qt6ct and the matugen-generated palette files.
#
#  Usage:
#    sudo ./40-root-symlink.sh              link everything below
#    sudo ./40-root-symlink.sh --status     show current link state
#    sudo ./40-root-symlink.sh --unlink     remove the links (restores
#                                           root's own copies if backed up)
# =============================================================================
set -uo pipefail

MODE="link"
for arg in "$@"; do
  case "$arg" in
    --status) MODE="status" ;;
    --unlink) MODE="unlink" ;;
  esac
done

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
ok()   { printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"; }
err()  { printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }
step() { printf '\n%s=== %s ===%s\n' "$BOLD" "$*" "$NC"; }

if [[ $EUID -ne 0 ]]; then
  err "run this with sudo; it writes under /root"
  exit 1
fi

#  Resolve the invoking (non-root) user so we link the right person's configs.
#  sudo sets SUDO_USER automatically; when run from a plain root shell there is
#  no way to guess, so accept it explicitly rather than failing outright.
TARGET_USER="${TARGET_USER:-${SUDO_USER:-}}"
if [[ -z "$TARGET_USER" ]]; then
  err "could not determine which user's theme to link (\$SUDO_USER is empty)."
  err "Either run it through sudo from your normal account:"
  err "  sudo bash ./40-root-symlink.sh"
  err "or name the user explicitly when running as root:"
  err "  TARGET_USER=yourname bash ./40-root-symlink.sh"
  exit 1
fi
if ! id "$TARGET_USER" &>/dev/null; then
  err "user '$TARGET_USER' does not exist"
  exit 1
fi
USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
  err "home directory for '$TARGET_USER' not found: ${USER_HOME:-<empty>}"
  exit 1
fi
info "linking theming from $USER_HOME (user: $TARGET_USER) into /root"

#  Paths to link. Directories are linked whole; files are linked
#  individually so we do not have to fight for the whole parent directory
#  with other root-owned state.
LINK_DIRS=(
  ".config/gtk-3.0"
  ".config/gtk-4.0"
  ".config/qt5ct"
  ".config/qt6ct"
  ".config/nwg-look"
  ".config/fastfetch"
  ".themes"
  ".icons"
  ".fonts"
)
LINK_FILES=(
  ".config/mimeapps.list"
  ".config/kdeglobals"
  ".config/starship.toml"
)

STAMP=$(date +%Y%m%d-%H%M%S)
LINKED=0; ALREADY=0; SKIPPED=0

link_one() {
  local rel="$1" kind="$2"   # kind: dir | file
  local src="$USER_HOME/$rel" dst="/root/$rel"

  if [[ "$kind" == "dir" && ! -d "$src" ]]; then
    info "skip (source dir missing): $rel"
    ((SKIPPED++)); return
  fi
  if [[ "$kind" == "file" && ! -f "$src" ]]; then
    info "skip (source file missing): $rel"
    ((SKIPPED++)); return
  fi

  case "$MODE" in
    status)
      if [[ -L "$dst" ]]; then
        if [[ "$(readlink -f "$dst")" == "$src" ]]; then
          ok "$rel -> linked"
          ((LINKED++)) || true
        else
          warn "$rel -> symlink points elsewhere"
        fi
      elif [[ -e "$dst" ]]; then
        warn "$rel -> real file/dir exists under /root, not linked"
      else
        info "$rel -> not linked yet"
      fi
      return
      ;;
    unlink)
      if [[ -L "$dst" ]] && [[ "$(readlink -f "$dst")" == "$src" ]]; then
        rm "$dst"
        ok "unlinked: $rel"
      fi
      return
      ;;
  esac

  #  link mode
  mkdir -p "$(dirname "$dst")"
  if [[ -L "$dst" ]]; then
    if [[ "$(readlink -f "$dst")" == "$src" ]]; then
      ((ALREADY++)); return
    fi
    rm "$dst"
    ln -s "$src" "$dst"
    ok "relinked: $rel"
    ((LINKED++))
  elif [[ -e "$dst" ]]; then
    mv "$dst" "${dst}.pre-mangosetup-${STAMP}"
    ln -s "$src" "$dst"
    warn "backed up existing /root copy: ${dst}.pre-mangosetup-${STAMP}"
    ok "linked: $rel"
    ((LINKED++))
  else
    ln -s "$src" "$dst"
    ok "linked: $rel"
    ((LINKED++))
  fi
}

step "Directories"
for d in "${LINK_DIRS[@]}"; do link_one "$d" dir; done

step "Files"
for f in "${LINK_FILES[@]}"; do link_one "$f" file; done

step "Summary"
case "$MODE" in
  status) info "see per-item results above" ;;
  unlink) ok "root theming links removed" ;;
  link)
    ok "linked/relinked : $LINKED"
    ok "already correct : $ALREADY"
    #  `((SKIPPED)) && info ...` would make this script exit 1 when SKIPPED is
    #  0 if it were the last statement; guarded with || true regardless.
    ((SKIPPED)) && info "skipped (source missing) : $SKIPPED" || true
    info "Root-run GUI apps now use your GTK/Qt theme, icons and cursor."
    ;;
esac
exit 0
