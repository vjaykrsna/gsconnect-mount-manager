#!/bin/bash
set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration
. "$SCRIPT_DIR/config_loader.sh"
load_config "$SCRIPT_DIR/config.conf"

# Validate configuration
if ! validate_config; then
    echo "Configuration validation failed. Exiting."
    exit 1
fi

# Set up derived paths
FLAG_FILE="$CONFIG_DIR/mounted"
BOOKMARK_ENTRY_FILE="$CONFIG_DIR/bookmark_entry"
LINK_PATH_FILE="$CONFIG_DIR/link_path"
LOG_FILE="$CONFIG_DIR/gsconnect-mount-manager.log"

mkdir -p "$CONFIG_DIR"

# Source component files
. "$SCRIPT_DIR/core.sh"
. "$SCRIPT_DIR/device.sh"
. "$SCRIPT_DIR/storage.sh"

# Initialize logging
log_conditional "INFO" "GSConnect Mount Manager started (PID: $$)"
log_conditional "INFO" "Configuration: poll_interval=${POLL_INTERVAL}s, symlink_dir=$SYMLINK_DIR, notifications=$ENABLE_NOTIFICATIONS"

# Main monitoring loop
while true; do
    # Rotate logs if needed
    rotate_logs

    # Clean up broken symlinks periodically
    cleanup_broken_symlinks

    # Detect GVFS path if enabled
    actual_mount_root=$(detect_gvfs_path)
    
    # Use a more robust approach to find the mount point
    find_result=""
    if ! find_result=$(find "$actual_mount_root" -maxdepth 1 -type d -name 'sftp:*' 2>/dev/null | head -n1); then
        log_conditional "WARN" "Failed to execute find command for SFTP mounts in $actual_mount_root"
        find_result=""
    fi
    MNT="$find_result"

    if [[ -n "$MNT" ]] && ! [[ -f "$FLAG_FILE" ]]; then
        # Mounted and not flagged -> run mount logic
        log_conditional "INFO" "Mount detected: $(basename "$MNT")"
        DEVICE_NAME=$(get_device_name "$(basename "$MNT")") || {
            log_conditional "WARN" "Could not determine device name, using mount path"
            DEVICE_NAME=$(basename "$MNT" | sed 's/sftp:host=\([^,]*\).*/\1/')
        }

        # Sanitize device name for filesystem use
        DEVICE_NAME_SANITIZED=$(sanitize_device_name "$DEVICE_NAME")

        log_conditional "INFO" "Device name: '$DEVICE_NAME' (sanitized: '$DEVICE_NAME_SANITIZED')"

        # Wait for mount point to stabilize
        timeout_count=0
        while ! [[ -d "$MNT/storage" ]] && [[ $timeout_count -lt $STORAGE_TIMEOUT ]]; do
            log_conditional "DEBUG" "Waiting for storage directory: $MNT/storage (${timeout_count}s/${STORAGE_TIMEOUT}s)"
            sleep 1
            ((timeout_count++))
        done

        if ! [[ -d "$MNT/storage" ]]; then
            log_conditional "ERROR" "Storage directory not found after ${STORAGE_TIMEOUT}s timeout: $MNT/storage"
            sleep "$POLL_INTERVAL"
            continue
        fi

        # Discover available storage paths
        log_conditional "DEBUG" "Discovering storage paths..."
        mapfile -t storage_paths < <(discover_storage_paths "$MNT")

        if [[ ${#storage_paths[@]} -eq 0 ]]; then
            log_conditional "ERROR" "No accessible storage found on device"
            sleep "$POLL_INTERVAL"
            continue
        fi

        log_conditional "INFO" "Found ${#storage_paths[@]} storage path(s)"
        for i in "${!storage_paths[@]}"; do
            log_conditional "DEBUG" "storage_paths[$i]: ${storage_paths[$i]}"
        done
        
        # Clear previous entries for this session
        if lock_file "$BOOKMARK_ENTRY_FILE"; then
            > "$BOOKMARK_ENTRY_FILE"
            unlock_file "$BOOKMARK_ENTRY_FILE"
        else
            log_conditional "ERROR" "Failed to acquire lock for bookmark entry file during session clear"
        fi
        
        if lock_file "$LINK_PATH_FILE"; then
            > "$LINK_PATH_FILE"
            unlock_file "$LINK_PATH_FILE"
        else
            log_conditional "ERROR" "Failed to acquire lock for link path file during session clear"
        fi

        # Create device directory structure and bookmark
        log_conditional "DEBUG" "About to create device structure for: $DEVICE_NAME (sanitized: $DEVICE_NAME_SANITIZED)"
        log_conditional "DEBUG" "Calling create_device_structure with parameters:"
        log_conditional "DEBUG" "  device_name_display: $DEVICE_NAME"
        log_conditional "DEBUG" "  device_name_sanitized: $DEVICE_NAME_SANITIZED"
        log_conditional "DEBUG" "  mount_point: $MNT"
        echo "DEBUG: About to call create_device_structure" >&2
        device_dir=$(create_device_structure "$DEVICE_NAME" "$DEVICE_NAME_SANITIZED" "$MNT")
        echo "DEBUG: Finished calling create_device_structure, device_dir=$device_dir" >&2
        echo "DEBUG: Checking if device directory exists: $(test -d "$device_dir" && echo "yes" || echo "no")" >&2
        log_conditional "DEBUG" "Created device directory: $device_dir"
        log_conditional "DEBUG" "Device directory exists: $(test -d "$device_dir" && echo "yes" || echo "no")"
        
        # Process each discovered storage path
        external_count=1
        usb_count=1
        success_count=0
        storage_summary=()

        for storage_info in "${storage_paths[@]}"; do
            storage_type="${storage_info%%:*}"
            storage_path="${storage_info#*:}"
            storage_index=""

            # Determine storage type and index
            if [[ "$storage_type" == "external" ]]; then
                # Check if it's USB OTG
                if [[ "$storage_path" == *"usbotg"* ]]; then
                    storage_type="usb"
                    storage_index="$usb_count"
                    ((usb_count++))
                else
                    storage_index="$external_count"
                    ((external_count++))
                fi
            fi

            log_conditional "DEBUG" "Processing $storage_type storage: $storage_path"
            log_conditional "DEBUG" "Device directory is: $device_dir"
            log_conditional "DEBUG" "Device directory exists: $(test -d "$device_dir" && echo "yes" || echo "no")"
            
            log_conditional "DEBUG" "About to call create_storage_symlink with parameters:"
            log_conditional "DEBUG" "  device_dir: $device_dir"
            log_conditional "DEBUG" "  storage_type: $storage_type"
            log_conditional "DEBUG" "  storage_path: $storage_path"
            log_conditional "DEBUG" "  storage_index: $storage_index"
            
            # Create symlink within device directory
            if create_storage_symlink "$device_dir" "$storage_type" "$storage_path" "$storage_index"; then
                ((success_count++))

                # Add to summary for notification
                storage_label="$storage_type"
                if [[ "$storage_type" == "external" ]] && [[ -n "$storage_index" ]] && [[ "$storage_index" -gt 1 ]]; then
                    storage_label="$storage_type $storage_index"
                elif [[ "$storage_type" == "usb" ]] && [[ -n "$storage_index" ]] && [[ "$storage_index" -gt 1 ]]; then
                    storage_label="$storage_type $storage_index"
                fi
                storage_summary+=("${storage_label}: $(basename "$storage_path")")
            else
                log_conditional "ERROR" "Failed to create symlink for $storage_type storage: $storage_path"
            fi
        done

        if [[ $success_count -gt 0 ]]; then
            if lock_file "$FLAG_FILE"; then
                touch "$FLAG_FILE"
                unlock_file "$FLAG_FILE"
                log_conditional "INFO" "✅ Mount setup complete for: $DEVICE_NAME ($success_count storage path(s))"
                log_conditional "INFO" "📁 Device folder: $device_dir"

                # Send consolidated notification
                notification_text="Device mounted: $DEVICE_NAME\n"
                notification_text+="📁 Folder: $DEVICE_NAME_SANITIZED\n"
                notification_text+="🔗 Storage: $(printf '%s, ' "${storage_summary[@]}" | sed 's/, $//')"
                send_notification "$notification_text"
            else
                log_conditional "ERROR" "Failed to acquire lock for flag file"
            fi
        else
            log_conditional "ERROR" "Failed to create any symlinks, skipping flag creation"
        fi

    elif [[ -z "$MNT" ]] && [[ -f "$FLAG_FILE" ]]; then
        # Not mounted but flagged -> run unmount logic
        log_conditional "INFO" "Unmount detected. Running cleanup..."

        # Remove device bookmark
        if [[ -f "$BOOKMARK_ENTRY_FILE" ]]; then
            local entry_to_remove=$(cat "$BOOKMARK_ENTRY_FILE")
            log_conditional "DEBUG" "Found bookmark entry to remove: $entry_to_remove"
            if [[ -n "$entry_to_remove" ]] && [[ -f "$BOOKMARK_FILE" ]] && grep -qF "$entry_to_remove" "$BOOKMARK_FILE"; then
                grep -vF "$entry_to_remove" "$BOOKMARK_FILE" > "$BOOKMARK_FILE.tmp" && mv "$BOOKMARK_FILE.tmp" "$BOOKMARK_FILE"
                log_conditional "INFO" "🔖 Device bookmark removed: $entry_to_remove"
            else
                log_conditional "DEBUG" "Bookmark entry not found in bookmark file or file does not exist."
            fi
            if lock_file "$BOOKMARK_ENTRY_FILE"; then
                rm "$BOOKMARK_ENTRY_FILE"
                unlock_file "$BOOKMARK_ENTRY_FILE"
            else
                log_conditional "ERROR" "Failed to acquire lock for bookmark entry file during removal"
            fi
        else
            log_conditional "DEBUG" "No bookmark entry file found."
        fi

        # Remove symlinks and device directory
        if [[ -f "$LINK_PATH_FILE" ]]; then
            log_conditional "DEBUG" "Found link path file. Processing symlinks for removal."
            symlink_count=0
            device_dir=""
            device_name=""

            while IFS= read -r link_to_remove; do
                if [[ -n "$link_to_remove" ]] && [[ -L "$link_to_remove" ]]; then
                    if [[ -z "$device_dir" ]]; then
                        device_dir=$(dirname "$link_to_remove")
                        device_name=$(basename "$device_dir")
                        log_conditional "DEBUG" "Determined device directory for cleanup: $device_dir"
                    fi
                    rm "$link_to_remove"
                    log_conditional "INFO" "🔗 Storage symlink removed: $link_to_remove"
                    ((symlink_count++))
                fi
            done < "$LINK_PATH_FILE"

            if [[ -n "$device_dir" ]] && [[ -d "$device_dir" ]]; then
                log_conditional "DEBUG" "Attempting to remove device directory: $device_dir"
                if rmdir "$device_dir" 2>/dev/null; then
                    log_conditional "INFO" "📁 Device directory removed: $device_dir"
                else
                    log_conditional "WARN" "Device directory not empty, keeping: $device_dir"
                fi
            fi

            if [[ $symlink_count -gt 0 ]]; then
                log_conditional "INFO" "Removed $symlink_count storage symlink(s)."
                if [[ -n "$device_name" ]]; then
                    send_notification "Device unmounted: $device_name\n$symlink_count storage path(s) disconnected"
                fi
            fi
            if lock_file "$LINK_PATH_FILE"; then
                rm "$LINK_PATH_FILE"
                unlock_file "$LINK_PATH_FILE"
            else
                log_conditional "ERROR" "Failed to acquire lock for link path file during removal"
            fi
        else
            log_conditional "DEBUG" "No link path file found."
        fi

        if lock_file "$FLAG_FILE"; then
            rm "$FLAG_FILE"
            unlock_file "$FLAG_FILE"
            log_conditional "INFO" "✅ Unmount cleanup complete"
        else
            log_conditional "ERROR" "Failed to acquire lock for flag file during cleanup"
        fi
    fi

    sleep "$POLL_INTERVAL"
done