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
- **Lightweight & Efficient:** Runs as a minimal background service with negligible resource usage.
- **Safe & Non-Intrusive:** Does not modify any GSConnect files, ensuring stability and compatibility with future GSConnect updates.

## How It Works

The script runs as a systemd user service, continuously monitoring for a GSConnect SFTP mount in the background.

- **On Mount:** When a device connects, the script automatically creates a bookmark in Nautilus and a symlink in your home directory for easy access.
- **On Unmount:** When the device disconnects, the script cleans up by removing the previously created bookmark and symlink.

This ensures that your phone's storage is always ready when connected and that no stale links are left behind when it's not.

## Requirements

- A working GSConnect installation on your GNOME desktop.

## Installation

Run the following commands in your terminal:
```bash
git clone https://github.com/fjueic/gsconnect-mount-manager.git
cd gsconnect-mount-manager
chmod +x install.sh
./install.sh
```
The script will be installed as a systemd user service and will start automatically.

**Note:** Do NOT run the installer with `sudo` or as the root user.

## Uninstallation

To completely remove the service and all related files, run the following commands. You may be prompted for your password to remove the systemd service file.
```bash
systemctl --user stop gsconnect-mount-manager.service
systemctl --user disable gsconnect-mount-manager.service
sudo rm /etc/systemd/user/gsconnect-mount-manager.service
rm -rf ~/.config/gsconnect-mount-manager
# Optional: Remove the symlink, replacing 'Your_Device_Name' with the actual name
# rm ~/Your_Device_Name
```

## Tested On

- Arch Linux (Gnome)
- Manjaro
- Garuda Linux
- Pop!_OS
- Fedora
- Ubuntu
