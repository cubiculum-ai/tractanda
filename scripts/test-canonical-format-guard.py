#!/usr/bin/env python3
"""Tiny offline tests for the canonical reader compatibility gate."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
import uuid
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    'canonical_format_guard', Path(__file__).with_name('canonical-format-guard.py'))
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)


def support(reader=2, writer=2, read=(1, 2), write=(2,), capabilities=(), write_capabilities=()):
    return {
        'profile': guard.PROFILE, 'readerLevel': reader, 'writerLevel': writer,
        'read': list(read), 'write': list(write), 'capabilities': list(capabilities),
        'writeCapabilities': list(write_capabilities),
    }


def requirement(store_id, level=1, formats=(1,), capabilities=()):
    return {
        'profile': guard.MARKER_PROFILE, 'storeID': store_id,
        'minimumReaderLevel': level, 'recordFormats': list(formats),
        'capabilities': list(capabilities),
    }


class FormatGuardTests(unittest.TestCase):
    def store(self, marker=None):
        temporary = tempfile.TemporaryDirectory(prefix='canonical-format-guard-')
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name).resolve() / 'store'
        root.mkdir(mode=0o700)
        store_id = str(uuid.uuid1())
        identity = {'formatVersion': 1, 'storeID': store_id}
        (root / '.tractanda-store-identity.json').write_text(json.dumps(identity) + '\n')
        if marker is not False:
            value = marker or requirement(store_id)
            (root / guard.MARKER_NAME).write_text(json.dumps(value) + '\n')
        for path in root.iterdir():
            path.chmod(0o600)
        root.chmod(0o700)
        return root, store_id

    def test_legacy_floor_accepts_verified_legacy_manifest_default(self):
        root, store_id = self.store()
        self.assertEqual(guard.support_from_manifest({}), guard.LEGACY)
        self.assertIsNone(guard.require_reader(
            guard.support_from_manifest({}), guard.load_requirement(root)))
        self.assertEqual(guard.validate_requirement(requirement(store_id)), requirement(store_id))

    def test_format_two_requirement_blocks_a_legacy_reader(self):
        root, store_id = self.store()
        marker = requirement(store_id, 2, (1, 2))
        (root / guard.MARKER_NAME).write_text(json.dumps(marker) + '\n')
        with self.assertRaisesRegex(RuntimeError, 'newer reader'):
            guard.require_reader(guard.LEGACY, guard.load_requirement(root))
        self.assertIsNone(guard.require_reader(support(), guard.load_requirement(root)))

    def test_missing_unknown_and_cross_store_proof_fail_closed(self):
        root, store_id = self.store(marker=False)
        with self.assertRaises(OSError):
            guard.load_requirement(root)
        unknown = requirement(store_id)
        unknown['profile'] = 'tractanda.canonical-reader.v999'
        (root / guard.MARKER_NAME).write_text(json.dumps(unknown) + '\n')
        (root / guard.MARKER_NAME).chmod(0o600)
        with self.assertRaisesRegex(RuntimeError, 'Unknown canonical reader requirement'):
            guard.load_requirement(root)
        other_store = requirement(str(uuid.uuid1()))
        (root / guard.MARKER_NAME).write_text(json.dumps(other_store) + '\n')
        with self.assertRaisesRegex(RuntimeError, 'another store'):
            guard.load_requirement(root)
        declaration = support()
        declaration['profile'] = 'unknown.profile'
        with self.assertRaisesRegex(RuntimeError, 'Unknown canonical reader declaration'):
            guard.support_from_manifest({'canonicalFormats': declaration})

    def test_registered_writer_future_write_support_blocks_shared_reader(self):
        root, store_id = self.store()
        floor = guard.load_requirement(root)
        with self.assertRaisesRegex(RuntimeError, 'registered writer future publications'):
            guard.require_reader(guard.LEGACY, floor, writer=support())
        active_legacy_writer = support(1, 1, (1,), (1,))
        self.assertIsNone(guard.require_reader(guard.LEGACY, floor, writer=active_legacy_writer))

    def test_reader_requirement_is_monotonic_in_identity_formats_level_and_caps(self):
        store_id = str(uuid.uuid1())
        first = requirement(store_id)
        second = requirement(store_id, 2, (1, 2), ('authority-v1',))
        self.assertIsNone(guard.require_monotonic(first, second))
        for regressed in (
            requirement(str(uuid.uuid1())),
            requirement(store_id, 1, (1,)),
            requirement(store_id, 2, (2,)),
            requirement(store_id, 2, (1, 2)),
        ):
            with self.subTest(regressed=regressed), self.assertRaises(RuntimeError):
                guard.require_monotonic(second, regressed)

    def test_owned_reader_requires_manifest_hash_and_declared_executable_bytes(self):
        root, _ = self.store()
        temporary = root.parent
        bundle = temporary / 'release'
        client = bundle / 'bin' / 'tractanda'
        client.parent.mkdir(parents=True)
        client.write_bytes(b'fixture reader')
        entry = {'path': 'bin/tractanda', 'sha256': hashlib.sha256(client.read_bytes()).hexdigest()}
        manifest = bundle / 'bundle-manifest.json'
        manifest.write_text(json.dumps({'files': [entry]}) + '\n')
        expected = hashlib.sha256(manifest.read_bytes()).hexdigest()
        self.assertIsNone(guard.require_owned_reader(client, root, expected))
        with self.assertRaisesRegex(RuntimeError, 'binding is missing or changed'):
            guard.require_owned_reader(client, root, None)
        manifest.write_bytes(manifest.read_bytes() + b' ')
        with self.assertRaisesRegex(RuntimeError, 'binding is missing or changed'):
            guard.require_owned_reader(client, root, expected)
        manifest.write_bytes(manifest.read_bytes().rstrip() + b'\n')
        expected = hashlib.sha256(manifest.read_bytes()).hexdigest()
        client.write_bytes(b'replaced reader')
        with self.assertRaisesRegex(RuntimeError, 'executable differs'):
            guard.require_owned_reader(client, root, expected)

    def test_executable_hash_streams_chunks_and_rejects_symlink_or_shared_paths(self):
        root, _ = self.store()
        executable = root.parent / 'reader'
        payload = b'format-guard-reader' * (64 * 1024)
        executable.write_bytes(payload)
        executable.chmod(0o600)
        expected = hashlib.sha256(payload).hexdigest()
        with patch.object(Path, 'read_bytes', side_effect=AssertionError('must stream via no-follow fd')):
            self.assertEqual(guard.digest_executable(executable), expected)

        symlink = root.parent / 'reader-link'
        symlink.symlink_to(executable)
        with self.assertRaises(OSError):
            guard.digest_executable(symlink)

        shared = root.parent / 'reader-hardlink'
        os.link(executable, shared)
        with self.assertRaisesRegex(RuntimeError, 'unsafe'):
            guard.digest_executable(executable)

        parent_alias = root.parent / 'reader-parent'
        parent_alias.symlink_to(executable.parent, target_is_directory=True)
        with self.assertRaises(OSError):
            guard.digest_executable(parent_alias / executable.name)


if __name__ == '__main__':
    unittest.main(verbosity=2)
