#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# GSConnect Mount Manager Installer
# -----------------------------------------------------------------------------

# --- Configuration ---
SCRIPT_NAME="gmm-main.sh"
LIB_SCRIPT_NAME="gmm-lib.sh"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gmm"
CONFIG_FILE="$CONFIG_DIR/gmm.conf"
SERVICE_NAME="gmm.service"
SERVICE_FILE="$HOME/.config/systemd/user/$SERVICE_NAME"
SOURCE_SCRIPT_PATH="$(dirname "$(realpath "${BASH_SOURCE[0]}")")/$SCRIPT_NAME"
SOURCE_LIB_PATH="$(dirname "$(realpath "${BASH_SOURCE[0]}")")/$LIB_SCRIPT_NAME"
DEST_SCRIPT_PATH="$CONFIG_DIR/$SCRIPT_NAME"
DEST_LIB_PATH="$CONFIG_DIR/$LIB_SCRIPT_NAME"

# Source the library for shared functions
source "$SOURCE_LIB_PATH"

# Override LOG_FILE for installer - use a location that won't conflict with uninstall
LOG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/gmm-install.log"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# Simple logging functions that use the shared log function
info() { log "INFO"  "$*"; }
warn()  { log "WARN"  "$*"; }
error() { log "ERROR" "$*"; }
# --- Functions ---
check_dependencies() {
    local deps=(systemctl bash mkdir cp chmod flock sed grep gdbus gio)
    local missing=()
    
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        for cmd in "${missing[@]}"; do
            error "Required command not found: $cmd (needed for installation)"
        done
        error "Please install the missing dependencies and try again."
        exit 1
    else
        info "All dependencies are installed."
    fi
}

create_config_dir() {
    if [[ ! -d "$CONFIG_DIR" ]]; then
        mkdir -p "$CONFIG_DIR"
        info "Created directory: $CONFIG_DIR"
    else
        info "Configuration directory already exists: $CONFIG_DIR"
    fi
}

create_default_config() {
    create_config_dir  # ensure the directory exists
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
    cat >"$CONFIG_FILE" <<'EOF'
POLL_INTERVAL=3
MOUNT_STRUCTURE_DIR="$HOME"
LOG_LEVEL="INFO"
MAX_LOG_SIZE=1024
LOG_ROTATE_COUNT=5
ENABLE_BOOKMARKS=true

# --- Android Storage Paths ---
# These paths are the ONLY storage locations that will be detected and symlinked.
# Add common internal, external, and USB storage paths here.
# Paths are comma-separated
INTERNAL_STORAGE_PATHS="/storage/emulated/0"
EXTERNAL_STORAGE_PATHS=""
USB_STORAGE_PATHS=""
EOF
        info "Default configuration created at $CONFIG_FILE"
    else
        warn "Configuration file already exists. Skipping creation."
    fi
}

copy_script() {
    info "Copying script files..."
    
    # --- Copy Main Script ---
    if [[ ! -f "$SOURCE_SCRIPT_PATH" ]]; then
        error "Source script not found at $SOURCE_SCRIPT_PATH"
        exit 1
    fi
    cp "$SOURCE_SCRIPT_PATH" "$DEST_SCRIPT_PATH" || {
        error "Failed to copy script to $DEST_SCRIPT_PATH"
        exit 1
    }
    chmod +x "$DEST_SCRIPT_PATH" || {
        error "Failed to make script executable"
        exit 1
    }
    info "Main script copied to $DEST_SCRIPT_PATH"

    # --- Copy Library Script ---
    if [[ ! -f "$SOURCE_LIB_PATH" ]]; then
        error "Library script not found at $SOURCE_LIB_PATH"
        exit 1
    fi
    cp "$SOURCE_LIB_PATH" "$DEST_LIB_PATH" || {
        error "Failed to copy library to $DEST_LIB_PATH"
        exit 1
    }
    info "Library script copied to $DEST_LIB_PATH"
}

install_systemd_service() {
    info "Installing systemd user service..."

    # Stop the service if it's already running to ensure a clean update
    if systemctl --user is-active --quiet "$SERVICE_NAME"; then
        info "Service is running. Stopping it for update..."
        systemctl --user stop "$SERVICE_NAME" || warn "Failed to stop the service. Continuing anyway."
    fi

    mkdir -p "$(dirname "$SERVICE_FILE")"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=GMM (GSConnect Mount Manager)
After=network-online.target

[Service]
Type=simple
ExecStart=$DEST_SCRIPT_PATH
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF

    info "Reloading systemd user daemon..."
    systemctl --user daemon-reload || {
        error "Failed to reload systemd user daemon"
        exit 1
    }

    systemctl --user enable --now "$SERVICE_NAME" || {
        error "Failed to enable/start service"
        exit 1
    }

    info "Systemd service installed and started successfully"
}

# --- Main Installation Logic ---
main() {
    printf -- '-%.0s' {1..50} >> "$LOG_FILE"
    printf "\n" >> "$LOG_FILE"
    info "Starting GMM (GSConnect Mount Manager) installation..."

    check_dependencies
    create_config_dir
    create_default_config
    copy_script
    install_systemd_service

    info "-------------------------------------------------"
    info "Installation complete!"
    info "To edit settings, modify: $CONFIG_FILE"
    info "-------------------------------------------------"
}

# Run the installer
main
