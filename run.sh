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

# File locking functions
lock_file() {
    local lockfile="$1.lock"
    local timeout="${2:-10}"
    local count=0
    
    while [[ $count -lt $timeout ]]; do
        if mkdir "$lockfile" 2>/dev/null; then
            echo $$ > "$lockfile/PID" 2>/dev/null || true
            return 0
        fi
        sleep 1
        ((count++))
    done
    
    return 1
}

unlock_file() {
    local lockfile="$1.lock"
    if [[ -d "$lockfile" ]] && [[ -f "$lockfile/PID" ]] && [[ "$(cat "$lockfile/PID")" == "$$" ]]; then
        rm -rf "$lockfile"
    fi
}

# Logging functions
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Check if we should log this level (always log if VERBOSE is true)
    if [[ "$VERBOSE" != true ]]; then
        case "$LOG_LEVEL" in
            DEBUG) ;;
            INFO) [[ "$level" == "DEBUG" ]] && return ;;
            WARN) [[ "$level" == "DEBUG" || "$level" == "INFO" ]] && return ;;
            ERROR) [[ "$level" != "ERROR" ]] && return ;;
        esac
    fi

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

# Conditional logging function for command substitution contexts
log_conditional() {
    local level="$1"
    local message="$2"
    
    # Only log if not in command substitution (when stdout is not captured)
    if [[ -t 1 ]]; then
        log_message "$level" "$message"
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
            if lock_file "$LOG_FILE"; then
                for i in $(seq $((LOG_ROTATE_COUNT-1)) -1 1); do
                    [[ -f "$LOG_FILE.$i" ]] && mv "$LOG_FILE.$i" "$LOG_FILE.$((i+1))"
                done
                mv "$LOG_FILE" "$LOG_FILE.1"
                touch "$LOG_FILE"
                unlock_file "$LOG_FILE"
                log_conditional "INFO" "Log rotated (was ${size_mb}MB)"
            else
                log_conditional "ERROR" "Failed to acquire lock for log file during rotation"
            fi
        fi
    fi
}

# Desktop notification function
send_notification() {
    if [[ "$ENABLE_NOTIFICATIONS" != true ]]; then
        return
    fi
    
    local message="$1"
    
    # Try multiple notification systems based on desktop environment
    local desktop_env=$(echo "$XDG_CURRENT_DESKTOP" | tr '[:upper:]' '[:lower:]')
    
    # KDE notification
    if [[ "$desktop_env" == *"kde"* ]] && command -v kdialog >/dev/null 2>&1; then
        kdialog --passivepopup "$message" 5 2>/dev/null
        return
    fi
    
    # GNOME and other desktops with notify-send
    if command -v notify-send >/dev/null 2>&1; then
        notify-send "GSConnect Mount Manager" "$message" --icon=phone 2>/dev/null
        return
    fi
    
    # Fallback to terminal output if no notification system available
    log_conditional "INFO" "Notification: $message"
}

get_device_name() {
    local mnt_path=$1
    # Temporarily store the current VERBOSE setting
    local original_verbose="$VERBOSE"
    # Temporarily disable verbose logging to prevent stdout interference
    VERBOSE=false
    
    log_conditional "DEBUG" "Attempting to get device name from mount path: $mnt_path"
    # Extract host IP
    local host=$(echo "$mnt_path" | sed -n 's/.*host=\([^,]*\).*/\1/p')
    log_conditional "DEBUG" "Extracted host IP: $host"

    if [[ -z "$host" ]]; then
        log_conditional "ERROR" "Could not extract host IP from mount path: $mnt_path"
        # Restore original VERBOSE setting
        VERBOSE="$original_verbose"
        return 1
    fi

    log_conditional "DEBUG" "Looking for GSConnect device with host IP: $host"

    # Check if dconf is available
    if ! command -v dconf >/dev/null 2>&1; then
        log_conditional "ERROR" "dconf command not found. GSConnect may not be installed."
        # Restore original VERBOSE setting
        VERBOSE="$original_verbose"
        return 1
    fi

    # Find the device ID that matches the host IP
    local device_list
    if ! device_list=$(dconf list /org/gnome/shell/extensions/gsconnect/device/ 2>/dev/null); then
        log_conditional "ERROR" "Cannot access GSConnect device list. GSConnect may not be configured."
        # Restore original VERBOSE setting
        VERBOSE="$original_verbose"
        return 1
    fi
    log_conditional "DEBUG" "Found GSConnect devices: $(echo "$device_list" | tr '\n' ' ')"

    for dev_id in $(echo "$device_list" | grep '/$'); do
        local full_path="/org/gnome/shell/extensions/gsconnect/device/${dev_id}"
        log_conditional "DEBUG" "Checking device path: $full_path"
        # Extract last connection IP
        local last_conn_ip=$(dconf read "${full_path}last-connection" 2>/dev/null | tr -d "'" | sed -n 's/lan:\/\/\([^:]*\):.*/\1/p')
        log_conditional "DEBUG" "Device $dev_id has last known IP: $last_conn_ip"

        if [[ "$last_conn_ip" == "$host" ]]; then
            local device_name=$(dconf read "${full_path}name" 2>/dev/null | tr -d "'")
            log_conditional "INFO" "Found matching device: '$device_name' for IP $host"
            # Restore original VERBOSE setting
            VERBOSE="$original_verbose"
            echo "$device_name"
            return 0
        fi
    done

    log_conditional "WARN" "No matching GSConnect device found for host IP: $host"
    # Restore original VERBOSE setting
    VERBOSE="$original_verbose"
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

# Function to detect GVFS mount path
detect_gvfs_path() {
    # If detection is disabled, return the configured path
    if [[ "$DETECT_GVFS_PATH" != true ]]; then
        echo "$MOUNT_ROOT"
        return
    fi
    
    # Try common GVFS paths
    local possible_paths=(
        "/run/user/$(id -u)/gvfs"           # Most common path
        "/home/$(id -un)/.gvfs"             # Older GNOME versions
        "/var/run/user/$(id -u)/gvfs"       # Some distributions
    )
    
    for path in "${possible_paths[@]}"; do
        if [[ -d "$path" ]]; then
            log_conditional "DEBUG" "Detected GVFS path: $path"
            echo "$path"
            return
        fi
    done
    
    # If none found, return the configured path
    log_conditional "WARN" "No GVFS path found, using configured path: $MOUNT_ROOT"
    echo "$MOUNT_ROOT"
}



# Function to cleanup broken symlinks
cleanup_broken_symlinks() {
    if [[ "$AUTO_CLEANUP" != true ]]; then
        log_conditional "DEBUG" "Auto cleanup disabled. Skipping."
        return
    fi

    if [[ ! -d "$MOUNT_STRUCTURE_DIR" ]]; then
        log_conditional "DEBUG" "Mount structure directory not found. Skipping cleanup."
        return
    fi

    log_conditional "DEBUG" "Starting cleanup of broken symlinks in $MOUNT_STRUCTURE_DIR"
    local broken_links
    mapfile -t broken_links < <(find "$MOUNT_STRUCTURE_DIR" -type l ! -exec test -e {} \; -print 2>/dev/null)

    if [[ ${#broken_links[@]} -gt 0 ]]; then
        log_conditional "DEBUG" "Found ${#broken_links[@]} broken symlinks."
        for broken_link in "${broken_links[@]}"; do
            if [[ -n "$broken_link" ]]; then
                rm "$broken_link"
                log_conditional "INFO" "Cleaned up broken symlink: $broken_link"
            fi
        done
    else
        log_conditional "DEBUG" "No broken symlinks found."
    fi

    log_conditional "DEBUG" "Checking for empty device directories..."
    local empty_dirs
    mapfile -t empty_dirs < <(find "$MOUNT_STRUCTURE_DIR" -mindepth 1 -maxdepth 1 -type d -empty -print 2>/dev/null)

    if [[ ${#empty_dirs[@]} -gt 0 ]]; then
        log_conditional "DEBUG" "Found ${#empty_dirs[@]} empty device directories."
        for empty_dir in "${empty_dirs[@]}"; do
            if [[ -n "$empty_dir" ]]; then
                rmdir "$empty_dir"
                log_conditional "INFO" "Cleaned up empty device directory: $(basename "$empty_dir")"
            fi
        done
    else
        log_conditional "DEBUG" "No empty device directories found."
    fi
}

# Function to discover available storage paths on device
discover_storage_paths() {
    local mount_point="$1"
    local storage_paths=()

    log_conditional "DEBUG" "Starting storage path discovery in: $mount_point"

    # Check for internal storage
    if [[ "$ENABLE_INTERNAL_STORAGE" == true ]]; then
        log_conditional "DEBUG" "Internal storage detection enabled. Path: $INTERNAL_STORAGE_PATH"
        local internal_path="$mount_point/$INTERNAL_STORAGE_PATH"
        if [[ -d "$internal_path" ]]; then
            storage_paths+=("internal:$internal_path")
            log_conditional "INFO" "Found internal storage: $internal_path"
        else
            log_conditional "WARN" "Internal storage path not found: $internal_path"
        fi
    else
        log_conditional "DEBUG" "Internal storage detection disabled."
    fi

    # Check for external storage
    if [[ "$ENABLE_EXTERNAL_STORAGE" == true ]]; then
        log_conditional "DEBUG" "External storage detection enabled. Patterns: $EXTERNAL_STORAGE_PATTERNS"
        local storage_dir="$mount_point/storage"
        if [[ -d "$storage_dir" ]]; then
            local external_count=0
            IFS=' ' read -ra patterns <<< "$EXTERNAL_STORAGE_PATTERNS"
            log_conditional "DEBUG" "Searching for patterns in: $storage_dir"

            for pattern in "${patterns[@]}"; do
                if [[ $external_count -ge $MAX_EXTERNAL_STORAGE ]]; then
                    log_conditional "DEBUG" "Reached max external storage limit ($MAX_EXTERNAL_STORAGE). Stopping search."
                    break
                fi

                log_conditional "DEBUG" "Checking pattern: $pattern"
                
                # Handle different pattern types
                if [[ "$pattern" == *"*"* ]] || [[ "$pattern" == *"["*"]"* ]] || [[ "$pattern" == *"?"* ]]; then
                    # This is a glob pattern, use find with -name
                    local found_paths
                    if ! mapfile -t found_paths < <(find "$storage_dir" -maxdepth 1 -type d -name "${pattern##*/}" -print 2>/dev/null); then
                        log_conditional "WARN" "Failed to execute find command for pattern: $pattern in $storage_dir"
                        continue
                    fi
                    for external_path in "${found_paths[@]}"; do
                        if [[ -n "$external_path" ]] && [[ -d "$external_path" ]] && [[ $external_count -lt $MAX_EXTERNAL_STORAGE ]]; then
                            storage_paths+=("external:$external_path")
                            log_conditional "INFO" "Found external storage (glob): $external_path"
                            ((external_count++))
                        fi
                    done
                else
                    # Direct path pattern
                    local external_path="$mount_point/$pattern"
                    if [[ -d "$external_path" ]] && [[ $external_count -lt $MAX_EXTERNAL_STORAGE ]]; then
                        storage_paths+=("external:$external_path")
                        log_conditional "INFO" "Found external storage (direct): $external_path"
                        ((external_count++))
                    fi
                fi
            done

            # Fallback: if no external storage found, try to find any storage directories
            if [[ $external_count -eq 0 ]]; then
                log_conditional "DEBUG" "No external storage devices found matching patterns. Trying fallback detection."
                local fallback_paths
                if ! mapfile -t fallback_paths < <(find "$storage_dir" -maxdepth 1 -type d -not -name "emulated" -not -name "." 2>/dev/null); then
                    log_conditional "WARN" "Failed to execute fallback find command in $storage_dir"
                else
                    log_conditional "DEBUG" "Fallback detection found ${#fallback_paths[@]} paths in $storage_dir"
                    for fallback_path in "${fallback_paths[@]}"; do
                        log_conditional "DEBUG" "Checking fallback path: $fallback_path"
                        if [[ -n "$fallback_path" ]] && [[ -d "$fallback_path" ]] && [[ $external_count -lt $MAX_EXTERNAL_STORAGE ]]; then
                            # Skip common system directories and the storage directory itself
                            local basename_fallback=$(basename "$fallback_path")
                            log_conditional "DEBUG" "Fallback path basename: $basename_fallback, storage_dir: $storage_dir, fallback_path: $fallback_path"
                            if [[ "$basename_fallback" != "self" ]] && [[ "$basename_fallback" != "emulated" ]] && [[ "$fallback_path" != "$storage_dir" ]]; then
                                storage_paths+=("external:$fallback_path")
                                log_conditional "INFO" "Found external storage (fallback): $fallback_path"
                                ((external_count++))
                            else
                                log_conditional "DEBUG" "Skipping fallback path: $fallback_path"
                            fi
                        fi
                    done
                fi
            fi
            
            if [[ $external_count -eq 0 ]]; then
                log_conditional "DEBUG" "No external storage devices found."
            fi
        else
            log_conditional "WARN" "Base storage directory not found: $storage_dir"
        fi
    else
        log_conditional "DEBUG" "External storage detection disabled."
    fi

    # Return the discovered paths
    if [[ ${#storage_paths[@]} -gt 0 ]]; then
        log_conditional "DEBUG" "Discovered storage paths: ${storage_paths[*]}"
        printf '%s\n' "${storage_paths[@]}"
    else
        log_conditional "WARN" "No storage paths were discovered."
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

    # Remove existing symlink or directory if it exists
    if [[ -L "$link_path" ]]; then
        rm "$link_path"
        log_conditional "DEBUG" "Removed existing symlink: $link_path"
    elif [[ -d "$link_path" ]]; then
        # It's a directory, remove it
        rm -rf "$link_path"
        log_conditional "DEBUG" "Removed existing directory: $link_path"
    elif [[ -e "$link_path" ]]; then
        # It's a regular file, remove it
        rm -f "$link_path"
        log_conditional "DEBUG" "Removed existing file: $link_path"
    fi

    # Create the symlink
    log_conditional "DEBUG" "create_storage_symlink called with parameters:"
    log_conditional "DEBUG" "  device_dir: $device_dir"
    log_conditional "DEBUG" "  storage_type: $storage_type"
    log_conditional "DEBUG" "  target_path: $target_path"
    log_conditional "DEBUG" "  storage_index: $storage_index"
    log_conditional "DEBUG" "  folder_name: $folder_name"
    log_conditional "DEBUG" "  link_path: $link_path"
    
    if ln -s "$target_path" "$link_path"; then
       if lock_file "$LINK_PATH_FILE"; then
           echo "$link_path" >> "$LINK_PATH_FILE"
           unlock_file "$LINK_PATH_FILE"
           log_conditional "INFO" "🔗 ${storage_type^} storage linked: $link_path → $target_path"
       else
           log_conditional "ERROR" "Failed to acquire lock for link path file"
       fi
       return 0
   else
       log_conditional "ERROR" "Failed to create symlink: $link_path"
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
    log_conditional "DEBUG" "Creating device directory: $device_dir"
    log_conditional "DEBUG" "MOUNT_STRUCTURE_DIR: $MOUNT_STRUCTURE_DIR"
    log_conditional "DEBUG" "device_name_sanitized: $device_name_sanitized"
    
    # If a directory or file with this name already exists, remove it
    if [[ -e "$device_dir" ]]; then
        log_conditional "DEBUG" "Device directory already exists"
        if [[ -d "$device_dir" ]] && [[ ! -L "$device_dir" ]]; then
            # It's a regular directory, remove it
            rm -rf "$device_dir"
            log_conditional "DEBUG" "Removed existing directory: $device_dir"
        elif [[ -L "$device_dir" ]]; then
            # It's already a symlink, remove it
            rm -f "$device_dir"
            log_conditional "DEBUG" "Removed existing symlink: $device_dir"
        else
            # It's a regular file, remove it
            rm -f "$device_dir"
            log_conditional "DEBUG" "Removed existing file: $device_dir"
        fi
    fi
    
    log_conditional "DEBUG" "About to create device directory with mkdir -p"
    log_conditional "DEBUG" "Command: mkdir -p \"$device_dir\""
    if mkdir -p "$device_dir"; then
        log_conditional "DEBUG" "Successfully created device directory: $device_dir"
        log_conditional "DEBUG" "Directory exists after creation: $(test -d "$device_dir" && echo "yes" || echo "no")"
    else
        log_conditional "ERROR" "Failed to create device directory: $device_dir"
        log_conditional "ERROR" "mkdir exit code: $?"
    fi

    # Create bookmark pointing to accessible device directory using display name
    local label="${SYMLINK_PREFIX}${device_name_display}${SYMLINK_SUFFIX}"
    local entry="file://$device_dir $label"

    # Check desktop environment and create appropriate bookmark
    local desktop_env=$(echo "$XDG_CURRENT_DESKTOP" | tr '[:upper:]' '[:lower:]')
    
    # For KDE, we can try to add to KDE bookmarks if available
    if [[ "$desktop_env" == *"kde"* ]]; then
        # Try to add to KDE bookmarks using kwriteconfig5 if available
        if command -v kwriteconfig5 >/dev/null 2>&1; then
            # KDE bookmarks are stored in ~/.local/share/user-places.xbel
            # We'll add the bookmark using kwriteconfig5
            if kwriteconfig5 --file ~/.local/share/user-places.xbel --group "Places" --key "GSConnectMount-$device_name_sanitized" "$device_dir" 2>/dev/null; then
                log_conditional "INFO" "🔖 Device bookmark added to KDE: $label"
            fi
        else
            # Fall back to GTK bookmarks if kwriteconfig5 is not available
            if ! grep -qxF "$entry" "$BOOKMARK_FILE" 2>/dev/null; then
                mkdir -p "$(dirname "$BOOKMARK_FILE")"
                if lock_file "$BOOKMARK_ENTRY_FILE"; then
                    echo "$entry" >> "$BOOKMARK_FILE"
                    echo "$entry" > "$BOOKMARK_ENTRY_FILE"
                    unlock_file "$BOOKMARK_ENTRY_FILE"
                    log_conditional "INFO" "🔖 Device bookmark added (fallback to GTK): $label"
                    log_conditional "DEBUG" "Bookmark points to accessible directory: $device_dir"
                else
                    log_conditional "ERROR" "Failed to acquire lock for bookmark entry file"
                fi
            else
                log_conditional "DEBUG" "Bookmark already exists: $label"
            fi
        fi
    else
        # For GNOME and other desktop environments, use GTK bookmarks
        if ! grep -qxF "$entry" "$BOOKMARK_FILE" 2>/dev/null; then
            mkdir -p "$(dirname "$BOOKMARK_FILE")"
            if lock_file "$BOOKMARK_ENTRY_FILE"; then
                echo "$entry" >> "$BOOKMARK_FILE"
                echo "$entry" > "$BOOKMARK_ENTRY_FILE"
                unlock_file "$BOOKMARK_ENTRY_FILE"
                log_conditional "INFO" "🔖 Device bookmark added: $label"
                log_conditional "DEBUG" "Bookmark points to accessible directory: $device_dir"
            else
                log_conditional "ERROR" "Failed to acquire lock for bookmark entry file"
            fi
        else
            log_conditional "DEBUG" "Bookmark already exists: $label"
        fi
    fi

    # Only output the device directory path, no debug messages
    echo "$device_dir"
}


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
