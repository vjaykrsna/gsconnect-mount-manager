#!/usr/bin/env bash
set -euo pipefail

# Source the library file containing helper functions
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/gmm-lib.sh"

# --- Main Logic ---
startup_cleanup() {
    log "INFO" "Performing startup cleanup..."
    
    # Find all managed symlink directories
    local -a managed_dirs=()
    if [[ -n "$SYMLINK_DIR" ]] && [[ -d "$SYMLINK_DIR" ]]; then
        # Improved heuristic: Find directories that contain a symlink with the exact name
        # of INTERNAL_STORAGE_NAME and verify its target is under a valid mount point.
        while IFS= read -r -d '' dir; do
            local symlink_path="$dir/$INTERNAL_STORAGE_NAME"
            if [[ -L "$symlink_path" ]]; then
                local target
                target=$(readlink -f "$symlink_path" 2>/dev/null)
                # Check if target is under MOUNT_ROOT
                if [[ "$target" == "$MOUNT_ROOT"/* ]]; then
                    managed_dirs+=("$dir")
                fi
            fi
        done < <(find "$SYMLINK_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
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
    # Explicitly unlock the file descriptor before removing the lock file
    # This helps prevent potential race conditions.
    flock -u 200 2>/dev/null || true
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
