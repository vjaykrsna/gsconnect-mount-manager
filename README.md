# GMM (GSConnect Mount Manager)

Automatically organizes and provides seamless access to your Android device storage via GSConnect. Creates clean bookmarks and symlinks for smooth file browsing.

![error](./error.png)

---

## Features

* **🔄 Auto Mount/Unmount** – Detects device connections and handles setup/cleanup automatically.
* **📁 Clean Organization** – Creates `~/Device-Name/` with organized storage folders and symlinks.
* **🔖 File Manager Integration** – Creates direct SFTP bookmarks for each detected storage (Internal, External, USB-OTG) and local symlinks for easy access.
* **💻 Terminal Access** – Direct symlinks to internal storage, SD cards, and USB OTG.
* **📱 Multi-Storage Support** – Handles internal storage, SD cards, and USB OTG devices.
* **⚙️ Configurable** – Customize via config file (polling, paths, etc.).
* **🛡️ Safe & Reliable** – No GSConnect modifications; automatic error recovery.

---

## Directory Layout

```
~/Device-Name/
  ├── Internal/       # Internal storage
  ├── SDCard/         # SD card (if present)
  └── USB-OTG/        # USB OTG device (if present)
```

**File Manager Experience:**

* Click “Device-Name” bookmark → opens device folder.
* Browse `Internal/`, `SDCard/`, `USB-OTG/` as needed.

**Terminal Access:**

```bash
cd ~/.Device-Name/
```

---

## Installation

```bash
git clone https://github.com/vjaykrsna/gsconnect-mount-manager.git
cd gsconnect-mount-manager
chmod +x install.sh
./install.sh
```

> **Note:** Do NOT run as `sudo` or root; install is per-user.

---


## Requirements

* **GSConnect** (GNOME Shell extension for KDE Connect)
* **GNOME/GTK environment** (for bookmarks)
* **systemd** (user service management)
* **Android device** with KDE Connect app installed

### Dependencies (common packages)

On most Linux distributions you should have these tools available; if not, install them from your package manager:

* gdbus (part of glib)
* gvfs / gio (GVFS backends for SFTP access)
* systemd (user services) and journalctl
* grep, sed, realpath, readlink

Example (Debian/Ubuntu):

```bash
sudo apt install git dbus-user-session libglib2.0-bin gvfs-bin coreutils grep sed
```

Note: package names vary by distro (Fedora/Arch/Manjaro use different package names). Ensure `gdbus` and `gvfs` are installed so device discovery and mounts work reliably.

---

## Configuration

Edit `~/.config/gmm/gmm.conf` and restart the service:

```bash
systemctl --user restart gmm.service
```

### Essential Settings

* `POLL_INTERVAL` – Check interval for device connections (seconds). Default: 3
* `MOUNT_STRUCTURE_DIR` – Where device folders are created. Default: `$HOME`
* `LOG_LEVEL` – Logging verbosity: `DEBUG`, `INFO`, `WARN`, `ERROR`. Default: `INFO`

### Storage Paths

*   `INTERNAL_STORAGE_PATHS` – Comma-separated list of internal storage paths on your Android device (e.g., `/storage/emulated/0`). Default: `/storage/emulated/0`
*   `EXTERNAL_STORAGE_PATHS` – Comma-separated list of external storage (SD card) paths. Default: (empty)
*   `USB_STORAGE_PATHS` – Comma-separated list of USB OTG storage paths. Default: (empty)

### Bookmark Settings

*   `ENABLE_BOOKMARKS` – Enable/disable GTK bookmarks. Default: `true`

---

## Management Commands

```bash
systemctl --user status gmm
journalctl --user -u gmm -f
systemctl --user stop gmm
systemctl --user start gmm
```

---

## Uninstallation

```bash
chmod +x uninstall.sh
./uninstall.sh
```

Stops the service, removes files, and cleans bookmarks.

---

## Troubleshooting

* **Device not detected:** Check GSConnect is installed and paired; enable file sharing.
*   **Bookmarks missing or incorrect:** Check `~/.config/gtk-3.0/bookmarks` directly. Ensure the `gmm.service` is running and your device is connected.
*   **Service issues:** Check logs with `journalctl --user -u gmm -n 20` and try restarting the service.
*   **Storage not detected:** Verify your `INTERNAL_STORAGE_PATHS`, `EXTERNAL_STORAGE_PATHS`, and `USB_STORAGE_PATHS` in `~/.config/gmm/gmm.conf` are correct and the paths exist on your device.

---

## Debugging

If you encounter issues, use the `debug.sh` script to collect comprehensive system and application information.

```bash
# If you have the repository cloned:
./debug.sh

# Or, download and run directly:
curl -fsSL https://raw.githubusercontent.com/vjaykrsna/gsconnect-mount-manager/main/debug.sh -o debug.sh
chmod +x debug.sh
./debug.sh
```

The script will:
*   Collect system information, GSConnect/KDE Connect status, and GMM configuration.
*   Temporarily enable `DEBUG` logging to capture detailed runtime logs.
*   Upload the collected `gmm-debug.log` to a paste service and provide a shareable link.
*   Restore your original GMM configuration.

**Always share the link provided by `debug.sh` when reporting issues.**

---

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make changes and test thoroughly
4. Submit a pull request

---

## License

MIT License – see LICENSE file.

---
