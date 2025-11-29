#!/bin/bash

# symlink.sh — Link user config and theme directories into /root for consistent theming

# === Colors ===
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }

# === Root Check ===
if [ "$EUID" -ne 0 ]; then
  error "This script must be run as root (use sudo)."
  exit 1
fi

# === Resolve user (used by sudo) ===
USER_HOME=$(eval echo "~$SUDO_USER")
if [ ! -d "$USER_HOME" ]; then
  error "Unable to detect valid user home directory."
  exit 1
fi

# === Directories to Link ===
link_dirs=(
  "$USER_HOME/.config/gtk-3.0"
  "$USER_HOME/.config/gtk-4.0"
  "$USER_HOME/.config/nwg-look"
  "$USER_HOME/.config/qt5ct"
  "$USER_HOME/.config/qt6ct"
  "$USER_HOME/.themes"
  "$USER_HOME/.icons"
)

info "Linking user theme and config directories into /root..."

for src in "${link_dirs[@]}"; do
  dst="/root${src#$USER_HOME}"

  if [ -d "$src" ]; then
    if [ -L "$dst" ]; then
      info "Link already exists: $dst"
    elif [ -e "$dst" ]; then
      warn "$dst exists and is not a symlink. Backing it up to ${dst}.bak"
      mv "$dst" "${dst}.bak"
      ln -s "$src" "$dst"
      success "Linked $src → $dst"
    else
      mkdir -p "$(dirname "$dst")"
      ln -s "$src" "$dst"
      success "Linked $src → $dst"
    fi
  else
    warn "Skipped (not found): $src"
  fi
done

success "Root theming symlinks created successfully."
