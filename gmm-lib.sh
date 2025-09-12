#!/usr/bin/env bash
set -euo pipefail

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # No Color

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gmm"
CONFIG_FILE="$CONFIG_DIR/gmm.conf"

LOG_FILE="$CONFIG_DIR/gmm.log"
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
rotate_logs() {
    if [[ ! -f "$LOG_FILE" ]]; then return 0; fi

    local size_kb
    if ! size_kb=$(du -k "$LOG_FILE" 2>/dev/null | cut -f1) || ! [[ "$size_kb" =~ ^[0-9]+$ ]]; then
        # Avoid calling log() here because rotate_logs may be invoked from log() itself
        printf "[WARN] Failed to get log file size for rotation, skipping...\n" >&2
        return 1
    fi

    if [[ "$MAX_LOG_SIZE" -le 0 ]] || [[ "$LOG_ROTATE_COUNT" -le 0 ]]; then return 0; fi

    if [[ $size_kb -gt "$MAX_LOG_SIZE" ]]; then
        printf "[INFO] Log file size (%s KB) exceeds max size (%s KB). Rotating logs.\n" "$size_kb" "$MAX_LOG_SIZE" >&2
        for i in $(seq $((LOG_ROTATE_COUNT - 1)) -1 1); do
            if [[ -f "$LOG_FILE.$i" ]]; then
                if ! mv "$LOG_FILE.$i" "$LOG_FILE.$((i + 1))" 2>/dev/null; then
                    printf "[ERROR] Failed to rotate log file %s\n" "$LOG_FILE.$i" >&2
                fi
            fi
        done
        if ! mv "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null; then
            printf "[ERROR] Failed to move main log file to %s.1\n" "$LOG_FILE" >&2
            return 1
        fi
        if ! touch "$LOG_FILE" 2>/dev/null; then
            printf "[ERROR] Failed to create new log file %s\n" "$LOG_FILE" >&2
            return 1
        fi
        printf "[INFO] Log rotation completed successfully.\n" >&2
    fi
    return 0
}

# Unified logging function with colored terminal output and file logging
# Usage: log LEVEL MESSAGE
# Levels: DEBUG, INFO, WARN, ERROR
log() {
    local level="$1" message="$2"

    rotate_logs || log "WARN" "Log rotation failed, continuing..."

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

    if [[ -z "$name" ]]; then
        log "ERROR" "Empty device name provided to sanitize_name, defaulting to 'unknown_device'"
        echo "unknown_device"
        return
    fi

    name="${name//[^a-zA-Z0-9._-]/_}"

    if [[ -z "${name//_/}" ]]; then
        log "ERROR" "Device name became empty after sanitization, defaulting to 'unknown_device'"
        echo "unknown_device"
        return
    fi

    if [[ ${#name} -gt 128 ]]; then
        log "WARN" "Device name too long (${#name} chars), truncating to 128 characters"
        name="${name:0:128}"
    fi

    echo "$name"
}

get_host_from_mount() {
    local mount_path="$1"
    [[ "$mount_path" =~ sftp:host=([^,]+) ]] && echo "${BASH_REMATCH[1]}" || echo ""
}

get_device_name_from_dbus() {
    local device_path
    # Use portable extraction (avoid grep -P dependency)
    device_path=$(gdbus call --session \
        --dest org.gnome.Shell.Extensions.GSConnect \
        --object-path /org/gnome/Shell/Extensions/GSConnect \
        --method org.freedesktop.DBus.ObjectManager.GetManagedObjects 2>/dev/null | \
        grep -o '/org/gnome/Shell/Extensions/GSConnect/Device/[a-z0-9]\+' | head -n 1)

    if [[ -z "$device_path" ]]; then return; fi

    local gdbus_output
    gdbus_output=$(gdbus call --session \
        --dest org.gnome.Shell.Extensions.GSConnect \
        --object-path "$device_path" \
        --method org.freedesktop.DBus.Properties.Get "org.gnome.Shell.Extensions.GSConnect.Device" "Name" 2>/dev/null)
    
    local device_name=""
    if [[ "$gdbus_output" =~ '"' ]]; then
        # gdbus may return a quoted string, fallback to extracting single-quoted
        [[ "$gdbus_output" =~ '"([^"]*)"' ]] && device_name="${BASH_REMATCH[1]}"
    else
        [[ "$gdbus_output" =~ \'([^\']*)\' ]] && device_name="${BASH_REMATCH[1]}"
    fi

    echo "$device_name"
}

discover_storage() {
    local mount_point="$1"
    local -a storage_paths=()


    log "DEBUG" "Storage paths - Internal: '${INTERNAL_STORAGE_PATHS}', External: '${EXTERNAL_STORAGE_PATHS}', USB: '${USB_STORAGE_PATHS}'"

    # Process internal storage
    if [[ -n "$INTERNAL_STORAGE_PATHS" ]]; then
        local full_path="$mount_point/$INTERNAL_STORAGE_PATHS"
        if [[ -d "$full_path" ]]; then
            storage_paths+=("internal:$full_path:Internal")
            log "INFO" "Added internal storage: $full_path"
        else
            log "WARN" "Internal storage path not found: $full_path"
        fi
    fi
    
    # Process external storage
    if [[ -n "$EXTERNAL_STORAGE_PATHS" ]]; then
        local full_path="$mount_point/$EXTERNAL_STORAGE_PATHS"
        if [[ -d "$full_path" ]]; then
            storage_paths+=("external:$full_path:External")
            log "INFO" "Added external storage: $full_path"
        else
            log "WARN" "External storage path not found: $full_path"
        fi
    fi
    
    # Process USB storage
    if [[ -n "$USB_STORAGE_PATHS" ]]; then
        local full_path="$mount_point/$USB_STORAGE_PATHS"
        if [[ -d "$full_path" ]]; then
            storage_paths+=("usb:$full_path:USB-OTG")
            log "INFO" "Added USB storage: $full_path"
        else
            log "WARN" "USB storage path not found: $full_path"
        fi
    fi

    printf '%s\n' "${storage_paths[@]}"
}

create_symlinks() {
    local device_dir="$1"
    shift
    local -a storage_info=("$@")
    local symlink_created=false

    for info in "${storage_info[@]}"; do
        # Expected format: type:path:name
        # Since path may contain colons, we need to parse carefully
        # Extract type (everything before the first colon)
        local type="${info%%:*}"
        local rest="${info#*:}"
        # Extract name (everything after the last colon)
        local name="${rest##*:}"
        local path="${rest%:*}"

        case "$type" in
            internal) name="Internal" ;;
            external) name="External" ;;
            usb)      name="USB-OTG" ;;
            *)        name="Storage" ;;
        esac

        # fallback name if empty
        [[ -z "$name" ]] && name="Storage"

        local link_target="$device_dir/$name"
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

add_bookmark() {
    local device_name="$1" host="$2" port="$3"
    shift 3 # Shift off device_name, host, port
    local -a storage_info=("$@") # Remaining arguments are storage_info

    # Respect config toggle
    if ! bookmarks_enabled; then
        log "DEBUG" "Bookmarks disabled by configuration. Skipping add for $device_name"
        return
    fi

    # Basic safety: ensure bookmark file is under user's config dir (canonical path check)
    local bookmark_file_real allowed_config
    bookmark_file_real=$(realpath -m "$BOOKMARK_FILE" 2>/dev/null)
    allowed_config=$(realpath -m "${XDG_CONFIG_HOME:-$HOME/.config}" 2>/dev/null)
    if [[ -z "$bookmark_file_real" || -z "$allowed_config" ]]; then
        log "ERROR" "Failed to resolve paths for bookmark file safety check."
        return
    fi
    # Only allow writing inside the user's config directory, not just any subdirectory of $HOME
    case "$bookmark_file_real" in
        "$allowed_config"/*) ;;
        "$allowed_config") ;;
        *) log "ERROR" "Refusing to write bookmark file outside user config directory: $BOOKMARK_FILE"; return ;;
    esac

    if ! touch "$BOOKMARK_FILE" 2>/dev/null; then
        log "ERROR" "Bookmark file not writable: $BOOKMARK_FILE"; return;
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

    if [[ -f "$BOOKMARK_FILE" ]]; then
        local sanitized_name=$(sanitize_name "$device_name")
        sed -i "\| $sanitized_name$|d" "$BOOKMARK_FILE"
        log "INFO" "Removed bookmark for $device_name"
    fi

}

cleanup_device_artifacts() {
    local device_name="$1" sanitized_name="$2"

    log "INFO" "Cleaning up artifacts for device: $device_name"
    remove_bookmark "$device_name" ""

    if [[ -n "$sanitized_name" ]]; then
        local device_dir="$MOUNT_STRUCTURE_DIR/$sanitized_name"
        if [[ "$AUTO_CLEANUP" == true ]] && [[ -d "$device_dir" ]]; then
            if validate_device_dir "$device_dir"; then
                rm -rf -- "$device_dir"
                log "INFO" "Removed directory: $device_dir"
            else
                log "ERROR" "Safety validation failed for directory '$device_dir'. Aborting deletion."
            fi
        fi
    fi
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

        log "INFO" "Cleaning up artifacts for device: $device_name"
        remove_bookmark "$device_name" "$host"

        local device_dir="$MOUNT_STRUCTURE_DIR/$sanitized_name"
        if [[ -d "$device_dir" ]]; then
            if validate_device_dir "$device_dir"; then
                rm -rf -- "$device_dir"
                log "INFO" "Removed directory: $device_dir"
            else
                log "ERROR" "Safety validation failed for directory '$device_dir' during uninstall. Aborting deletion for this entry."
            fi
        fi
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
    if ! canonical_device_dir=$(realpath -m "$device_dir" 2>/dev/null); then
        log "ERROR" "Could not canonicalize device directory path: $device_dir"
        return 1
    fi

    local canonical_base
    if ! canonical_base=$(realpath -m "$MOUNT_STRUCTURE_DIR" 2>/dev/null); then
        log "ERROR" "Could not canonicalize base directory path: $MOUNT_STRUCTURE_DIR"
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
