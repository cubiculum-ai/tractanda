#!/usr/bin/env python3
"""Tiny offline tests for the operator-only canonical upgrade checkpoint."""
import contextlib
import copy
import importlib.util
import json
import os
from pathlib import Path
import platform
import pwd
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('activation', Path(__file__).with_name('activate-release.py'))
activation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(activation)


def metadata(path):
    value = path.lstat()
    return {'mode': value.st_mode & 0o7777, 'uid': value.st_uid, 'gid': value.st_gid,
            'flags': 0, 'acl': '', 'xattrs': {}}


class CheckpointTests(unittest.TestCase):
    def fixture(self):
        temporary = tempfile.TemporaryDirectory(prefix='activation-checkpoint-')
        root = Path(temporary.name).resolve()
        store = root / 'store'
        store.mkdir(mode=0o700)
        for name in ('items/one.tractanda', 'attachments/payloads/original',
                     'documents/content/page.json', '.tractanda-store-identity.json',
                     'settings.json', 'document-jobs/pending/record.json', '.writer.lock'):
            path = store / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('synthetic-' + name)
            path.chmod(0o600)
        self.addCleanup(temporary.cleanup)
        return root, store

    def test_full_inventory_and_immutable_original_page_identity_settings_preservation(self):
        _, store = self.fixture()
        before = activation.inventory(store, metadata)
        self.assertEqual(len([x for x in before['entries'].values() if x['kind'] == 'file']), 7)
        for name in ('items/one.tractanda', 'attachments/payloads/original',
                     'documents/content/page.json', '.tractanda-store-identity.json', 'settings.json'):
            after = copy.deepcopy(before)
            after['entries'][name]['sha256'] = 'changed'
            with self.assertRaises(RuntimeError):
                activation.require_preserved(before, after)
        after = copy.deepcopy(before)
        del after['entries']['document-jobs/pending/record.json']
        after['entries']['.writer.lock']['sha256'] = 'operational'
        self.assertEqual(activation.require_preserved(before, after), [])

    def test_meaningful_metadata_changes_reject_without_inode_equality(self):
        _, store = self.fixture()
        before = activation.inventory(store, metadata)
        entry = before['entries']['items/one.tractanda']
        self.assertNotIn('inode', entry['metadata'])
        for key in ('mode', 'uid', 'gid', 'acl', 'xattrs'):
            after = copy.deepcopy(before)
            after['entries']['items/one.tractanda']['metadata'][key] = 'changed'
            with self.assertRaises(RuntimeError):
                activation.require_preserved(before, after)

    def test_symlink_leaf_and_parent_hashing_reject(self):
        root, store = self.fixture()
        (store / 'alias').symlink_to(store / 'settings.json')
        with self.assertRaises(RuntimeError):
            activation.inventory(store, metadata)
        with self.assertRaises(OSError):
            activation.digest(store / 'alias')
        (root / 'alias-parent').symlink_to(store, target_is_directory=True)
        with self.assertRaises(OSError):
            activation.digest(root / 'alias-parent/settings.json')

    def test_unknown_capacity_and_reserve_reject_without_disk_filling(self):
        for free in (0, activation.BACKUP_RESERVE + 99):
            with self.assertRaises(RuntimeError):
                activation.require_capacity(Path('/'), 100, lambda _: free)
        with self.assertRaises(OSError):
            activation.require_capacity(Path('/'), 100, lambda _: (_ for _ in ()).throw(OSError('unknown')))
        activation.require_capacity(Path('/'), 100, lambda _: activation.BACKUP_RESERVE + 100)

    def test_entry_and_copy_caps_fail_closed_on_tiny_fixtures(self):
        _, store = self.fixture()
        with patch.object(activation, 'BACKUP_ENTRY_CAP', 2):
            with self.assertRaises(RuntimeError):
                activation.inventory(store, metadata)
        with patch.object(activation, 'BACKUP_COPY_CAP', 1):
            with self.assertRaises(RuntimeError):
                activation.inventory(store, metadata)

    def test_checkpoint_holds_same_writer_lock_and_restores_after_copy_failure(self):
        root, store = self.fixture()
        events = []
        @contextlib.contextmanager
        def lock(_):
            events.append('lock')
            try:
                yield
            finally:
                events.append('unlock')
        def fail(*_):
            events.append('copy')
            raise RuntimeError('fixture copy failed')
        with self.assertRaises(RuntimeError):
            activation.checkpoint_backup(store, root / 'backup', lambda: events.append('stop'),
                                         lambda: events.append('restore'), lock=lock,
                                         inspect=lambda _: activation.inventory(store, metadata), copier=fail)
        self.assertEqual(events, ['stop', 'lock', 'copy', 'unlock', 'restore'])
        with activation.existing_writer_lock(store):
            with self.assertRaises(BlockingIOError):
                with activation.existing_writer_lock(store):
                    pass

    def test_explicit_semantic_change_keeps_metadata_and_records_hashes(self):
        _, store = self.fixture()
        (store / 'semantic.json').write_text('{}')
        before = activation.inventory(store, metadata)
        after = copy.deepcopy(before)
        after['entries']['semantic.json']['sha256'] = 'new'
        changes = []
        def allowed(old, new):
            changes.append((old['sha256'], new['sha256']))
        self.assertEqual(activation.require_preserved(before, after, semantic_change=allowed), ['semantic.json'])
        self.assertEqual(len(changes), 1)
        after['entries']['semantic.json']['metadata']['mode'] = 0o777
        with self.assertRaises(RuntimeError):
            activation.require_preserved(before, after, semantic_change=allowed)

    def test_exact_installer_granite_recipe_accepts_qwen_transition_and_rejects_wrong_operation(self):
        _, store = self.fixture()
        identifier = '22222222-2222-1222-8222-222222222222'
        payload = {'backend': 'vmlx-granite-embedding-f32-v1',
                   'model': 'tractanda-granite-embedding-311m-multilingual-r2-vmlx-fp32-44399559',
                   'modelRevision': '44399559930365213510b1ee2eb15ded83374f0e:weights-bf16:compute-f32:dcb6431bfa6e817fe100a2b0521360cec3383963b03fa966b685de18ca310d31:vmlx-61a4b20d4ad01b10466e8fc94c50402a9f994430',
                   'dimensions': 768}
        previous_receipt = {'embedding': {'backend': 'vmlx-qwen3-f32-v1'}}
        updated = {'instance': 'production', 'port': 48728, 'embeddingConfigurationID': identifier,
                   'embedding': payload}
        # Exact SetupEmbeddings.graniteConfiguration recipe, independent of the Python helper.
        configuration = {'formatVersion': 2, 'configurationID': identifier,
                         'operationID': 'setup-embedding-v2-production-' + identifier,
                         'endpoint': 'http://127.0.0.1:48729/v1/embeddings',
                         'model': payload['model'], 'modelRevision': payload['modelRevision'],
                         'dimensions': 768, 'documentPrefix': '', 'queryPrefix': '',
                         'chunkBytes': 384, 'overlapBytes': 64, 'pooling': 'cls',
                         'normalization': 'l2', 'inputEncoding': 'item-text-utf8-v2'}
        (store / 'semantic.json').write_text(json.dumps(configuration))
        result = activation.verify_semantic_migration(store, previous_receipt, updated,
                                                      {'sha256': 'old'}, {'sha256': 'new'})
        self.assertEqual((result['beforeSHA256'], result['afterSHA256']), ('old', 'new'))
        configuration['operationID'] = 'setup-embedding-v2-production'
        (store / 'semantic.json').write_text(json.dumps(configuration))
        with self.assertRaises(RuntimeError):
            activation.verify_semantic_migration(store, previous_receipt, updated,
                                                  {'sha256': 'old'}, {'sha256': 'new'})

    def test_failure_receipt_io_cannot_skip_old_service_restoration(self):
        root, store = self.fixture()
        destination = root / 'partial'
        destination.mkdir(mode=0o700)
        events = []
        @contextlib.contextmanager
        def lock(_):
            yield
        def fail(*_):
            raise OSError('fixture copy failure')
        with patch.object(activation, 'write_private', side_effect=OSError('fixture receipt failure')):
            with self.assertRaises(OSError):
                activation.checkpoint_backup(store, destination, lambda: events.append('stop'),
                                             lambda: events.append('restore'), lock=lock,
                                             inspect=lambda _: {}, copier=fail)
        self.assertEqual(events, ['stop', 'restore'])
        self.assertTrue(destination.exists())

    @unittest.skipUnless(platform.system() == 'Darwin', 'Native macOS metadata-copy check')
    def test_actual_tiny_copy_preserves_acl_xattrs_permissions_and_sync_receipt(self):
        root, store = self.fixture()
        leaf = store / 'settings.json'
        user = pwd.getpwuid(os.getuid()).pw_name
        subprocess.run(['/bin/chmod', '+a', user + ' allow read,readattr,readextattr,readsecurity', str(leaf)], check=True)
        subprocess.run(['/usr/bin/xattr', '-w', 'ai.tractanda.checkpoint.fixture', 'synthetic', str(leaf)], check=True)
        before = activation.inventory(store)
        self.assertTrue(before['entries']['settings.json']['metadata']['acl'])
        self.assertIn('ai.tractanda.checkpoint.fixture', before['entries']['settings.json']['metadata']['xattrs'])
        proof = activation.copy_backup(store, root / 'backup', before)
        recorded = json.loads(proof.read_text())
        self.assertEqual(recorded['status'], 'verified')
        self.assertEqual(recorded['inventory']['entries'], before['entries'])
        self.assertEqual(proof.stat().st_mode & 0o777, 0o600)
        self.assertEqual(proof.parent.stat().st_mode & 0o777, 0o700)
        self.assertLess(before['logicalBytes'], 4096)


if __name__ == '__main__':
    unittest.main()
