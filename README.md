# GSConnect Mount Manager

Automatically organize and access your Android device storage when connected via GSConnect. Creates clean bookmarks and symlinks for seamless file browsing.

![error](./error.png)

## Features

- **🔄 Auto Mount/Unmount**: Detects device connections and handles setup/cleanup automatically
- **📁 Clean Organization**: Creates `~/.gsconnect-mount/Device-Name/` with organized storage folders  
- **🔖 File Manager Integration**: Single bookmark per device showing all storage types as subfolders
- **💻 Terminal Access**: Direct symlinks to internal storage and SD cards
- **📱 Multi-Storage Support**: Handles internal storage, SD cards, and USB OTG devices
- **🔔 Smart Notifications**: Desktop alerts when devices mount/unmount
- **⚙️ Configurable**: Customizable via config file (polling, paths, naming, etc.)
- **🛡️ Safe & Reliable**: No GSConnect modifications, automatic error recovery

## How It Works

**When your phone connects:**
1. 🔍 Detects GSConnect SFTP mount
2. 📁 Creates `~/.gsconnect-mount/Device-Name/` directory
3. 🔗 Creates symlinks: `Internal/`, `SDCard/`, `USB-OTG/` (as available)
4. 🔖 Adds bookmark to file manager sidebar
5. 🔔 Shows desktop notification

**When your phone disconnects:**
- 🧹 Automatically cleans up all symlinks and bookmarks
- 📂 Removes empty device directories

## Storage Organization

```
~/.gsconnect-mount/
└── IQOO-Z9x-5G/              # Device folder (spaces → hyphens)
    ├── Internal/              # → Android internal storage
    ├── SDCard/                # → SD card (if present)
    └── USB-OTG/               # → USB OTG device (if present)
```

**File Manager Experience:**
- Click "iQOO Z9x 5G" bookmark → Opens device folder
- See `Internal/`, `SDCard/` folders → Click to browse storage
- Natural folder navigation, no complex paths

**Terminal Access:**
```bash
cd ~/.gsconnect-mount/IQOO-Z9x-5G/Internal    # Phone storage
cd ~/.gsconnect-mount/IQOO-Z9x-5G/SDCard      # SD card
```

## Installation

```bash
git clone https://github.com/vjaykrsna/gsconnect-mount-manager.git
cd gsconnect-mount-manager
chmod +x install.sh
./install.sh
```

The script installs as a systemd user service and starts automatically.

**Note:** Do NOT run the installer with `sudo` or as the root user.

## Updating

To update to the latest version, run the `update.sh` script:
```bash
cd gsconnect-mount-manager
./update.sh
```
This will pull the latest changes from the repository and reinstall the service.

## Requirements

- **GSConnect**: GNOME Shell extension for KDE Connect protocol
- **GNOME/GTK Environment**: For bookmark integration
- **systemd**: For service management
- **Android Device**: With KDE Connect app installed

## Customization

Edit the configuration file to customize behavior:
```bash
nano ~/.config/gsconnect-mount-manager/config.conf
```

After editing, restart the service:
```bash
systemctl --user restart gsconnect-mount-manager
```

### General Settings
- `POLL_INTERVAL`: How often to check for device connections (seconds).
- `MOUNT_STRUCTURE_DIR`: Where to create device folders (e.g., `~/Devices`).
- `ENABLE_NOTIFICATIONS`: `true` or `false` to control desktop alerts.

### Naming & Symlinks
- `SYMLINK_PREFIX` / `SYMLINK_SUFFIX`: Add text before/after the device name in bookmarks.
- `INTERNAL_STORAGE_NAME`: Folder name for internal storage (default: `Internal`).
- `EXTERNAL_STORAGE_NAME`: Base name for SD cards (default: `SDCard`).
- `USB_STORAGE_NAME`: Base name for USB-OTG devices (default: `USB-OTG`).

### Storage Detection
- `ENABLE_INTERNAL_STORAGE`: `true` to mount internal storage.
- `ENABLE_EXTERNAL_STORAGE`: `true` to detect and mount SD cards/USB.
- `INTERNAL_STORAGE_PATH`: Path to internal storage on the device.
- `EXTERNAL_STORAGE_PATTERNS`: Space-separated patterns to find external storage (e.g., `storage/sdcard1 storage/*[0-9A-F]`).
- `MAX_EXTERNAL_STORAGE`: Maximum number of external drives to mount.
- `STORAGE_TIMEOUT`: How long to wait for storage to appear after connection (seconds).

### Logging & Cleanup
- `LOG_LEVEL`: `DEBUG`, `INFO`, `WARN`, `ERROR`.
- `MAX_LOG_SIZE`: Max log file size in MB before rotation.
- `LOG_ROTATE_COUNT`: How many old log files to keep.
- `AUTO_CLEANUP`: `true` to automatically remove broken symlinks from previous sessions.

## Management Commands

```bash
# Check service status
systemctl --user status gsconnect-mount-manager

# View live logs
journalctl --user -u gsconnect-mount-manager -f

# Stop/start the service
systemctl --user stop gsconnect-mount-manager
systemctl --user start gsconnect-mount-manager
```

## Uninstallation

The provided `uninstall.sh` script will stop the service, remove all installed files, and clean up bookmarks.

```bash
cd gsconnect-mount-manager
chmod +x uninstall.sh
./uninstall.sh
```

## Troubleshooting

**Device not detected:**
- Ensure GSConnect is installed and device is paired
- Check if file sharing is enabled on your phone
- Verify the device appears in GSConnect settings

**Bookmark not working:**
- Check if `~/.gsconnect-mount/Device-Name/` directory exists
- Verify symlinks are not broken: `ls -la ~/.gsconnect-mount/*/`

**Service issues:**
- Check logs: `journalctl --user -u gsconnect-mount-manager -n 20`
- Restart service: `systemctl --user restart gsconnect-mount-manager`

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly before committing
5. Submit a pull request

## License

This project is licensed under the MIT License - see the LICENSE file for details.
