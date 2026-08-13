#!/usr/bin/env bash
# =============================================================================
#  10-packages.sh - install mango + DankMaterialShell, skip what is present
# =============================================================================
#  Reads packages/packages.txt and installs ONLY what is missing, routing each
#  package to pacman (official repos) or yay (AUR) automatically. Anything
#  already installed is left alone, so the script is safe to re-run.
#
#  It is purely additive: it never removes packages. If you are coming from
#  another desktop environment, uninstall it yourself once mango is verified
#  working.
#
#  Usage:
#    ./10-packages.sh [--dry-run] [--with-optional]
#
#  --with-optional installs lines in packages.txt marked "# optional"
#  (currently: xwayland-satellite, ttf-ms-fonts).
#
#  EXTRA_PKG_FILE=<path> (environment variable, not a flag): merge in an
#  additional newline-separated package list on top of packages.txt. Used
#  by scripts/setup.sh to pass along whatever apps were chosen in its
#  interactive category picker, without duplicating this script's
#  install/dedupe/pacman-vs-AUR-routing logic.
# =============================================================================
set -uo pipefail

DRY_RUN=false
WITH_OPTIONAL=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --with-optional) WITH_OPTIONAL=true ;;
  esac
done

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
ok()   { printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"; }
err()  { printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }
step() { printf '\n%s=== %s ===%s\n' "$BOLD" "$*" "$NC"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_FILE="$SCRIPT_DIR/../packages/packages.txt"
[[ -f "$PKG_FILE" ]] || { err "packages.txt not found at $PKG_FILE"; exit 1; }

[[ $EUID -eq 0 ]] && { err "do not run as root; it uses sudo where needed"; exit 1; }

# -----------------------------------------------------------------------------
#  Parse packages.txt (+ optional EXTRA_PKG_FILE): strip comments, optionally
#  skip "# optional" lines, dedupe.
# -----------------------------------------------------------------------------
step "Reading package manifest"
mapfile -t BASE_PKGS < <(
  grep -Ev '^\s*(#|$)' "$PKG_FILE" \
    | awk -v opt="$WITH_OPTIONAL" '
        /# *optional/ && opt != "true" { next }
        { sub(/\s+#.*$/, ""); print $1 }' \
    | grep -v '^$'
)
info "packages.txt lists ${#BASE_PKGS[@]} package(s)"
$WITH_OPTIONAL && info "including optional packages" || info "excluding optional packages (use --with-optional to include)"

EXTRA_PKGS=()
if [[ -n "${EXTRA_PKG_FILE:-}" ]]; then
  if [[ -f "$EXTRA_PKG_FILE" ]]; then
    mapfile -t EXTRA_PKGS < <(grep -Ev '^\s*(#|$)' "$EXTRA_PKG_FILE" | grep -v '^$')
    info "EXTRA_PKG_FILE adds ${#EXTRA_PKGS[@]} package(s) from $EXTRA_PKG_FILE"
  else
    warn "EXTRA_PKG_FILE was set but not found: $EXTRA_PKG_FILE (ignoring)"
  fi
fi

#  Dedupe the combined list, preserving first-seen order.
mapfile -t ALL_PKGS < <(printf '%s\n' "${BASE_PKGS[@]}" "${EXTRA_PKGS[@]}" | awk '!seen[$0]++')
info "combined manifest: ${#ALL_PKGS[@]} unique package(s)"

# -----------------------------------------------------------------------------
#  Partition into: already installed / needs pacman / needs AUR
# -----------------------------------------------------------------------------
step "Checking installed state"
ALREADY=(); NEED_PACMAN=(); NEED_AUR=(); UNKNOWN=()
for pkg in "${ALL_PKGS[@]}"; do
  pkg="${pkg%%#*}"; pkg="${pkg// /}"
  [[ -z "$pkg" ]] && continue
  if pacman -Qi "$pkg" &>/dev/null; then
    ALREADY+=("$pkg")
  elif pacman -Si "$pkg" &>/dev/null; then
    NEED_PACMAN+=("$pkg")
  elif command -v yay &>/dev/null && yay -Si "$pkg" &>/dev/null; then
    NEED_AUR+=("$pkg")
  else
    UNKNOWN+=("$pkg")
  fi
done

info "already installed : ${#ALREADY[@]}"
info "need pacman (repo): ${#NEED_PACMAN[@]}"
info "need AUR          : ${#NEED_AUR[@]}"
if ((${#UNKNOWN[@]})); then
  warn "not found in repos OR AUR (check for a rename): ${UNKNOWN[*]}"
fi

if ((${#NEED_PACMAN[@]})); then
  printf '\n%sFrom official repos:%s\n' "$BOLD" "$NC"
  printf '  %s\n' "${NEED_PACMAN[@]}"
fi
if ((${#NEED_AUR[@]})); then
  printf '\n%sFrom the AUR (via yay):%s\n' "$BOLD" "$NC"
  printf '  %s\n' "${NEED_AUR[@]}"
fi

if ((${#NEED_PACMAN[@]} == 0 && ${#NEED_AUR[@]} == 0)); then
  ok "nothing to install; everything in the manifest is already present"
  exit 0
fi

if $DRY_RUN; then
  info "[DRY RUN] would install ${#NEED_PACMAN[@]} repo + ${#NEED_AUR[@]} AUR package(s)"
  exit 0
fi

read -rp "$(printf '%sProceed with installation?%s [y/N] ' "$BOLD" "$NC")" reply
[[ "$reply" == "y" || "$reply" == "Y" ]] || { info "aborted"; exit 0; }

# -----------------------------------------------------------------------------
#  Install
# -----------------------------------------------------------------------------
step "Installing repo packages"
if ((${#NEED_PACMAN[@]})); then
  sudo pacman -S --needed --noconfirm "${NEED_PACMAN[@]}"
  ok "repo packages installed"
else
  info "none needed"
fi

step "Installing AUR packages"
if ((${#NEED_AUR[@]})); then
  if ! command -v yay &>/dev/null; then
    err "yay not found, but AUR packages are required."
    err "Install an AUR helper first, e.g.:"
    err "  sudo pacman -S --needed git base-devel"
    err "  git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si"
    exit 1
  fi
  FAILED=()
  for pkg in "${NEED_AUR[@]}"; do
    info "building $pkg..."
    if ! yay -S --needed --noconfirm "$pkg"; then
      err "failed: $pkg"
      FAILED+=("$pkg")
    fi
  done
  if ((${#FAILED[@]})); then
    warn "the following AUR packages failed to build: ${FAILED[*]}"
    warn "retry individually with: yay -S <pkg>"
  else
    ok "all AUR packages installed"
  fi
else
  info "none needed"
fi

step "Summary"
ok "package installation pass complete"
info "Next: symlink configs (20-symlink.sh), then check 00-preflight.sh output"
info "for the mkinitcpio fix, THEN log into mango for the first time."
