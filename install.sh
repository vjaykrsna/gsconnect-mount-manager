#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# GMM (GSConnect / KDE Connect Mount Manager) 2.0.3 Installer
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

    local temp_bin
    temp_bin="$(mktemp "$BIN_DIR/.gmm-install.XXXXXX")"
    if [[ -n "$SOURCE_DIR" ]] && [[ -f "$SOURCE_BIN" ]]; then
        cp "$SOURCE_BIN" "$temp_bin"
    else
        info "Fetching gmm from GitHub..."
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL "$RAW_REPO_URL/gmm" -o "$temp_bin" || { rm -f "$temp_bin"; return 1; }
        elif command -v wget >/dev/null 2>&1; then
            wget -qO "$temp_bin" "$RAW_REPO_URL/gmm" || { rm -f "$temp_bin"; return 1; }
        else
            rm -f "$temp_bin"
            error "Neither curl nor wget found. Cannot download gmm."
            return 1
        fi
    fi

    if ! python3 -c 'import pathlib, sys; compile(pathlib.Path(sys.argv[1]).read_bytes(), sys.argv[1], "exec")' "$temp_bin"; then
        rm -f "$temp_bin"
        error "The downloaded executable failed Python syntax validation."
        return 1
    fi
    chmod +x "$temp_bin"
    mv -f "$temp_bin" "$BIN_DIR/gmm"

    if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
        warn "$BIN_DIR is not currently in your PATH."
        if [[ -t 0 ]]; then
            read -p "Would you like to automatically add $BIN_DIR to your shell configuration? (y/N) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                local shell_rc="$HOME/.bashrc"
                if [[ "${SHELL:-}" == *"zsh"* ]] && [[ -f "$HOME/.zshrc" ]]; then
                    shell_rc="$HOME/.zshrc"
                fi
                {
                    echo ""
                    echo "# Added by GMM installer"
                    echo "export PATH=\"$BIN_DIR:\$PATH\""
                } >> "$shell_rc"
                info "Added PATH export to $shell_rc."
                info "Run 'source $shell_rc' or restart your terminal to use 'gmm'."
            fi
        else
            warn "Add 'export PATH=\"$BIN_DIR:\$PATH\"' to your ~/.bashrc or ~/.zshrc to use 'gmm' directly."
        fi
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
bookmark_mode = "sftp_only"

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
After=dbus.service

[Service]
Type=simple
ExecStart=$BIN_DIR/gmm daemon
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=3

[Install]
WantedBy=default.target
EOF

    if ! systemctl --user daemon-reload 2>/dev/null; then
        warn "Could not reload systemd user daemon (systemd user session may not be active)."
        warn "You can manually enable the service later with: systemctl --user enable --now $SERVICE_NAME"
        return
    fi

    local was_active=false
    if systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        was_active=true
    fi
    if systemctl --user enable --now "$SERVICE_NAME" 2>/dev/null; then
        if [[ "$was_active" == true ]]; then
            if systemctl --user restart "$SERVICE_NAME" 2>/dev/null; then
                info "Systemd user service restarted with the updated executable."
            else
                warn "The service could not be restarted; run: systemctl --user restart $SERVICE_NAME"
            fi
        else
            info "Systemd user service enabled and started."
        fi
    else
        warn "Could not start systemd user service automatically."
        warn "Start it manually when logged into a systemd session: systemctl --user start $SERVICE_NAME"
    fi
}

main() {
    echo "================================================="
    echo "  GMM (GSConnect / KDE Connect Mount Manager) 2.0.3"
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
