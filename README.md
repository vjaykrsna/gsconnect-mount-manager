# GMM (GSConnect / KDE Connect Mount Manager)

<p align="left">
  <a href="https://www.kernel.org"><img src="https://img.shields.io/badge/platform-Linux-blue.svg" alt="Platform"></a>
  <a href="https://www.python.org"><img src="https://img.shields.io/badge/python-3.11+-brightgreen.svg" alt="Python"></a>
  <a href="#"><img src="https://img.shields.io/badge/desktop-GNOME%20%7C%20KDE%20%7C%20XFCE-orange.svg" alt="Desktop Environments"></a>
  <a href="#"><img src="https://img.shields.io/badge/idle%20CPU-0%25%20(event--driven)-success.svg" alt="Zero Polling"></a>
</p>

Seamless, zero-polling Android storage integration for Linux desktops. Automatically maps internal storage and SD cards into clean local folders and bookmarks when connecting via **GSConnect** or **KDE Connect**.

---

## 🎯 The Problem & The Fix

When opening an Android device via GSConnect or KDE Connect, file managers default to the unreadable SFTP root (`/`), triggering permission errors:

<p align="center">
  <img src="./error.png" alt="Nautilus SFTP Error" width="480">
</p>

**GMM eliminates this completely.** It detects mounts in real-time and organizes accessible storage directly in your user directory and file manager sidebar:

```text
~/Devices/
└── Pixel_7_0123456789/
    ├── Internal -> /run/user/1000/gvfs/sftp:.../storage/emulated/0
    └── SDCard   -> /run/user/1000/gvfs/sftp:.../storage/3C82-16F4
```

* **File Manager:** Click `Pixel_7` in the sidebar to browse storage directly.
* **Terminal & CLI:** Access storage seamlessly via `cd ~/Devices/Pixel_7_0123456789/Internal`.

---

## ⚡ Quick Install

Run this in your terminal (no git clone required):

```bash
curl -fsSL https://raw.githubusercontent.com/vjaykrsna/gsconnect-mount-manager/main/install.sh | bash
```

> **Note:** Run as your regular user (do **not** use `sudo`). Installs `gmm` to `~/.local/bin/gmm` and enables the user systemd service. To update later, run `gmm update`; it uses the same installer and preserves your configuration.

<details>
<summary><b>Or install via Git clone</b></summary>

```bash
git clone https://github.com/vjaykrsna/gsconnect-mount-manager.git
cd gsconnect-mount-manager
chmod +x install.sh
./install.sh
```
</details>

---

## ✨ Features

* **⚡ Zero Polling (0% CPU at idle)** – Pure event-driven daemon using `Gio.VolumeMonitor`. No background loops, no battery drain.
* **📱 Multi-Device Support** – Simultaneously tracks multiple phones and tablets without state collision.
* **💾 Smart Storage Auto-Discovery** – Automatically discovers Internal Storage (`/storage/emulated/0`) and MicroSD/USB-OTG drives (detecting volume UUIDs like `3C82-16F4`) out of the box.
* **🔖 IP-Immune Bookmarks** – Creates local directory bookmarks that stay working even when your phone changes Wi-Fi IP addresses.
* **🛡️ Safer Cleanup** – Tracks its own links and bookmark entries. Bookmark writes use atomic replacement and a lock shared by GMM processes; concurrent edits by other applications may still conflict.

---

## 💻 CLI Usage

GMM includes a standalone management CLI:

```bash
gmm status            # View connected devices, active mounts, and bookmarks
gmm list              # List all paired GSConnect / KDE Connect devices
gmm mount             # Mount all online devices (or: gmm mount "Pixel 7")
gmm unmount           # Unmount all devices & clean up (or: gmm unmount "Pixel 7")
gmm clean             # Clean up stale symlinks and dead bookmarks
gmm config            # Inspect active settings (or: gmm config --init)
gmm doctor            # Check system health & dependencies
gmm doctor --export   # Generate Markdown diagnostics (review for private data)
gmm update            # Rerun the installer for the latest version from GitHub
gmm uninstall         # Remove GMM and its background service
```

---

<details>
<summary><b>⚙️ Configuration (<code>~/.config/gmm/config.toml</code>)</b></summary>

<br>

Settings are stored in `~/.config/gmm/config.toml`:

```toml
[general]
# Base directory where device folders are organized
mount_structure_dir = "~/Devices"

# Bookmark mode: "both", "sftp_only", "local_only", "none"
bookmark_mode = "both"

# Desktop notifications on mount/unmount
notifications = true

# Automatically mount when device connects to Wi-Fi
auto_mount = true

# Clean up empty device folders on disconnect
auto_cleanup = true

[storage]
# Automatically discover Internal and SD Card UUID partitions
auto_discover = true

# Exclude internal Android pseudo-directories
exclude_directories = ["self", "knox", "legacy", "sdcard"]

# Optional custom storage paths: ["/path:Label"]
custom_paths = []

[logging]
level = "INFO"
```

To apply changes: `systemctl --user restart gmm`

GMM manages an SFTP mount only when its host matches exactly one connected,
paired device. For GSConnect, it can read the device's last LAN connection from
GSConnect settings. If the address is unavailable or the match is ambiguous,
the mount is skipped. Device folder names include a stable ID suffix to avoid
collisions. Links and bookmarks created by older versions without ownership
records are preserved and may need to be removed manually.
</details>

---

<details>
<summary><b>❓ Troubleshooting & FAQ</b></summary>

<br>

* **Device paired, but storage doesn't appear?**  
  Open KDE Connect on your phone $\rightarrow$ tap your computer $\rightarrow$ **Plugin Settings** $\rightarrow$ enable **Filesystem expose** (Storage access).
* **Firewall issues?**  
  Ensure ports **1716–1764 (TCP & UDP)** are allowed in your firewall (`sudo ufw allow 1716:1764/udp && sudo ufw allow 1716:1764/tcp`).
* **Changing the mount folder:**  
  Change `mount_structure_dir = "~/PhoneStorage"` in `~/.config/gmm/config.toml`, then restart: `systemctl --user restart gmm`.
* **Diagnostics:**  
  Run `gmm --version`, `gmm doctor`, and `gmm status`. For service logs, run
  `journalctl --user -u gmm -n 50 --no-pager`. Review the output for private
  information before sharing it.
</details>

---

<details>
<summary><b>🧪 Testing & Development</b></summary>

<br>

Run the unit test suite:
```bash
python3 tests/test_gmm.py
```
</details>
