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
CONFIG_FILE="$CONFIG_DIR/gmm.conf"

# Source the library for shared functions
if [[ -f "$CONFIG_DIR/gmm-lib.sh" ]]; then
    source "$CONFIG_DIR/gmm-lib.sh"
elif [[ -f "./gmm-lib.sh" ]]; then
    source "./gmm-lib.sh"
else
    # Fallback logging functions if library not found
    info()  { echo "[INFO]  $*"; }
    warn()  { echo "[WARN]  $*"; }
    error() { echo "[ERROR] $*"; }
    exit 1
fi

# Override LOG_FILE for uninstaller - use a location that won't be removed
LOG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/gmm-uninstall.log"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# Simple logging functions that use the shared log function
info() { log "INFO"  "$*"; }
warn()  { log "WARN"  "$*"; }
error() { log "ERROR" "$*"; }

# --- Functions ---
stop_and_disable_service() {
    if ! command -v systemctl >/dev/null 2>&1; then
        warn "systemctl not found. Skipping service removal."
        return
    fi

    info "Stopping and disabling systemd user service..."
    if systemctl --user cat "$SERVICE_NAME" >/dev/null 2>&1; then
        systemctl --user stop "$SERVICE_NAME" || warn "Service $SERVICE_NAME was not running."
        systemctl --user disable "$SERVICE_NAME" || warn "Service $SERVICE_NAME was not enabled."
        info "Service $SERVICE_NAME stopped and disabled."
    else
        warn "Service $SERVICE_NAME not found. It might have been already removed."
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

remove_symlink() {
    local symlink_path="$HOME/.config/systemd/user/default.target.wants/$SERVICE_NAME"
    if [[ -L "$symlink_path" ]]; then
        info "Removing systemd service symlink..."
        rm -f "$symlink_path"
        info "Symlink removed: $symlink_path"
    else
        warn "Systemd service symlink not found: $symlink_path"
    fi
}

remove_config_directory() {
    if [[ -d "$CONFIG_DIR" ]]; then
        # Extra safety: only remove if CONFIG_DIR is under XDG_CONFIG_HOME or $HOME
        local canonical_config
        if canonical_config=$(realpath -m "$CONFIG_DIR" 2>/dev/null); then
            case "$canonical_config" in
                "${XDG_CONFIG_HOME:-$HOME/.config}/gmm"*|"$HOME/.config/gmm"*)
                    info "Removing configuration directory..."
                    rm -rf -- "$CONFIG_DIR"
                    info "Directory removed: $CONFIG_DIR"
                    ;;
                *)
                    warn "Refusing to remove configuration directory outside allowed config paths: $CONFIG_DIR"
                    ;;
            esac
        else
            warn "Could not canonicalize $CONFIG_DIR; skipping removal."
        fi
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
    remove_symlink
    remove_lock_file
    remove_config_directory

    info "-------------------------------------------------"
    info "Uninstallation complete!"
    info "All related files and services have been removed."
    info "-------------------------------------------------"
}

main
