#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# GSConnect Mount Manager Core Utilities
# -----------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/gsconnect-mount-manager}"
LOG_FILE="$CONFIG_DIR/gsconnect-mount-manager.log"
FLAG_LOCK="/tmp/gsconnect-mount-manager.lock"

# -----------------------------
# Logging Functions
# -----------------------------

log_conditional() {
    # Usage: log_conditional "LEVEL" "Message"
    local level="$1"
    shift
    local message="$*"

    local levels=("DEBUG" "INFO" "WARN" "ERROR")
    local level_priority=0
    case "$level" in
        DEBUG) level_priority=0 ;;
        INFO)  level_priority=1 ;;
        WARN)  level_priority=2 ;;
        ERROR) level_priority=3 ;;
        *) level_priority=1 ;;  # default INFO
    esac

    # Only log if level is >= configured LOG_LEVEL
    declare -A log_map=( ["DEBUG"]=0 ["INFO"]=1 ["WARN"]=2 ["ERROR"]=3 )
    if [[ ${log_map[$LOG_LEVEL]:-1} -le $level_priority ]]; then
        printf "[%s] %s\n" "$level" "$message" | /usr/bin/tee -a "$LOG_FILE"
    fi
}

rotate_logs() {
    # Rotate logs if size exceeds MAX_LOG_SIZE MB
    local max_size_bytes=$((MAX_LOG_SIZE * 1024 * 1024))
    if [[ -f "$LOG_FILE" ]] && [[ $(stat -c%s "$LOG_FILE") -ge $max_size_bytes ]]; then
        for ((i=LOG_ROTATE_COUNT; i>1; i--)); do
            [[ -f "$LOG_FILE.$((i-1))" ]] && mv "$LOG_FILE.$((i-1))" "$LOG_FILE.$i"
        done
        mv "$LOG_FILE" "$LOG_FILE.1"
        touch "$LOG_FILE"
        log_conditional "INFO" "Rotated logs"
    fi
}

# -----------------------------
# File Locking Utilities
# -----------------------------

lock_file() {
    local file="$1"
    exec 200>"$file"
    flock -n 200 && return 0 || return 1
}

unlock_file() {
    local file="$1"
    exec 200>&-
}

# -----------------------------
# Notification Functions
# -----------------------------

send_notification() {
    local message="$1"
    if [[ "$ENABLE_NOTIFICATIONS" == true ]] && command -v notify-send >/dev/null 2>&1; then
        notify-send "GSConnect Mount Manager" "$message"
    fi
}

# -----------------------------
# Misc Utilities
# -----------------------------

sanitize_device_name() {
    # Remove problematic characters from filenames
    local name="$1"
    name="${name// /_}"
    name="${name//[^a-zA-Z0-9._-]/}"
    echo "$name"
}

# Wait until directory exists with timeout
wait_for_dir() {
    local dir="$1"
    local timeout="${2:-30}"  # default 30s
    local count=0
    while [[ ! -d "$dir" ]] && [[ $count -lt $timeout ]]; do
        sleep 1
        ((count++))
    done
    [[ -d "$dir" ]]
}

# Detect GVFS path (if dynamic)
detect_gvfs_path() {
    if [[ "$DETECT_GVFS_PATH" == true ]]; then
        echo "/run/user/$(id -u)/gvfs"
    else
        echo "$MOUNT_ROOT"
    fi
}
