#!/usr/bin/env bash
# GSConnect Mount Manager - Debug Collector
# Usage: ./debug_log.sh

set -euo pipefail

# Colors for output
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    NC=$(tput sgr0)
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    NC=""
fi

info()    { printf "%s[INFO]%s %s\n" "$GREEN" "$NC" "$*"; }
warn()    { printf "%s[WARN]%s %s\n" "$YELLOW" "$NC" "$*"; }
error()   { printf "%s[ERROR]%s %s\n" "$RED" "$NC" "$*"; }
debug()   { printf "%s[DEBUG]%s %s\n" "$BLUE" "$NC" "$*"; }

DEBUG_LOG="$HOME/gsmm-debug.log"
CONFIG_DIR="$HOME/.config/gsconnect-mount-manager"
SERVICE="gsconnect-mount-manager.service"

# Clean up any existing debug logs older than 7 days
find "$HOME" -name "gsmm-debug.log*" -mtime +7 -delete 2>/dev/null || true

# Backup existing log if it exists
if [[ -f "$DEBUG_LOG" ]]; then
    mv "$DEBUG_LOG" "${DEBUG_LOG}.$(date +%Y%m%d_%H%M%S).bak"
fi

info "Collecting GSConnect Mount Manager debug info..."
echo "=== GSConnect Mount Manager Debug Report ===" > "$DEBUG_LOG"
date >> "$DEBUG_LOG"
echo >> "$DEBUG_LOG"

echo "=== System Info ===" >> "$DEBUG_LOG"
uname -a >> "$DEBUG_LOG"
echo "Distro: $(lsb_release -d 2>/dev/null | cut -f2 || cat /etc/*release 2>/dev/null | head -1 || echo 'Unknown')" >> "$DEBUG_LOG"
echo "Desktop: $XDG_CURRENT_DESKTOP ($GDMSESSION)" >> "$DEBUG_LOG"
echo "User: $(whoami) ($(id -u))" >> "$DEBUG_LOG"
echo "Home: $HOME" >> "$DEBUG_LOG"
echo >> "$DEBUG_LOG"

echo "=== Environment ===" >> "$DEBUG_LOG"
echo "PATH: $PATH" >> "$DEBUG_LOG"
echo "SHELL: $SHELL" >> "$DEBUG_LOG"
echo "TERM: $TERM" >> "$DEBUG_LOG"
echo "LANG: $LANG" >> "$DEBUG_LOG"
echo >> "$DEBUG_LOG"

echo "=== GSConnect/KDE Connect Status ===" >> "$DEBUG_LOG"
if command -v gdbus >/dev/null 2>&1; then
    echo "GSConnect extension status:" >> "$DEBUG_LOG"
    gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell --method org.gnome.Shell.Extensions.GetExtensionInfo gsconnect@andyholmes.github.io 2>/dev/null >> "$DEBUG_LOG" || echo "GSConnect extension not found or not running" >> "$DEBUG_LOG"

    echo "KDE Connect devices:" >> "$DEBUG_LOG"
    gdbus call --session --dest org.kde.kdeconnect --object-path /modules/kdeconnect --method org.kde.kdeconnect.daemon.devices 2>/dev/null >> "$DEBUG_LOG" || echo "KDE Connect daemon not running" >> "$DEBUG_LOG"
else
    echo "gdbus not available for extension checks" >> "$DEBUG_LOG"
fi
echo >> "$DEBUG_LOG"

echo "=== Installed Packages ===" >> "$DEBUG_LOG"
for cmd in gvfs-mount gio nautilus notify-send dconf find gdbus; do
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "$cmd: $(command -v "$cmd")" >> "$DEBUG_LOG"
        if [[ "$cmd" == "gvfs-mount" ]] || [[ "$cmd" == "gio" ]]; then
            "$cmd" --version 2>/dev/null >> "$DEBUG_LOG" || true
        elif [[ "$cmd" == "nautilus" ]]; then
            "$cmd" --version 2>/dev/null >> "$DEBUG_LOG" || true
        fi
    else
        echo "$cmd: NOT FOUND" >> "$DEBUG_LOG"
    fi
done
echo >> "$DEBUG_LOG"

echo "=== Config ===" >> "$DEBUG_LOG"
if [[ -f "$CONFIG_DIR/config.conf" ]]; then
    cat "$CONFIG_DIR/config.conf" >> "$DEBUG_LOG"
else
    echo "(no config found)" >> "$DEBUG_LOG"
fi
echo >> "$DEBUG_LOG"

echo "=== Enabling DEBUG mode temporarily ===" >> "$DEBUG_LOG"
if [[ -f "$CONFIG_DIR/config.conf" ]]; then
    # Backup original config
    cp "$CONFIG_DIR/config.conf" "$CONFIG_DIR/config.conf.debug_bak"
    info "Backed up original config"

    # Enable debug mode
    sed -i 's/^LOG_LEVEL=.*/LOG_LEVEL=DEBUG/' "$CONFIG_DIR/config.conf"
    echo "LOG_LEVEL changed to DEBUG" >> "$DEBUG_LOG"

    # Restart service to apply changes
    if systemctl --user restart "$SERVICE" 2>/dev/null; then
        info "Service restarted with DEBUG mode"
        sleep 3  # Give service time to start up
        echo "Service restarted successfully" >> "$DEBUG_LOG"
    else
        warn "Failed to restart service (may not be installed)"
        echo "Service restart failed" >> "$DEBUG_LOG"
    fi
else
    warn "No config file found, skipping DEBUG mode enable"
    echo "No config file found" >> "$DEBUG_LOG"
fi
echo >> "$DEBUG_LOG"

echo "=== Service Status ===" >> "$DEBUG_LOG"
if command -v systemctl >/dev/null 2>&1; then
    systemctl --user status "$SERVICE" >> "$DEBUG_LOG" 2>&1 || echo "Service not found or not running" >> "$DEBUG_LOG"
    echo >> "$DEBUG_LOG"
    echo "=== Service Details ===" >> "$DEBUG_LOG"
    systemctl --user show "$SERVICE" 2>/dev/null | grep -E "(ActiveState|SubState|ExecMainStatus|StatusErrno)" >> "$DEBUG_LOG" || echo "Service details unavailable" >> "$DEBUG_LOG"
else
    echo "systemctl not available" >> "$DEBUG_LOG"
fi
echo >> "$DEBUG_LOG"

echo "=== Journal Logs (last 300 lines) ===" >> "$DEBUG_LOG"
if command -v journalctl >/dev/null 2>&1; then
    journalctl --user -u "$SERVICE" -n 300 --no-pager >> "$DEBUG_LOG" 2>&1 || echo "(no journal logs yet)" >> "$DEBUG_LOG"
else
    echo "journalctl not available" >> "$DEBUG_LOG"
fi
echo >> "$DEBUG_LOG"

echo "=== Internal Logs ===" >> "$DEBUG_LOG"
if [[ -f "$CONFIG_DIR/gsconnect-mount-manager.log" ]]; then
    cat "$CONFIG_DIR/gsconnect-mount-manager.log" >> "$DEBUG_LOG"
else
    echo "(no internal log yet)" >> "$DEBUG_LOG"
fi
echo >> "$DEBUG_LOG"

# Restore original config
if [[ -f "$CONFIG_DIR/config.conf.debug_bak" ]]; then
    info "Restoring original config..."
    mv "$CONFIG_DIR/config.conf.debug_bak" "$CONFIG_DIR/config.conf"
    if systemctl --user restart "$SERVICE" 2>/dev/null; then
        info "Service restarted with original config"
    else
        warn "Could not restart service (may not be installed)"
    fi
fi

echo "=== Debug Collection Complete ===" >> "$DEBUG_LOG"
echo "Log saved locally at: $DEBUG_LOG" >> "$DEBUG_LOG"
echo "File size: $(du -h "$DEBUG_LOG" | cut -f1)" >> "$DEBUG_LOG"

# Upload log if curl is available
if command -v curl >/dev/null 2>&1; then
    info "Uploading debug log..."
    if URL=$(cat "$DEBUG_LOG" | curl -s -F 'file=@-' https://0x0.st); then
        info "Debug log uploaded successfully!"
        echo "Share this link with developers:"
        echo "  $URL"
        echo
        echo "Local copy also available at: $DEBUG_LOG"
    else
        error "Failed to upload debug log"
        echo "Local debug log available at: $DEBUG_LOG"
    fi
else
    warn "curl not available, skipping upload"
    echo "Local debug log available at: $DEBUG_LOG"
fi
