#!/usr/bin/env bash
set -euo pipefail

# -------- Colors --------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { printf "%b%s%b\n" "$1" "$2" "$NC"; }

# -------- Paths --------
SERVICE_FILE="$HOME/.config/systemd/user/gsconnect-mount-manager.service"
CONFIG_DIR="$HOME/.config/gsconnect-mount-manager"
MOUNT_DIR="$HOME/.gsconnect-mount"
GTK_BOOKMARKS="$HOME/.config/gtk-3.0/bookmarks"
KDE_BOOKMARKS="$HOME/.local/share/user-places.xbel"

log "$YELLOW" "Uninstalling GSConnect Mount Manager..."

# -------- Stop & disable service --------
if command -v systemctl &>/dev/null; then
    if systemctl --user is-active gsconnect-mount-manager.service &>/dev/null; then
        log "$GREEN" "Stopping service..."
        systemctl --user stop gsconnect-mount-manager.service
    fi

    if systemctl --user is-enabled gsconnect-mount-manager.service &>/dev/null; then
        log "$GREEN" "Disabling service..."
        systemctl --user disable gsconnect-mount-manager.service
    fi

    if [[ -f "$SERVICE_FILE" ]]; then
        rm -f "$SERVICE_FILE"
        log "$GREEN" "Service file removed"
    fi

    systemctl --user daemon-reload
fi

# -------- Remove bookmarks --------
if [[ -f "$GTK_BOOKMARKS" ]]; then
    tmp=$(mktemp)
    grep -v "gsconnect-mount" "$GTK_BOOKMARKS" > "$tmp" && mv "$tmp" "$GTK_BOOKMARKS"
    log "$GREEN" "Cleaned GTK bookmarks"
fi

if command -v kwriteconfig5 &>/dev/null; then
    kwriteconfig5 --file "$KDE_BOOKMARKS" --group "Places" --key "GSConnectMount*" "" 2>/dev/null || \
        log "$YELLOW" "Failed to clean KDE bookmarks"
fi

# -------- Remove directories --------
for dir in "$CONFIG_DIR" "$MOUNT_DIR"; do
    if [[ -d "$dir" ]]; then
        rm -rf "$dir"
        log "$GREEN" "Removed $dir"
    fi
done

log "$GREEN" "✅ Uninstallation complete!"
