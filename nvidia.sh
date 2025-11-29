#!/bin/bash

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Helpers
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Parse arguments
DRY_RUN=false
for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
done

# Run wrapper
run() {
  if $DRY_RUN; then
    echo "[DRY RUN] $*"
  else
    eval "$@"
  fi
}

# Banner
if command -v figlet &>/dev/null; then
  echo -e "${GREEN}"
  figlet -f smslant "NVIDIA Setup"
  echo -e "${NC}"
else
  echo -e "${GREEN}== NVIDIA Setup ==${NC}"
fi

# Prerequisite check
for bin in gum sudo; do
  if ! command -v "$bin" &>/dev/null; then
    error "Missing dependency: '$bin'. Install it via pacman."
    exit 1
  fi
done

if gum confirm "Do you have an NVIDIA GPU and want to install the proprietary driver?"; then

  # AUR helper handling
  aur_helper="${aur_helper:-yay}"
  HAS_AUR_HELPER=false
  if command -v "$aur_helper" &>/dev/null; then
    HAS_AUR_HELPER=true
  else
    if $DRY_RUN; then
      warn "AUR helper '$aur_helper' not found, but continuing due to --dry-run."
    else
      error "AUR helper '$aur_helper' not found. Install it or set aur_helper explicitly."
      exit 1
    fi
  fi

  # Remove conflicting Hyprland-NVIDIA packages (only if helper available)
  info "Checking for conflicting Hyprland NVIDIA packages..."
  if $HAS_AUR_HELPER && "$aur_helper" -Qs hyprland &>/dev/null; then
    info "Removing conflicting Hyprland-NVIDIA packages..."
    for pkg in hyprland-git hyprland-nvidia hyprland-nvidia-git hyprland-nvidia-hidpi-git; do
      run "$aur_helper -R --noconfirm $pkg 2>/dev/null || true"
    done
    success "Conflicting Hyprland packages removed (if any)."
  else
    info "No conflicting Hyprland packages found or AUR helper unavailable."
  fi

  # Install NVIDIA and VAAPI packages
  info "Installing NVIDIA and VAAPI packages..."
  nvidia_pkgs=(
    nvidia-dkms
    nvidia-utils
    nvidia-settings
    libva
    libva-nvidia-driver-git
  )

  # Install kernel headers for all installed kernels
  if $HAS_AUR_HELPER || $DRY_RUN; then
    for krnl in $(cat /usr/lib/modules/*/pkgbase 2>/dev/null); do
      run "$aur_helper -S --needed --noconfirm ${krnl}-headers"
    done

    # Install driver stack
    run "$aur_helper -S --needed --noconfirm ${nvidia_pkgs[*]}"
    success "NVIDIA packages installation commands issued."
  else
    warn "Skipping NVIDIA package installation because no AUR helper is available."
  fi

  # mkinitcpio: add nvidia modules safely, idempotent
  if ! grep -q 'nvidia_drm' /etc/mkinitcpio.conf 2>/dev/null; then
    info "Updating /etc/mkinitcpio.conf with NVIDIA modules..."
    # If MODULES=() is empty, replace; otherwise prepend modules
    run "sudo sed -Ei 's/^MODULES=\(\)/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf"
    run "sudo sed -Ei 's/^MODULES=\(/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm /' /etc/mkinitcpio.conf"
    success "mkinitcpio.conf updated."
  else
    info "mkinitcpio.conf already contains NVIDIA modules."
  fi

  run "sudo mkinitcpio -P"

  # modprobe config
  conf_file="/etc/modprobe.d/nvidia.conf"
  if [[ ! -f "$conf_file" ]]; then
    info "Creating /etc/modprobe.d/nvidia.conf..."
    run "echo 'options nvidia_drm modeset=1 fbdev=1' | sudo tee $conf_file >/dev/null"
    success "Created modprobe config."
  else
    info "modprobe config $conf_file already exists."
  fi

  # GRUB
  if [[ -f /etc/default/grub ]]; then
    info "Configuring GRUB kernel parameters for NVIDIA..."
    if ! grep -q 'nvidia-drm.modeset=1' /etc/default/grub; then
      run "sudo sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/\"$/ nvidia-drm.modeset=1 nvidia_drm.fbdev=1\"/' /etc/default/grub"
      success "Added NVIDIA kernel params to GRUB_CMDLINE_LINUX_DEFAULT."
    else
      info "GRUB already has NVIDIA kernel params."
    fi
    run "sudo grub-mkconfig -o /boot/grub/grub.cfg"
  else
    info "/etc/default/grub not found; skipping GRUB configuration."
  fi

  # systemd-boot
  if [[ -f /boot/loader/loader.conf ]]; then
    info "Detected systemd-boot. Checking loader entries..."

    shopt -s nullglob
    entries=(/boot/loader/entries/*.conf)
    shopt -u nullglob

    if ((${#entries[@]} == 0)); then
      warn "systemd-boot detected but no loader entries found."
    else
      updated=false
      for entry in "${entries[@]}"; do
        if ! grep -q 'nvidia-drm.modeset=1' "$entry"; then
          info "Updating $entry for NVIDIA params..."
          run "sudo cp \"$entry\" \"$entry.ml4w.bkp\""

          # Extract current options line (without "options " prefix)
          opts=$(grep -E '^options ' "$entry" | sed 's/^options //') || opts=""

          # Strip existing quiet/splash and any previous nvidia* flags
          opts=$(echo "$opts" | sed 's/\bquiet\b//g; s/\bsplash\b//g; s/\bnvidia[^ ]*\b//g')

          new_line="options ${opts} quiet splash nvidia-drm.modeset=1 nvidia_drm.fbdev=1"

          if $DRY_RUN; then
            echo "[DRY RUN] would set options line in $entry to:"
            echo "          $new_line"
          else
            sudo sed -i "s/^options .*/$new_line/" "$entry"
          fi

          updated=true
        fi
      done

      if $updated; then
        success "Updated systemd-boot entries with NVIDIA parameters."
      else
        warn "systemd-boot entries already contain NVIDIA parameters."
      fi
    fi
  fi

  # Blacklist Nouveau
  if gum confirm "Would you like to blacklist the Nouveau driver?"; then
    info "Blacklisting Nouveau..."
    run "echo 'blacklist nouveau' | sudo tee /etc/modprobe.d/nouveau.conf >/dev/null"
    run "echo 'install nouveau /bin/true' | sudo tee /etc/modprobe.d/blacklist.conf >/dev/null"
    success "Nouveau driver blacklisted."
  else
    info "Nouveau blacklisting skipped."
  fi

  success "NVIDIA setup complete. Reboot recommended."

else
  info "NVIDIA setup skipped."
fi
