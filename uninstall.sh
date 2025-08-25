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
    # Remove GSConnect Mount Manager bookmarks more precisely
    # Create a temporary file to store bookmarks we want to keep
    grep -v "gsconnect-mount" "$bookmark_file" > "$bookmark_file.tmp.keep" 2>/dev/null || true
    
    # Check if the file was actually modified (has fewer lines)
    if [ -f "$bookmark_file.tmp.keep" ]; then
        # Only replace the original file if we actually removed something
        if [ "$(wc -l < "$bookmark_file" 2>/dev/null || echo 0)" -gt "$(wc -l < "$bookmark_file.tmp.keep" 2>/dev/null || echo 0)" ]; then
            mv "$bookmark_file.tmp.keep" "$bookmark_file" 2>/dev/null || true
            printf "%sCleaned up GTK bookmarks%s\n" "$GREEN" "$NC"
        else
            # No bookmarks were removed, clean up temp file
            rm -f "$bookmark_file.tmp.keep" 2>/dev/null || true
        fi
    fi
fi

# Try to clean up KDE bookmarks if kwriteconfig5 is available
if command -v kwriteconfig5 >/dev/null 2>&1; then
    # Remove KDE bookmarks related to GSConnect Mount Manager
    # Note: This is a simplified approach. A more thorough cleanup would parse the XML file.
    kwriteconfig5 --file ~/.local/share/user-places.xbel --group "Places" --key "GSConnectMount*" "" 2>/dev/null || true
    printf "%sCleaned up KDE bookmarks%s\n" "$GREEN" "$NC"
fi

# Remove directories
# Add safety checks to ensure we're not removing unintended directories
if [ -n "$HOME" ] && [ -d "$HOME/.config/gsconnect-mount-manager" ]; then
    rm -rf "$HOME/.config/gsconnect-mount-manager"
fi
if [ -n "$HOME" ] && [ -d "$HOME/.gsconnect-mount" ]; then
    rm -rf "$HOME/.gsconnect-mount"
fi

printf "%s✅ Uninstallation complete!%s\n" "$GREEN" "$NC"
