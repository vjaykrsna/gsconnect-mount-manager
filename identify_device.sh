#!/usr/bin/env bash
# GSConnect Mount Manager – Unified device discovery & setup
# Usage: ./identify_device.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load core utilities, configuration, and device/storage functions
. "$SCRIPT_DIR/core.sh"
. "$SCRIPT_DIR/config_loader.sh"
. "$SCRIPT_DIR/device.sh"
. "$SCRIPT_DIR/storage.sh"
. "$SCRIPT_DIR/gvfs_error_handler.sh"

load_config "$SCRIPT_DIR/config.conf"

# Detect GVFS mount root
MOUNT_ROOT_PATH=$(detect_gvfs_path)
[[ -d "$MOUNT_ROOT_PATH" ]] || { log_message "ERROR" "GVFS mount root not found: $MOUNT_ROOT_PATH"; exit 1; }

# Find SFTP mount points
mapfile -t sftp_mounts < <(find "$MOUNT_ROOT_PATH" -maxdepth 1 -type d -name 'sftp:*' 2>/dev/null)
if [[ ${#sftp_mounts[@]} -eq 0 ]]; then
    log_message "INFO" "No connected devices found."
    exit 0
fi

# Iterate through devices
for MNT in "${sftp_mounts[@]}"; do
    mount_basename=$(basename "$MNT")
    host=$(echo "$mount_basename" | sed -n 's/sftp:host=\([^,]*\).*/\1/p')
    port=$(echo "$mount_basename" | sed -n 's/.*port=\([0-9]*\).*/\1/p')

    DEVICE_NAME=$(get_device_name "$mount_basename") || DEVICE_NAME="$host"
    DEVICE_NAME_SANITIZED=$(sanitize_device_name "$DEVICE_NAME")

    echo "----------------------------------------"
    echo "Device: $DEVICE_NAME"
    echo "IP:     $host"
    echo "Port:   $port"
    echo "Mount:  $MNT"

    # Discover storage
    mapfile -t storage_paths < <(discover_storage_paths "$MNT")
    echo "Storage paths found: ${storage_paths[*]}"

    # Create device structure & symlinks/bookmarks
    device_dir=$(create_device_structure "$DEVICE_NAME" "$DEVICE_NAME_SANITIZED" "$MNT")
    if [[ -n "$device_dir" ]]; then
        for path in "${storage_paths[@]}"; do
            type="${path%%:*}"
            target="${path#*:}"
            create_storage_symlink "$device_dir" "$type" "$target"
        done
    fi

    echo "SFTP URL: sftp://${host}:${port}"
    echo "----------------------------------------"
done
