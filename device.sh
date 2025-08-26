#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Device Utilities
# -----------------------------

# Get device name from GSConnect mount (fallback to hostname if unavailable)
get_device_name() {
    local mount_name="$1"
    
    # Attempt to parse GSConnect SFTP mount name
    # Example: sftp:host=myphone,port=22
    if [[ "$mount_name" =~ sftp:host=([^,]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$mount_name"
    fi
}

# Create device directory structure
create_device_structure() {
    local device_name="$1"
    local sanitized_name="$2"
    local mount_point="$3"

    local device_dir="$MOUNT_STRUCTURE_DIR/$sanitized_name"
    
    if [[ ! -d "$device_dir" ]]; then
        mkdir -p "$device_dir"
        log_conditional "INFO" "Created device directory: $device_dir"
    else
        log_conditional "DEBUG" "Device directory already exists: $device_dir"
    fi

    # Track device directory for cleanup
    echo "$device_dir" >> "$LINK_PATH_FILE"

    # Optionally add GVFS bookmark
    if [[ "$ENABLE_GVFS_BOOKMARKS" == true ]] && [[ -f "$BOOKMARK_FILE" ]]; then
        local bookmark_entry="file://$mount_point/$INTERNAL_STORAGE_PATH $sanitized_name"
        if ! grep -qF "$bookmark_entry" "$BOOKMARK_FILE"; then
            echo "$bookmark_entry" >> "$BOOKMARK_FILE"
            log_conditional "INFO" "Added GVFS bookmark for $sanitized_name"
            echo "$bookmark_entry" >> "$BOOKMARK_ENTRY_FILE"
        fi
    fi

    echo "$device_dir"
}

# Create storage symlink within device directory
# Usage: create_storage_symlink <device_dir> <type> <path> [index]
create_storage_symlink() {
    local device_dir="$1"
    local storage_type="$2"
    local storage_path="$3"
    local index="${4:-}"

    local name=""
    case "$storage_type" in
        internal) name="$INTERNAL_STORAGE_NAME" ;;
        external) name="$EXTERNAL_STORAGE_NAME" ;;
        usb)      name="$USB_STORAGE_NAME" ;;
        *)        name="Storage" ;;
    esac

    # Append index if multiple external/USB
    [[ -n "$index" ]] && name+="$index"

    # Apply symlink prefix/suffix
    [[ -n "$SYMLINK_PREFIX" ]] && name="$SYMLINK_PREFIX$name"
    [[ -n "$SYMLINK_SUFFIX" ]] && name="$name$SYMLINK_SUFFIX"

    local link_path="$device_dir/$name"

    if [[ ! -e "$link_path" ]]; then
        ln -s "$storage_path" "$link_path"
        log_conditional "INFO" "Created symlink: $link_path -> $storage_path"
        echo "$link_path" >> "$LINK_PATH_FILE"
        return 0
    else
        log_conditional "WARN" "Symlink already exists: $link_path"
        return 1
    fi
}

# Discover storage paths for a mounted device
# Returns array of storage_type:path
discover_storage_paths() {
    local mount_point="$1"
    local paths=()

    # Internal storage
    if [[ "$ENABLE_INTERNAL_STORAGE" == true ]]; then
        local internal_path="$mount_point/$INTERNAL_STORAGE_PATH"
        if [[ -d "$internal_path" ]]; then
            paths+=("internal:$internal_path")
        fi
    fi

    # External storage
    if [[ "$ENABLE_EXTERNAL_STORAGE" == true ]]; then
        local ext_count=0
        for pattern in $EXTERNAL_STORAGE_PATTERNS; do
            for path in "$mount_point/$pattern"; do
                [[ -d "$path" ]] || continue
                ((ext_count++))
                [[ $ext_count -le $MAX_EXTERNAL_STORAGE ]] || break
                paths+=("external:$path")
            done
        done
    fi

    echo "${paths[@]}"
}

# Cleanup broken symlinks in mount structure
cleanup_broken_symlinks() {
    if [[ "$AUTO_CLEANUP" == true ]]; then
        find "$MOUNT_STRUCTURE_DIR" -type l ! -exec test -e {} \; -print -delete | while read -r broken_link; do
            log_conditional "INFO" "Removed broken symlink: $broken_link"
        done
    fi
}
