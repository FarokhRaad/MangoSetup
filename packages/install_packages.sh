#!/bin/bash

# === Color and Logging Setup ===
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }

# === Dry-Run Mode Support ===
DRY_RUN=false
for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
done

run() {
  if $DRY_RUN; then
    echo "[DRY RUN] $*"
  else
    eval "$@"
  fi
}

# === Visual Header ===
if command -v figlet &>/dev/null; then
  echo -e "${GREEN}"
  figlet -f slant "Package Install"
  echo -e "${NC}"
else
  echo -e "${GREEN}== Package Install ==${NC}"
fi

# === File Setup ===
pkg_file="packages.txt"

if [[ ! -f "$pkg_file" ]]; then
  error "Missing file: $pkg_file"
  exit 1
fi

# Read file into array, ignore empty lines and comments
mapfile -t all_packages < <(grep -Ev '^\s*($|#)' "$pkg_file")

if [[ ${#all_packages[@]} -eq 0 ]]; then
  warn "No packages found in $pkg_file"
fi

# === Helper: check if package is in official repos ===
is_pacman_pkg() {
  local pkg="$1"
  pacman -Si "$pkg" &>/dev/null
}

# === Yay Bootstrap, only when needed ===
ensure_yay() {
  if command -v yay &>/dev/null; then
    return 0
  fi

  info "yay not found. Installing yay from AUR..."
  run "sudo pacman -S --needed --noconfirm base-devel git"

  workdir=$(mktemp -d)
  run "git clone https://aur.archlinux.org/yay.git \"$workdir/yay\""
  run "cd \"$workdir/yay\" && makepkg -si --noconfirm"
  run "cd ~ && rm -rf \"$workdir\""

  if command -v yay &>/dev/null; then
    success "yay installed successfully."
  else
    error "Failed to install yay."
    exit 1
  fi
}

# === Install packages, auto routing between pacman and yay ===
install_all_packages() {
  for pkg in "${all_packages[@]}"; do
    if is_pacman_pkg "$pkg"; then
      info "Installing repo package with pacman: $pkg"
      run "sudo pacman -S --needed --noconfirm \"$pkg\""
    else
      info "Installing AUR package with yay: $pkg"
      ensure_yay
      run "yay -S --needed --noconfirm \"$pkg\""
    fi
  done
}

install_all_packages

success "All packages processed."
exit 0
