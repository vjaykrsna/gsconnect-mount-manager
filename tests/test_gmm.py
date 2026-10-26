#!/usr/bin/env python3
"""Comprehensive unit tests for GMM 2.0."""

import os
import shutil
import tempfile
import unittest
from pathlib import Path

# Add project root to sys.path
import sys
import importlib.util
from importlib.machinery import SourceFileLoader

ROOT_DIR = Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(ROOT_DIR))

# Dynamically import the extensionless `gmm` script
gmm_path = ROOT_DIR / "gmm"
loader = SourceFileLoader("gmm", str(gmm_path))
spec = importlib.util.spec_from_loader("gmm", loader)
if spec is None:
    raise ImportError("Could not create module spec for gmm")
gmm = importlib.util.module_from_spec(spec)
sys.modules["gmm"] = gmm
loader.exec_module(gmm)


class TestNameSanitizer(unittest.TestCase):
    """Test device name sanitization and path safety checks."""

    def test_normal_names(self):
        self.assertEqual(gmm.sanitize_device_name("Pixel 7"), "Pixel_7")
        self.assertEqual(gmm.sanitize_device_name("Galaxy-S21"), "Galaxy-S21")
        self.assertEqual(gmm.sanitize_device_name("iPad.Mini"), "iPad.Mini")

    def test_unsafe_and_special_characters(self):
        # Traversal and forbidden chars
        self.assertEqual(gmm.sanitize_device_name("../../../etc/passwd"), "etc_passwd")
        self.assertEqual(gmm.sanitize_device_name("Phone /with/ slashes"), "Phone_with_slashes")
        self.assertEqual(gmm.sanitize_device_name("Phone:Special?*<>|Chars"), "Phone_Special_Chars")

    def test_empty_and_whitespace(self):
        self.assertEqual(gmm.sanitize_device_name(""), "Unknown_Device")
        self.assertEqual(gmm.sanitize_device_name("    "), "Unknown_Device")
        self.assertEqual(gmm.sanitize_device_name("..."), "Unknown_Device")

    def test_truncation(self):
        long_name = "A" * 100
        sanitized = gmm.sanitize_device_name(long_name)
        self.assertLessEqual(len(sanitized), 64)

    def test_path_safety(self):
        base = Path("/home/user/Devices")
        safe_child = Path("/home/user/Devices/Pixel_7")
        unsafe_child = Path("/home/user/Pixel_7")
        unsafe_traversal = Path("/home/user/Devices/../../etc")

        self.assertTrue(gmm.is_safe_subpath(safe_child, base))
        self.assertFalse(gmm.is_safe_subpath(unsafe_child, base))
        self.assertFalse(gmm.is_safe_subpath(unsafe_traversal, base))


class TestConfig(unittest.TestCase):
    """Test configuration loading and defaults."""

    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.cfg_file = Path(self.temp_dir) / "config.toml"

    def tearDown(self):
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_defaults(self):
        cfg = gmm.Config.load(config_path=Path(self.temp_dir) / "nonexistent.toml")
        self.assertEqual(cfg.bookmark_mode, "both")
        self.assertTrue(cfg.auto_mount)
        self.assertTrue(cfg.auto_cleanup)
        self.assertTrue(cfg.auto_discover)
        self.assertEqual(cfg.log_level, "INFO")

    def test_load_custom_toml(self):
        toml_content = """
        [general]
        mount_structure_dir = "/tmp/my_devices"
        bookmark_mode = "sftp_only"
        auto_mount = false
        notifications = false

        [storage]
        auto_discover = true
        exclude_directories = ["custom_ex"]
        custom_paths = ["/storage/custom:MyFolder"]

        [logging]
        level = "DEBUG"
        """
        self.cfg_file.write_text(toml_content, encoding="utf-8")
        cfg = gmm.Config.load(config_path=self.cfg_file)

        self.assertEqual(cfg.mount_structure_dir, Path("/tmp/my_devices"))
        self.assertEqual(cfg.bookmark_mode, "sftp_only")
        self.assertFalse(cfg.auto_mount)
        self.assertFalse(cfg.notifications)
        self.assertEqual(cfg.exclude_directories, ["custom_ex"])
        self.assertEqual(cfg.custom_paths, ["/storage/custom:MyFolder"])
        self.assertEqual(cfg.log_level, "DEBUG")


class TestStorageScanner(unittest.TestCase):
    """Test dynamic storage and SD Card UUID detection."""

    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.mount_root = Path(self.temp_dir) / "gvfs_mount"
        self.mount_root.mkdir(parents=True)
        self.config = gmm.Config()
        self.scanner = gmm.StorageScanner(self.config)

    def tearDown(self):
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_detect_internal_storage(self):
        internal = self.mount_root / "storage" / "emulated" / "0"
        internal.mkdir(parents=True)

        partitions = self.scanner.discover(self.mount_root)
        self.assertIn("Internal", partitions)
        self.assertEqual(partitions["Internal"], internal)

    def test_detect_sd_card_uuid(self):
        sd_card = self.mount_root / "storage" / "3C82-16F4"
        sd_card.mkdir(parents=True)

        partitions = self.scanner.discover(self.mount_root)
        self.assertIn("SDCard", partitions)
        self.assertEqual(partitions["SDCard"], sd_card)

    def test_detect_multiple_sd_cards(self):
        sd1 = self.mount_root / "storage" / "1234-ABCD"
        sd2 = self.mount_root / "storage" / "5678-EF01"
        sd1.mkdir(parents=True)
        sd2.mkdir(parents=True)

        partitions = self.scanner.discover(self.mount_root)
        self.assertIn("SDCard", partitions)
        self.assertIn("SDCard-2", partitions)

    def test_exclude_directories(self):
        excluded = self.mount_root / "storage" / "self"
        excluded.mkdir(parents=True)

        partitions = self.scanner.discover(self.mount_root)
        self.assertNotIn("self", partitions)

    def test_saf_root_fallback(self):
        # When Android SAF mounts directly expose folders like DCIM / Download at root
        (self.mount_root / "DCIM").mkdir()
        (self.mount_root / "Download").mkdir()

        partitions = self.scanner.discover(self.mount_root)
        self.assertIn("Internal", partitions)
        self.assertEqual(partitions["Internal"], self.mount_root)

    def test_custom_paths_traversal_prevention(self):
        cfg = gmm.Config(custom_paths=["../../etc:System"])
        scanner = gmm.StorageScanner(cfg)
        partitions = scanner.discover(self.mount_root)
        self.assertNotIn("System", partitions)

    def test_saf_subdirectory_discovery(self):
        internal_sub = self.mount_root / "Internal storage"
        sd_sub = self.mount_root / "SD card"
        internal_sub.mkdir()
        sd_sub.mkdir()

        partitions = self.scanner.discover(self.mount_root)
        self.assertIn("Internal", partitions)
        self.assertEqual(partitions["Internal"], internal_sub)
        self.assertIn("SDCard", partitions)
        self.assertEqual(partitions["SDCard"], sd_sub)

    def test_generic_storage_fallback(self):
        # A custom exposed directory with files (e.g. Music share)
        (self.mount_root / "song.mp3").write_text("audio")
        partitions = self.scanner.discover(self.mount_root)
        self.assertIn("Storage", partitions)
        self.assertEqual(partitions["Storage"], self.mount_root)


class TestBookmarkManager(unittest.TestCase):
    """Test GTK bookmark modifications and file safety."""

    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.bm_file = Path(self.temp_dir) / "bookmarks"
        self.manager = gmm.BookmarkManager(self.bm_file)

    def tearDown(self):
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_add_and_remove_bookmarks(self):
        # Initial bookmarks
        self.bm_file.write_text("file:///home/user/Downloads Downloads\n", encoding="utf-8")

        partitions = {
            "Internal": Path("/run/user/1000/gvfs/sftp:host=1.2.3.4,port=1739/storage/emulated/0"),
            "SDCard": Path("/run/user/1000/gvfs/sftp:host=1.2.3.4,port=1739/storage/3C82-16F4"),
        }
        local_dir = Path("/home/user/Devices/Pixel_7")

        # 1. Update in "both" mode
        success = self.manager.update_device_bookmarks(
            sanitized_name="Pixel_7",
            partitions=partitions,
            sftp_base_uri="sftp://1.2.3.4:1739/",
            local_device_dir=local_dir,
            bookmark_mode="both",
        )
        self.assertTrue(success)

        content = self.bm_file.read_text(encoding="utf-8")
        self.assertIn("Downloads Downloads", content)
        self.assertIn("file:///home/user/Devices/Pixel_7 Pixel_7", content)
        self.assertIn("sftp://1.2.3.4:1739/storage/emulated/0 Pixel_7/Internal", content)
        self.assertIn("sftp://1.2.3.4:1739/storage/3C82-16F4 Pixel_7/SDCard", content)

        # 2. Remove bookmarks
        self.manager.remove_device_bookmarks("Pixel_7")
        content_after = self.bm_file.read_text(encoding="utf-8")
        self.assertIn("Downloads Downloads", content_after)
        self.assertNotIn("Pixel_7", content_after)

    def test_clean_bookmarks_with_url_encoding(self):
        devices_dir = Path(self.temp_dir) / "Devices"
        devices_dir.mkdir(parents=True)
        valid_phone = devices_dir / "My Phone"
        valid_phone.mkdir(parents=True)

        # Write bookmarks: one valid with spaces, one dead with spaces, one outside devices
        dead_uri = (devices_dir / "Dead Phone").as_uri()
        valid_uri = valid_phone.as_uri()
        outside_uri = "file:///home/user/Documents Documents"

        self.bm_file.write_text(
            f"{outside_uri}\n{dead_uri} Dead Phone\n{valid_uri} My Phone\n",
            encoding="utf-8",
        )

        removed = self.manager.clean_bookmarks(devices_dir)
        self.assertEqual(removed, 1)

        content = self.bm_file.read_text(encoding="utf-8")
        self.assertIn(outside_uri, content)
        self.assertIn("My Phone", content)
        self.assertNotIn("Dead Phone", content)

    def test_saf_root_bookmark_uri_generation(self):
        mount_root = Path(self.temp_dir) / "gvfs_mount"
        mount_root.mkdir(parents=True, exist_ok=True)
        partitions = {"Internal": mount_root}
        local_dir = Path("/home/user/Devices/Pixel_7")

        success = self.manager.update_device_bookmarks(
            sanitized_name="Pixel_7",
            partitions=partitions,
            sftp_base_uri="sftp://192.168.1.50:1739/",
            local_device_dir=local_dir,
            bookmark_mode="sftp_only",
            mount_path=mount_root,
        )
        self.assertTrue(success)
        content = self.bm_file.read_text(encoding="utf-8")
        self.assertIn("sftp://192.168.1.50:1739 Pixel_7/Internal", content)
        self.assertNotIn("storage/gvfs_mount", content)

    def test_clean_bookmarks_prefix_protection(self):
        devices_dir = Path(self.temp_dir) / "Devices"
        devices_dir.mkdir(parents=True, exist_ok=True)

        # Sibling directory starting with the same prefix
        archive_uri = "file:///tmp/Devices_Archive Devices_Archive"
        dead_device_uri = (devices_dir / "Dead_Phone").as_uri() + " Dead_Phone"

        self.bm_file.write_text(f"{archive_uri}\n{dead_device_uri}\n", encoding="utf-8")
        removed = self.manager.clean_bookmarks(devices_dir)
        self.assertEqual(removed, 1)

        content = self.bm_file.read_text(encoding="utf-8")
        self.assertIn(archive_uri, content)
        self.assertNotIn("Dead_Phone", content)

    def test_device_bookmark_label_exact_match(self):
        user_bookmark = "file:///home/user/Work My Pixel_7"
        device_bookmark = "file:///home/user/Devices/Pixel_7 Pixel_7"
        self.bm_file.write_text(f"{user_bookmark}\n{device_bookmark}\n", encoding="utf-8")

        self.manager.remove_device_bookmarks("Pixel_7")
        content = self.bm_file.read_text(encoding="utf-8")
        self.assertIn(user_bookmark, content)
        self.assertNotIn(device_bookmark, content)


class TestDeviceController(unittest.TestCase):
    """Test symlink creation and cleanup."""

    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.base_dir = Path(self.temp_dir) / "Devices"
        self.base_dir.mkdir(parents=True)
        self.config = gmm.Config(mount_structure_dir=self.base_dir)
        self.controller = gmm.DeviceController(self.config)

    def tearDown(self):
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_setup_and_teardown(self):
        # Create dummy target directories
        target_internal = Path(self.temp_dir) / "gvfs_internal"
        target_internal.mkdir(parents=True)

        partitions = {"Internal": target_internal}
        uri = "sftp://192.168.1.50:1739/"

        # Setup
        active = self.controller.setup_device(
            uri=uri,
            display_name="Pixel 7",
            mount_path=Path(self.temp_dir),
            partitions=partitions,
        )
        self.assertIsNotNone(active)
        device_dir = self.base_dir / "Pixel_7"
        self.assertTrue(device_dir.exists())
        symlink = device_dir / "Internal"
        self.assertTrue(symlink.is_symlink())
        self.assertEqual(symlink.resolve(), target_internal.resolve())

        # Teardown
        removed = self.controller.teardown_device(uri)
        self.assertEqual(removed, active)
        self.assertFalse(symlink.exists())
        self.assertFalse(device_dir.exists())
        # Stray base directory is also cleaned up when empty
        self.assertFalse(self.base_dir.exists())


class TestCLICommands(unittest.TestCase):
    """Test CLI commands and diagnostic reporting."""

    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.config = gmm.Config(
            mount_structure_dir=Path(self.temp_dir) / "Devices",
            bookmark_file=Path(self.temp_dir) / "bookmarks",
        )
        self.cli = gmm.CLI(self.config)
        # Mock D-Bus so unit tests never touch real devices or system mounts
        self.cli.dbus.get_all_devices = lambda: []
        self.cli.dbus.is_available = lambda: True
        self.cli._mount_device = lambda dev: True
        self.cli._unmount_device = lambda dev: None

    def tearDown(self):
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_doctor_export_mode(self):
        import io
        from contextlib import redirect_stdout

        f = io.StringIO()
        with redirect_stdout(f):
            ret = self.cli.cmd_doctor(export=True)

        self.assertEqual(ret, 0)
        output = f.getvalue()
        self.assertIn("GMM System Diagnostics", output)
        self.assertIn("Python Version", output)
        self.assertIn("```text", output)

    def test_clean_command(self):
        ret = self.cli.cmd_clean()
        self.assertEqual(ret, 0)

    def test_mount_unmount_no_args(self):
        ret_mount = self.cli.cmd_mount()
        self.assertEqual(ret_mount, 0)
        ret_unmount = self.cli.cmd_unmount()
        self.assertEqual(ret_unmount, 0)

    def test_device_matching_by_sanitized_name(self):
        sample_dev = gmm.DeviceInfo(
            id="dev123",
            name="My Pixel 7",
            is_reachable=True,
            is_mounted=False,
            backend="kdeconnect",
        )
        self.cli.dbus.get_all_devices = lambda: [sample_dev]

        # Exact match
        self.assertEqual(self.cli.dbus.find_device_by_name_or_id("My Pixel 7"), sample_dev)
        # Case insensitive
        self.assertEqual(self.cli.dbus.find_device_by_name_or_id("my pixel 7"), sample_dev)
        # Sanitized name with underscores
        self.assertEqual(self.cli.dbus.find_device_by_name_or_id("My_Pixel_7"), sample_dev)
        # By ID
        self.assertEqual(self.cli.dbus.find_device_by_name_or_id("dev123"), sample_dev)
        # Nonexistent
        self.assertIsNone(self.cli.dbus.find_device_by_name_or_id("iPhone"))

    def test_device_matching_empty_query(self):
        sample_dev = gmm.DeviceInfo(
            id="dev123",
            name="My Pixel 7",
            is_reachable=True,
            is_mounted=False,
            backend="kdeconnect",
        )
        self.cli.dbus.get_all_devices = lambda: [sample_dev]

        # Empty or whitespace query should NOT match the first device
        self.assertIsNone(self.cli.dbus.find_device_by_name_or_id(""))
        self.assertIsNone(self.cli.dbus.find_device_by_name_or_id("   "))

    def test_config_command(self):
        import io
        from contextlib import redirect_stdout

        f = io.StringIO()
        with redirect_stdout(f):
            ret = self.cli.cmd_config()
        self.assertEqual(ret, 0)
        out = f.getvalue()
        self.assertIn("GMM Configuration", out)
        self.assertIn("mount_structure_dir", out)

        # Show path
        f_path = io.StringIO()
        with redirect_stdout(f_path):
            ret_path = self.cli.cmd_config(show_path=True)
        self.assertEqual(ret_path, 0)
        self.assertIn("config.toml", f_path.getvalue())

    def test_unmount_offline_device_directory_cleanup(self):
        # Create a managed device directory
        dev_dir = self.config.mount_structure_dir / "Pixel_7"
        dev_dir.mkdir(parents=True, exist_ok=True)
        dummy_link = dev_dir / "Internal"
        dummy_link.symlink_to(self.temp_dir)

        # Device is not on D-Bus
        self.cli.dbus.get_all_devices = lambda: []

        ret = self.cli.cmd_unmount("Pixel 7")
        self.assertEqual(ret, 0)
        self.assertFalse(dummy_link.exists())
        self.assertFalse(dev_dir.exists())

    def test_status_with_custom_mount_structure_dir(self):
        custom_base = Path(self.temp_dir) / "PhoneStorage"
        custom_base.mkdir(parents=True, exist_ok=True)
        cfg = gmm.Config(
            mount_structure_dir=custom_base,
            bookmark_file=Path(self.temp_dir) / "bookmarks",
        )
        cli = gmm.CLI(cfg)

        # Write bookmark matching custom base directory
        cfg.bookmark_file.write_text(
            f"file://{custom_base}/Pixel_7 Pixel_7\n", encoding="utf-8"
        )

        import io
        from contextlib import redirect_stdout

        f = io.StringIO()
        with redirect_stdout(f):
            ret = cli.cmd_status()
        self.assertEqual(ret, 0)
        out = f.getvalue()
        self.assertIn("file://", out)
        self.assertIn("Pixel_7", out)


if __name__ == "__main__":
    unittest.main()
