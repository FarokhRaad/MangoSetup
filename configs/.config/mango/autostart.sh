#!/bin/bash

# ========== XDG Environment Variables ==========
# Export all relevant environment variables to systemd and dbus for proper portal functionality
dbus-update-activation-environment --systemd \
    WAYLAND_DISPLAY \
    XDG_CURRENT_DESKTOP=wlroots \
    XDG_SESSION_TYPE=wayland \
    XDG_SESSION_DESKTOP=wlroots &

# ========== XDG Desktop Portal ==========
# Start the desktop portal backend for screen sharing, file pickers, etc.
# Uncomment the portal that matches your toolkit preference:
# /usr/libexec/xdg-desktop-portal-wlr &        # For wlroots-based compositors
# /usr/libexec/xdg-desktop-portal-gtk &        # For GTK-based applications
# Note: xdg-desktop-portal itself is usually auto-started by dbus

# ========== PipeWire Session Manager ==========
# WirePlumber is typically started automatically by user systemd services
# Uncomment only if you need manual startup:
# /usr/bin/wireplumber &

# Move focus to primary monitor on startup
mmsg -d focusmon,HDMI-A-1 >/dev/null 2>&1 &

# Noctalia Shell
# qs -c noctalia-shell >/dev/null 2>&1 &

# DankMaterialShell
dms run >/dev/null 2>&1 &

# Polkit authentication agent
/usr/lib/mate-polkit/polkit-mate-authentication-agent-1 >/dev/null 2>&1 &

# Clipboard manager
wl-paste --watch cliphist store >/dev/null 2>&1 &

# Dolphin Open With... context menu
XDG_MENU_PREFIX=arch- kbuildsycoca6 --noincremental >/dev/null 2>&1 &


# ========== User Applications =========

# Solaar
solaar -w hide >/dev/null 2>&1 &

# Ferdium
ferdium --start-in-tray >/dev/null 2>&1 &

# Persepolis download manager
persepolis --tray >/dev/null 2>&1 &