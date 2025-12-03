#!/bin/bash

# ========== Export compositor environment into systemd and dbus ==========

# Import relevant session variables into the systemd user manager
systemctl --user import-environment \
    WAYLAND_DISPLAY \
    XDG_CURRENT_DESKTOP XDG_CURRENT_SESSION \
    XDG_SESSION_TYPE XDG_SESSION_DESKTOP \
    DESKTOP_SESSION \
    QT_QPA_PLATFORM QT_QPA_PLATFORMTHEME \
    XDG_MENU_PREFIX \
    GDK_BACKEND 

    

# Update dbus activation environment with the same set
dbus-update-activation-environment --systemd \
    WAYLAND_DISPLAY \
    XDG_CURRENT_DESKTOP XDG_CURRENT_SESSION \
    XDG_SESSION_TYPE XDG_SESSION_DESKTOP \
    DESKTOP_SESSION \
    QT_QPA_PLATFORM QT_QPA_PLATFORMTHEME \
    XDG_MENU_PREFIX \
    GDK_BACKEND 
    



# ========== Misc =========

# Move focus to primary monitor on startup
mmsg -d focusmon,HDMI-A-1 >/dev/null 2>&1 &

# Clipboard manager
wl-paste --watch cliphist store >/dev/null 2>&1 &

# Dolphin Open With... context menu
XDG_MENU_PREFIX=arch- kbuildsycoca6 --noincremental >/dev/null 2>&1 &

# DankMaterialShell
dms run >/dev/null 2>&1 &


# ========== User Applications =========
# Solaar
solaar -w hide >/dev/null 2>&1 &
# Ferdium
ferdium --start-in-tray >/dev/null 2>&1 &
# Brisk download manager
# brisk --from-startup >/dev/null 2>&1 &