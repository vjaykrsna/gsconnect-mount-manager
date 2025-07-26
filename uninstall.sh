#!/bin/sh
set -eu

# Colors for output
RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[1;33m')
NC=$(printf '\033[0m')

printf "%sUninstalling GSConnect Mount Manager...%s\n" "$YELLOW" "$NC"

# Stop and disable service
if systemctl --user is-active gsconnect-mount-manager.service >/dev/null 2>&1; then
    printf "%sStopping service...%s\n" "$GREEN" "$NC"
    systemctl --user stop gsconnect-mount-manager.service
fi

if systemctl --user is-enabled gsconnect-mount-manager.service >/dev/null 2>&1; then
    printf "%sDisabling service...%s\n" "$GREEN" "$NC"
    systemctl --user disable gsconnect-mount-manager.service
fi

# Remove service file
service_file="$HOME/.config/systemd/user/gsconnect-mount-manager.service"
if [ -f "$service_file" ]; then
    rm "$service_file"
    printf "%sService file removed%s\n" "$GREEN" "$NC"
fi

# Reload systemd
systemctl --user daemon-reload

# Clean up bookmarks
bookmark_file="$HOME/.config/gtk-3.0/bookmarks"
if [ -f "$bookmark_file" ]; then
    # Remove GSConnect Mount Manager bookmarks
    grep -v "GSConnect\|gsconnect-mount" "$bookmark_file" > "$bookmark_file.tmp" 2>/dev/null || true
    mv "$bookmark_file.tmp" "$bookmark_file" 2>/dev/null || true
    printf "%sCleaned up bookmarks%s\n" "$GREEN" "$NC"
fi

# Remove directories
rm -rf "$HOME/.config/gsconnect-mount-manager"
rm -rf "$HOME/.gsconnect-mount"

printf "%s✅ Uninstallation complete!%s\n" "$GREEN" "$NC"
