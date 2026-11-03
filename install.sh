#!/usr/bin/env bash
# GMM 3.1.0 — installs the same executable used by `gmm update`.
set -euo pipefail

BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
RAW_REPO_URL="https://raw.githubusercontent.com/vjaykrsna/gsconnect-mount-manager/main"
SOURCE_DIR=""
TEMP_BIN=""
TEMP_UNIT=""

cleanup() {
    [[ -z "$TEMP_BIN" ]] || rm -f -- "$TEMP_BIN"
    [[ -z "$TEMP_UNIT" ]] || rm -f -- "$TEMP_UNIT"
}
trap cleanup EXIT

if [[ "$(id -u)" -eq 0 ]]; then
    echo "Run this installer as your regular user, without sudo." >&2
    exit 1
fi
if ! python3 -c 'import sys; assert sys.version_info >= (3, 11); import gi; gi.require_version("Gio", "2.0"); from gi.repository import Gio, GLib' >/dev/null 2>&1; then
    echo "GMM requires Python 3.11+ and PyGObject (python3-gi or python-gobject)." >&2
    exit 1
fi
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fi
BIN_DIR="$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$BIN_DIR")"
mkdir -p -- "$BIN_DIR"
TEMP_BIN="$(mktemp "$BIN_DIR/.gmm-install.XXXXXX")"
if [[ -n "$SOURCE_DIR" && -f "$SOURCE_DIR/gmm" ]]; then
    cp -- "$SOURCE_DIR/gmm" "$TEMP_BIN"
elif command -v curl >/dev/null 2>&1; then
    curl --fail --silent --show-error --location --max-time 60 "$RAW_REPO_URL/gmm" -o "$TEMP_BIN"
elif command -v wget >/dev/null 2>&1; then
    wget --quiet --timeout=60 -O "$TEMP_BIN" "$RAW_REPO_URL/gmm"
else
    echo "Install curl or wget to download GMM, or run install.sh from a cloned repository." >&2
    exit 1
fi
python3 -c 'import pathlib, sys; compile(pathlib.Path(sys.argv[1]).read_bytes(), sys.argv[1], "exec")' "$TEMP_BIN"
chmod 755 "$TEMP_BIN"

# Stop the old daemon before changing its config or owned entries.
if command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet gmm.service; then
    systemctl --user stop gmm.service
fi
if ! "$TEMP_BIN" --prepare-config; then
    echo "Configuration preparation failed. The previous executable remains installed; the service was not restarted." >&2
    exit 1
fi
mv -f -- "$TEMP_BIN" "$BIN_DIR/gmm"
TEMP_BIN=""

if command -v systemctl >/dev/null 2>&1; then
    mkdir -p -- "$SYSTEMD_USER_DIR"
    TEMP_UNIT="$(mktemp "$SYSTEMD_USER_DIR/.gmm-service.XXXXXX")"
    python3 - "$BIN_DIR/gmm" > "$TEMP_UNIT" <<'PY'
import json
import sys
executable = json.dumps(sys.argv[1].replace('%', '%%').replace('$', '$$'), ensure_ascii=False)
print(f'''[Unit]
Description=GMM phone storage access
After=dbus.service
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
ExecStart={executable} daemon
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
''')
PY
    chmod 644 "$TEMP_UNIT"
    mv -f -- "$TEMP_UNIT" "$SYSTEMD_USER_DIR/gmm.service"
    TEMP_UNIT=""
    if systemctl --user daemon-reload && systemctl --user enable --now gmm.service; then
        echo "GMM installed and running. It will wait for GSConnect or KDE Connect to mount your phone."
    else
        echo "GMM installed, but its service could not start. From your desktop session, run:"
        echo "  systemctl --user enable --now gmm.service"
    fi
else
    echo "GMM installed. systemd was not found; run '$BIN_DIR/gmm daemon' in your desktop session."
fi
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo "$BIN_DIR is not in PATH. Add it to your shell's PATH or use $BIN_DIR/gmm directly."
fi
echo "Use gmm status or gmm doctor to check storage access."
