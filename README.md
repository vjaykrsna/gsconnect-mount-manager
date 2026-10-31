# GMM — GSConnect / KDE Connect Mount Manager

GSConnect or KDE Connect can mount an Android phone at `/`, even when that location is inaccessible. GMM finds the usable storage inside an existing mount and gives you a direct way to open it.

GMM **never requests a mount or unmount**. Use GSConnect or KDE Connect to mount your phone first. GMM cannot fix a failed SFTP connection or grant Android storage permissions.

## What you get

For a phone with one storage location, a sidebar entry named after the phone opens storage directly. A phone with multiple locations gets entries such as **Phone / Internal** and **Phone / SD card**. Names get a short identifier only when needed to distinguish devices.

Terminal links are created directly inside `~/Devices`:

```text
# One storage location
~/Devices/Phone -> accessible storage

# Multiple storage locations
~/Devices/Phone_Internal -> internal storage
~/Devices/Phone_SD_card  -> SD card
```

GMM updates its entries when storage changes and removes them when the mount disappears. An existing local item that conflicts with a link is backed up before replacement. GMM never deletes the contents of that item to make room for a link.

The file manager's native network mount may remain visible alongside GMM's entry. GMM does not hide or modify that native entry.

## Supported environment

- Linux desktop with a paired phone and a working GSConnect or KDE Connect mount.
- Python 3.11+ and PyGObject with GIO/GLib bindings.
- A GTK file manager for sidebar bookmarks. **Dolphin Places integration is not implemented.** KDE Connect backend support does not imply Dolphin bookmark support.
- GVfs with its SFTP backend for GSConnect; KDE Connect uses its existing SSHFS mount.
- A systemd user session for automatic service startup, or run `gmm daemon` yourself.

GSConnect entries use the existing SFTP URI. KDE Connect entries use paths inside its existing local SSHFS mount; they do not open a new SFTP connection. Terminal links use the local mount path. A direct sidebar entry avoids routing file manager browsing through GMM's symlink, but does not guarantee faster transfers or navigation.

GMM observes existing mounts and periodically checks for changes to recover from missed events. It does not continually request mounts.

## Install and update

Run as your regular user:

```bash
curl -fsSL https://raw.githubusercontent.com/vjaykrsna/gsconnect-mount-manager/main/install.sh | bash
```

Or clone this repository and run `bash install.sh`. The installer checks dependencies, installs `~/.local/bin/gmm` and starts `gmm.service` in your user session. Add `~/.local/bin` to your shell's PATH if needed.

To update later:

```bash
gmm update
```

Update runs the same installer. It downloads from the repository's `main` branch.

## Commands

```bash
gmm status       # Current phone storage and GMM entries
gmm doctor       # Diagnose why storage access is unavailable
gmm --version
gmm update
gmm uninstall
```

The background service runs `gmm daemon`. Service controls remain available through systemd:

```bash
systemctl --user restart gmm
systemctl --user status gmm --no-pager
journalctl --user -u gmm -n 100 --no-pager
```

Uninstall removes GMM's service, executable and tracked entries. It leaves the native phone mount alone. Configuration is retained unless you choose `gmm uninstall --purge`.

## Advanced settings

Edit `~/.config/gmm/config.toml`, then restart the service. Defaults work without editing:

```toml
version = 3

[general]
mount_structure_dir = "~/Devices"
notifications = true

[storage]
# Optional paths relative to the existing mount, with display labels.
custom_paths = []
# Example: custom_paths = ["/storage/custom:Shared"]

[logging]
level = "INFO"
```

Notifications can be disabled with `notifications = false`. GMM reports storage becoming available or disappearing, and a useful failure message when a matched mount has no accessible storage. Diagnostics remain available when notifications are disabled.

GMM respects `XDG_CONFIG_HOME` and `XDG_BIN_HOME` for its configuration and installed executable.

## Upgrading from GMM 1.x or 2.x

**3.0 is a breaking change.** On the first upgrade, the old configuration is saved with a dated backup and replaced with the new defaults. This resets custom paths, notification preferences, bookmark modes and other old settings. The installer reports the backup; reapply supported preferences using the configuration above. Later updates within the new configuration format preserve your settings.

The new defaults create direct sidebar entries and flat terminal links, enable notifications, and never request mounts. Old GMM-owned entries are migrated only when their ownership can be established. Untracked files and bookmarks are left alone.

The `list`, `mount`, `unmount`, `clean` and `config` commands have been removed. Use `status` for an overview, GSConnect/KDE Connect for mounting, and edit the config file for settings. Cleanup happens as part of storage reconciliation and uninstall.

## Troubleshooting

Start with `gmm doctor`. The important distinction is whether the phone has no native mount, has a mount but no accessible storage path, or has accessible storage but no GMM entry.

If there is no native mount, check GSConnect/KDE Connect and the Android app's filesystem access permissions. If the mount exists but opening its root fails, GMM should provide access to a readable storage location. If it cannot identify one, it reports that failure instead of creating an entry to a known unusable location.

For a bug report, use the repository's [bug report template](.github/ISSUE_TEMPLATE/bug_report.md). Logs may include details about your device or computer, so check them before posting and remove anything you’d rather keep private.

## Development

```bash
python3 -m unittest discover -s tests
bash -n install.sh
```

Tests cover logic and failure handling. They do not replace testing the native mount and actual file manager on each supported desktop. See [storage research](GMM-STORAGE-RESEARCH.md) for the evidence and limitations behind this design.
