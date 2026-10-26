#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# GMM (GSConnect / KDE Connect Mount Manager) 2.0 Uninstaller
# -----------------------------------------------------------------------------

BIN_PATH="${XDG_BIN_HOME:-$HOME/.local/bin}/gmm"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gmm"
SERVICE_NAME="gmm.service"
SERVICE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$SERVICE_NAME"

info()  { printf "\033[32m[INFO]\033[0m %s\n" "$*"; }
warn()  { printf "\033[33m[WARN]\033[0m %s\n" "$*"; }
error() { printf "\033[31m[ERROR]\033[0m %s\n" "$*" >&2; }

# Parse arguments
AUTO_CONFIRM=false
REMOVE_CONFIG=false
for arg in "$@"; do
    case "$arg" in
        -y|--yes|--force) AUTO_CONFIRM=true ;;
        --purge) AUTO_CONFIRM=true; REMOVE_CONFIG=true ;;
    esac
done

if [[ "$AUTO_CONFIRM" != true ]]; then
    read -p "Are you sure you want to uninstall GMM? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "Uninstallation cancelled."
        exit 0
    fi
fi

# 1. Clean up managed bookmarks and symlinks
if [[ -x "$BIN_PATH" ]]; then
    info "Running artifact cleanup via gmm clean..."
    "$BIN_PATH" clean || warn "gmm clean reported a warning."
elif command -v gmm >/dev/null 2>&1; then
    gmm clean || warn "gmm clean reported a warning."
fi

# 2. Stop and disable systemd user service
if command -v systemctl >/dev/null 2>&1; then
    if systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        info "Stopping $SERVICE_NAME..."
        systemctl --user stop "$SERVICE_NAME" || true
    fi
    if systemctl --user is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        info "Disabling $SERVICE_NAME..."
        systemctl --user disable "$SERVICE_NAME" || true
    fi
fi

# 3. Remove systemd service file
if [[ -f "$SERVICE_FILE" ]]; then
    info "Removing $SERVICE_FILE..."
    rm -f "$SERVICE_FILE"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user daemon-reload || true
    fi
fi

# 4. Remove executable binary
if [[ -f "$BIN_PATH" ]]; then
    info "Removing $BIN_PATH..."
    rm -f "$BIN_PATH"
fi

# 5. Handle configuration removal
if [[ "$REMOVE_CONFIG" == true ]]; then
    if [[ -d "$CONFIG_DIR" ]]; then
        info "Purging configuration directory at $CONFIG_DIR..."
        rm -rf "$CONFIG_DIR"
    fi
elif [[ -d "$CONFIG_DIR" ]]; then
    info "Configuration directory preserved at $CONFIG_DIR."
    info "To completely remove it, run: rm -rf \"$CONFIG_DIR\""
fi

echo "-------------------------------------------------"
info "GMM has been successfully uninstalled."
echo "-------------------------------------------------"
