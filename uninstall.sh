#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# GSConnect Mount Manager Uninstaller
# -------------------------------------------------------------------

# --- Configuration ---
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gmm"
SERVICE_NAME="gmm.service"
SERVICE_FILE="$HOME/.config/systemd/user/$SERVICE_NAME"
LOCK_FILE="/tmp/gmm.lock"
SCRIPT_PATH="$CONFIG_DIR/gmm-main.sh"

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { printf "%b[INFO] %s%b\n"  "$GREEN" "$*" "$NC"; }
warn()  { printf "%b[WARN] %s%b\n"  "$YELLOW" "$*" "$NC"; }
error() { printf "%b[ERROR] %s%b\n" "$RED" "$*" "$NC"; }

# --- Functions ---
stop_and_disable_service() {
    if ! command -v systemctl >/dev/null 2>&1; then
        warn "systemctl not found. Skipping service removal."
        return
    fi

    info "Stopping and disabling systemd user service..."
    if systemctl --user cat "$SERVICE_NAME" >/dev/null 2>&1; then
        systemctl --user stop "$SERVICE_NAME" || warn "Service was not running."
        systemctl --user disable "$SERVICE_NAME" || warn "Service was not enabled."
        info "Service stopped and disabled."
    else
        warn "Service not found. It might have been already removed."
    fi
}

remove_service_file() {
    if [[ -f "$SERVICE_FILE" ]]; then
        info "Removing systemd service file..."
        rm -f "$SERVICE_FILE"
        systemctl --user daemon-reload || warn "Failed to reload systemd daemon."
        info "Systemd daemon reloaded."
    fi
}

remove_config_directory() {
    if [[ -d "$CONFIG_DIR" ]]; then
        info "Removing configuration directory..."
        rm -rf "$CONFIG_DIR"
        info "Directory removed: $CONFIG_DIR"
    fi
}

run_script_cleanup() {
    if [[ -x "$SCRIPT_PATH" ]]; then
        info "Running cleanup task in the main script..."
        # Run the script's own cleanup function to remove bookmarks and symlinks
        "$SCRIPT_PATH" --uninstall-cleanup || warn "The script's cleanup function reported an error."
    else
        warn "Main script not found or not executable at $SCRIPT_PATH. Skipping artifact cleanup."
        warn "You may need to manually remove any created bookmarks or directories in $HOME."
    fi
}

remove_lock_file() {
    if [[ -f "$LOCK_FILE" ]]; then
        info "Removing lock file..."
        rm -f "$LOCK_FILE"
    fi
}

# --- Main Uninstallation Logic ---
main() {
    info "Starting GMM (GSConnect Mount Manager) uninstallation..."
    
    read -p "Are you sure you want to uninstall? This will remove all configuration and service files. (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "Uninstallation cancelled."
        exit 0
    fi

    stop_and_disable_service
    run_script_cleanup
    remove_service_file
    remove_config_directory
    remove_lock_file

    info "-------------------------------------------------"
    info "Uninstallation complete!"
    info "All related files and services have been removed."
    info "-------------------------------------------------"
}

main
