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
# Override LOG_FILE for uninstaller - use a location that won't be removed
LOG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/gmm-uninstall.log"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

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

# --- Functions ---
stop_and_disable_service() {
    if ! command -v systemctl >/dev/null 2>&1; then
        warn "systemctl not found. Skipping service removal."
        return
    fi

    log "INFO" "Stopping and disabling systemd user service..."
    if systemctl --user cat "$SERVICE_NAME" >/dev/null 2>&1; then
        timeout 5 systemctl --user stop "$SERVICE_NAME" || log "WARN" "Service $SERVICE_NAME was not running or timed out."
        timeout 5 systemctl --user disable "$SERVICE_NAME" || log "WARN" "Service $SERVICE_NAME was not enabled or timed out."
        log "INFO" "Service $SERVICE_NAME stopped and disabled."
    else
        log "WARN" "Service $SERVICE_NAME not found. It might have been already removed."
    fi
}

remove_service_file() {
    if [[ -f "$SERVICE_FILE" ]]; then
        log "INFO" "Removing systemd service file..."
        rm -f "$SERVICE_FILE"
        systemctl --user daemon-reload || log "WARN" "Failed to reload systemd daemon."
        log "INFO" "Systemd daemon reloaded."
    fi
}

remove_symlink() {
    # Note: systemctl --user disable already removes the symlink, so this is just a safety check
    local symlink_path="$HOME/.config/systemd/user/default.target.wants/$SERVICE_NAME"
    if [[ -L "$symlink_path" ]]; then
        log "INFO" "Removing systemd service symlink..."
        rm -f "$symlink_path"
        log "INFO" "Symlink removed: $symlink_path"
    else
        log "DEBUG" "Systemd service symlink already removed by systemctl disable"
    fi
}

remove_config_directory() {
    if [[ -d "$CONFIG_DIR" ]]; then
        # Extra safety: only remove if CONFIG_DIR is under XDG_CONFIG_HOME or $HOME
        local canonical_config
        if canonical_config=$(realpath -m "$CONFIG_DIR" 2>/dev/null); then
            case "$canonical_config" in
                "${XDG_CONFIG_HOME:-$HOME/.config}/gmm"*|"$HOME/.config/gmm"*)
                    log "INFO" "Removing configuration directory..."
                    rm -rf -- "$CONFIG_DIR"
                    log "INFO" "Directory removed: $CONFIG_DIR"
                    ;;
                *)
                    log "WARN" "Refusing to remove configuration directory outside allowed config paths: $CONFIG_DIR"
                    ;;
            esac
        else
            log "WARN" "Could not canonicalize $CONFIG_DIR; skipping removal."
        fi
    fi
}

run_script_cleanup() {
    if [[ -x "$SCRIPT_PATH" ]]; then
        log "INFO" "Running cleanup task in the main script..."
        # Run the script's own cleanup function to remove bookmarks and symlinks
        "$SCRIPT_PATH" --uninstall-cleanup || log "WARN" "The script's cleanup function reported an error."
    else
        log "WARN" "Main script not found or not executable at $SCRIPT_PATH. Skipping artifact cleanup."
        log "WARN" "You may need to manually remove any created bookmarks or directories in $HOME."
    fi
}

remove_lock_file() {
    if [[ -f "$LOCK_FILE" ]]; then
        log "INFO" "Removing lock file..."
        rm -f "$LOCK_FILE"
    fi
}

cleanup_log_files() {
    log "INFO" "Cleaning up log files..."
    for log_file in "$CONFIG_DIR/gmm.log" "$CONFIG_DIR/gmm-uninstall.log" "$CONFIG_DIR/gmm-install.log"; do
        if [[ -f "$log_file" ]]; then
            rm -f "$log_file"
            log "INFO" "Removed log file: $log_file"
        fi
    done
}

cleanup_bookmarks_fallback() {
    # Fallback cleanup for bookmarks if the main script cleanup fails
    local bookmark_file="${XDG_CONFIG_HOME:-$HOME/.config}/gtk-3.0/bookmarks"

    if [[ -f "$bookmark_file" ]] && [[ -f "$MANAGED_DEVICES_LOG" ]]; then
        log "INFO" "Performing fallback bookmark cleanup..."
        while IFS='|' read -r device_name sanitized_name host || [[ -n "$device_name" ]]; do
            if [[ -n "$sanitized_name" ]] && [[ -n "$device_name" ]]; then
                # Remove all bookmarks for this device
                sed -i "\| $sanitized_name/|d" "$bookmark_file"
                log "INFO" "Removed bookmarks for $device_name via fallback cleanup"
            fi
        done < "$MANAGED_DEVICES_LOG"
    fi
}

# --- Main Uninstallation Logic ---
main() {
    log "INFO" "Starting GMM (GSConnect Mount Manager) uninstallation..."
    
    read -p "Are you sure you want to uninstall? This will remove all configuration and service files. (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "INFO" "Uninstallation cancelled."
        exit 0
    fi

    stop_and_disable_service
    remove_service_file
    remove_symlink
    remove_lock_file
    run_script_cleanup
    cleanup_bookmarks_fallback
    cleanup_log_files
    remove_config_directory

    # After removing the config directory, ensure subsequent logs don't try to write there
    LOG_FILE="/dev/null"
    log "INFO" "-------------------------------------------------"
    log "INFO" "Uninstallation complete!"
    log "INFO" "All related files and services have been removed."
    log "INFO" "-------------------------------------------------"
}

main
