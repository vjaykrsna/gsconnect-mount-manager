#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# GMM (GSConnect / KDE Connect Mount Manager) 2.0 Installer
# -----------------------------------------------------------------------------

BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gmm"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE_NAME="gmm.service"

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
SOURCE_BIN="$SOURCE_DIR/gmm"
RAW_REPO_URL="https://raw.githubusercontent.com/vjaykrsna/gsconnect-mount-manager/main"

# Output helpers
info()  { printf "\033[32m[INFO]\033[0m %s\n" "$*"; }
warn()  { printf "\033[33m[WARN]\033[0m %s\n" "$*"; }
error() { printf "\033[31m[ERROR]\033[0m %s\n" "$*" >&2; }

# Guard against running as root
if [[ "$(id -u)" -eq 0 ]]; then
    error "Do not run install.sh as root or with sudo. GMM runs as a user service."
    exit 1
fi

check_dependencies() {
    info "Checking system requirements..."

    if ! command -v python3 >/dev/null 2>&1; then
        error "Python 3 is required but not installed."
        exit 1
    fi

    local py_ok
    py_ok=$(python3 -c "import sys; print('yes' if sys.version_info >= (3, 11) else 'no')")
    if [[ "$py_ok" != "yes" ]]; then
        error "Python 3.11 or newer is required."
        exit 1
    fi

    if ! python3 -c "import gi; gi.require_version('Gio', '2.0'); from gi.repository import Gio" >/dev/null 2>&1; then
        error "PyGObject (python3-gi) is required but missing."
        echo "Install it via your distribution's package manager:"
        echo "  Debian/Ubuntu: sudo apt install python3-gi"
        echo "  Fedora:        sudo dnf install python3-gobject"
        echo "  Arch Linux:    sudo pacman -S python-gobject"
        exit 1
    fi

    info "Prerequisite dependencies satisfied."
}

install_binary() {
    info "Installing gmm executable to $BIN_DIR/gmm..."
    mkdir -p "$BIN_DIR"

    if [[ -n "$SOURCE_DIR" ]] && [[ -f "$SOURCE_BIN" ]]; then
        cp "$SOURCE_BIN" "$BIN_DIR/gmm"
    else
        info "Fetching gmm from GitHub..."
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL "$RAW_REPO_URL/gmm" -o "$BIN_DIR/gmm"
        elif command -v wget >/dev/null 2>&1; then
            wget -qO "$BIN_DIR/gmm" "$RAW_REPO_URL/gmm"
        else
            error "Neither curl nor wget found. Cannot download gmm."
            exit 1
        fi
    fi

    chmod +x "$BIN_DIR/gmm"

    if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
        warn "$BIN_DIR is not currently in your PATH."
        warn "You may want to add 'export PATH=\"\$HOME/.local/bin:\$PATH\"' to your ~/.bashrc or ~/.zshrc."
    fi
}

install_config() {
    mkdir -p "$CONFIG_DIR"
    local target_config="$CONFIG_DIR/config.toml"

    if [[ ! -f "$target_config" ]]; then
        info "Creating default configuration at $target_config..."
        cat > "$target_config" <<'EOF'
# GMM (GSConnect / KDE Connect Mount Manager) Configuration File

[general]
# Base directory where device symlinks are organized
mount_structure_dir = "~/Devices"

# GTK bookmark mode: "both", "sftp_only", "local_only", "none"
bookmark_mode = "both"

# Show desktop notifications when storage is connected or disconnected
notifications = true

# Automatically trigger SFTP mounting when a paired device connects to Wi-Fi
auto_mount = true

# Clean up empty device directories and dangling links on disconnect
auto_cleanup = true

[storage]
# Automatically discover Internal and SD Card UUID partitions
auto_discover = true

# Exclude internal Android pseudo-directories from symlinking
exclude_directories = ["self", "knox", "legacy", "sdcard"]

# Custom storage paths (optional override). Format: ["/mount/path:DisplayName"]
custom_paths = []

[logging]
level = "INFO"
EOF
    else
        info "Configuration file already exists at $target_config. Preserving existing config."
    fi
}

install_systemd_service() {
    if ! command -v systemctl >/dev/null 2>&1; then
        return
    fi

    info "Installing systemd user service..."
    mkdir -p "$SYSTEMD_USER_DIR"
    cat > "$SYSTEMD_USER_DIR/$SERVICE_NAME" <<EOF
[Unit]
Description=GMM (GSConnect / KDE Connect Mount Manager)
Documentation=https://github.com/vjaykrsna/gsconnect-mount-manager
After=network.target

[Service]
Type=simple
ExecStart=%h/.local/bin/gmm daemon
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=3

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable --now "$SERVICE_NAME"
    info "Systemd user service enabled and started."
}

main() {
    echo "================================================="
    echo "  GMM (GSConnect / KDE Connect Mount Manager) 2.0"
    echo "================================================="

    check_dependencies
    install_binary
    install_config
    install_systemd_service

    echo "-------------------------------------------------"
    info "Installation complete!"
    echo
    echo "Useful commands:"
    echo "  gmm status                  - View connected devices, mounts, and bookmarks"
    echo "  gmm list                    - List paired devices"
    echo "  gmm doctor                  - Run diagnostic checks"
    echo "  systemctl --user status gmm - Check background service status"
    echo "-------------------------------------------------"
}

main
