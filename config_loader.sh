#!/usr/bin/env bash
# Configuration loader for GSConnect Mount Manager

# Default configuration values
DEFAULT_POLL_INTERVAL=5
DEFAULT_MOUNT_ROOT="/run/user/$(id -u)/gvfs"
DEFAULT_CONFIG_DIR="$HOME/.config/gsconnect-mount-manager"
DEFAULT_BOOKMARK_FILE="$HOME/.config/gtk-3.0/bookmarks"
DEFAULT_SYMLINK_DIR=""
DEFAULT_SYMLINK_PREFIX=""
DEFAULT_SYMLINK_SUFFIX=""
DEFAULT_ENABLE_NOTIFICATIONS=true
DEFAULT_LOG_LEVEL="INFO"
DEFAULT_MAX_LOG_SIZE=10
DEFAULT_LOG_ROTATE_COUNT=5
DEFAULT_MOUNT_STRUCTURE_DIR="$HOME/.gsconnect-mount"
DEFAULT_ENABLE_INTERNAL_STORAGE=true
DEFAULT_ENABLE_EXTERNAL_STORAGE=true
DEFAULT_INTERNAL_STORAGE_PATH="storage/emulated/0"
DEFAULT_INTERNAL_STORAGE_NAME="Internal"
DEFAULT_EXTERNAL_STORAGE_NAME="SDCard"
DEFAULT_USB_STORAGE_NAME="USB-OTG"
DEFAULT_EXTERNAL_STORAGE_PATTERNS="storage/[0-9A-F][0-9A-F][0-9A-F][0-9A-F]* storage/sdcard1 storage/extSdCard storage/external_sd storage/usbotg"
DEFAULT_MAX_EXTERNAL_STORAGE=3
DEFAULT_AUTO_CLEANUP=true
DEFAULT_STORAGE_TIMEOUT=30
DEFAULT_VERBOSE=false

# Function to load configuration
load_config() {
    local config_file="$1"
    
    # Set defaults first
    POLL_INTERVAL=$DEFAULT_POLL_INTERVAL
    MOUNT_ROOT=$DEFAULT_MOUNT_ROOT
    CONFIG_DIR=$DEFAULT_CONFIG_DIR
    BOOKMARK_FILE=$DEFAULT_BOOKMARK_FILE
    SYMLINK_DIR=$DEFAULT_SYMLINK_DIR
    SYMLINK_PREFIX=$DEFAULT_SYMLINK_PREFIX
    SYMLINK_SUFFIX=$DEFAULT_SYMLINK_SUFFIX
    ENABLE_NOTIFICATIONS=$DEFAULT_ENABLE_NOTIFICATIONS
    LOG_LEVEL=$DEFAULT_LOG_LEVEL
    MAX_LOG_SIZE=$DEFAULT_MAX_LOG_SIZE
    LOG_ROTATE_COUNT=$DEFAULT_LOG_ROTATE_COUNT
    MOUNT_STRUCTURE_DIR=$DEFAULT_MOUNT_STRUCTURE_DIR
    ENABLE_INTERNAL_STORAGE=$DEFAULT_ENABLE_INTERNAL_STORAGE
    ENABLE_EXTERNAL_STORAGE=$DEFAULT_ENABLE_EXTERNAL_STORAGE
    INTERNAL_STORAGE_PATH=$DEFAULT_INTERNAL_STORAGE_PATH
    INTERNAL_STORAGE_NAME=$DEFAULT_INTERNAL_STORAGE_NAME
    EXTERNAL_STORAGE_NAME=$DEFAULT_EXTERNAL_STORAGE_NAME
    USB_STORAGE_NAME=$DEFAULT_USB_STORAGE_NAME
    EXTERNAL_STORAGE_PATTERNS=$DEFAULT_EXTERNAL_STORAGE_PATTERNS
    MAX_EXTERNAL_STORAGE=$DEFAULT_MAX_EXTERNAL_STORAGE
    AUTO_CLEANUP=$DEFAULT_AUTO_CLEANUP
    STORAGE_TIMEOUT=$DEFAULT_STORAGE_TIMEOUT
    VERBOSE=$DEFAULT_VERBOSE
    
    # Load config file if it exists
    if [[ -f "$config_file" ]]; then
        # Source the config file, but only load valid variable assignments
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ $key =~ ^[[:space:]]*# ]] && continue
            [[ -z $key ]] && continue
            
            # Remove leading/trailing whitespace
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            
            # Remove quotes from value if present
            value=$(echo "$value" | sed 's/^["'\'']\|["'\'']$//g')
            
            # Set the variable if it's a known config option
            case "$key" in
                POLL_INTERVAL) POLL_INTERVAL="$value" ;;
                MOUNT_ROOT) MOUNT_ROOT="$value" ;;
                CONFIG_DIR) CONFIG_DIR="$value" ;;
                BOOKMARK_FILE) BOOKMARK_FILE="$value" ;;
                SYMLINK_DIR) SYMLINK_DIR="$value" ;;
                SYMLINK_PREFIX) SYMLINK_PREFIX="$value" ;;
                SYMLINK_SUFFIX) SYMLINK_SUFFIX="$value" ;;
                ENABLE_NOTIFICATIONS) ENABLE_NOTIFICATIONS="$value" ;;
                LOG_LEVEL) LOG_LEVEL="$value" ;;
                MAX_LOG_SIZE) MAX_LOG_SIZE="$value" ;;
                LOG_ROTATE_COUNT) LOG_ROTATE_COUNT="$value" ;;
                MOUNT_STRUCTURE_DIR) MOUNT_STRUCTURE_DIR="$value" ;;
                ENABLE_INTERNAL_STORAGE) ENABLE_INTERNAL_STORAGE="$value" ;;
                ENABLE_EXTERNAL_STORAGE) ENABLE_EXTERNAL_STORAGE="$value" ;;
                INTERNAL_STORAGE_PATH) INTERNAL_STORAGE_PATH="$value" ;;
                INTERNAL_STORAGE_NAME) INTERNAL_STORAGE_NAME="$value" ;;
                EXTERNAL_STORAGE_NAME) EXTERNAL_STORAGE_NAME="$value" ;;
                USB_STORAGE_NAME) USB_STORAGE_NAME="$value" ;;
                EXTERNAL_STORAGE_PATTERNS) EXTERNAL_STORAGE_PATTERNS="$value" ;;
                MAX_EXTERNAL_STORAGE) MAX_EXTERNAL_STORAGE="$value" ;;
                AUTO_CLEANUP) AUTO_CLEANUP="$value" ;;
                STORAGE_TIMEOUT) STORAGE_TIMEOUT="$value" ;;
                VERBOSE) VERBOSE="$value" ;;
            esac
        done < "$config_file"
    fi
    
    # Expand variables in paths (safe expansion)
    MOUNT_ROOT="${MOUNT_ROOT//\$HOME/$HOME}"
    MOUNT_ROOT="${MOUNT_ROOT//\$(id -u)/$(id -u)}"
    CONFIG_DIR="${CONFIG_DIR//\$HOME/$HOME}"
    BOOKMARK_FILE="${BOOKMARK_FILE//\$HOME/$HOME}"
    MOUNT_STRUCTURE_DIR="${MOUNT_STRUCTURE_DIR//\$HOME/$HOME}"

    # Set symlink directory to MOUNT_STRUCTURE_DIR if empty
    if [[ -z "$SYMLINK_DIR" ]]; then
        SYMLINK_DIR="$MOUNT_STRUCTURE_DIR"
    else
        SYMLINK_DIR="${SYMLINK_DIR//\$HOME/$HOME}"
    fi
    
    # Validate numeric values
    if ! [[ "$POLL_INTERVAL" =~ ^[0-9]+$ ]] || [[ "$POLL_INTERVAL" -lt 1 ]]; then
        echo "Warning: Invalid POLL_INTERVAL '$POLL_INTERVAL', using default: $DEFAULT_POLL_INTERVAL"
        POLL_INTERVAL=$DEFAULT_POLL_INTERVAL
    fi
    
    if ! [[ "$STORAGE_TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$STORAGE_TIMEOUT" -lt 1 ]]; then
        echo "Warning: Invalid STORAGE_TIMEOUT '$STORAGE_TIMEOUT', using default: $DEFAULT_STORAGE_TIMEOUT"
        STORAGE_TIMEOUT=$DEFAULT_STORAGE_TIMEOUT
    fi
    
    if ! [[ "$MAX_LOG_SIZE" =~ ^[0-9]+$ ]]; then
        echo "Warning: Invalid MAX_LOG_SIZE '$MAX_LOG_SIZE', using default: $DEFAULT_MAX_LOG_SIZE"
        MAX_LOG_SIZE=$DEFAULT_MAX_LOG_SIZE
    fi
    
    if ! [[ "$LOG_ROTATE_COUNT" =~ ^[0-9]+$ ]] || [[ "$LOG_ROTATE_COUNT" -lt 1 ]]; then
        echo "Warning: Invalid LOG_ROTATE_COUNT '$LOG_ROTATE_COUNT', using default: $DEFAULT_LOG_ROTATE_COUNT"
        LOG_ROTATE_COUNT=$DEFAULT_LOG_ROTATE_COUNT
    fi
    
    # Validate boolean values
    case "$ENABLE_NOTIFICATIONS" in
        true|false) ;;
        *) 
            echo "Warning: Invalid ENABLE_NOTIFICATIONS '$ENABLE_NOTIFICATIONS', using default: $DEFAULT_ENABLE_NOTIFICATIONS"
            ENABLE_NOTIFICATIONS=$DEFAULT_ENABLE_NOTIFICATIONS
            ;;
    esac
    
    case "$AUTO_CLEANUP" in
        true|false) ;;
        *) 
            echo "Warning: Invalid AUTO_CLEANUP '$AUTO_CLEANUP', using default: $DEFAULT_AUTO_CLEANUP"
            AUTO_CLEANUP=$DEFAULT_AUTO_CLEANUP
            ;;
    esac
    
    case "$VERBOSE" in
        true|false) ;;
        *) 
            echo "Warning: Invalid VERBOSE '$VERBOSE', using default: $DEFAULT_VERBOSE"
            VERBOSE=$DEFAULT_VERBOSE
            ;;
    esac
    
    # Validate log level
    case "$LOG_LEVEL" in
        DEBUG|INFO|WARN|ERROR) ;;
        *)
            echo "Warning: Invalid LOG_LEVEL '$LOG_LEVEL', using default: $DEFAULT_LOG_LEVEL"
            LOG_LEVEL=$DEFAULT_LOG_LEVEL
            ;;
    esac

    # Validate directories exist or can be created
    if [[ -n "$SYMLINK_DIR" ]]; then
        if ! [[ -d "$SYMLINK_DIR" ]] && ! mkdir -p "$SYMLINK_DIR" 2>/dev/null; then
            echo "Warning: Cannot create SYMLINK_DIR '$SYMLINK_DIR', using HOME directory"
            SYMLINK_DIR="$HOME"
        fi
    fi

    if ! [[ -d "$CONFIG_DIR" ]] && ! mkdir -p "$CONFIG_DIR" 2>/dev/null; then
        echo "Error: Cannot create CONFIG_DIR '$CONFIG_DIR'"
        return 1
    fi

    # Validate MOUNT_ROOT exists
    if ! [[ -d "$MOUNT_ROOT" ]]; then
        echo "Warning: MOUNT_ROOT '$MOUNT_ROOT' does not exist"
    fi

    # Validate storage path formats
    if [[ "$INTERNAL_STORAGE_PATH" =~ ^/ ]]; then
        echo "Warning: INTERNAL_STORAGE_PATH should be relative, removing leading slash"
        INTERNAL_STORAGE_PATH="${INTERNAL_STORAGE_PATH#/}"
    fi

    # Validate boolean values for storage options
    case "$ENABLE_INTERNAL_STORAGE" in
        true|false) ;;
        *)
            echo "Warning: Invalid ENABLE_INTERNAL_STORAGE '$ENABLE_INTERNAL_STORAGE', using default: $DEFAULT_ENABLE_INTERNAL_STORAGE"
            ENABLE_INTERNAL_STORAGE=$DEFAULT_ENABLE_INTERNAL_STORAGE
            ;;
    esac

    case "$ENABLE_EXTERNAL_STORAGE" in
        true|false) ;;
        *)
            echo "Warning: Invalid ENABLE_EXTERNAL_STORAGE '$ENABLE_EXTERNAL_STORAGE', using default: $DEFAULT_ENABLE_EXTERNAL_STORAGE"
            ENABLE_EXTERNAL_STORAGE=$DEFAULT_ENABLE_EXTERNAL_STORAGE
            ;;
    esac

    # Validate MAX_EXTERNAL_STORAGE
    if ! [[ "$MAX_EXTERNAL_STORAGE" =~ ^[0-9]+$ ]] || [[ "$MAX_EXTERNAL_STORAGE" -lt 0 ]] || [[ "$MAX_EXTERNAL_STORAGE" -gt 10 ]]; then
        echo "Warning: Invalid MAX_EXTERNAL_STORAGE '$MAX_EXTERNAL_STORAGE', using default: $DEFAULT_MAX_EXTERNAL_STORAGE"
        MAX_EXTERNAL_STORAGE=$DEFAULT_MAX_EXTERNAL_STORAGE
    fi

    # Validate directory names don't contain problematic characters
    if [[ "$INTERNAL_STORAGE_NAME" =~ [/\\] ]]; then
        echo "Warning: INTERNAL_STORAGE_NAME contains invalid characters, using default"
        INTERNAL_STORAGE_NAME=$DEFAULT_INTERNAL_STORAGE_NAME
    fi

    if [[ "$EXTERNAL_STORAGE_NAME" =~ [/\\] ]]; then
        echo "Warning: EXTERNAL_STORAGE_NAME contains invalid characters, using default"
        EXTERNAL_STORAGE_NAME=$DEFAULT_EXTERNAL_STORAGE_NAME
    fi

    if [[ "$USB_STORAGE_NAME" =~ [/\\] ]]; then
        echo "Warning: USB_STORAGE_NAME contains invalid characters, using default"
        USB_STORAGE_NAME=$DEFAULT_USB_STORAGE_NAME
    fi
}

# Function to validate configuration after loading
validate_config() {
    local errors=0

    # Check required commands
    if ! command -v dconf >/dev/null 2>&1; then
        echo "Error: dconf command not found. GSConnect may not be installed."
        ((errors++))
    fi

    if ! command -v find >/dev/null 2>&1; then
        echo "Error: find command not found."
        ((errors++))
    fi

    # Check GSConnect extension
    if ! dconf list /org/gnome/shell/extensions/gsconnect/ >/dev/null 2>&1; then
        echo "Warning: GSConnect extension not found or not configured"
    fi

    # Check notification support
    if [[ "$ENABLE_NOTIFICATIONS" == true ]] && ! command -v notify-send >/dev/null 2>&1; then
        echo "Warning: notify-send not found. Desktop notifications will be disabled."
    fi

    return $errors
}

# Function to create default config file
create_default_config() {
    local config_file="$1"
    local config_dir=$(dirname "$config_file")
    
    mkdir -p "$config_dir"
    
    cat > "$config_file" << 'EOF'
# GSConnect Mount Manager Configuration
# This file contains configuration options for the mount manager

# Polling interval in seconds (how often to check for mounts)
POLL_INTERVAL=5

# Root directory where GVFS mounts are located
MOUNT_ROOT="/run/user/$(id -u)/gvfs"

# Directory where configuration and state files are stored
CONFIG_DIR="$HOME/.config/gsconnect-mount-manager"

# Location of GTK bookmarks file
BOOKMARK_FILE="$HOME/.config/gtk-3.0/bookmarks"

# Mount structure directory (where device folders are created)
MOUNT_STRUCTURE_DIR="$HOME/.gsconnect-mount"

# Custom symlink prefix (added before device name)
# Example: "Phone-" would create "Phone-DeviceName" symlinks
SYMLINK_PREFIX=""

# Custom symlink suffix (added after device name)
# Example: "-Storage" would create "DeviceName-Storage" symlinks
SYMLINK_SUFFIX=""

# Enable desktop notifications (true/false)
ENABLE_NOTIFICATIONS=true

# Log level (DEBUG, INFO, WARN, ERROR)
LOG_LEVEL=INFO

# Maximum log file size in MB (0 = no limit)
MAX_LOG_SIZE=10

# Number of log files to keep in rotation
LOG_ROTATE_COUNT=5

# Storage Configuration
# Enable internal storage (storage/emulated/0) - Android internal storage
ENABLE_INTERNAL_STORAGE=true

# Enable external storage detection (SD cards, USB OTG) - storage/[UUID] or storage/sdcard1
ENABLE_EXTERNAL_STORAGE=true

# Custom internal storage path (default: storage/emulated/0)
INTERNAL_STORAGE_PATH="storage/emulated/0"


# External storage detection patterns (space-separated list)
# Patterns to match external storage directories
EXTERNAL_STORAGE_PATTERNS="storage/[0-9A-F][0-9A-F][0-9A-F][0-9A-F]* storage/sdcard1 storage/extSdCard storage/external_sd storage/usbotg"

# Maximum number of external storage devices to detect
MAX_EXTERNAL_STORAGE=3

# Enable automatic cleanup of broken symlinks (true/false)
AUTO_CLEANUP=true

# Timeout in seconds to wait for device storage to become available
STORAGE_TIMEOUT=30

# Enable verbose logging (true/false)
VERBOSE=false
EOF
}
