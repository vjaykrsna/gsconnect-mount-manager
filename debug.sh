#!/usr/bin/env bash
# GSConnect Mount Manager - Debug Collector
# Usage: ./debug.sh

set -euo pipefail

# --- Configuration ---
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gmm"
CONFIG_FILE="$CONFIG_DIR/config.conf"
SERVICE_NAME="gmm.service"
DEBUG_LOG="gmm-debug.log"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { printf "%b[INFO]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$*"; }
error() { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$*"; }

# --- Cleanup Function ---
cleanup() {
    if [[ -f "$CONFIG_FILE.debug_bak" ]]; then
        info "Restoring original configuration..."
        mv "$CONFIG_FILE.debug_bak" "$CONFIG_FILE"
        # Try to restart, but don't fail if it doesn't exist
        systemctl --user restart "$SERVICE_NAME" &>/dev/null || warn "Service not running, could not restart with original config."
        info "Service restarted with original config."
    fi
}

# --- Main Logic ---
main() {
    # Set trap to ensure cleanup happens on exit
    trap cleanup EXIT

    # Check if running from the correct directory
    if [[ ! -f "gmm-main.sh" ]]; then
        error "This script must be run from the project's root directory."
        exit 1
    fi

    # Clear previous debug log
    rm -f "$DEBUG_LOG"

    info "Collecting GMM (GSConnect Mount Manager) debug info..."
    info "Log file will be saved to: $DEBUG_LOG"

    # --- Header ---
    {
        echo "================================================="
        echo "== GMM (GSConnect Mount Manager) Debug Report"
        echo "================================================="
        echo "Date: $(date)"
        echo "Script Version: 1.0"
        echo
    } >> "$DEBUG_LOG"

    # --- System and Environment ---
    {
        echo "--- System Information ---"
        uname -a
        echo "Distro: $(lsb_release -ds 2>/dev/null || cat /etc/*release 2>/dev/null | head -n1 || echo 'Unknown')"
        echo "Desktop: $XDG_CURRENT_DESKTOP ($GDMSESSION)"
        echo "User: $(whoami) (ID: $(id -u))"
        echo
        echo "--- Environment ---"
        printenv | grep -E '^(PATH|SHELL|TERM|LANG|XDG_.*|GDM.*)' || true
        echo
    } >> "$DEBUG_LOG"

    # --- Dependencies ---
    {
        echo "--- Dependencies Check ---"
        for cmd in systemctl gio dconf find gdbus; do
            printf "% -15s: %s\n" "$cmd" "$(command -v "$cmd" || echo 'NOT FOUND')"
        done
        echo
    } >> "$DEBUG_LOG"

    # --- GSConnect/KDEConnect Status ---
    {
        echo "--- GSConnect / KDE Connect Status ---"
        if command -v gdbus >/dev/null;
        then
            echo "[GSConnect Extension Info]"
            gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell --method org.gnome.Shell.Extensions.GetExtensionInfo gsconnect@andyholmes.github.io 2>/dev/null || echo "Could not get GSConnect info."
            echo
            echo "[KDE Connect Devices]"
            gdbus call --session --dest org.kde.kdeconnect --object-path /modules/kdeconnect --method org.kde.kdeconnect.daemon.devices 2>/dev/null || echo "Could not list KDE Connect devices."
        else
            echo "gdbus command not found. Cannot check service status."
        fi
        echo
    } >> "$DEBUG_LOG"

    # --- App Configuration ---
    {
        echo "--- Configuration File ($CONFIG_FILE) ---"
        if [[ -f "$CONFIG_FILE" ]]; then
            cat "$CONFIG_FILE"
        else
            echo "Configuration file not found."
        fi
        echo
    } >> "$DEBUG_LOG"

    # --- Temporarily Enable Debug Logging ---
    if [[ -f "$CONFIG_FILE" ]]; then
        info "Temporarily enabling DEBUG log level..."
        cp "$CONFIG_FILE" "$CONFIG_FILE.debug_bak"
        # Use sed to change LOG_LEVEL or add it if it doesn't exist
        if grep -q "^LOG_LEVEL=" "$CONFIG_FILE"; then
            sed -i 's/^LOG_LEVEL=.*/LOG_LEVEL=DEBUG/' "$CONFIG_FILE"
        else
            echo "LOG_LEVEL=DEBUG" >> "$CONFIG_FILE"
        fi
        
        info "Restarting service to apply debug settings..."
        if systemctl --user restart "$SERVICE_NAME"; then
            info "Service restarted. Waiting 5 seconds for logs..."
            sleep 5
        else
            warn "Service could not be restarted. It may not be installed or running."
        fi
    else
        warn "No config file found. Cannot enable debug logging."
    fi

    # --- Logs and Service Status ---
    {
        LOG_FILE="$CONFIG_DIR/gmm.log"
        echo "--- Service Status (systemctl) ---"
        systemctl --user status --no-pager "$SERVICE_NAME" 2>&1 || echo "Service not found."
        echo
        echo "--- Journal Logs (last 100 lines) ---"
        journalctl --user -u "$SERVICE_NAME" -n 100 --no-pager 2>&1 || true
        echo
        echo "--- Internal Log File ($LOG_FILE) ---"
        if [[ -f "$LOG_FILE" ]]; then
            cat "$LOG_FILE"
        else
            echo "Internal log file not found."
        fi
        echo
    } >> "$DEBUG_LOG"

    info "Debug collection complete."

    # --- Upload to 0x0.st ---
    if command -v curl >/dev/null;
    then
        info "Uploading log file..."
        if URL=$(curl -s -F "file=@$DEBUG_LOG" https://0x0.st);
        then
            info "Debug log uploaded successfully!"
            echo "Please share this URL with the developers: $URL"
        else
            error "Failed to upload debug log."
            echo "You can find the log file at: $DEBUG_LOG"
        fi
    else
        warn "curl is not installed. Cannot upload log."
        echo "Please share the contents of the log file: $DEBUG_LOG"
    fi
}

main
