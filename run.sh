#!/usr/bin/env bash
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

    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"

    # Also output to console for INFO and above (unless verbose is disabled)
    if [[ "$level" != "DEBUG" ]] || [[ "$VERBOSE" == true ]]; then
        case "$level" in
            ERROR) echo -e "\033[0;31m$message\033[0m" ;;
            WARN) echo -e "\033[1;33m$message\033[0m" ;;
            INFO) echo -e "\033[0;32m$message\033[0m" ;;
            DEBUG) [[ "$VERBOSE" == true ]] && echo -e "\033[0;36m$message\033[0m" ;;
        esac
    fi
}

# Log rotation function
rotate_logs() {
    if [[ "$MAX_LOG_SIZE" -gt 0 ]] && [[ -f "$LOG_FILE" ]]; then
        local size_mb=$(( $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) / 1024 / 1024 ))
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

    # Find the device ID that matches the host IP
    for dev_id in $(dconf list /org/gnome/shell/extensions/gsconnect/device/ | grep '/$'); do
        local full_path="/org/gnome/shell/extensions/gsconnect/device/${dev_id}"
        local last_conn_ip=$(dconf read "${full_path}last-connection" 2>/dev/null | tr -d "'" | sed -n 's/lan:\/\/\([^:]*\):.*/\1/p')

        log_message "DEBUG" "Checking device $dev_id with IP: $last_conn_ip"

        if [[ "$last_conn_ip" == "$host" ]]; then
            local device_name=$(dconf read "${full_path}name" 2>/dev/null | tr -d "'")
            log_message "DEBUG" "Found matching device: $device_name"
            echo "$device_name"
            return
        fi
    done

    log_message "WARN" "No matching device found for host $host"
}

# Function to create symlink with custom naming
create_symlink() {
    local device_name="$1"
    local target_path="$2"

    # Apply prefix and suffix
    local link_name="${SYMLINK_PREFIX}${device_name}${SYMLINK_SUFFIX}"
    local link_path="$SYMLINK_DIR/$link_name"

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
        echo "$link_path" > "$LINK_PATH_FILE"
        log_message "INFO" "🔗 Symlink created: $link_path"
        send_notification "Device mounted: $device_name\nSymlink: $link_path"
        return 0
    else
        log_message "ERROR" "Failed to create symlink: $link_path"
        return 1
    fi
}

# Function to cleanup broken symlinks
cleanup_broken_symlinks() {
    if [[ "$AUTO_CLEANUP" == true ]]; then
        log_message "DEBUG" "Checking for broken symlinks in $SYMLINK_DIR"
        find "$SYMLINK_DIR" -maxdepth 1 -type l ! -exec test -e {} \; -print 2>/dev/null | while read -r broken_link; do
            if [[ "$broken_link" =~ $SYMLINK_PREFIX.*($SYMLINK_SUFFIX|$INTERNAL_STORAGE_SUFFIX|$EXTERNAL_STORAGE_SUFFIX)$ ]]; then
                rm "$broken_link"
                log_message "INFO" "Cleaned up broken symlink: $broken_link"
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
                # Handle glob patterns
                if [[ "$pattern" == *"*"* ]]; then
                    # Use find for glob patterns
                    while IFS= read -r -d '' external_path; do
                        if [[ -d "$external_path" ]] && [[ $external_count -lt $MAX_EXTERNAL_STORAGE ]]; then
                            storage_paths+=("external:$external_path")
                            log_message "DEBUG" "Found external storage: $external_path"
                            ((external_count++))
                        fi
                    done < <(find "$mount_point" -maxdepth 2 -type d -path "*/$pattern" -print0 2>/dev/null)
                else
                    # Direct path check
                    local external_path="$mount_point/$pattern"
                    if [[ -d "$external_path" ]] && [[ $external_count -lt $MAX_EXTERNAL_STORAGE ]]; then
                        storage_paths+=("external:$external_path")
                        log_message "DEBUG" "Found external storage: $external_path"
                        ((external_count++))
                    fi
                fi

                # Stop if we've reached the maximum
                if [[ $external_count -ge $MAX_EXTERNAL_STORAGE ]]; then
                    break
                fi
            done

            if [[ $external_count -eq 0 ]]; then
                log_message "DEBUG" "No external storage found"
            fi
        else
            log_message "DEBUG" "Storage directory not found: $storage_dir"
        fi
    fi

    # Return the discovered paths
    printf '%s\n' "${storage_paths[@]}"
}

# Function to create storage-specific symlink
create_storage_symlink() {
    local device_name="$1"
    local storage_type="$2"  # "internal" or "external"
    local target_path="$3"
    local storage_index="${4:-}"  # For multiple external storage

    # Determine suffix based on storage type
    local suffix=""
    case "$storage_type" in
        internal)
            suffix="$INTERNAL_STORAGE_SUFFIX"
            ;;
        external)
            suffix="$EXTERNAL_STORAGE_SUFFIX"
            if [[ -n "$storage_index" ]] && [[ "$storage_index" -gt 1 ]]; then
                suffix="${suffix}${storage_index}"
            fi
            ;;
    esac

    # Apply prefix and suffix
    local link_name="${SYMLINK_PREFIX}${device_name}${suffix}"
    local link_path="$SYMLINK_DIR/$link_name"

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
        log_message "INFO" "🔗 ${storage_type^} storage symlink created: $link_path"
        return 0
    else
        log_message "ERROR" "Failed to create symlink: $link_path"
        return 1
    fi
}

# Function to create single hierarchical bookmark for device
create_device_bookmark() {
    local device_name="$1"
    local mount_point="$2"

    local label="${SYMLINK_PREFIX}${device_name}${SYMLINK_SUFFIX}"
    local entry="file://$mount_point $label"

    if ! grep -qxF "$entry" "$BOOKMARK_FILE" 2>/dev/null; then
        mkdir -p "$(dirname "$BOOKMARK_FILE")"
        echo "$entry" >> "$BOOKMARK_FILE"
        echo "$entry" > "$BOOKMARK_ENTRY_FILE"
        log_message "INFO" "🔖 Device bookmark added: $label"
        log_message "DEBUG" "Bookmark points to: $mount_point (shows internal storage, SD cards, etc. as subfolders)"
    else
        log_message "DEBUG" "Bookmark already exists: $label"
    fi
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
        DEVICE_NAME=$(get_device_name "$(basename "$MNT")")

        if [[ -z "$DEVICE_NAME" ]]; then
            log_message "WARN" "Could not determine device name, using mount path"
            DEVICE_NAME=$(basename "$MNT" | sed 's/sftp:host=\([^,]*\).*/\1/')
        fi

        log_message "INFO" "Device name: '$DEVICE_NAME'"

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

        # Create single hierarchical bookmark pointing to device root
        create_device_bookmark "$DEVICE_NAME" "$MNT"

        # Process each discovered storage path for symlinks
        local external_count=1
        local success_count=0
        local storage_summary=()

        for storage_info in "${storage_paths[@]}"; do
            local storage_type="${storage_info%%:*}"
            local storage_path="${storage_info#*:}"
            local storage_index=""

            # For external storage, assign index if multiple
            if [[ "$storage_type" == "external" ]]; then
                storage_index="$external_count"
                ((external_count++))
            fi

            log_message "DEBUG" "Processing $storage_type storage: $storage_path"

            # Create symlink for this storage
            if create_storage_symlink "$DEVICE_NAME" "$storage_type" "$storage_path" "$storage_index"; then
                ((success_count++))

                # Add to summary for notification
                local storage_label="$storage_type"
                if [[ "$storage_type" == "external" ]] && [[ -n "$storage_index" ]] && [[ "$storage_index" -gt 1 ]]; then
                    storage_label="$storage_type $storage_index"
                fi
                storage_summary+=("${storage_label}: $(basename "$storage_path")")
            fi
        done

        if [[ $success_count -gt 0 ]]; then
            touch "$FLAG_FILE"
            log_message "INFO" "✅ Mount setup complete for: $DEVICE_NAME ($success_count storage path(s))"

            # Send consolidated notification
            local notification_text="Device mounted: $DEVICE_NAME\n"
            notification_text+="📁 Bookmark: Browse all storage in file manager\n"
            notification_text+="🔗 Symlinks: $(printf '%s, ' "${storage_summary[@]}" | sed 's/, $//')"
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

        # Remove symlinks
        if [[ -f "$LINK_PATH_FILE" ]]; then
            local symlink_count=0
            local device_name=""

            while IFS= read -r link_to_remove; do
                if [[ -n "$link_to_remove" ]] && [[ -L "$link_to_remove" ]]; then
                    # Extract device name from first symlink (for notification)
                    if [[ -z "$device_name" ]]; then
                        device_name=$(basename "$link_to_remove" | sed "s/^$SYMLINK_PREFIX//; s/$SYMLINK_SUFFIX$//; s/$INTERNAL_STORAGE_SUFFIX$//; s/$EXTERNAL_STORAGE_SUFFIX[0-9]*$//")
                    fi

                    rm "$link_to_remove"
                    log_message "INFO" "🔗 Symlink removed: $link_to_remove"
                    ((symlink_count++))
                fi
            done < "$LINK_PATH_FILE"

            if [[ $symlink_count -gt 0 ]]; then
                log_message "INFO" "Removed $symlink_count symlink(s)"
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
