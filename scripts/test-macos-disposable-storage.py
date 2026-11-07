#!/usr/bin/env python3
"""Unit tests for physical storage selection; no real volume is modified."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('storage', Path(__file__).with_name('macos-disposable-storage.py'))
storage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(storage)


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name).resolve()
        self.mount = base / 'mount'
        self.mount.mkdir(mode=0o700)
        self.root = self.mount / 'scratch'
        self.root.mkdir(mode=0o700)
        self.fallback = base / 'fallback'
        self.fallback.mkdir(mode=0o700)
        self.uuid = '12345678-1234-4ABC-8DEF-1234567890AB'
        self.config = {'disposableVolumeMount': str(self.mount), 'disposableRoot': str(self.root),
                       'disposableVolumeUUID': self.uuid}
        self.mounted = lambda path: True
        self.read_uuid = lambda path: self.uuid
        self.reserve = patch.object(storage, 'RESERVE', 0)
        self.reserve.start()
        self.addCleanup(self.reserve.stop)

    def choose(self, mounted=None, uuid=None):
        return storage.select(self.config, self.fallback, mounted=mounted or self.mounted,
                              uuid=uuid or self.read_uuid)

    def test_external_and_missing_volume_fallback(self):
        external = self.choose()
        self.assertEqual(Path(external['path']).parent, self.root)
        storage.verify(external, mounted=self.mounted, uuid=self.read_uuid)
        fallback = self.choose(mounted=lambda path: False)
        self.assertEqual(Path(fallback['path']).parent, self.fallback)
        storage.verify(fallback)
        self.assertNotEqual(external['path'], fallback['path'])

    def test_wrong_uuid_and_symlink_are_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'UUID differs'):
            self.choose(uuid=lambda path: '00000000-0000-0000-0000-000000000000')
        self.root.rmdir()
        self.root.symlink_to(self.fallback, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, 'symlinks'):
            self.choose()

    def test_loss_then_new_run_reselects_fallback(self):
        external = self.choose()
        with self.assertRaisesRegex(RuntimeError, 'unavailable'):
            storage.verify(external, mounted=lambda path: False, uuid=self.read_uuid)
        resumed = self.choose(mounted=lambda path: False)
        self.assertEqual(Path(resumed['path']).parent, self.fallback)
        self.assertNotEqual(resumed['path'], external['path'])

    def test_missing_root_leaf_created_only_on_verified_mount(self):
        self.root.rmdir()
        selected = self.choose()
        self.assertEqual(Path(selected['path']).parent, self.root)
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o700)
        self.root.rename(self.mount / 'saved')
        with self.assertRaisesRegex(RuntimeError, 'UUID differs'):
            self.choose(uuid=lambda path: '00000000-0000-0000-0000-000000000000')
        self.assertFalse(self.root.exists())

    def test_cleanup_exact_run_only_and_refuses_replacement(self):
        first = self.choose()
        run = Path(first['path'])
        (run / 'build').mkdir()
        (run / 'build' / 'derived').write_text('derived')
        sibling = self.root / 'someone-else'
        sibling.mkdir()
        (sibling / 'keep').write_text('keep')
        storage.dispose(first, self.root, mounted=self.mounted, uuid=self.read_uuid)
        self.assertFalse(run.exists())
        self.assertEqual((sibling / 'keep').read_text(), 'keep')
        second = self.choose()
        path = Path(second['path'])
        path.rename(path.with_name('old'))
        path.mkdir(mode=0o700)
        (path / 'unknown').write_text('keep')
        with self.assertRaisesRegex(RuntimeError, 'identity changed'):
            storage.dispose(second, self.root, mounted=self.mounted, uuid=self.read_uuid)
        self.assertTrue((path / 'unknown').exists())
        with self.assertRaisesRegex(RuntimeError, 'outside'):
            storage.dispose(second, self.fallback, mounted=self.mounted, uuid=self.read_uuid)

    def test_cleanup_missing_is_idempotent_only_on_verified_volume(self):
        identity = self.choose()
        storage.dispose(identity, self.root, mounted=self.mounted, uuid=self.read_uuid)
        storage.dispose(identity, self.root, mounted=self.mounted, uuid=self.read_uuid)
        with self.assertRaisesRegex(RuntimeError, 'unavailable'):
            storage.dispose(identity, self.root, mounted=lambda path: False, uuid=self.read_uuid)
        with self.assertRaisesRegex(RuntimeError, 'changed'):
            storage.dispose(identity, self.root, mounted=self.mounted, uuid=lambda path: 'wrong')

    def test_retired_external_run_survives_device_number_change(self):
        identity = self.choose()
        changed = {**identity, 'device': identity['device'] + 1}
        with self.assertRaisesRegex(RuntimeError, 'identity changed'):
            storage.verify(changed, mounted=self.mounted, uuid=self.read_uuid)
        storage.dispose(changed, self.root, mounted=self.mounted, uuid=self.read_uuid)
        self.assertFalse(Path(identity['path']).exists())

    def test_uuid_reader_only_accepts_the_configured_mount(self):
        def mount_uuid(path):
            if Path(path) != self.mount:
                raise AssertionError('UUID reader must receive the mount, not a descendant')
            return self.uuid
        self.root.rmdir()
        identity = self.choose(uuid=mount_uuid)
        storage.verify(identity, mounted=self.mounted, uuid=mount_uuid)
        storage.dispose(identity, self.root, mounted=self.mounted, uuid=mount_uuid)
        storage.dispose(identity, self.root, mounted=self.mounted, uuid=mount_uuid)

    def test_optional_configuration_is_complete_and_valid(self):
        self.assertIsNone(storage.validate_settings({}))
        self.assertEqual(storage.validate_settings(self.config)[0], self.mount)
        for bad in ({'disposableRoot': str(self.root)},
                    {**self.config, 'disposableVolumeUUID': ''},
                    {**self.config, 'disposableVolumeUUID': 'not-a-uuid'},
                    {**self.config, 'disposableRoot': str(self.mount)}):
            with self.subTest(bad=bad), self.assertRaises(RuntimeError):
                storage.validate_settings(bad)

    def test_directory_replacement_is_rejected(self):
        external = self.choose()
        run = Path(external['path'])
        run.rename(run.with_name('old'))
        run.mkdir(mode=0o700)
        with self.assertRaisesRegex(RuntimeError, 'identity changed'):
            storage.verify(external, mounted=self.mounted, uuid=self.read_uuid)


if __name__ == '__main__':
    unittest.main()
