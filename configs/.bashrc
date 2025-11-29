#
# ~/.bashrc
#

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

# Load all modular bash config files from ~/.config/bashrc/
for config_file in ~/.config/bashrc/*; do
    # Only source files that exist and are regular files
    [ -f "$config_file" ] && source "$config_file"
done

alias ls='ls --color=auto'
alias grep='grep --color=auto'
PS1='[\u@\h \W]\$ '
