#!/bin/bash
set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration
source "$SCRIPT_DIR/config_loader.sh"
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

# Logging functions
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Check if we should log this level
    case "$LOG_LEVEL" in
        DEBUG) ;;
        INFO) [[ "$level" == "DEBUG" ]] && return ;;
        WARN) [[ "$level" == "DEBUG" || "$level" == "INFO" ]] && return ;;
        ERROR) [[ "$level" != "ERROR" ]] && return ;;
    esac

    # Write to log file (plain text, no colors)
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"

    # Output to console with colors (only if not DEBUG or if VERBOSE is true)
    if [[ "$level" != "DEBUG" ]] || [[ "$VERBOSE" == true ]]; then
        case "$level" in
            ERROR) echo -e "\033[0;31m[$timestamp] [$level] $message\033[0m" ;;
            WARN) echo -e "\033[1;33m[$timestamp] [$level] $message\033[0m" ;;
            INFO) echo -e "\033[0;32m[$timestamp] [$level] $message\033[0m" ;;
            DEBUG) [[ "$VERBOSE" == true ]] && echo -e "\033[0;36m[$timestamp] [$level] $message\033[0m" ;;
        esac
    fi
}

# Log rotation function
rotate_logs() {
    if [[ "$MAX_LOG_SIZE" -gt 0 ]] && [[ -f "$LOG_FILE" ]]; then
        # Get file size in bytes (portable way)
        local size_bytes
        if command -v stat >/dev/null 2>&1; then
            # Try GNU stat first, then BSD stat
            size_bytes=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
        else
            # Fallback using ls and awk
            size_bytes=$(ls -l "$LOG_FILE" 2>/dev/null | awk '{print $5}' || echo 0)
        fi

        local size_mb=$((size_bytes / 1024 / 1024))
        if [[ "$size_mb" -gt "$MAX_LOG_SIZE" ]]; then
            for i in $(seq $((LOG_ROTATE_COUNT-1)) -1 1); do
                [[ -f "$LOG_FILE.$i" ]] && mv "$LOG_FILE.$i" "$LOG_FILE.$((i+1))"
            done
            mv "$LOG_FILE" "$LOG_FILE.1"
            touch "$LOG_FILE"
            log_message "INFO" "Log rotated (was ${size_mb}MB)"
        fi
    fi
}

# Desktop notification function
send_notification() {
    if [[ "$ENABLE_NOTIFICATIONS" == true ]] && command -v notify-send >/dev/null 2>&1; then
        notify-send "GSConnect Mount Manager" "$1" --icon=phone 2>/dev/null || true
    fi
}

get_device_name() {
    local mnt_path=$1
    local host=$(echo "$mnt_path" | sed -n 's/.*host=\([^,]*\).*/\1/p')

    log_message "DEBUG" "Looking for device with host IP: $host"

    # Check if dconf is available
    if ! command -v dconf >/dev/null 2>&1; then
        log_message "ERROR" "dconf command not found. GSConnect may not be installed."
        return 1
    fi

    # Find the device ID that matches the host IP
    local device_list
    if ! device_list=$(dconf list /org/gnome/shell/extensions/gsconnect/device/ 2>/dev/null); then
        log_message "ERROR" "Cannot access GSConnect device list. GSConnect may not be configured."
        return 1
    fi

    for dev_id in $(echo "$device_list" | grep '/$'); do
        local full_path="/org/gnome/shell/extensions/gsconnect/device/${dev_id}"
        local last_conn_ip=$(dconf read "${full_path}last-connection" 2>/dev/null | tr -d "'" | sed -n 's/lan:\/\/\([^:]*\):.*/\1/p')

        log_message "DEBUG" "Checking device $dev_id with IP: $last_conn_ip"

        if [[ "$last_conn_ip" == "$host" ]]; then
            local device_name=$(dconf read "${full_path}name" 2>/dev/null | tr -d "'")
            log_message "DEBUG" "Found matching device: $device_name"
            echo "$device_name"
            return 0
        fi
    done

    log_message "WARN" "No matching device found for host $host"
    return 1
}

# Function to sanitize device name for filesystem use
sanitize_device_name() {
    local device_name="$1"

    # Handle empty device name
    if [[ -z "$device_name" ]]; then
        echo "Unknown-Device"
        return
    fi

    # Replace spaces with hyphens and remove other problematic characters
    local sanitized=$(echo "$device_name" | sed 's/ /-/g' | sed 's/[^a-zA-Z0-9._-]//g')

    # Ensure we have at least something after sanitization
    if [[ -z "$sanitized" ]]; then
        sanitized="Unknown-Device"
    fi

    echo "$sanitized"
}



# Function to cleanup broken symlinks
cleanup_broken_symlinks() {
    if [[ "$AUTO_CLEANUP" == true ]] && [[ -d "$MOUNT_STRUCTURE_DIR" ]]; then
        log_message "DEBUG" "Checking for broken symlinks in $MOUNT_STRUCTURE_DIR"

        # Find broken symlinks in device directories (avoid subshell)
        local broken_links
        mapfile -t broken_links < <(find "$MOUNT_STRUCTURE_DIR" -type l ! -exec test -e {} \; -print 2>/dev/null)

        for broken_link in "${broken_links[@]}"; do
            if [[ -n "$broken_link" ]]; then
                rm "$broken_link"
                log_message "INFO" "Cleaned up broken symlink: $broken_link"
            fi
        done

        # Remove empty device directories (avoid subshell)
        local empty_dirs
        mapfile -t empty_dirs < <(find "$MOUNT_STRUCTURE_DIR" -mindepth 1 -maxdepth 1 -type d -empty -print 2>/dev/null)

        for empty_dir in "${empty_dirs[@]}"; do
            if [[ -n "$empty_dir" ]]; then
                rmdir "$empty_dir"
                log_message "INFO" "Cleaned up empty device directory: $(basename "$empty_dir")"
            fi
        done
    fi
}

# Function to discover available storage paths on device
discover_storage_paths() {
    local mount_point="$1"
    local storage_paths=()

    log_message "DEBUG" "Discovering storage paths in: $mount_point"

    # Check for internal storage
    if [[ "$ENABLE_INTERNAL_STORAGE" == true ]]; then
        local internal_path="$mount_point/$INTERNAL_STORAGE_PATH"
        if [[ -d "$internal_path" ]]; then
            storage_paths+=("internal:$internal_path")
            log_message "DEBUG" "Found internal storage: $internal_path"
        else
            log_message "WARN" "Internal storage not found: $internal_path"
        fi
    fi

    # Check for external storage
    if [[ "$ENABLE_EXTERNAL_STORAGE" == true ]]; then
        local storage_dir="$mount_point/storage"
        if [[ -d "$storage_dir" ]]; then
            local external_count=0

            # Convert patterns to array
            IFS=' ' read -ra patterns <<< "$EXTERNAL_STORAGE_PATTERNS"

            for pattern in "${patterns[@]}"; do
                # Stop if we've reached the maximum
                if [[ $external_count -ge $MAX_EXTERNAL_STORAGE ]]; then
                    break
                fi

                # Handle glob patterns
                if [[ "$pattern" == *"*"* ]]; then
                    # Use find for glob patterns (limit depth for performance)
                    local found_paths
                    mapfile -t found_paths < <(find "$storage_dir" -maxdepth 1 -type d -name "${pattern##*/}" -print 2>/dev/null)

                    for external_path in "${found_paths[@]}"; do
                        if [[ -n "$external_path" ]] && [[ -d "$external_path" ]] && [[ $external_count -lt $MAX_EXTERNAL_STORAGE ]]; then
                            storage_paths+=("external:$external_path")
                            log_message "DEBUG" "Found external storage: $external_path"
                            ((external_count++))
                        fi

                        # Stop if we've reached the maximum
                        if [[ $external_count -ge $MAX_EXTERNAL_STORAGE ]]; then
                            break
                        fi
                    done
                else
                    # Direct path check (faster)
                    local external_path="$mount_point/$pattern"
                    if [[ -d "$external_path" ]] && [[ $external_count -lt $MAX_EXTERNAL_STORAGE ]]; then
                        storage_paths+=("external:$external_path")
                        log_message "DEBUG" "Found external storage: $external_path"
                        ((external_count++))
                    fi
                fi
            done

            if [[ $external_count -eq 0 ]]; then
                log_message "DEBUG" "No external storage found"
            fi
        else
            log_message "DEBUG" "Storage directory not found: $storage_dir"
        fi
    fi

    # Return the discovered paths (handle empty array safely)
    if [[ ${#storage_paths[@]} -gt 0 ]]; then
        printf '%s\n' "${storage_paths[@]}"
    fi
}

# Function to create storage symlink within device directory
create_storage_symlink() {
    local device_dir="$1"
    local storage_type="$2"  # "internal", "external", or "usb"
    local target_path="$3"
    local storage_index="${4:-}"  # For multiple external storage

    # Determine folder name based on storage type
    local folder_name=""
    case "$storage_type" in
        internal)
            folder_name="$INTERNAL_STORAGE_NAME"
            ;;
        external)
            folder_name="$EXTERNAL_STORAGE_NAME"
            if [[ -n "$storage_index" ]] && [[ "$storage_index" -gt 1 ]]; then
                folder_name="${folder_name}${storage_index}"
            fi
            ;;
        usb)
            folder_name="$USB_STORAGE_NAME"
            if [[ -n "$storage_index" ]] && [[ "$storage_index" -gt 1 ]]; then
                folder_name="${folder_name}${storage_index}"
            fi
            ;;
    esac

    local link_path="$device_dir/$folder_name"

    # Remove existing symlink if it exists
    if [[ -L "$link_path" ]]; then
        rm "$link_path"
        log_message "DEBUG" "Removed existing symlink: $link_path"
    elif [[ -e "$link_path" ]]; then
        log_message "ERROR" "Cannot create symlink: $link_path already exists and is not a symlink"
        return 1
    fi

    # Create the symlink
    if ln -s "$target_path" "$link_path"; then
        echo "$link_path" >> "$LINK_PATH_FILE"
        log_message "INFO" "🔗 ${storage_type^} storage linked: $folder_name → $(basename "$target_path")"
        return 0
    else
        log_message "ERROR" "Failed to create symlink: $link_path"
        return 1
    fi
}

# Function to create device directory structure and bookmark
create_device_structure() {
    local device_name_display="$1"
    local device_name_sanitized="$2"
    local mount_point="$3"

    # Create device directory using sanitized name
    local device_dir="$MOUNT_STRUCTURE_DIR/${device_name_sanitized}"
    mkdir -p "$device_dir"

    # Create bookmark pointing to accessible device directory using display name
    local label="${SYMLINK_PREFIX}${device_name_display}${SYMLINK_SUFFIX}"
    local entry="file://$device_dir $label"

    if ! grep -qxF "$entry" "$BOOKMARK_FILE" 2>/dev/null; then
        mkdir -p "$(dirname "$BOOKMARK_FILE")"
        echo "$entry" >> "$BOOKMARK_FILE"
        echo "$entry" > "$BOOKMARK_ENTRY_FILE"
        log_message "INFO" "🔖 Device bookmark added: $label"
        log_message "DEBUG" "Bookmark points to accessible directory: $device_dir"
    else
        log_message "DEBUG" "Bookmark already exists: $label"
    fi

    echo "$device_dir"
}


# Initialize logging
log_message "INFO" "GSConnect Mount Manager started (PID: $$)"
log_message "INFO" "Configuration: poll_interval=${POLL_INTERVAL}s, symlink_dir=$SYMLINK_DIR, notifications=$ENABLE_NOTIFICATIONS"

# Main monitoring loop
while true; do
    # Rotate logs if needed
    rotate_logs

    # Clean up broken symlinks periodically
    cleanup_broken_symlinks

    MNT=$(find "$MOUNT_ROOT" -maxdepth 1 -type d -name 'sftp:*' | head -n1 || true)

    if [[ -n "$MNT" ]] && ! [[ -f "$FLAG_FILE" ]]; then
        # Mounted and not flagged -> run mount logic
        log_message "INFO" "Mount detected: $(basename "$MNT")"
        DEVICE_NAME=$(get_device_name "$(basename "$MNT")") || true

        if [[ -z "$DEVICE_NAME" ]]; then
            log_message "WARN" "Could not determine device name, using mount path"
            DEVICE_NAME=$(basename "$MNT" | sed 's/sftp:host=\([^,]*\).*/\1/')
        fi

        # Sanitize device name for filesystem use
        DEVICE_NAME_SANITIZED=$(sanitize_device_name "$DEVICE_NAME")

        log_message "INFO" "Device name: '$DEVICE_NAME' (sanitized: '$DEVICE_NAME_SANITIZED')"

        # Wait for mount point to stabilize
        timeout_count=0
        while ! [[ -d "$MNT/storage" ]] && [[ $timeout_count -lt $STORAGE_TIMEOUT ]]; do
            log_message "DEBUG" "Waiting for storage directory: $MNT/storage (${timeout_count}s/${STORAGE_TIMEOUT}s)"
            sleep 1
            ((timeout_count++))
        done

        if ! [[ -d "$MNT/storage" ]]; then
            log_message "ERROR" "Storage directory not found after ${STORAGE_TIMEOUT}s timeout: $MNT/storage"
            sleep "$POLL_INTERVAL"
            continue
        fi

        # Discover available storage paths
        log_message "DEBUG" "Discovering storage paths..."
        mapfile -t storage_paths < <(discover_storage_paths "$MNT")

        if [[ ${#storage_paths[@]} -eq 0 ]]; then
            log_message "ERROR" "No accessible storage found on device"
            sleep "$POLL_INTERVAL"
            continue
        fi

        log_message "INFO" "Found ${#storage_paths[@]} storage path(s)"

        # Clear previous entries for this session
        > "$BOOKMARK_ENTRY_FILE"
        > "$LINK_PATH_FILE"

        # Create device directory structure and bookmark
        device_dir=$(create_device_structure "$DEVICE_NAME" "$DEVICE_NAME_SANITIZED" "$MNT")

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

            log_message "DEBUG" "Processing $storage_type storage: $storage_path"

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
            fi
        done

        if [[ $success_count -gt 0 ]]; then
            touch "$FLAG_FILE"
            log_message "INFO" "✅ Mount setup complete for: $DEVICE_NAME ($success_count storage path(s))"
            log_message "INFO" "📁 Device folder: $device_dir"

            # Send consolidated notification
            notification_text="Device mounted: $DEVICE_NAME\n"
            notification_text+="📁 Folder: $DEVICE_NAME_SANITIZED\n"
            notification_text+="🔗 Storage: $(printf '%s, ' "${storage_summary[@]}" | sed 's/, $//')"
            send_notification "$notification_text"
        else
            log_message "ERROR" "Failed to create any symlinks, skipping flag creation"
        fi

    elif [[ -z "$MNT" ]] && [[ -f "$FLAG_FILE" ]]; then
        # Not mounted but flagged -> run unmount logic
        log_message "INFO" "Unmount detected. Running cleanup..."

        # Remove device bookmark
        if [[ -f "$BOOKMARK_ENTRY_FILE" ]]; then
            local entry_to_remove=$(cat "$BOOKMARK_ENTRY_FILE")
            if [[ -n "$entry_to_remove" ]] && [[ -f "$BOOKMARK_FILE" ]] && grep -qF "$entry_to_remove" "$BOOKMARK_FILE"; then
                grep -vF "$entry_to_remove" "$BOOKMARK_FILE" > "$BOOKMARK_FILE.tmp" && mv "$BOOKMARK_FILE.tmp" "$BOOKMARK_FILE"
                log_message "INFO" "🔖 Device bookmark removed"
            fi
            rm "$BOOKMARK_ENTRY_FILE"
        fi

        # Remove symlinks and device directory
        if [[ -f "$LINK_PATH_FILE" ]]; then
            symlink_count=0
            device_dir=""
            device_name=""

            while IFS= read -r link_to_remove; do
                if [[ -n "$link_to_remove" ]] && [[ -L "$link_to_remove" ]]; then
                    # Extract device directory from first symlink
                    if [[ -z "$device_dir" ]]; then
                        device_dir=$(dirname "$link_to_remove")
                        device_name=$(basename "$device_dir")
                    fi

                    rm "$link_to_remove"
                    log_message "INFO" "🔗 Storage symlink removed: $(basename "$link_to_remove")"
                    ((symlink_count++))
                fi
            done < "$LINK_PATH_FILE"

            # Remove device directory if it exists and is empty
            if [[ -n "$device_dir" ]] && [[ -d "$device_dir" ]]; then
                # Remove directory if empty
                if rmdir "$device_dir" 2>/dev/null; then
                    log_message "INFO" "📁 Device directory removed: $device_dir"
                else
                    log_message "WARN" "Device directory not empty, keeping: $device_dir"
                fi
            fi

            if [[ $symlink_count -gt 0 ]]; then
                log_message "INFO" "Removed $symlink_count storage symlink(s)"
                if [[ -n "$device_name" ]]; then
                    send_notification "Device unmounted: $device_name\n$symlink_count storage path(s) disconnected"
                fi
            fi
            rm "$LINK_PATH_FILE"
        fi

        rm "$FLAG_FILE"
        log_message "INFO" "✅ Unmount cleanup complete"
    fi

    sleep "$POLL_INTERVAL"
done
