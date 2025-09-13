#!/usr/bin/env bash
set -euo pipefail

# Source the library file containing helper functions
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/gmm-lib.sh"

# Reads device state from DEVICE_STATE_FILE
# Outputs: old_device_name, old_sanitized_name, old_host (pipe-separated)
read_device_state() {
    local old_device_info=$(cat "$DEVICE_STATE_FILE" 2>/dev/null || echo "")
    local old_device_name="" old_sanitized_name="" old_host=""
    if [[ -n "$old_device_info" ]]; then
        IFS='|' read -r old_device_name old_sanitized_name old_host <<< "$old_device_info"
    fi
    printf "%s|%s|%s" "$old_device_name" "$old_sanitized_name" "$old_host"
}

# Writes device state to DEVICE_STATE_FILE
# Parameters:
#   $1 - device_name
#   $2 - sanitized_name
#   $3 - host
write_device_state() {
    local device_name="$1" sanitized_name="$2" host="$3"
    echo "$device_name|$sanitized_name|$host" > "$DEVICE_STATE_FILE"
}

# Handle device connection event
# Creates symlinks and bookmarks for the connected device
# Parameters:
#   $1 - device_name: Name of the connected device
#   $2 - host: Host address of the device
#   $3 - port: Port number used for connection
#   $4 - mount_point: Path where the device is mounted
handle_device_connection() {
    local device_name="$1" host="$2" port="$3" mount_point="$4"
    
    log "INFO" "Device connected: $device_name (Host: $host, Port: $port)"
    
    local sanitized_name=$(sanitize_name "$device_name")
    write_device_state "$device_name" "$sanitized_name" "$host"
    if ! grep -qF "|$sanitized_name|" "$MANAGED_DEVICES_LOG"; then
        echo "$device_name|$sanitized_name|$host" >> "$MANAGED_DEVICES_LOG"
        rotate_managed_devices_log
    fi
    local device_dir="$MOUNT_STRUCTURE_DIR/$sanitized_name"
    mkdir -p "$device_dir"

    local -a storage=()
    mapfile -t storage < <(discover_storage "$mount_point")

    create_symlinks "$device_dir" "${storage[@]}"
    add_bookmark "$device_name" "$host" "$port" "${storage[@]}"
}

# Handle device disconnection event
# Cleans up symlinks and bookmarks for the disconnected device
# Parameters:
#   $1 - old_device_name: Name of the disconnected device
#   $2 - old_sanitized_name: Sanitized name of the disconnected device
handle_device_disconnection() {
    local old_device_name="$1" old_sanitized_name="$2"
    
    log "INFO" "Device disconnected: $old_device_name"
    
    rm -f "$DEVICE_STATE_FILE"
    cleanup_device_artifacts "$old_device_name" "$old_sanitized_name"
}

# Detects and returns the current SFTP mount point
get_current_sftp_mount_point() {
    # Use timeout to prevent hanging on unresponsive network filesystems
    local mount_point=""
    if mount_point=$(timeout 10 find "$MOUNT_ROOT" -maxdepth 1 -type d -name 'sftp:host=*' 2>/dev/null | head -n 1); then
        echo "$mount_point"
    else
        log "WARN" "Timeout or error while searching for SFTP mount points"
        echo ""
    fi
}

startup_cleanup() {
    log "INFO" "Performing startup cleanup..."
    
    local current_device_name=""
    local current_sanitized_name=""
    local mount_point=$(get_current_sftp_mount_point)

    if [[ -n "$mount_point" ]]; then
        current_device_name=$(get_device_name_from_dbus)
        if [[ -n "$current_device_name" ]]; then
            current_sanitized_name=$(sanitize_name "$current_device_name")
        else
            log "WARN" "Found SFTP mount point but could not get device name from DBus. Skipping current device identification for cleanup."
        fi
    fi

    local old_device_name old_sanitized_name old_host
    IFS='|' read -r old_device_name old_sanitized_name old_host <<< "$(read_device_state)"

    # Only clean up if there was an old device and it's no longer connected (or its name changed)
    if [[ -n "$old_sanitized_name" ]] && [[ "$old_sanitized_name" != "$current_sanitized_name" ]]; then
        log "INFO" "Cleaning up artifacts for previously connected device: $old_device_name (Sanitized: $old_sanitized_name)"
        cleanup_device_artifacts "$old_device_name" "$old_sanitized_name"
    fi
}

cleanup() {
    log "INFO" "GSConnect Mount Manager is shutting down."
    flock -u 200 2>/dev/null || true
    rm -f "$LOCK_FILE"
    exit 0
}

# Encapsulates device name, host, and port extraction from a mount point
# Parameters:
#   $1 - mount_point: Path where the device is mounted
# Outputs: device_name, host, port (pipe-separated)
get_device_details_from_mount() {
    local mount_point="$1"
    local device_name="" host="" port=""

    if [[ -n "$mount_point" ]]; then
        host=$(get_host_from_mount "$mount_point")
        [[ "$mount_point" =~ ,port=([0-9]+) ]] && port="${BASH_REMATCH[1]}"
        device_name=$(get_device_name_from_dbus)
        [[ -z "$device_name" ]] && device_name="$host"
    fi
    printf "%s|%s|%s" "$device_name" "$host" "$port"
}

main() {
    load_config

    exec 200>"$LOCK_FILE" || { log "ERROR" "Failed to open lock file at $LOCK_FILE. Exiting."; exit 1; }
    if ! flock -n 200; then
        log "ERROR" "Another instance is already running (lock file: $LOCK_FILE). Exiting."
        exit 1
    fi
    
    trap cleanup SIGINT SIGTERM

    startup_cleanup

    log "INFO" "GSConnect Mount Manager started. Watching for devices..."

    # Small delay to allow system to settle after startup
    sleep 1

    while true; do
        local mount_point=$(get_current_sftp_mount_point)
        local device_name="" host="" port=""

        if [[ -n "$mount_point" ]]; then
            IFS='|' read -r device_name host port <<< "$(get_device_details_from_mount "$mount_point")"
        fi

        local old_device_name old_sanitized_name old_host
        IFS='|' read -r old_device_name old_sanitized_name old_host <<< "$(read_device_state)"

        if [[ -n "$device_name" ]] && [[ "$device_name" != "$old_device_name" ]]; then
            handle_device_connection "$device_name" "$host" "$port" "$mount_point"
        fi

        if [[ -z "$device_name" ]] && [[ -n "$old_device_name" ]]; then
            handle_device_disconnection "$old_device_name" "$old_sanitized_name"
        fi

        sleep "$POLL_INTERVAL"
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -gt 0 ]] && [[ "$1" == "--uninstall-cleanup" ]]; then
        # For uninstall cleanup, redirect logging to /dev/null to avoid issues with removed config directory
        # This must be set BEFORE sourcing gmm-lib.sh
        LOG_FILE="/dev/null"
        # Override individual config files to /dev/null instead of setting CONFIG_DIR to /dev/null
        CONFIG_FILE="/dev/null"
        DEVICE_STATE_FILE="/dev/null"
        MANAGED_DEVICES_LOG="/dev/null"
        source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/gmm-lib.sh" # Re-source with new config file paths
        load_config
        uninstall_cleanup
        exit 0
    fi

    main
fi
