#!/bin/bash

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions for consistent messaging
function success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
function error()   { echo -e "${RED}[ERROR]${NC} $1"; }
function info()    { echo -e "${BLUE}[INFO]${NC} $1"; }

# Show banner
figlet -f slant "YAY Installer"
echo

# Ensure not running as root
if [ "$EUID" -eq 0 ]; then
  error "Please do not run this script as root."
  exit 1
fi

# Check if sudo is available
if ! command -v sudo &>/dev/null; then
  error "'sudo' is not installed. Please install it first: pacman -S sudo"
  exit 1
fi

# Update system and install required packages
info "Updating system and installing 'base-devel' and 'git'..."
sudo pacman -Syu --needed --noconfirm base-devel git
if [ $? -eq 0 ]; then
  success "System updated and required packages installed."
else
  error "Failed to update system or install base-devel/git."
  exit 1
fi

# Apply parallel build optimization
threads=$(nproc)
info "Configuring parallel build: using $threads threads for makepkg..."
sudo sed -i "s/^#MAKEFLAGS=.*/MAKEFLAGS=\"-j$threads\"/" /etc/makepkg.conf
sudo sed -i "s/^MAKEFLAGS=.*/MAKEFLAGS=\"-j$threads\"/" /etc/makepkg.conf
success "Parallel build flags updated in /etc/makepkg.conf"

# Prepare temporary directory
workdir=$(mktemp -d -t yay-install-XXXX)
cd "$workdir" || { error "Could not change to temp directory."; exit 1; }

# Clone yay repo
info "Cloning yay from AUR..."
git clone https://aur.archlinux.org/yay.git
if [ $? -eq 0 ]; then
  success "yay repository cloned successfully."
else
  error "Failed to clone yay repository."
  exit 1
fi

# Build and install yay
cd yay || { error "yay directory not found."; exit 1; }
info "Building and installing yay..."
export MAKEFLAGS="-j$threads"
makepkg -sci --noconfirm --needed
if [ $? -eq 0 ]; then
  success "yay built and installed successfully."
else
  error "yay installation failed."
  exit 1
fi

# Cleanup
cd ~
rm -rf "$workdir"
success "Temporary files cleaned up."

# Verify yay installation
if yay --version &>/dev/null; then
  echo
  figlet -f small "yay is ready!"
  echo -e "${GREEN}You can now install AUR packages using:${NC} yay -S <package-name>"
else
  error "yay verification failed after installation."
  exit 1
fi
