# GSConnect Mount Manager

A simple, robust script to automatically manage your phone's storage via GSConnect. This script runs as a lightweight background service to automatically handle mounting and unmounting your device's storage.

## Problem Solved

This script provides a seamless solution to the issue where accessing GSConnect's mounted storage directly can be cumbersome or result in folders opening in new windows.

![error](./error.png)

## Features

- **Automatic Mounting:** Detects when your phone connects via GSConnect and automatically prepares the storage.
- **Automatic Unmounting:** Detects when your phone disconnects and cleans up the created links and bookmarks.
- **Dynamic Naming:** Automatically uses your device's name for bookmarks and symlinks (e.g., a bookmark and symlink named "MyPhone").
- **Nautilus Bookmark:** Creates a bookmark in your file manager for easy, one-click access.
- **CLI Symlink:** Creates a symlink in your home directory for quick terminal access.
- **Multi-Storage Support:** Automatically detects and mounts both internal storage and external storage (SD cards, USB OTG).
- **Customizable Configuration:** Advanced installation mode with configurable paths, polling intervals, and naming schemes.
- **Desktop Notifications:** Optional notifications when devices mount/unmount with storage-specific details.
- **Structured Logging:** Configurable log levels with automatic log rotation.
- **Error Recovery:** Robust error handling and automatic cleanup of broken symlinks.
- **Lightweight & Efficient:** Runs as a minimal background service with negligible resource usage.
- **Safe & Non-Intrusive:** Does not modify any GSConnect files, ensuring stability and compatibility with future GSConnect updates.

## How It Works

The script runs as a systemd user service, continuously monitoring for a GSConnect SFTP mount in the background.

- **On Mount:** When a device connects, the script automatically creates a bookmark in Nautilus and a symlink in your home directory for easy access.
- **On Unmount:** When the device disconnects, the script cleans up by removing the previously created bookmark and symlink.

This ensures that your phone's storage is always ready when connected and that no stale links are left behind when it's not.

## Multi-Storage Support

The system automatically detects and provides access to multiple storage types:

### Internal Storage
- **Path**: `storage/emulated/0` (Android's internal storage)
- **Symlink**: `DeviceName` (or with custom suffix)
- **Contains**: Apps, photos, downloads, documents

### External Storage (SD Cards, USB OTG)
- **Auto-Detection**: Scans for SD cards and USB devices
- **Symlink**: `DeviceName-SDCard` (or custom suffix)
- **Multiple Devices**: Supports up to 10 external storage devices
- **Smart Naming**: Automatically numbers multiple devices (SDCard, SDCard2, etc.)

### Example Setup
When your phone "MyPhone" connects with an SD card:

**Single Bookmark Created:**
- `MyPhone` → Opens device root showing:
  - `storage/emulated/0/` (internal storage)
  - `storage/1234-5678/` (SD card)
  - Any other connected storage

**Symlinks Created:**
```bash
~/MyPhone          → internal storage (photos, apps, downloads)
~/MyPhone-SDCard   → SD card (additional storage)
```

**User Experience:**
- 📁 **File Manager**: Click "MyPhone" bookmark → browse all storage in one place
- 💻 **Terminal**: Use `~/MyPhone` or `~/MyPhone-SDCard` for direct access
- 🔔 **Notifications**: Get notified when storage mounts/unmounts

## Requirements

- A working GSConnect installation on your GNOME desktop.

## Installation

Run the following commands in your terminal:

```bash
git clone https://github.com/vjaykrsna/gsconnect-mount-manager.git
cd gsconnect-mount-manager
chmod +x install.sh
./install.sh
```

The script will be installed as a systemd user service and will start automatically with these default settings:

- **📁 Single Bookmark**: One bookmark per device that shows internal storage, SD cards, etc. as subfolders
- **🔗 Smart Symlinks**: Separate symlinks for internal storage and each SD card
- **🔔 Notifications**: Desktop notifications when devices mount/unmount
- **📊 Logging**: INFO level with automatic log rotation
- **⚡ Polling**: Checks for device changes every 5 seconds

**Note:** Do NOT run the installer with `sudo` or as the root user.

## Customization

To customize settings, edit the configuration file:
```bash
nano ~/.config/gsconnect-mount-manager/config.conf
```

**Common Customizations:**

```bash
# Change polling frequency (1-60 seconds)
POLL_INTERVAL=10

# Custom symlink location
SYMLINK_DIR="/home/user/Devices"

# Custom naming
SYMLINK_PREFIX="Phone-"
EXTERNAL_STORAGE_SUFFIX="-SD"

# Disable notifications
ENABLE_NOTIFICATIONS=false

# More verbose logging
LOG_LEVEL=DEBUG
VERBOSE=true

# Storage options
ENABLE_INTERNAL_STORAGE=true
ENABLE_EXTERNAL_STORAGE=true
MAX_EXTERNAL_STORAGE=5
```

After editing, restart the service:
```bash
systemctl --user restart gsconnect-mount-manager
```

## Management Commands

Check service status:
```bash
systemctl --user status gsconnect-mount-manager
```

View live logs:
```bash
journalctl --user -u gsconnect-mount-manager -f
```

Stop/start the service:
```bash
systemctl --user stop gsconnect-mount-manager
systemctl --user start gsconnect-mount-manager
```

## Uninstallation

To completely remove the service and all related files:
```bash
systemctl --user stop gsconnect-mount-manager.service
systemctl --user disable gsconnect-mount-manager.service
rm ~/.config/systemd/user/gsconnect-mount-manager.service
rm -rf ~/.config/gsconnect-mount-manager
# Optional: Remove device symlinks from your home directory
# ls -la ~ | grep "^l.*->"  # List symlinks to identify device links
```

## Tested On

- Ubuntu (Gnome)
