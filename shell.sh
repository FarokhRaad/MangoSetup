#!/usr/bin/env bash
set -e

# ============================
# Color Formatting
# ============================
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }

# ============================
# Dry-run support
# ============================
DRY_RUN=false
for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
done

run() {
  if $DRY_RUN; then
    echo "[DRY RUN] would run: $*"
  else
    eval "$@"
  fi
}

# ============================
# Privileges
# ============================
if [[ $EUID -ne 0 ]]; then
  SUDO="sudo"
else
  SUDO=""
fi

sleep 1
clear

# ============================
# UI Header
# ============================
if command -v figlet >/dev/null 2>&1; then
  figlet -f smslant "Shell"
else
  echo "====== Shell Selection ======"
fi

echo ":: Select your default shell"
echo

# ============================
# Selection
# ============================
if command -v gum >/dev/null 2>&1; then
  shell=$(gum choose "bash" "zsh" "Cancel")
else
  echo "1) bash"
  echo "2) zsh"
  echo "3) Cancel"
  read -rp "Enter choice [1-3]: " choice
  case "$choice" in
    1) shell="bash" ;;
    2) shell="zsh" ;;
    *) shell="Cancel" ;;
  esac
fi

# ============================
# Package helpers
# ============================
ensure_repo_pkg() {
  local pkg="$1"
  if pacman -Qi "$pkg" >/dev/null 2>&1; then
    info "$pkg already installed"
  else
    info "Installing $pkg"
    run "$SUDO pacman -S --needed --noconfirm $pkg"
  fi
}

ensure_aur_pkg() {
  local pkg="$1"

  if pacman -Qi "$pkg" >/dev/null 2>&1; then
    info "$pkg already installed"
    return
  fi

  if ! command -v yay >/dev/null 2>&1; then
    warn "yay not installed. Cannot install $pkg automatically."
    warn "Install yay manually or install $pkg later."
    return
  fi

  info "Installing AUR package: $pkg"
  run "yay -S --needed --noconfirm $pkg"
}

# ============================
# Shell change handler
# ============================
change_shell() {
  local target_shell="$1"

  if ! command -v "$target_shell" >/dev/null 2>&1; then
    error "$target_shell is not installed"
    exit 1
  fi

  local shell_path
  shell_path=$(command -v "$target_shell")

  info "Changing login shell to $shell_path"

  if $DRY_RUN; then
    echo "[DRY RUN] would run: chsh -s $shell_path"
    return
  fi

  local attempts=0
  while ! chsh -s "$shell_path"; do
    attempts=$((attempts + 1))
    if (( attempts >= 3 )); then
      error "Failed to change shell after 3 attempts."
      exit 1
    fi
    echo "Authentication failed. Try again..."
    sleep 1
  done

  success "Shell changed to: $target_shell"
}

# ============================
# Install oh-my-posh
# ============================
install_oh_my_posh() {
  if command -v oh-my-posh >/dev/null 2>&1; then
    info "oh-my-posh already installed."
    return
  fi

  info "Installing oh-my-posh via official install script (curl)"
  run "curl -s https://ohmyposh.dev/install.sh | bash -s"
  success "oh-my-posh installed."
}

# ============================
# oh-my-zsh + plugin install
# ============================
install_oh_my_zsh_and_plugins() {
  if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
    info "Installing oh-my-zsh"
    run "sh -c \"\$(wget -O- https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)\" '' --unattended"
  else
    info "oh-my-zsh already installed."
  fi

  ensure_repo_pkg "zsh-autosuggestions"
  ensure_repo_pkg "zsh-syntax-highlighting"
  ensure_aur_pkg  "zsh-fast-syntax-highlighting"

}

# ============================
# Execution Branches
# ============================
if [[ "$shell" == "bash" ]]; then
  ensure_repo_pkg "bash"
  change_shell "bash"
  install_oh_my_posh

elif [[ "$shell" == "zsh" ]]; then
  ensure_repo_pkg "zsh"
  change_shell "zsh"
  install_oh_my_posh
  install_oh_my_zsh_and_plugins

else
  echo ":: Shell change canceled."
  exit 0
fi

if command -v gum >/dev/null 2>&1; then
  gum spin --spinner dot --title "Log out and back in (or reboot) to apply the change." -- sleep 2
else
  echo ":: Log out and back in to activate the shell change."
fi

success "Done."
