#!/usr/bin/env bash
# GSConnect Mount Manager - Configuration Loader
# Loads and validates configuration with defaults

set -euo pipefail
IFS=$'\n\t'

# ---------- Default Configuration ----------
declare -A DEFAULTS=(
    [POLL_INTERVAL]=5
    [MOUNT_ROOT]="/run/user/$(id -u)/gvfs"
    [CONFIG_DIR]="$HOME/.config/gsconnect-mount-manager"
    [BOOKMARK_FILE]="$HOME/.config/gtk-3.0/bookmarks"
    [SYMLINK_DIR]=""
    [SYMLINK_PREFIX]=""
    [SYMLINK_SUFFIX]=""
    [ENABLE_NOTIFICATIONS]=true
    [LOG_LEVEL]="INFO"
    [MAX_LOG_SIZE]=1
    [LOG_ROTATE_COUNT]=5
    [MOUNT_STRUCTURE_DIR]="$HOME"
    [ENABLE_INTERNAL_STORAGE]=true
    [ENABLE_EXTERNAL_STORAGE]=true
    [INTERNAL_STORAGE_PATH]="storage/emulated/0"
    [INTERNAL_STORAGE_NAME]="Internal"
    [EXTERNAL_STORAGE_NAME]="SDCard"
    [USB_STORAGE_NAME]="USB-OTG"
    [EXTERNAL_STORAGE_PATTERNS]="storage/[0-9A-F][0-9A-F][0-9A-F][0-9A-F]* storage/sdcard1 storage/extSdCard storage/external_sd storage/usbotg storage/[0-9a-f]{4}-[0-9a-f]{4} storage/????-???? storage/???????????????? storage/emulated/1 storage/emulated/2 storage/emulated/external storage/????-????-????-????"
    [MAX_EXTERNAL_STORAGE]=3
    [AUTO_CLEANUP]=true
    [STORAGE_TIMEOUT]=30
    [VERBOSE]=false
    [DETECT_GVFS_PATH]=true
    [ENABLE_GVFS_BOOKMARKS]=false
)

# ---------- Load Configuration ----------
load_config() {
    local config_file="$1"

    # Load defaults first
    for key in "${!DEFAULTS[@]}"; do
        declare -g "$key"="${DEFAULTS[$key]}"
    done

    # Load user config if exists
    if [[ -f "$config_file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%%#*}"       # Remove comments
            [[ -z "$line" ]] && continue

            if [[ "$line" == *"="* ]]; then
                key="${line%%=*}"
                value="${line#*=}"
                key=$(echo "$key" | xargs)
                value=$(echo "$value" | xargs)
                # Remove surrounding quotes
                value="${value%\"}"
                value="${value#\"}"
                value="${value%\'}"
                value="${value#\'}"

                # Apply only known keys
                if [[ -v DEFAULTS[$key] ]]; then
                    declare -g "$key"="$value"
                fi
            fi
        done <"$config_file"
    fi

    # Expand paths
    for path_var in MOUNT_ROOT CONFIG_DIR BOOKMARK_FILE MOUNT_STRUCTURE_DIR SYMLINK_DIR; do
        eval "$path_var=\"\${$path_var//\$HOME/$HOME}\""
    done

    # Set SYMLINK_DIR to MOUNT_STRUCTURE_DIR if empty
    [[ -z "$SYMLINK_DIR" ]] && SYMLINK_DIR="$MOUNT_STRUCTURE_DIR"

    # Validate booleans
    for bool_var in ENABLE_NOTIFICATIONS AUTO_CLEANUP VERBOSE DETECT_GVFS_PATH ENABLE_INTERNAL_STORAGE ENABLE_EXTERNAL_STORAGE ENABLE_GVFS_BOOKMARKS; do
        eval "val=\$$bool_var"
        if [[ "$val" != true && "$val" != false ]]; then
            eval "$bool_var=${DEFAULTS[$bool_var]}"
            echo "Warning: Invalid $bool_var, using default ${DEFAULTS[$bool_var]}"
        fi
    done

    # Validate numeric
    for num_var in POLL_INTERVAL STORAGE_TIMEOUT MAX_LOG_SIZE LOG_ROTATE_COUNT MAX_EXTERNAL_STORAGE; do
        eval "val=\$$num_var"
        if ! [[ "$val" =~ ^[0-9]+$ ]]; then
            eval "$num_var=${DEFAULTS[$num_var]}"
            echo "Warning: Invalid $num_var, using default ${DEFAULTS[$num_var]}"
        fi
    done

    # Validate directories exist or create
    for dir_var in CONFIG_DIR MOUNT_STRUCTURE_DIR SYMLINK_DIR; do
        eval "dir=\$$dir_var"
        if ! mkdir -p "$dir" 2>/dev/null; then
            echo "Warning: Cannot create $dir_var '$dir', using HOME"
            eval "$dir_var=$HOME"
        fi
    done

    # Normalize INTERNAL_STORAGE_PATH (remove leading slash)
    INTERNAL_STORAGE_PATH="${INTERNAL_STORAGE_PATH#/}"
}

# ---------- Validate Config ----------
validate_config() {
    local errors=0
    command -v dconf >/dev/null 2>&1 || { echo "Error: dconf not found"; ((errors++)); }
    command -v find >/dev/null 2>&1 || { echo "Error: find not found"; ((errors++)); }

    if [[ "$ENABLE_NOTIFICATIONS" == true ]] && ! command -v notify-send >/dev/null 2>&1; then
        echo "Warning: notify-send not found. Notifications disabled."
    fi

    return $errors
}

# ---------- Create Default Config ----------
create_default_config() {
    local config_file="$1"
    mkdir -p "$(dirname "$config_file")"

    cat >"$config_file" <<'EOF'
# GSConnect Mount Manager Default Config
POLL_INTERVAL=5
MOUNT_ROOT="/run/user/$(id -u)/gvfs"
CONFIG_DIR="$HOME/.config/gsconnect-mount-manager"
BOOKMARK_FILE="$HOME/.config/gtk-3.0/bookmarks"
MOUNT_STRUCTURE_DIR="$HOME"
SYMLINK_DIR=""
SYMLINK_PREFIX=""
SYMLINK_SUFFIX=""
ENABLE_NOTIFICATIONS=true
LOG_LEVEL=INFO
MAX_LOG_SIZE=1
LOG_ROTATE_COUNT=5
ENABLE_INTERNAL_STORAGE=true
ENABLE_EXTERNAL_STORAGE=true
INTERNAL_STORAGE_PATH="storage/emulated/0"
INTERNAL_STORAGE_NAME="Internal"
EXTERNAL_STORAGE_NAME="SDCard"
USB_STORAGE_NAME="USB-OTG"
EXTERNAL_STORAGE_PATTERNS="storage/[0-9A-F][0-9A-F][0-9A-F][0-9A-F]* storage/sdcard1 storage/extSdCard storage/external_sd storage/usbotg storage/[0-9a-f]{4}-[0-9a-f]{4} storage/????-???? storage/???????????????? storage/emulated/1 storage/emulated/2 storage/emulated/external storage/????-????-????-????"
MAX_EXTERNAL_STORAGE=3
AUTO_CLEANUP=true
STORAGE_TIMEOUT=30
VERBOSE=false
DETECT_GVFS_PATH=true
ENABLE_GVFS_BOOKMARKS=false
EOF
}

