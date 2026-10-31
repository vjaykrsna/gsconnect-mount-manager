#!/usr/bin/env python3
"""Storage access and ownership regressions; never touches a real device or session."""
import importlib.util
from importlib.machinery import SourceFileLoader
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace as NS
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
loader = SourceFileLoader('gmm', str(ROOT / 'gmm'))
spec = importlib.util.spec_from_loader(loader.name, loader)
gmm = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = gmm
loader.exec_module(gmm)


class IsolatedTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.home = self.root / 'home'
        self.home.mkdir()
        self.addCleanup(patch.stopall)
        patch.object(Path, 'home', return_value=self.home).start()
        patch.dict(os.environ, {'XDG_CONFIG_HOME': str(self.root / 'config'),
                                'XDG_STATE_HOME': str(self.root / 'state')}).start()
        self.config = gmm.Config(directory=self.home / 'Devices')


class FakeReader:
    def __init__(self, readable=(), directories=None):
        self.accessible = set(readable)
        self.listings = directories or {}
        self.calls = []

    def directories(self, uri):
        self.calls.append(('directories', uri))
        if uri not in self.listings:
            raise PermissionError(uri)
        return self.listings[uri]

    def readable(self, uri):
        self.calls.append(('readable', uri))
        if uri not in self.accessible:
            raise PermissionError(uri)
        return True


class StorageTests(IsolatedTest):
    def setUp(self):
        super().setUp()
        self.uri = 'sftp://192.0.2.1:1739/'
        self.mount = gmm.Mount('gsconnect:phone', 'Phone', self.root / 'mounted', self.uri)
        self.internal = self.uri + 'storage/emulated/0'

    def test_multiple_mounts_of_one_phone_and_nested_shortcut(self):
        base = self.internal
        camera = base + '/DCIM'
        other = self.uri + 'storage/1234-ABCD'
        mounts = [gmm.Mount('gsconnect:phone', 'Phone', self.root / 'a', base, {'Internal': ''}),
                  gmm.Mount('gsconnect:phone', 'Phone', self.root / 'b', other, {'SD card': ''}),
                  gmm.Mount('gsconnect:phone', 'Phone', self.root / 'c', camera, {'Camera': ''})]
        result = gmm.scan(self.config, mounts, FakeReader([base+'/', other+'/', camera+'/']))
        self.assertEqual({e['name'] for e in result['entries']}, {'Phone_Internal', 'Phone_SD_card'})
        self.assertEqual(len(result['devices']), 1)

    def test_inaccessible_root_does_not_block_known_child(self):
        reader = FakeReader([self.internal])
        result = gmm.scan(self.config, [self.mount], reader)
        self.assertEqual(len(result['entries']), 1)
        entry = result['entries'][0]
        self.assertEqual(entry['uri'], self.internal)
        self.assertEqual(entry['label'], 'Phone')
        self.assertEqual(entry['name'], 'Phone')
        self.assertEqual(entry['target'], str(self.mount.local / 'storage/emulated/0'))

    def test_empty_internal_storage_is_still_usable(self):
        reader = FakeReader([self.internal], {self.internal: []})
        self.assertEqual(gmm.storage_paths(self.mount, self.config, reader), {'Internal': 'storage/emulated/0'})

    def test_internal_and_sd_card_get_separate_direct_entries(self):
        card = self.uri + 'storage/1234-ABCD'
        reader = FakeReader([self.internal, card], {self.uri + 'storage': ['self', 'emulated', '1234-ABCD']})
        entries = gmm.scan(self.config, [self.mount], reader)['entries']
        self.assertEqual({e['name'] for e in entries}, {'Phone_Internal', 'Phone_SD_card'})
        self.assertEqual({e['label'] for e in entries}, {'Phone / Internal', 'Phone / SD card'})
        self.assertEqual({e['uri'] for e in entries}, {self.internal, card})

    def test_unusable_storage_produces_no_fallback_root_entry(self):
        reader = FakeReader([], {self.uri: ['storage', 'system', 'vendor']})
        snapshot = gmm.scan(self.config, [self.mount], reader)
        self.assertEqual(snapshot['entries'], [])
        self.assertFalse(snapshot['devices'][self.mount.device_id]['ready'])
        self.assertTrue(any('no usable storage' in note for note in snapshot['notes']))

    def test_already_exposed_storage_root_is_used(self):
        reader = FakeReader([], {self.uri: ['DCIM', 'Download']})
        result = gmm.scan(self.config, [self.mount], reader)
        self.assertEqual(result['entries'][0]['uri'], self.uri)
        self.assertEqual(result['entries'][0]['target'], str(self.mount.local))

    def test_remote_entry_can_work_without_local_fuse_projection(self):
        self.mount.local = None
        snapshot = gmm.scan(self.config, [self.mount], FakeReader([self.internal]))
        self.assertEqual(snapshot['entries'][0]['uri'], self.internal)
        self.assertIsNone(snapshot['entries'][0]['target'])
        self.assertTrue(any('terminal links' in note for note in snapshot['notes']))

    def test_configured_path_is_quoted_and_does_not_escape_mount(self):
        self.config.custom_paths = ['/storage/My files:Work']
        uri = self.uri + 'storage/My%20files'
        entries = gmm.scan(self.config, [self.mount], FakeReader([uri]))['entries']
        self.assertEqual(entries[0]['uri'], uri)
        self.assertEqual(entries[0]['target'], str(self.mount.local / 'storage/My files'))
        with self.assertRaises(ValueError):
            gmm.child_uri(self.uri, '../private')

    def test_duplicate_phone_names_get_distinct_stable_labels(self):
        other = gmm.Mount('gsconnect:second', 'Phone', self.root / 'second', 'sftp://192.0.2.2:1739/')
        reader = FakeReader([self.internal, other.uri + 'storage/emulated/0'])
        first = gmm.scan(self.config, [self.mount, other], reader)['entries']
        reverse = gmm.scan(self.config, [other, self.mount], reader)['entries']
        self.assertEqual(len({e['label'] for e in first}), 2)
        self.assertEqual({e['id']: e['label'] for e in first}, {e['id']: e['label'] for e in reverse})
        self.assertTrue(all(e['label'].startswith('Phone (') for e in first))

    def test_distinct_names_with_same_filesystem_spelling_do_not_clobber(self):
        self.mount.name = 'A/B'
        other = gmm.Mount('gsconnect:second', 'A B', self.root / 'second', 'sftp://192.0.2.2:1739/')
        entries = gmm.scan(self.config, [self.mount, other], FakeReader([self.internal, other.uri + 'storage/emulated/0']))['entries']
        self.assertEqual(len({e['name'] for e in entries}), 2)
        self.assertTrue(all('/' not in e['name'] for e in entries))

    def test_kde_camera_shortcut_does_not_count_as_second_storage(self):
        self.mount.paths = {'Internal': 'storage/emulated/0', 'Camera': 'storage/emulated/0/DCIM'}
        entries = gmm.scan(self.config, [self.mount], FakeReader([self.internal, self.internal + '/DCIM']))['entries']
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]['label'], 'Phone')


class ArtifactTests(IsolatedTest):
    def setUp(self):
        super().setUp()
        self.artifacts = gmm.Artifacts(self.root / 'owned', self.root / 'gtk/bookmarks')
        self.target = self.root / 'mounted/storage/emulated/0'
        self.target.mkdir(parents=True)
        self.entry = {'id': 'phone:internal', 'uri': 'sftp://192.0.2.1:1739/storage/emulated/0',
                      'label': 'Phone', 'name': 'Phone', 'target': str(self.target)}

    def contents(self):
        return self.artifacts.bookmarks.read_text().splitlines()

    def write_bookmarks(self, lines):
        self.artifacts.bookmarks.parent.mkdir(parents=True, exist_ok=True)
        self.artifacts.bookmarks.write_text('\n'.join(lines) + '\n')

    def test_repeated_reconciliation_is_idempotent_and_preserves_unrelated_bookmarks(self):
        user = ['file:///home/example/Documents Documents', 'sftp://192.0.2.9/home Work server']
        self.write_bookmarks(user)
        self.artifacts.reconcile(self.config, [self.entry])
        before = self.artifacts.path.read_bytes()
        self.artifacts.reconcile(self.config, [self.entry])
        self.assertEqual(self.artifacts.path.read_bytes(), before)
        self.assertEqual(self.contents(), user + [self.entry['uri'] + ' Phone'])
        self.assertEqual(os.readlink(self.config.directory / 'Phone'), str(self.target))
        self.artifacts.reconcile(self.config, [])
        self.assertEqual(self.contents(), user)
        self.assertFalse(os.path.lexists(self.config.directory / 'Phone'))

    def test_preexisting_identical_bookmark_is_not_claimed(self):
        line = self.entry['uri'] + ' Phone'
        self.write_bookmarks([line])
        self.artifacts.reconcile(self.config, [self.entry])
        self.artifacts.reconcile(self.config, [])
        self.assertEqual(self.contents(), [line])

    def test_restart_can_remove_old_entries_from_persisted_ownership(self):
        self.artifacts.reconcile(self.config, [self.entry])
        restarted = gmm.Artifacts(self.artifacts.directory, self.artifacts.bookmarks)
        restarted.reconcile(self.config, [])
        self.assertEqual(self.contents(), [])
        self.assertFalse(os.path.lexists(self.config.directory / 'Phone'))

    def test_single_to_multiple_to_single_removes_old_owned_paths(self):
        self.artifacts.reconcile(self.config, [self.entry])
        card = self.root / 'mounted/storage/1234-ABCD'
        card.mkdir()
        internal = {**self.entry, 'name': 'Phone_Internal', 'label': 'Phone / Internal'}
        sd = {**self.entry, 'id': 'phone:sd', 'name': 'Phone_SD_card', 'label': 'Phone / SD card',
              'target': str(card), 'uri': 'sftp://192.0.2.1:1739/storage/1234-ABCD'}
        self.artifacts.reconcile(self.config, [internal, sd])
        self.assertFalse(os.path.lexists(self.config.directory / 'Phone'))
        self.assertEqual({p.name for p in self.config.directory.iterdir()}, {'Phone_Internal', 'Phone_SD_card'})
        self.assertEqual(len(self.contents()), 2)
        self.artifacts.reconcile(self.config, [self.entry])
        self.assertEqual({p.name for p in self.config.directory.iterdir()}, {'Phone'})
        self.assertEqual(self.contents(), [self.entry['uri'] + ' Phone'])

    def test_conflicting_file_directory_and_broken_link_are_backed_up(self):
        for kind in ('file', 'directory', 'symlink'):
            with self.subTest(kind=kind):
                cfg = gmm.Config(directory=self.root / kind)
                cfg.directory.mkdir()
                conflict = cfg.directory / 'Phone'
                if kind == 'file':
                    conflict.write_text('user data')
                elif kind == 'directory':
                    conflict.mkdir()
                    (conflict / 'keep.txt').write_text('user data')
                else:
                    conflict.symlink_to(self.root / 'missing')
                self.artifacts.reconcile(cfg, [self.entry])
                backups = list(cfg.directory.glob('Phone.gmm-backup-*'))
                self.assertEqual(len(backups), 1)
                if kind == 'file':
                    self.assertEqual(backups[0].read_text(), 'user data')
                elif kind == 'directory':
                    self.assertEqual((backups[0] / 'keep.txt').read_text(), 'user data')
                else:
                    self.assertEqual(os.readlink(backups[0]), str(self.root / 'missing'))
                self.assertEqual(os.readlink(conflict), str(self.target))
                self.artifacts.reconcile(cfg, [])
                self.assertTrue(os.path.lexists(backups[0]))

    def test_user_modified_link_is_preserved_on_disconnect(self):
        self.artifacts.reconcile(self.config, [self.entry])
        link = self.config.directory / 'Phone'
        link.unlink()
        link.symlink_to(self.root / 'user-target')
        self.artifacts.reconcile(self.config, [])
        self.assertEqual(os.readlink(link), str(self.root / 'user-target'))

    def test_address_change_removes_only_old_owned_bookmark(self):
        self.artifacts.reconcile(self.config, [self.entry])
        updated = {**self.entry, 'uri': self.entry['uri'].replace('192.0.2.1', '192.0.2.2')}
        self.artifacts.reconcile(self.config, [updated])
        self.assertEqual(self.contents(), [updated['uri'] + ' Phone'])

    def test_v2_bookmark_manifest_migrates_exact_entries(self):
        old = 'file:///old/Devices/Phone Phone'
        user = 'sftp://192.0.2.9/ My files'
        self.write_bookmarks([old, user])
        self.artifacts.bookmarks.with_name('gmm-bookmarks.json').write_text(json.dumps({'file:///old/Devices/Phone': [old]}))
        self.artifacts.reconcile(self.config, [self.entry])
        self.assertEqual(self.contents(), [user, self.entry['uri'] + ' Phone'])
        self.assertFalse(self.artifacts.bookmarks.with_name('gmm-bookmarks.json').exists())

    def test_corrupt_ownership_prevents_cleanup(self):
        self.artifacts.directory.mkdir()
        self.artifacts.path.write_text('{broken')
        self.write_bookmarks(['file:///home/example/Work Work'])
        with self.assertRaises(ValueError):
            self.artifacts.reconcile(self.config, [])
        self.assertEqual(self.contents(), ['file:///home/example/Work Work'])


class ConfigTests(IsolatedTest):
    def write(self, text):
        self.config.path.parent.mkdir(parents=True, exist_ok=True)
        self.config.path.write_text(text)

    def test_major_upgrade_backs_up_and_resets_old_settings_once(self):
        old = '[general]\nnotifications = false\nmount_structure_dir = ' + json.dumps(str(self.root / 'old-devices')) + '\n'
        self.write(old)
        gmm.prepare_config()
        backups = list(self.config.path.parent.glob('config.toml.gmm-backup-*'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), old)
        self.assertTrue(gmm.Config.load().notifications)
        self.write(gmm.DEFAULT_CONFIG.replace('notifications = true', 'notifications = false'))
        gmm.prepare_config()
        self.assertFalse(gmm.Config.load().notifications)
        self.assertEqual(len(list(self.config.path.parent.glob('config.toml.gmm-backup-*'))), 1)

    def test_legacy_links_cleanup_preserves_user_items_and_retargeted_links(self):
        base = self.root / 'old-devices'
        folder = base / 'Phone'
        folder.mkdir(parents=True)
        (folder / 'Internal').symlink_to('/old/mount')
        (folder / 'User').symlink_to('/user/changed')
        (folder / 'notes.txt').write_text('keep')
        (folder / '.gmm-links.json').write_text(json.dumps({'Internal': '/old/mount', 'User': '/old/user-target'}))
        self.write('[general]\nmount_structure_dir = ' + json.dumps(str(base)) + '\n')
        gmm.prepare_config()
        self.assertFalse(os.path.lexists(folder / 'Internal'))
        self.assertEqual(os.readlink(folder / 'User'), '/user/changed')
        self.assertEqual((folder / 'notes.txt').read_text(), 'keep')

    def test_path_traversal_in_custom_storage_is_rejected(self):
        self.write('version = 3\n[storage]\ncustom_paths = ["../secrets:Bad"]\n')
        with self.assertRaisesRegex(ValueError, 'custom storage'):
            gmm.Config.load()

    def test_notifications_requires_boolean(self):
        self.write('version = 3\n[general]\nnotifications = "false"\n')
        with self.assertRaisesRegex(ValueError, 'notifications'):
            gmm.Config.load()

    def test_old_config_requires_explicit_installer_migration(self):
        self.write('[general]\nnotifications = false\n')
        with self.assertRaisesRegex(ValueError, 'migrate'):
            gmm.Config.load()


class Bus:
    def __init__(self, replies):
        self.replies = replies
        self.calls = []

    def call_sync(self, service, path, interface, method, parameters, reply_type, flags, timeout, cancel):
        self.calls.append((service, path, method, flags, timeout, parameters))
        value = self.replies[method]
        if isinstance(value, Exception):
            raise value
        return NS(unpack=lambda: (value,))


def mounted(uri):
    root = NS(get_uri_scheme=lambda: 'sftp', get_uri=lambda: uri, get_path=lambda: '/tmp/mount')
    return NS(get_root=lambda: root, get_default_location=lambda: NS(get_path=lambda: '/tmp/mount'))


class DiscoveryTests(IsolatedTest):
    def setup_bus(self, replies, mounts=()):
        bus = Bus(replies)
        fake_gio = NS(BusType=NS(SESSION=1), DBusCallFlags=NS(NO_AUTO_START=7),
                      bus_get_sync=lambda *args: bus,
                      VolumeMonitor=NS(get=lambda: NS(get_mounts=lambda: mounts)))
        patch.object(gmm, 'Gio', fake_gio).start()
        patch.object(gmm, 'GLib', NS(Variant=lambda signature, args: (signature, args))).start()
        return bus

    def test_gs_matches_unique_phone_and_does_not_adopt_port22(self):
        phone = {'Paired': True, 'Connected': True, 'Name': 'Phone', 'Id': 'abc'}
        bus = self.setup_bus({'ListNames': ['org.gnome.Shell.Extensions.GSConnect'],
            'GetManagedObjects': {'/Device/abc': {'org.gnome.Shell.Extensions.GSConnect.Device': phone}}},
            [mounted('sftp://192.0.2.1:1739/'), mounted('sftp://192.0.2.1:22/')])
        with patch.object(gmm, '_gsconnect_host', return_value='192.0.2.1'):
            mounts, _ = gmm.discover_mounts()
        self.assertEqual([x.device_id for x in mounts], ['gsconnect:abc'])
        self.assertTrue(all(x[3:5] == (7, 2000) for x in bus.calls))
        self.assertFalse(any(x[2] in ('mount', 'mountAndWait', 'startBrowsing', 'Activate') for x in bus.calls))

    def test_ambiguous_host_is_not_owned(self):
        phone = {'Paired': True, 'Connected': True, 'Name': 'Phone'}
        objects = {'/Device/' + i: {'org.gnome.Shell.Extensions.GSConnect.Device': {**phone, 'Id': i}}
                   for i in ('one', 'two')}
        self.setup_bus({'ListNames': ['org.gnome.Shell.Extensions.GSConnect'], 'GetManagedObjects': objects},
                       [mounted('sftp://192.0.2.1:1739/')])
        with patch.object(gmm, '_gsconnect_host', return_value='192.0.2.1'):
            self.assertEqual(gmm.discover_mounts()[0], [])

    def kde_replies(self):
        return {'ListNames': ['org.kde.kdeconnect'], 'devices': ['abc'],
                'GetAll': {'isPaired': True, 'isReachable': True, 'name': 'Phone'},
                'isMounted': True, 'mountPoint': '/run/user/1000/abc',
                'getDirectories': {'/run/user/1000/abc/storage/emulated/0': 'All files',
                                   '/run/user/1000/abc/storage/emulated/0/DCIM': 'Camera',
                                   '/run/user/1000/abc/../secrets': 'Bad'}}

    def test_kde_existing_sshfs_produces_file_uri_and_reported_paths(self):
        bus = self.setup_bus(self.kde_replies())
        with patch.object(gmm, '_sshfs_mount_points', return_value={'/run/user/1000/abc'}):
            mounts, _ = gmm.discover_mounts()
        self.assertEqual(mounts[0].uri, 'file:///run/user/1000/abc')
        self.assertEqual(mounts[0].paths, {'Internal': 'storage/emulated/0', 'Camera': 'storage/emulated/0/DCIM'})
        self.assertTrue(all(x[3:5] == (7, 2000) for x in bus.calls))
        self.assertEqual({x[2] for x in bus.calls}, {'ListNames', 'devices', 'GetAll', 'isMounted', 'mountPoint', 'getDirectories'})

    def test_kde_not_mounted_is_not_probed_or_mounted(self):
        replies = self.kde_replies()
        replies['isMounted'] = False
        bus = self.setup_bus(replies)
        with patch.object(gmm, '_sshfs_mount_points', return_value=set()):
            self.assertEqual(gmm.discover_mounts()[0], [])
        self.assertNotIn('getDirectories', [x[2] for x in bus.calls])

    def test_kde_stale_reported_mount_does_not_create_storage(self):
        bus = self.setup_bus(self.kde_replies())
        with patch.object(gmm, '_sshfs_mount_points', return_value=set()):
            self.assertEqual(gmm.discover_mounts()[0], [])
        self.assertNotIn('getDirectories', [x[2] for x in bus.calls])

    def test_failed_snapshot_raises_rather_than_removing_all_entries(self):
        self.setup_bus({'ListNames': ['org.kde.kdeconnect'], 'devices': RuntimeError('timeout')})
        with self.assertRaisesRegex(RuntimeError, 'timeout'):
            gmm.discover_mounts()

    def test_missing_backend_is_not_activated(self):
        bus = self.setup_bus({'ListNames': []})
        self.assertEqual(gmm.discover_mounts()[0], [])
        self.assertEqual(len(bus.calls), 1)

    def test_mountinfo_escaping(self):
        content = '12 10 0:2 / /run/user/1000/a\\040b rw - fuse.sshfs kdeconnect@192.0.2.1:/ rw\n'
        with patch.object(Path, 'read_text', return_value=content):
            self.assertEqual(gmm._sshfs_mount_points(), {'/run/user/1000/a b'})


if __name__ == '__main__':
    unittest.main()
