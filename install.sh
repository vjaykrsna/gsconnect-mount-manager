#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# GSConnect Mount Manager Installer
# -----------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.config/gsconnect-mount-manager"
SERVICE_FILE="$HOME/.config/systemd/user/gsconnect-mount-manager.service"

# Check if colors are supported
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    NC=$(tput sgr0)
else
    RED=""
    GREEN=""
    YELLOW=""
    NC=""
fi

info()    { printf "%s[INFO] %s%s\n" "$GREEN" "$*" "$NC"; }
warn()    { printf "%s[WARN] %s%s\n" "$YELLOW" "$*" "$NC"; }
error()   { printf "%s[ERROR] %s%s\n" "$RED" "$*" "$NC"; }

# -----------------------------
# Functions
# -----------------------------

check_dependencies() {
    local deps=("systemctl" "bash" "mkdir" "grep" "sed" "tee" "ln" "cp" "mv" "date")
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            error "Required command not found: $cmd"
            exit 1
        fi
    done
}

create_config_dir() {
    [[ ! -d "$CONFIG_DIR" ]] && mkdir -p "$CONFIG_DIR" && info "Created config directory: $CONFIG_DIR"
}

backup_existing_config() {
    [[ -f "$CONFIG_DIR/config.conf" ]] && mv "$CONFIG_DIR/config.conf" "$CONFIG_DIR/config.conf.bak_$(date +%s)" && info "Backed up existing config.conf"
}

copy_default_config() {
    [[ -f "$SCRIPT_DIR/config.conf" ]] && cp "$SCRIPT_DIR/config.conf" "$CONFIG_DIR/" && info "Copied default config.conf"
}

install_service() {
    info "Installing systemd user service..."
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=GSConnect Mount Manager
After=network.target

[Service]
Type=simple
ExecStart=$SCRIPT_DIR/run.sh
Restart=always
RestartSec=5
# Full PATH for systemd environment
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="HOME=$HOME"

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable --now gsconnect-mount-manager.service
    info "Service installed and started"
}

# -----------------------------
# Main
# -----------------------------
info "Starting GSConnect Mount Manager installation..."
check_dependencies
create_config_dir
backup_existing_config
copy_default_config
install_service
info "✅ Installation complete!"
