# -----------------------------------------------------
# Modular Zsh configuration loader
#
# You can define your custom configuration by adding
# files in ~/.config/zshrc
# -----------------------------------------------------

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

# Load all modular zsh config files from ~/.config/zshrc/
for config_file in ~/.config/zshrc/*; do
    # Only source files that exist and are regular files
    [ -f "$config_file" ] && source "$config_file"
done
