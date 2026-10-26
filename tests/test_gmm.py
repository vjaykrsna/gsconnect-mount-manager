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


if __name__ == "__main__":
    unittest.main()
