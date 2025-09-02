#!/usr/bin/env bash
set -euo pipefail

# --- Configuration with Defaults ---
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gsconnect-mount-manager"
CONFIG_FILE="$CONFIG_DIR/config.conf"

# --- Script-level Globals ---
LOG_FILE="$CONFIG_DIR/gsconnect-mount-manager.log"
LOCK_FILE="/tmp/gsconnect-mount-manager.lock"
DEVICE_STATE_FILE="$CONFIG_DIR/.device_state"
MANAGED_DEVICES_LOG="$CONFIG_DIR/managed_devices.log"

# Ensure log directory exists
mkdir -p "$CONFIG_DIR"
touch "$LOG_FILE"
touch "$MANAGED_DEVICES_LOG"

# --- Default Settings ---
declare -A DEFAULTS=(
    [POLL_INTERVAL]=3
    [MOUNT_ROOT]="/run/user/$(id -u)/gvfs"
    [MOUNT_STRUCTURE_DIR]="$HOME"
    [SYMLINK_DIR]=""
    [SYMLINK_PREFIX]=""
    [SYMLINK_SUFFIX]=""
    
    [LOG_LEVEL]="INFO"
    [MAX_LOG_SIZE]=1
    [LOG_ROTATE_COUNT]=5
    [ENABLE_INTERNAL_STORAGE]=true
    [ENABLE_EXTERNAL_STORAGE]=true
    [INTERNAL_STORAGE_PATH]="storage/emulated/0"
    [INTERNAL_STORAGE_NAME]="Internal"
    [EXTERNAL_STORAGE_NAME]="SDCard"
    [USB_STORAGE_NAME]="USB-OTG"
    [EXTERNAL_STORAGE_PATTERNS]="storage/[0-9A-F]{4}-*"
    [MAX_EXTERNAL_STORAGE]=3
    [AUTO_CLEANUP]=true
    [STORAGE_TIMEOUT]=10
    [DETECT_GVFS_PATH]=true
    [ENABLE_BOOKMARKS]=true
    [BOOKMARK_FILE]="${XDG_CONFIG_HOME:-$HOME/.config}/gtk-3.0/bookmarks"
)

# --- Logging ---
rotate_logs() {
    if [[ ! -f "$LOG_FILE" ]] || [[ -z "$MAX_LOG_SIZE" ]] || [[ "$MAX_LOG_SIZE" -le 0 ]]; then
        return
    fi

    # Get file size in MB
    local size_kb
    size_kb=$(du -k "$LOG_FILE" | cut -f1)
    local max_size_kb=$((MAX_LOG_SIZE * 1024))

    if [[ $size_kb -gt $max_size_kb ]]; then
        log "INFO" "Log file size ($size_kb KB) exceeds max size ($max_size_kb KB). Rotating logs."
        for i in $(seq $((LOG_ROTATE_COUNT - 1)) -1 1); do
            if [[ -f "$LOG_FILE.$i" ]]; then
                mv "$LOG_FILE.$i" "$LOG_FILE.$((i + 1))"
            fi
        done
        mv "$LOG_FILE" "$LOG_FILE.1"
        touch "$LOG_FILE"
    fi
}

log() {
    local level="$1"
    local message="$2"

    # Ensure log directory and file exist before logging
    if [[ ! -f "$LOG_FILE" ]]; then
        mkdir -p "$(dirname "$LOG_FILE")"
        touch "$LOG_FILE"
    fi
    
    rotate_logs

    local levels=("DEBUG" "INFO" "WARN" "ERROR")
    local current_level_idx=1
    local level_idx=1

    for i in "${!levels[@]}"; do
        [[ "${levels[$i]}" == "$LOG_LEVEL" ]] && current_level_idx=$i
        [[ "${levels[$i]}" == "$level" ]] && level_idx=$i
    done

    if [[ $level_idx -ge $current_level_idx ]]; then
        printf "[%s] [%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$message" | tee -a "$LOG_FILE"
    fi
}

# --- Configuration Loading ---
load_config() {
    mkdir -p "$CONFIG_DIR"
    touch "$LOG_FILE"

    # Load defaults
    for key in "${!DEFAULTS[@]}"; do
        declare -g "$key"="${DEFAULTS[$key]}"
    done

    # Load user config if it exists
    if [[ -f "$CONFIG_FILE" ]]; then
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ "$key" =~ ^\s*# ]] || [[ -z "$key" ]] && continue

            # Trim whitespace
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)

            # Remove quotes
            value="${value#\"}"
            value="${value%\"}"
            value="${value#\'}"
            value="${value%\'}"

            # Set config value if it's a valid key
            if [[ -v DEFAULTS[$key] ]]; then
                declare -g "$key"="$value"
            fi
        done < "$CONFIG_FILE"
    fi

    # Expand paths
    for path_var in MOUNT_ROOT MOUNT_STRUCTURE_DIR SYMLINK_DIR BOOKMARK_FILE; do
        eval "value=\$$path_var"
        value="${value//\$HOME/$HOME}"
        declare -g "$path_var=$value"
    done

    # Default SYMLINK_DIR to MOUNT_STRUCTURE_DIR if not set
    [[ -z "$SYMLINK_DIR" ]] && SYMLINK_DIR="$MOUNT_STRUCTURE_DIR"
}



sanitize_name() {
    local name="$1"
    name="${name//[^\'a-zA-Z0-9._-]/_}"
    echo "$name"
}

# --- Device and Storage Functions ---
get_host_from_mount() {
    local mount_path="$1"
    if [[ "$mount_path" =~ sftp:host=([^,]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo ""
    fi
}

get_device_name_from_dbus() {
    # Find the first connected device path on D-Bus
    local device_path
    device_path=$(gdbus call --session \
        --dest org.gnome.Shell.Extensions.GSConnect \
        --object-path /org/gnome/Shell/Extensions/GSConnect \
        --method org.freedesktop.DBus.ObjectManager.GetManagedObjects 2>/dev/null | \
        grep -oP "/org/gnome/Shell/Extensions/GSConnect/Device/[a-z0-9]+" | head -n 1)

    if [[ -z "$device_path" ]]; then
        echo ""
        return
    fi

    # Get the device name from D-Bus
    local gdbus_output
    gdbus_output=$(gdbus call --session \
        --dest org.gnome.Shell.Extensions.GSConnect \
        --object-path "$device_path" \
        --method org.freedesktop.DBus.Properties.Get "org.gnome.Shell.Extensions.GSConnect.Device" "Name" 2>/dev/null)
    
    # Extract device name more precisely - get content between first pair of single quotes
    local device_name=""
    if [[ "$gdbus_output" =~ \'([^\']*)\' ]]; then
        device_name="${BASH_REMATCH[1]}"
    fi
    
    log "DEBUG" "D-Bus GetManagedObjects output: $gdbus_output"
    log "DEBUG" "Extracted device name: [$device_name]"
    
    echo "$device_name"
}

discover_storage() {
    local mount_point="$1"
    local -a storage_paths=()

    # Internal Storage
    if [[ "$ENABLE_INTERNAL_STORAGE" == true ]]; then
        local internal_path="$mount_point/$INTERNAL_STORAGE_PATH"
        if [[ -d "$internal_path" ]]; then
            storage_paths+=("internal:$internal_path")
        fi
    fi

    # External Storage
    if [[ "$ENABLE_EXTERNAL_STORAGE" == true ]]; then
        local ext_count=0
        for pattern in $EXTERNAL_STORAGE_PATTERNS; do
            # Using find with regex instead of glob
            # Store find results in a temporary file to avoid process substitution issues
            local temp_file=$(mktemp)
            find "$mount_point" -maxdepth 1 -type d -regex ".*/$pattern" -print0 2>/dev/null > "$temp_file" || true
            while IFS= read -r -d '' path; do
                if [[ $ext_count -lt $MAX_EXTERNAL_STORAGE ]]; then
                    storage_paths+=("external:$path")
                    ((ext_count++))
                fi
            done < "$temp_file"
            rm -f "$temp_file"
        done
    fi

    # Output paths safely, one per line
    printf '%s\n' "${storage_paths[@]}"
}

create_symlinks() {
    local device_dir="$1"
    shift
    local -a storage_info=("$@")
    local symlink_created=false

    for info in "${storage_info[@]}"; do
        local type="${info%%:*}"
        local path="${info#*:}"
        local name

        case "$type" in
            internal) name="$INTERNAL_STORAGE_NAME" ;; 
            external) name="$EXTERNAL_STORAGE_NAME" ;; 
            usb)      name="$USB_STORAGE_NAME" ;; 
            *)        name="Storage" ;; 
        esac

        local link_target="$device_dir/$name"
        if [[ ! -e "$link_target" ]]; then
            ln -s "$path" "$link_target"
            log "INFO" "Created symlink: $link_target -> $path"
            symlink_created=true
        else
            log "DEBUG" "Symlink already exists: $link_target"
        fi
    done

    # Return 0 if any symlink created, 1 otherwise
    if [[ "$symlink_created" == true ]]; then
        return 0
    else
        return 1
    fi
}

add_bookmark() {
    local device_dir="$1"
    local device_name="$2"
    local host="$3"
    local port="$4"

    [[ "$ENABLE_BOOKMARKS" != true ]] && return

    # Ensure bookmark file exists and is writable
    touch "$BOOKMARK_FILE" 2>/dev/null || { log "ERROR" "Bookmark file not writable: $BOOKMARK_FILE"; return; }

    local sanitized_name
    sanitized_name=$(sanitize_name "$device_name")
    
    log "DEBUG" "Sanitized device name: [$sanitized_name]"

    local bookmark
    if [[ -n "$host" && -n "$port" ]]; then
        # sftp URI with host, port, internal storage path and sanitized name as label
        bookmark="sftp://$host:$port/$INTERNAL_STORAGE_PATH $sanitized_name"
    else
        # Fallback to file URI
        bookmark="file://$device_dir $sanitized_name"
    fi

    if ! grep -qF "$bookmark" "$BOOKMARK_FILE"; then
        log "DEBUG" "Adding bookmark: $bookmark"
        echo "$bookmark" >> "$BOOKMARK_FILE"
        log "INFO" "Added bookmark for $device_name"
    else
        log "DEBUG" "Bookmark already exists for $device_name"
    fi
}

remove_bookmark() {
    local device_name="$1"
    local host="$2" # Keep for compatibility, but not strictly needed for removal
    
    if [[ "$ENABLE_BOOKMARKS" == true ]] && [[ -f "$BOOKMARK_FILE" ]]; then
        local sanitized_name
        sanitized_name=$(sanitize_name "$device_name")
        
        log "DEBUG" "Removing bookmark for: $device_name (sanitized: $sanitized_name)"

        # Remove any bookmark entry for this device by matching the label at the end of the line.
        # This is more robust and cleans up old, incorrect formats as well.
        sed -i "\| $sanitized_name$|d" "$BOOKMARK_FILE"

        log "INFO" "Removed bookmark for $device_name"
    fi
}

cleanup_device_artifacts() {
    local device_name="$1"
    local sanitized_name="$2"
    
    log "INFO" "Cleaning up artifacts for device: $device_name"
    
    # Remove bookmark
    remove_bookmark "$device_name" ""

    # Remove symlink directory
    if [[ -n "$sanitized_name" ]]; then
        local device_dir="$MOUNT_STRUCTURE_DIR/$sanitized_name"
        if [[ "$AUTO_CLEANUP" == true ]] && [[ -d "$device_dir" ]]; then
            rm -rf "$device_dir"
            log "INFO" "Removed directory: $device_dir"
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
        # Avoid processing duplicates
        if [[ " ${cleaned_entries[*]} " =~ " $sanitized_name " ]]; then
            continue
        fi

        log "INFO" "Cleaning up artifacts for device: $device_name"
        
        # Remove bookmark
        remove_bookmark "$device_name" "$host"

        # Remove symlink directory
        local device_dir="$MOUNT_STRUCTURE_DIR/$sanitized_name"
        if [[ -d "$device_dir" ]]; then
            rm -rf "$device_dir"
            log "INFO" "Removed directory: $device_dir"
        fi
        cleaned_entries+=("$sanitized_name")
    done < "$MANAGED_DEVICES_LOG"

    log "INFO" "Uninstall cleanup complete."
    # The rest of the config dir will be removed by uninstall.sh
}

# --- Main Logic ---
startup_cleanup() {
    log "INFO" "Performing startup cleanup..."
    
    # Find all managed symlink directories
    local -a managed_dirs=()
    if [[ -n "$SYMLINK_DIR" ]] && [[ -d "$SYMLINK_DIR" ]]; then
        # This is a simple heuristic. It assumes that any directory in the SYMLINK_DIR
        # that contains a symlink named "Internal" is a managed directory.
        mapfile -t managed_dirs < <(find "$SYMLINK_DIR" -maxdepth 2 -type l -name "$INTERNAL_STORAGE_NAME" -printf '%h\n' 2>/dev/null)
    fi

    if [[ ${#managed_dirs[@]} -eq 0 ]]; then
        log "INFO" "No existing managed directories found to clean up."
        return
    fi

    # Get the currently connected device's sanitized name
    local current_device_sanitized_name=""
    local mount_point
    mount_point=$(find "$MOUNT_ROOT" -maxdepth 1 -type d -name 'sftp:host=*' 2>/dev/null | head -n 1)
    if [[ -n "$mount_point" ]]; then
        local current_device_name
        current_device_name=$(get_device_name_from_dbus)
        if [[ -n "$current_device_name" ]]; then
            current_device_sanitized_name=$(sanitize_name "$current_device_name")
        fi
    fi

    # Read the last known device state
    local old_device_name=""
    if [[ -f "$DEVICE_STATE_FILE" ]]; then
        IFS='|' read -r old_device_name _ < "$DEVICE_STATE_FILE"
    fi

    for dir in "${managed_dirs[@]}"; do
        local dir_basename="${dir##*/}" # Pure Bash basename
        if [[ "$dir_basename" != "$current_device_sanitized_name" ]]; then
            local device_to_cleanup="$old_device_name"
            local sanitized_to_cleanup="$dir_basename"

            cleanup_device_artifacts "$device_to_cleanup" "$sanitized_to_cleanup"
        fi
    done
}

cleanup() {
    log "INFO" "GSConnect Mount Manager is shutting down."
    rm -f "$LOCK_FILE"
    exit 0
}

main() {
    load_config

    # --- Lock to prevent multiple instances ---
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        log "ERROR" "Another instance is already running. Exiting."
        exit 1
    fi
    
    # --- Trap signals for graceful shutdown ---
    trap cleanup SIGINT SIGTERM

    startup_cleanup

    log "INFO" "GSConnect Mount Manager started. Watching for devices..."

    while true; do
        log "DEBUG" "Polling for devices..."
        # --- Find connected device ---
        local mount_point
        mount_point=$(find "$MOUNT_ROOT" -maxdepth 1 -type d -name 'sftp:host=*' 2>/dev/null | head -n 1)

        local device_name=""
        local host=""
        local port=""
        if [[ -n "$mount_point" ]]; then
            host=$(get_host_from_mount "$mount_point")
            if [[ "$mount_point" =~ ,port=([0-9]+) ]]; then
                port="${BASH_REMATCH[1]}"
            fi
            device_name=$(get_device_name_from_dbus)
            # Fallback to host if D-Bus fails
            [[ -z "$device_name" ]] && device_name="$host"
        fi

        # --- Get old state ---
        local old_device_info
        old_device_info=$(cat "$DEVICE_STATE_FILE" 2>/dev/null || echo "")
        local old_device_name=""
        local old_sanitized_name=""
        local old_host=""
        if [[ -n "$old_device_info" ]]; then
            IFS='|' read -r old_device_name old_sanitized_name old_host <<< "$old_device_info"
        fi

        # --- Device Connected ---
        if [[ -n "$device_name" ]] && [[ "$device_name" != "$old_device_name" ]]; then
            log "INFO" "Device connected: $device_name (Host: $host, Port: $port)"
            log "DEBUG" "Raw device name: [$device_name]"
            
            local sanitized_name
            sanitized_name=$(sanitize_name "$device_name")
            echo "$device_name|$sanitized_name|$host" > "$DEVICE_STATE_FILE"
            # Add to the persistent log of all managed devices
            if ! grep -qF "|$sanitized_name|" "$MANAGED_DEVICES_LOG"; then
                echo "$device_name|$sanitized_name|$host" >> "$MANAGED_DEVICES_LOG"
            fi
            local device_dir="$MOUNT_STRUCTURE_DIR/$sanitized_name"
            mkdir -p "$device_dir"

            local -a storage=()
            mapfile -t storage < <(discover_storage "$mount_point")

            if [[ ${#storage[@]} -gt 0 ]]; then
                log "INFO" "Found ${#storage[@]} storage location(s). Processing..."
                create_symlinks "$device_dir" "${storage[@]}"
                add_bookmark "$device_dir" "$device_name" "$host" "$port"
            else
                log "WARN" "No storage found for $device_name."
            fi
        fi

        # --- Device Disconnected ---
        if [[ -z "$device_name" ]] && [[ -n "$old_device_name" ]]; then
            log "INFO" "Device disconnected: $old_device_name"
            
            local old_sanitized_name
            local old_host
            IFS='|' read -r _ old_sanitized_name old_host < "$DEVICE_STATE_FILE"
            rm -f "$DEVICE_STATE_FILE"

            cleanup_device_artifacts "$old_device_name" "$old_sanitized_name"
        fi

        sleep "$POLL_INTERVAL"
    done
}

# --- Entry Point ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Handle command-line arguments
    if [[ $# -gt 0 ]] && [[ "$1" == "--uninstall-cleanup" ]]; then
        load_config
        uninstall_cleanup
        exit 0
    fi

    main
fi
