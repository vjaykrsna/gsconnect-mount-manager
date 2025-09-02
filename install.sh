#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# GSConnect Mount Manager Installer
# -----------------------------------------------------------------------------

# --- Configuration ---
SCRIPT_NAME="gsconnect-mount-manager.sh"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gsconnect-mount-manager"
CONFIG_FILE="$CONFIG_DIR/config.conf"
SERVICE_NAME="gsconnect-mount-manager.service"
SERVICE_FILE="$HOME/.config/systemd/user/$SERVICE_NAME"
SOURCE_SCRIPT_PATH="$(dirname "$(realpath "${BASH_SOURCE[0]}")")/$SCRIPT_NAME"
DEST_SCRIPT_PATH="$CONFIG_DIR/$SCRIPT_NAME"

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

LOG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/gsconnect-mount-manager/gsconnect-mount-manager.log"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

info() {
    local msg="$*"
    printf "%b[INFO] %s%b\n" "$GREEN" "$msg" "$NC"      # colored output
    printf "[INFO] %s\n" "$msg" >> "$LOG_FILE"           # plain log
}

warn() {
    local msg="$*"
    printf "%b[WARN] %s%b\n" "$YELLOW" "$msg" "$NC"
    printf "[WARN] %s\n" "$msg" >> "$LOG_FILE"
}

error() {
    local msg="$*"
    printf "%b[ERROR] %s%b\n" "$RED" "$msg" "$NC"
    printf "[ERROR] %s\n" "$msg" >> "$LOG_FILE"
}
# --- Functions ---
check_dependencies() {
    info "Checking dependencies..."
    
    local deps=(systemctl bash mkdir cp chmod flock sed grep gio)
    local missing=()
    
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        for cmd in "${missing[@]}"; do
            error "Required command not found: $cmd"
        done
        error "Please install the missing dependencies and try again."
        exit 1
    else
        info "All dependencies are installed."
    fi
}

create_config_dir() {
    info "Creating configuration directory..."
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
        info "Creating default configuration file..."
        cat >"$CONFIG_FILE" <<'EOF'
POLL_INTERVAL=3
MOUNT_STRUCTURE_DIR="$HOME"
LOG_LEVEL="INFO"
ENABLE_BOOKMARKS=true
EOF
        info "Default configuration created at $CONFIG_FILE"
    else
        warn "Configuration file already exists. Skipping creation."
    fi
}

copy_script() {
    info "Copying main script..."
    if [[ ! -f "$SOURCE_SCRIPT_PATH" ]]; then
        error "Source script not found at $SOURCE_SCRIPT_PATH"
        exit 1
    fi
    
    # Use cat to avoid quote escaping issues
    cat "$SOURCE_SCRIPT_PATH" > "$DEST_SCRIPT_PATH" || {
        error "Failed to copy script to $DEST_SCRIPT_PATH"
        exit 1
    }
    chmod +x "$DEST_SCRIPT_PATH" || {
        error "Failed to make script executable"
        exit 1
    }
    info "Script copied and made executable at $DEST_SCRIPT_PATH"
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
Description=GSConnect Mount Manager
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

    info "Enabling and starting the service..."
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
    info "Starting GSConnect Mount Manager installation..."

    check_dependencies
    create_config_dir
    create_default_config
    copy_script
    install_systemd_service

    info "-------------------------------------------------"
    info "Installation complete!"
    info "The service is now running in the background."
    info "To view logs, run: journalctl --user -u $SERVICE_NAME -f"
    info "To edit settings, modify: $CONFIG_FILE"
    info "-------------------------------------------------"
}

# Run the installer
main
