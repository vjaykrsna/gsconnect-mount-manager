#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# GSConnect Mount Manager Runner
# -----------------------------

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration
. "$SCRIPT_DIR/config_loader.sh"
load_config "$SCRIPT_DIR/config.conf"
echo "Configuration loaded"

# Validate configuration
if ! validate_config; then
    echo "Configuration validation failed. Exiting."
    exit 1
fi
echo "Configuration validated"

# Derived paths
FLAG_FILE="$CONFIG_DIR/mounted"
BOOKMARK_ENTRY_FILE="$CONFIG_DIR/bookmark_entry"
LINK_PATH_FILE="$CONFIG_DIR/link_path"
LOG_FILE="$CONFIG_DIR/gsconnect-mount-manager.log"

mkdir -p "$CONFIG_DIR"

# Source modules
. "$SCRIPT_DIR/core.sh"
. "$SCRIPT_DIR/device.sh"
. "$SCRIPT_DIR/storage.sh"
. "$SCRIPT_DIR/gvfs_error_handler.sh"

log_conditional "INFO" "GSConnect Mount Manager started"

# -----------------------------
# Main monitoring loop
# -----------------------------
while true; do
    rotate_logs
    cleanup_broken_symlinks

    # Detect actual GVFS root
    GVFS_ROOT=$(detect_gvfs_path)

    # Find first SFTP mount
    MNT=$(safe_gvfs_op find "$GVFS_ROOT" -maxdepth 1 -type d -name 'sftp:*' 2>/dev/null | head -n1)

    # -----------------------------
    # Mount handling
    # -----------------------------
    if [[ -n "$MNT" ]] && [[ ! -f "$FLAG_FILE" ]]; then
        DEVICE_NAME=$(get_device_name "$(basename "$MNT")" || echo "$(basename "$MNT" | sed 's/sftp:host=\([^,]*\).*/\1/')")
        DEVICE_SANITIZED=$(sanitize_device_name "$DEVICE_NAME")

        # Wait for storage to appear
        timeout_count=0
        while ! safe_gvfs_op [[ -d "$MNT/storage" ]] && [[ $timeout_count -lt $STORAGE_TIMEOUT ]]; do
            sleep 1
            ((timeout_count++))
        done
        if ! safe_gvfs_op [[ -d "$MNT/storage" ]]; then
            log_conditional "WARN" "Storage not found: $DEVICE_NAME"
            sleep "$POLL_INTERVAL"
            continue
        fi

        # Discover storage paths
        mapfile -t STORAGE_PATHS < <(discover_storage_paths "$MNT")

        if [[ ${#STORAGE_PATHS[@]} -eq 0 ]]; then
            log_conditional "WARN" "No storage paths found for $DEVICE_NAME"
            sleep "$POLL_INTERVAL"
            continue
        fi

        # Clear previous session files
        > "$BOOKMARK_ENTRY_FILE" 2>/dev/null || true
        > "$LINK_PATH_FILE" 2>/dev/null || true

        # Create device structure
        DEVICE_DIR=$(create_device_structure "$DEVICE_NAME" "$DEVICE_SANITIZED" "$MNT")
        if [[ -z "$DEVICE_DIR" ]]; then
            log_conditional "ERROR" "Failed to create device directory for $DEVICE_NAME"
            sleep "$POLL_INTERVAL"
            continue
        fi

        # Create symlinks for storage paths
        SUCCESS_COUNT=0
        STORAGE_SUMMARY=()
        for storage_info in "${STORAGE_PATHS[@]}"; do
            TYPE="${storage_info%%:*}"
            PATH="${storage_info#*:}"
            INDEX=""

            case "$TYPE" in
                external) INDEX=1 ;;
                usb) INDEX=1 ;;
                internal) INDEX="" ;;
                *) TYPE="external"; INDEX=1 ;;
            esac

            if create_storage_symlink "$DEVICE_DIR" "$TYPE" "$PATH" "$INDEX"; then
                ((SUCCESS_COUNT++))
                LABEL="$TYPE"
                [[ -n "$INDEX" ]] && LABEL="$TYPE $INDEX"
                STORAGE_SUMMARY+=("${LABEL}: $(basename "$PATH")")
            else
                log_conditional "WARN" "Failed symlink for $TYPE storage: $PATH"
            fi
        done

        # Flag device and notify
        if [[ $SUCCESS_COUNT -gt 0 ]]; then
            touch "$FLAG_FILE"
            send_notification "Device mounted: $DEVICE_NAME\nFolder: $DEVICE_SANITIZED\nStorage: $(printf '%s, ' "${STORAGE_SUMMARY[@]}" | sed 's/, $//')"
        else
            log_conditional "ERROR" "No symlinks created. Cleaning up $DEVICE_DIR"
            rm -rf "$DEVICE_DIR"
        fi

    # -----------------------------
    # Unmount handling
    # -----------------------------
    elif [[ -z "$MNT" ]] && [[ -f "$FLAG_FILE" ]]; then
        # Remove bookmarks and symlinks
        [[ -f "$BOOKMARK_ENTRY_FILE" ]] && while IFS= read -r entry; do
            grep -vF "$entry" "$BOOKMARK_FILE" > "$BOOKMARK_FILE.tmp" && mv "$BOOKMARK_FILE.tmp" "$BOOKMARK_FILE"
        done < "$BOOKMARK_ENTRY_FILE" || true
        rm -f "$BOOKMARK_ENTRY_FILE" "$LINK_PATH_FILE" "$FLAG_FILE"

        # Cleanup device directories
        DEVICE_DIRS=("$CONFIG_DIR"/*)
        for dir in "${DEVICE_DIRS[@]}"; do
            [[ -d "$dir" ]] && rmdir "$dir" 2>/dev/null || true
        done

        send_notification "Device unmounted"
    fi

    sleep "$POLL_INTERVAL"
done
