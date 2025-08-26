#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Storage Utilities (Lean Version)
# -----------------------------

# Load core utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/core.sh"

# Detect actual GVFS path if auto-detection is enabled
detect_gvfs_path_dynamic() {
    if [[ "$DETECT_GVFS_PATH" == true ]]; then
        local gvfs_path
        gvfs_path=$(find /run/user/$(id -u)/gvfs -maxdepth 1 -type d 2>/dev/null | head -n1)
        if [[ -n "$gvfs_path" ]]; then
            echo "$gvfs_path"
            return 0
        else
            log_conditional "WARN" "No GVFS mounts detected; falling back to configured MOUNT_ROOT"
        fi
    fi
    echo "$MOUNT_ROOT"
}

# Rotate log files (delegates to core)
rotate_logs_wrapper() {
    rotate_logs  # call core.sh implementation
}

# Lock/unlock wrapper (delegates to core)
lock_file_wrapper() {
    local file="$1"
    lock_file "$file"  # core.sh handles file descriptor
}

unlock_file_wrapper() {
    unlock_file  # core.sh handles file descriptor
}

# Send notifications (delegates to core)
send_notification_wrapper() {
    local message="$1"
    send_notification "$message"  # core.sh handles logging & desktop notifications
}

# Sanitize device names (delegates to core)
sanitize_device_name_wrapper() {
    local name="$1"
    sanitize_device_name "$name"
}

