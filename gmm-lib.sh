#!/usr/bin/env bash
set -euo pipefail

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # No Color

CONFIG_DIR="${CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gmm}"
CONFIG_FILE="$CONFIG_DIR/gmm.conf"

LOG_FILE="${LOG_FILE:-$CONFIG_DIR/gmm.log}"
LOCK_FILE="/tmp/gmm.lock"
DEVICE_STATE_FILE="$CONFIG_DIR/.device_state"
MANAGED_DEVICES_LOG="$CONFIG_DIR/managed_devices.log"

mkdir -p "$CONFIG_DIR"

POLL_INTERVAL="${POLL_INTERVAL:-3}"
MOUNT_ROOT="${MOUNT_ROOT:-/run/user/$(id -u)/gvfs}"
MOUNT_STRUCTURE_DIR="${MOUNT_STRUCTURE_DIR:-$HOME}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
MAX_LOG_SIZE="${MAX_LOG_SIZE:-1024}"
LOG_ROTATE_COUNT="${LOG_ROTATE_COUNT:-5}"
AUTO_CLEANUP="${AUTO_CLEANUP:-true}"
STORAGE_TIMEOUT="${STORAGE_TIMEOUT:-10}"
DETECT_GVFS_PATH="${DETECT_GVFS_PATH:-true}"
ENABLE_BOOKMARKS="${ENABLE_BOOKMARKS:-true}"
BOOKMARK_FILE="${BOOKMARK_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/gtk-3.0/bookmarks}"
INTERNAL_STORAGE_PATHS="${INTERNAL_STORAGE_PATHS:-/storage/emulated/0}"
EXTERNAL_STORAGE_PATHS="${EXTERNAL_STORAGE_PATHS:-}"
USB_STORAGE_PATHS="${USB_STORAGE_PATHS:-}"
GMM_BACKEND="${GMM_BACKEND:-auto}" # auto, gsconnect, or kdeconnect

# Generic log rotation function
# Parameters: log_file_path, max_size_kb, rotate_count, [use_log_function]
# If use_log_function is true, uses log() function for output, otherwise uses printf
rotate_log_file() {
    local log_file="$1" max_size="$2" rotate_count="$3" use_log="${4:-false}"

    if [[ ! -f "$log_file" ]]; then return 0; fi

    local size_kb
    if ! size_kb=$(du -k "$log_file" 2>/dev/null | cut -f1) || ! [[ "$size_kb" =~ ^[0-9]+$ ]]; then
        if [[ "$use_log" == "true" ]]; then
            log "WARN" "Failed to get log file size for rotation, skipping..."
        else
            printf "[WARN] Failed to get log file size for rotation, skipping...\n" >&2
        fi
        return 1
    fi

    if [[ "$max_size" -le 0 ]] || [[ "$rotate_count" -le 0 ]]; then return 0; fi

    if [[ $size_kb -gt "$max_size" ]]; then
        if [[ "$use_log" == "true" ]]; then
            log "INFO" "Log file size (%s KB) exceeds max size (%s KB). Rotating logs." "$size_kb" "$max_size"
        else
            printf "[INFO] Log file size (%s KB) exceeds max size (%s KB). Rotating logs.\n" "$size_kb" "$max_size" >&2
        fi

        for i in $(seq $((rotate_count - 1)) -1 1); do
            if [[ -f "$log_file.$i" ]]; then
                if ! mv "$log_file.$i" "$log_file.$((i + 1))" 2>/dev/null; then
                    if [[ "$use_log" == "true" ]]; then
                        log "ERROR" "Failed to rotate log file %s" "$log_file.$i"
                    else
                        printf "[ERROR] Failed to rotate log file %s\n" "$log_file.$i" >&2
                    fi
                fi
            fi
        done

        if ! mv "$log_file" "$log_file.1" 2>/dev/null; then
            if [[ "$use_log" == "true" ]]; then
                log "ERROR" "Failed to move main log file to %s.1" "$log_file"
            else
                printf "[ERROR] Failed to move main log file to %s.1\n" "$log_file" >&2
            fi
            return 1
        fi

        if ! touch "$log_file" 2>/dev/null; then
            if [[ "$use_log" == "true" ]]; then
                log "ERROR" "Failed to create new log file %s" "$log_file"
            else
                printf "[ERROR] Failed to create new log file %s\n" "$log_file" >&2
            fi
            return 1
        fi

        if [[ "$use_log" == "true" ]]; then
            log "INFO" "Log rotation completed successfully."
        else
            printf "[INFO] Log rotation completed successfully.\n" >&2
        fi
    fi
    return 0
}

# Managed Devices Log Rotation
MANAGED_DEVICES_LOG_MAX_SIZE="${MANAGED_DEVICES_LOG_MAX_SIZE:-100}" # in KB
MANAGED_DEVICES_LOG_ROTATE_COUNT="${MANAGED_DEVICES_LOG_ROTATE_COUNT:-3}"

rotate_logs() {
    rotate_log_file "$LOG_FILE" "$MAX_LOG_SIZE" "$LOG_ROTATE_COUNT" "false"
}

rotate_managed_devices_log() {
    rotate_log_file "$MANAGED_DEVICES_LOG" "$MANAGED_DEVICES_LOG_MAX_SIZE" "$MANAGED_DEVICES_LOG_ROTATE_COUNT" "true"
}

# Unified logging function with colored terminal output and file logging
# Usage: log LEVEL MESSAGE
# Levels: DEBUG, INFO, WARN, ERROR
log() {
    local level="$1" message="$2"

    # Only attempt log rotation if not already in a log rotation failure context
    if [[ -z "${_GMM_LOG_ROTATION_IN_PROGRESS:-}" ]]; then
        if ! rotate_logs; then
            # Set flag to prevent recursive log rotation attempts
            _GMM_LOG_ROTATION_IN_PROGRESS=1 log "WARN" "Log rotation failed, continuing..."
            unset _GMM_LOG_ROTATION_IN_PROGRESS
        fi
    fi

    local levels=("DEBUG" "INFO" "WARN" "ERROR")
    local current_level_idx=1 level_idx=1

    # Determine if we should log this message based on LOG_LEVEL
    for i in "${!levels[@]}"; do
        [[ "${levels[$i]}" == "$LOG_LEVEL" ]] && current_level_idx=$i
        [[ "${levels[$i]}" == "$level" ]] && level_idx=$i
    done

    if [[ $level_idx -ge $current_level_idx ]]; then
        local color=""
        case "$level" in
            "DEBUG") color="$BLUE" ;;
            "INFO")  color="$GREEN" ;;
            "WARN")  color="$YELLOW" ;;
            "ERROR") color="$RED" ;;
        esac
        
        # Colored output to terminal
        printf "%b[%s] [%s] %s%b\n" "$color" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$message" "$NC" >&2
        
        # Plain log to file
        printf "[%s] [%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$message" >> "$LOG_FILE"
    fi
}

# Load configuration from gmm.conf and set default values for all options
# This function ensures all configuration variables have sensible defaults
load_config() {
    mkdir -p "$CONFIG_DIR"
    touch "$LOG_FILE" "$MANAGED_DEVICES_LOG"

    # Source the config file if it exists
    if [[ -f "$CONFIG_FILE" ]]; then
        # Validate config file before sourcing
        if ! grep -q '^[a-zA-Z_][a-zA-Z0-9_]*=.*' "$CONFIG_FILE" 2>/dev/null; then
            log "WARN" "Config file appears to be empty or malformed"
        else
            # Source the config file
            source "$CONFIG_FILE"
            log "DEBUG" "Configuration loaded from $CONFIG_FILE"
        fi
    else
        log "DEBUG" "No config file found at $CONFIG_FILE, using defaults"
    fi

    # Expand $HOME in path variables
    MOUNT_ROOT="${MOUNT_ROOT//\$HOME/$HOME}"
    MOUNT_STRUCTURE_DIR="${MOUNT_STRUCTURE_DIR//\$HOME/$HOME}"
    BOOKMARK_FILE="${BOOKMARK_FILE//\$HOME/$HOME}"
    

    # If BOOKMARK_FILE points to a directory, append the default 'bookmarks' filename
    if [[ -n "${BOOKMARK_FILE:-}" && -d "$BOOKMARK_FILE" ]]; then
        log "WARN" "BOOKMARK_FILE in config points to a directory. Using $BOOKMARK_FILE/bookmarks instead."
        BOOKMARK_FILE="$BOOKMARK_FILE/bookmarks"
    fi
}

sanitize_name() {
    local name="$1"

    # Handle empty input
    if [[ -z "$name" ]]; then
        log "ERROR" "Empty device name provided to sanitize_name, defaulting to 'unknown_device'"
        echo "unknown_device"
        return
    fi

    # Replace invalid characters with underscores
    name="${name//[^a-zA-Z0-9._-]/_}"

    # Check if name became empty or contains only underscores/spaces after sanitization
    local cleaned_name="${name//_/}"
    cleaned_name="${cleaned_name// /}"
    if [[ -z "$cleaned_name" ]]; then
        log "ERROR" "Device name '$1' became invalid after sanitization (contains only invalid characters), defaulting to 'unknown_device'"
        echo "unknown_device"
        return
    fi

    # Truncate if too long
    if [[ ${#name} -gt 128 ]]; then
        log "WARN" "Device name too long (${#name} chars), truncating to 128 characters"
        name="${name:0:128}"
        # Re-check if truncated name is still valid
        cleaned_name="${name//_/}"
        cleaned_name="${cleaned_name// /}"
        if [[ -z "$cleaned_name" ]]; then
            log "WARN" "Truncated device name became invalid, using fallback"
            echo "unknown_device"
            return
        fi
    fi

    echo "$name"
}

get_host_from_mount() {
    local mount_path="$1"
    [[ "$mount_path" =~ sftp:host=([^,]+) ]] && echo "${BASH_REMATCH[1]}" || echo ""
}

detect_backend() {
    if [[ "$GMM_BACKEND" == "gsconnect" ]] || [[ "$GMM_BACKEND" == "kdeconnect" ]]; then
        echo "$GMM_BACKEND"
        return
    fi

    # Auto-detection: Check for DBus services
    if gdbus introspect --session --dest org.gnome.Shell.Extensions.GSConnect --object-path /org/gnome/Shell/Extensions/GSConnect >/dev/null 2>&1; then
        echo "gsconnect"
    elif gdbus introspect --session --dest org.kde.kdeconnect --object-path /modules/kdeconnect >/dev/null 2>&1; then
        echo "kdeconnect"
    else
        echo "none"
    fi
}

get_device_id_from_dbus() {
    local backend="$1"
    if [[ "$backend" == "kdeconnect" ]]; then
        local device_ids_str
        device_ids_str=$(timeout 5 gdbus call --session \
            --dest org.kde.kdeconnect \
            --object-path /modules/kdeconnect \
            --method org.kde.kdeconnect.daemon.devices 2>/dev/null || echo "")
        
        if [[ -n "$device_ids_str" ]]; then
            # Robustly parse: (['...'],)
            echo "$device_ids_str" | sed -e "s/([['\"]//g" -e "s/['\"])],*//g" | head -n 1
        fi
    fi
}

get_device_name_from_dbus() {
    local backend="$1"
    local device_id="$2"
    local device_name=""

    if [[ "$backend" == "gsconnect" ]]; then
        local device_path
        device_path=$(timeout 5 gdbus call --session \
            --dest org.gnome.Shell.Extensions.GSConnect \
            --object-path /org/gnome/Shell/Extensions/GSConnect \
            --method org.freedesktop.DBus.ObjectManager.GetManagedObjects 2>/dev/null | \
            grep -o '/org/gnome/Shell/Extensions/GSConnect/Device/[a-z0-9]\+' | head -n 1)

        if [[ -n "$device_path" ]]; then
            local gdbus_output
            gdbus_output=$(timeout 5 gdbus call --session \
                --dest org.gnome.Shell.Extensions.GSConnect \
                --object-path "$device_path" \
                --method org.freedesktop.DBus.Properties.Get "org.gnome.Shell.Extensions.GSConnect.Device" "Name" 2>/dev/null)
            
            if [[ "$gdbus_output" =~ \<\'([^\']+)\'\> ]] || [[ "$gdbus_output" =~ ['"]([^'"]*)['"] ]]; then
                device_name="${BASH_REMATCH[1]}"
            fi
        fi
    elif [[ "$backend" == "kdeconnect" ]] && [[ -n "$device_id" ]]; then
        local gdbus_output
        gdbus_output=$(timeout 5 gdbus call --session \
            --dest org.kde.kdeconnect \
            --object-path "/modules/kdeconnect/devices/$device_id" \
            --method org.freedesktop.DBus.Properties.Get "org.kde.kdeconnect.device" "name" 2>/dev/null)

        if [[ "$gdbus_output" =~ \<\'([^\']+)\'\> ]] || [[ "$gdbus_output" =~ ['"]([^'"]*)['"] ]]; then
            device_name="${BASH_REMATCH[1]}"
        fi
    fi

    if [[ -z "$device_name" ]]; then
        log "WARN" "Could not get device name from DBus for backend $backend"
    fi

    echo "$device_name"
}

discover_storage() {
    local mount_point="$1"
    local -a storage_paths=()
    local -A storage_types=(
        ["INTERNAL_STORAGE_PATHS"]="internal:Internal"
        ["EXTERNAL_STORAGE_PATHS"]="external:External"
        ["USB_STORAGE_PATHS"]="usb:USB-OTG"
    )

    log "DEBUG" "Discovering storage for mount point: $mount_point"

    for var_name in "${!storage_types[@]}"; do
        local config_paths_str="${!var_name}"
        local type_name="${storage_types[$var_name]%%:*}"
        local display_name="${storage_types[$var_name]##*:}"

        if [[ -n "$config_paths_str" ]]; then
            # Split comma-separated paths
            IFS=',' read -r -a paths_array <<< "$config_paths_str"
            for path_segment in "${paths_array[@]}"; do
                local full_path="$mount_point/$path_segment"
                # Use timeout to prevent hanging on unresponsive network filesystems
                if timeout 5 [ -d "$full_path" ] 2>/dev/null; then
                    storage_paths+=("$type_name:$full_path:$display_name")
                    log "INFO" "Added $type_name storage: $full_path (Display: $display_name)"
                else
                    log "WARN" "$type_name storage path not found or timeout: $full_path"
                fi
            done
        fi
    done

    printf '%s\n' "${storage_paths[@]}"
}


ensure_kdeconnect_mount() {
    local backend="$1"
    local device_id="$2"

    if [[ "$backend" != "kdeconnect" ]] || [[ -z "$device_id" ]]; then
        return
    fi

    local is_mounted
    is_mounted=$(gdbus call --session --dest org.kde.kdeconnect \
        --object-path "/modules/kdeconnect/devices/$device_id/sftp" \
        --method org.kde.kdeconnect.device.sftp.isMounted 2>/dev/null || echo "(false,)")
    
    if [[ "$is_mounted" != "(true,)" ]]; then
        log "INFO" "KDE Connect device not mounted. Attempting to mount..."
        gdbus call --session --dest org.kde.kdeconnect \
            --object-path "/modules/kdeconnect/devices/$device_id/sftp" \
            --method org.kde.kdeconnect.device.sftp.mount >/dev/null 2>&1
        sleep 2 # Give it a moment to mount
    fi
}

create_symlinks() {
    local device_dir="$1"
    shift
    local -a storage_info=("$@")
    local symlink_created=false

    for info in "${storage_info[@]}"; do
        # Expected format: type:path:display_name
        # Since path may contain colons, we need to parse carefully
        # Extract type (everything before the first colon)
        local type="${info%%:*}"
        local rest="${info#*:}"
        # Extract display_name (everything after the last colon)
        local display_name="${rest##*:}"
        local path="${rest%:*}"

        # Use display_name from discover_storage, fallback if empty
        if [[ -z "$display_name" ]]; then
            case "$type" in
                internal) display_name="Internal" ;;
                external) display_name="External" ;;
                usb)      display_name="USB-OTG" ;;
                *)        display_name="Storage" ;;
            esac
        fi

        local link_target="$device_dir/$display_name"
        if [[ -L "$link_target" ]]; then
            # existing symlink: check target and replace if different or broken
            local existing_target=$(readlink "$link_target" 2>/dev/null || true)
            if [[ "$existing_target" != "$path" ]]; then
                rm -f "$link_target"
                ln -s "$path" "$link_target"
                log "INFO" "Replaced symlink: $link_target -> $path"
                symlink_created=true
            else
                log "DEBUG" "Symlink already correct: $link_target -> $path"
            fi
        elif [[ -e "$link_target" ]]; then
            log "WARN" "Path exists and is not a symlink: $link_target. Skipping."
        else
            ln -s "$path" "$link_target"
            log "INFO" "Created symlink: $link_target -> $path"
            symlink_created=true
        fi
    done

    [[ "$symlink_created" == true ]]
}

bookmarks_enabled() {
    local enabled="${ENABLE_BOOKMARKS:-true}"
    [[ "$enabled" == true || "$enabled" == "1" ]]
}

# Validate bookmark file path for safety
# Ensures the bookmark file is writable and within the user's config directory
validate_bookmark_file() {
    local bookmark_file="$1"

    # Basic safety: ensure bookmark file is under user's config dir (canonical path check)
    local bookmark_file_real allowed_config
    bookmark_file_real=$(realpath -m "$bookmark_file" 2>/dev/null)
    allowed_config=$(realpath -m "${XDG_CONFIG_HOME:-$HOME/.config}" 2>/dev/null)
    if [[ -z "$bookmark_file_real" || -z "$allowed_config" ]]; then
        log "ERROR" "Failed to resolve paths for bookmark file safety check."
        return 1
    fi

    # Only allow writing inside the user's config directory, not just any subdirectory of $HOME
    case "$bookmark_file_real" in
        "$allowed_config"/*) ;;
        "$allowed_config") ;;
        *) log "ERROR" "Refusing to write bookmark file outside user config directory: $bookmark_file"; return 1 ;;
    esac

    if ! touch "$bookmark_file" 2>/dev/null; then
        log "ERROR" "Bookmark file not writable: $bookmark_file"
        return 1
    fi

    return 0
}

add_bookmark() {
    local device_name="$1" host="$2" port="$3"
    shift 3 # Shift off device_name, host, port
    local -a storage_info=("$@") # Remaining arguments are storage_info

    # Respect config toggle
    if ! bookmarks_enabled; then
        log "DEBUG" "Bookmarks disabled by configuration. Skipping add for $device_name"
        return
    fi

    # Validate bookmark file safety
    if ! validate_bookmark_file "$BOOKMARK_FILE"; then
        return
    fi

    local sanitized_device_name=$(sanitize_name "$device_name")
    
    if [[ -n "$host" && -n "$port" ]]; then
        for info in "${storage_info[@]}"; do
            # Expected format: type:path:name
            local type="${info%%:*}"
            local rest="${info#*:}"
            local name="${rest##*:}"
            local path="${rest%:*}"

            # Extract the path relative to the mount point for the SFTP URL
            # Example path: /run/user/1000/gvfs/sftp:host=192.168.1.66,port=1739//storage/emulated/0
            # We need to extract //storage/emulated/0
            local sftp_relative_path
            if [[ "$path" =~ sftp:host=.*,port=[0-9]+//(.*) ]]; then
                sftp_relative_path="/${BASH_REMATCH[1]}"
            else
                sftp_relative_path="/" # Fallback to root if path format is unexpected
            fi

            local bookmark_display_name="${sanitized_device_name}/${name}"
            local sftp_bookmark="sftp://$host:$port$sftp_relative_path $bookmark_display_name"

            if ! grep -qF "$sftp_bookmark" "$BOOKMARK_FILE"; then
                echo "$sftp_bookmark" >> "$BOOKMARK_FILE"
                log "INFO" "Added SFTP bookmark for $device_name ($name): $sftp_bookmark"
            else
                log "DEBUG" "SFTP bookmark already exists for $device_name ($name): $sftp_bookmark"
            fi
        done
    else
        log "WARN" "Cannot create SFTP bookmarks for $device_name: host or port is missing."
    fi
}

remove_bookmark() {
    local device_name="$1"
    # Respect config toggle
    if ! bookmarks_enabled; then
        log "DEBUG" "Bookmarks disabled by configuration. Skipping remove for $device_name"
        return
    fi

    if [[ -f "$BOOKMARK_FILE" ]] && [[ "$BOOKMARK_FILE" != "/dev/null" ]]; then
        local sanitized_name=$(sanitize_name "$device_name")
        
        # Remove all bookmarks for this device
        sed -i "\| $sanitized_name/|d" "$BOOKMARK_FILE"
        
        log "INFO" "Removed bookmarks for $device_name"
    elif [[ "$BOOKMARK_FILE" == "/dev/null" ]]; then
        log "DEBUG" "Bookmark file redirected to /dev/null, skipping bookmark removal"
    else
        log "DEBUG" "Bookmark file does not exist: $BOOKMARK_FILE"
    fi
}

# Helper function for cleaning up device artifacts
# Parameters: device_name, sanitized_name
cleanup_single_device() {
    local device_name="$1" sanitized_name="$2"

    log "INFO" "Cleaning up artifacts for device: $device_name"
    remove_bookmark "$device_name"

    if [[ -n "$sanitized_name" ]]; then
        local device_dir="$MOUNT_STRUCTURE_DIR/$sanitized_name"
        if [[ "$AUTO_CLEANUP" == true ]] && [[ -d "$device_dir" ]]; then
            if validate_device_dir "$device_dir"; then
                rm -rf -- "$device_dir"
                log "INFO" "Removed directory: $device_dir"
            else
                log "ERROR" "Safety validation failed for directory '$device_dir'. Aborting deletion."
            fi
        elif [[ "$AUTO_CLEANUP" != true ]]; then
            log "DEBUG" "Auto cleanup disabled. Skipping directory removal for: $device_dir"
        elif [[ ! -d "$device_dir" ]]; then
            log "DEBUG" "Device directory does not exist, nothing to remove: $device_dir"
        fi
    else
        log "DEBUG" "No sanitized name provided, skipping directory cleanup"
    fi
}

cleanup_device_artifacts() {
    local device_name="$1" sanitized_name="$2"
    cleanup_single_device "$device_name" "$sanitized_name"
}

uninstall_cleanup() {
    log "INFO" "Performing full uninstall cleanup..."
    if [[ ! -f "$MANAGED_DEVICES_LOG" ]]; then
        log "INFO" "No managed device log found. Nothing to clean up."
        return
    fi

    local cleaned_entries=()
    while IFS='|' read -r device_name sanitized_name host || [[ -n "$device_name" ]]; do
        if [[ " ${cleaned_entries[*]} " =~ " $sanitized_name " ]]; then continue; fi

        cleanup_single_device "$device_name" "$sanitized_name"
        cleaned_entries+=("$sanitized_name")
    done < "$MANAGED_DEVICES_LOG"

    log "INFO" "Uninstall cleanup complete."
}

validate_device_dir() {
    local device_dir="$1"

    if [[ -z "$device_dir" ]]; then
        log "ERROR" "Device directory path is empty - refusing to proceed"
        return 1
    fi

    if [[ "$device_dir" == "/" ]]; then
        log "ERROR" "Refusing to delete root directory: $device_dir"
        return 1
    fi

    if [[ "$device_dir" == "$HOME" ]]; then
        log "ERROR" "Refusing to delete home directory: $device_dir"
        return 1
    fi

    local canonical_device_dir
    if ! canonical_device_dir=$(timeout 5 realpath -m "$device_dir" 2>/dev/null); then
        log "ERROR" "Timeout or could not canonicalize device directory path: $device_dir"
        return 1
    fi

    local canonical_base
    if ! canonical_base=$(timeout 5 realpath -m "$MOUNT_STRUCTURE_DIR" 2>/dev/null); then
        log "ERROR" "Timeout or could not canonicalize base directory path: $MOUNT_STRUCTURE_DIR"
        return 1
    fi

    if ! [[ "$canonical_device_dir" == "$canonical_base"* ]]; then
        log "ERROR" "Device directory $canonical_device_dir is not inside base directory $canonical_base"
        return 1
    fi

    local relative_path="${canonical_device_dir#$canonical_base}"
    relative_path="${relative_path#/}"
    if [[ -z "$relative_path" ]]; then
        log "ERROR" "Device directory resolves to base directory itself: $device_dir"
        return 1
    fi

    log "DEBUG" "Device directory validation passed for: $device_dir"
    return 0
}
