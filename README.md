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

The script installs as a systemd user service and starts automatically with these defaults:
- **📁 Single Bookmark**: One bookmark per device showing all storage as subfolders
- **🔗 Smart Symlinks**: Separate symlinks for internal storage and each SD card
- **🔔 Notifications**: Desktop notifications when devices mount/unmount
- **📊 Logging**: INFO level with automatic log rotation
- **⚡ Polling**: Checks for device changes every 5 seconds

**Note:** Do NOT run the installer with `sudo` or as the root user.

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

**Common Settings:**
```bash
# Change polling frequency (1-60 seconds)
POLL_INTERVAL=10

# Custom mount directory
MOUNT_STRUCTURE_DIR="$HOME/Devices"

# Custom naming
SYMLINK_PREFIX="Phone-"
EXTERNAL_STORAGE_NAME="SD-Card"

# Disable notifications
ENABLE_NOTIFICATIONS=false

# More verbose logging
LOG_LEVEL=DEBUG
```

After editing, restart the service:
```bash
systemctl --user restart gsconnect-mount-manager
```

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

```bash
systemctl --user stop gsconnect-mount-manager.service
systemctl --user disable gsconnect-mount-manager.service
rm ~/.config/systemd/user/gsconnect-mount-manager.service
rm -rf ~/.config/gsconnect-mount-manager
rm -rf ~/.gsconnect-mount
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
