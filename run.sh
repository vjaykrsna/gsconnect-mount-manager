#!/usr/bin/env bash
set -euo pipefail

MOUNT_ROOT="/run/user/$(id -u)/gvfs"
CONFIG_DIR="$HOME/.config/gsconnect-mount-manager"
FLAG_FILE="$CONFIG_DIR/mounted"
BOOKMARK_FILE="$HOME/.config/gtk-3.0/bookmarks"
BOOKMARK_ENTRY_FILE="$CONFIG_DIR/bookmark_entry"
LINK_PATH_FILE="$CONFIG_DIR/link_path"

mkdir -p "$CONFIG_DIR"

get_device_name() {
  local mnt_path=$1
  local host=$(echo "$mnt_path" | sed -n 's/.*host=\([^,]*\).*/\1/p')

  # Find the device ID that matches the host IP
  for dev_id in $(dconf list /org/gnome/shell/extensions/gsconnect/device/ | grep '/$'); do
    local full_path="/org/gnome/shell/extensions/gsconnect/device/${dev_id}"
    local last_conn_ip=$(dconf read "${full_path}last-connection" 2>/dev/null | tr -d "'" | sed -n 's/lan:\/\/\([^:]*\):.*/\1/p')

    if [[ "$last_conn_ip" == "$host" ]]; then
      dconf read "${full_path}name" 2>/dev/null | tr -d "'"
      return
    fi
  done
}


while true; do
  MNT=$(find "$MOUNT_ROOT" -maxdepth 1 -type d -name 'sftp:*' | head -n1 || true)

  if [[ -n "$MNT" ]] && ! [[ -f "$FLAG_FILE" ]]; then
    # Mounted and not flagged -> run mount logic
    echo "Mount detected. Running setup..."
    DEVICE_NAME=$(get_device_name "$(basename "$MNT")")
    echo "Device name set to: '$DEVICE_NAME'"

    SDCARD="$MNT/storage/emulated/0"
    if ! [[ -d "$SDCARD" ]]; then
      echo "❌ Mounted, but internal storage path not found."
      sleep 5
      continue
    fi

    # Bookmark
    LABEL="$DEVICE_NAME"
    ENTRY="file://$SDCARD $LABEL"
    grep -qxF "$ENTRY" "$BOOKMARK_FILE" 2>/dev/null || {
      mkdir -p "$(dirname "$BOOKMARK_FILE")"
      echo "$ENTRY" >> "$BOOKMARK_FILE"
      echo "$ENTRY" > "$BOOKMARK_ENTRY_FILE"
      echo "🔖 Added bookmark: $LABEL"
    }

    # Symlink
    LINK="$HOME/$DEVICE_NAME"
    if [[ -L "$LINK" ]]; then
      rm "$LINK"
    fi
    ln -s "$SDCARD" "$LINK"
    echo "$LINK" > "$LINK_PATH_FILE"
    echo "🔗 Symlink created: $LINK"

    touch "$FLAG_FILE"
    echo "✅ Mount setup complete."

  elif [[ -z "$MNT" ]] && [[ -f "$FLAG_FILE" ]]; then
    # Not mounted but flagged -> run unmount logic
    echo "Unmount detected. Running cleanup..."

    # Remove bookmark
    if [[ -f "$BOOKMARK_ENTRY_FILE" ]]; then
      ENTRY_TO_REMOVE=$(cat "$BOOKMARK_ENTRY_FILE")
      grep -vF "$ENTRY_TO_REMOVE" "$BOOKMARK_FILE" > "$BOOKMARK_FILE.tmp" && mv "$BOOKMARK_FILE.tmp" "$BOOKMARK_FILE"
      rm "$BOOKMARK_ENTRY_FILE"
      echo "🔖 Bookmark removed."
    fi

    # Remove symlink
    if [[ -f "$LINK_PATH_FILE" ]]; then
      LINK_TO_REMOVE=$(cat "$LINK_PATH_FILE")
      if [[ -L "$LINK_TO_REMOVE" ]]; then
        rm "$LINK_TO_REMOVE"
        echo "🔗 Symlink removed."
      fi
      rm "$LINK_PATH_FILE"
    fi

    rm "$FLAG_FILE"
    echo "✅ Unmount cleanup complete."
  fi

  sleep 5 # Check every 5 seconds
done
