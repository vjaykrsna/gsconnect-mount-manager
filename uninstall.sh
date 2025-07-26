#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}Uninstalling GSConnect Mount Manager...${NC}"

# Stop and disable service
if systemctl --user is-active gsconnect-mount-manager.service >/dev/null 2>&1; then
    echo -e "${GREEN}Stopping service...${NC}"
    systemctl --user stop gsconnect-mount-manager.service
fi

if systemctl --user is-enabled gsconnect-mount-manager.service >/dev/null 2>&1; then
    echo -e "${GREEN}Disabling service...${NC}"
    systemctl --user disable gsconnect-mount-manager.service
fi

# Remove service file
service_file="$HOME/.config/systemd/user/gsconnect-mount-manager.service"
if [[ -f "$service_file" ]]; then
    rm "$service_file"
    echo -e "${GREEN}Service file removed${NC}"
fi

# Reload systemd
systemctl --user daemon-reload

# Clean up bookmarks
bookmark_file="$HOME/.config/gtk-3.0/bookmarks"
if [[ -f "$bookmark_file" ]]; then
    # Remove GSConnect Mount Manager bookmarks
    grep -v "GSConnect\|gsconnect-mount" "$bookmark_file" > "$bookmark_file.tmp" 2>/dev/null || true
    mv "$bookmark_file.tmp" "$bookmark_file" 2>/dev/null || true
    echo -e "${GREEN}Cleaned up bookmarks${NC}"
fi

# Remove directories
rm -rf ~/.config/gsconnect-mount-manager
rm -rf ~/.gsconnect-mount

echo -e "${GREEN}✅ Uninstallation complete!${NC}"