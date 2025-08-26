#!/bin/bash
# Device management functions for GSConnect Mount Manager

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