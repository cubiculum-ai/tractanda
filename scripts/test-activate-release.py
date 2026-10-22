#!/usr/bin/env python3
"""Tiny offline tests for the operator-only canonical upgrade checkpoint."""
import contextlib
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import pwd
import subprocess
import shutil
import stat
import tempfile
import sys
import unittest
import uuid
from types import SimpleNamespace
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('activation', Path(__file__).with_name('activate-release.py'))
activation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(activation)


def metadata(path):
    value = path.lstat()
    return {'mode': value.st_mode & 0o7777, 'uid': value.st_uid, 'gid': value.st_gid,
            'flags': 0, 'acl': '', 'xattrs': {}}


class CheckpointTests(unittest.TestCase):
    store_identity_name = '.tractanda-store-identity.json'
    replica_identity_name = '.tractanda-replica-identity.json'
    reader_requirement_name = 'canonical-reader.json'
    store_id = '11111111-1111-1111-8111-111111111111'
    replica_id = '22222222-2222-1222-8222-222222222222'

    def fixture(self):
        temporary = tempfile.TemporaryDirectory(prefix='activation-checkpoint-')
        root = Path(temporary.name).resolve()
        store = root / 'store'
        store.mkdir(mode=0o700)
        files = ('items/one.tractanda', 'attachments/payloads/original',
                 'documents/content/page.json', self.store_identity_name,
                 self.replica_identity_name, self.reader_requirement_name, 'settings.json',
                 'document-jobs/pending/record.json', '.writer.lock')
        for name in files:
            path = store / name
            path.parent.mkdir(parents=True, exist_ok=True)
            if name == self.store_identity_name:
                contents = {'formatVersion': 1, 'storeID': self.store_id}
                path.write_text(json.dumps(contents, sort_keys=True) + '\n')
            elif name == self.replica_identity_name:
                contents = {'formatVersion': 1, 'storeID': self.store_id, 'replicaID': self.replica_id}
                path.write_text(json.dumps(contents, sort_keys=True) + '\n')
                for value in (contents['storeID'], contents['replicaID']):
                    parsed = uuid.UUID(value)
                    self.assertEqual(parsed.version, 1)
                    self.assertEqual(parsed.variant, uuid.RFC_4122)
            elif name == self.reader_requirement_name:
                contents = {'profile': activation.format_guard.MARKER_PROFILE,
                            'storeID': self.store_id, 'minimumReaderLevel': 1,
                            'recordFormats': [1], 'capabilities': []}
                path.write_text(json.dumps(contents, sort_keys=True) + '\n')
            else:
                path.write_text('synthetic-' + name)
            path.chmod(0o600)
        self.addCleanup(temporary.cleanup)
        return root, store

    def test_full_inventory_and_immutable_original_page_identity_settings_preservation(self):
        _, store = self.fixture()
        before = activation.inventory(store, metadata)
        self.assertEqual(len([x for x in before['entries'].values() if x['kind'] == 'file']), 9)
        for name in ('items/one.tractanda', 'attachments/payloads/original',
                     'documents/content/page.json', self.store_identity_name,
                     self.replica_identity_name, self.reader_requirement_name, 'settings.json'):
            after = copy.deepcopy(before)
            after['entries'][name]['sha256'] = 'changed'
            with self.assertRaises(RuntimeError):
                activation.require_preserved(before, after)
        missing_replica_identity = copy.deepcopy(before)
        del missing_replica_identity['entries'][self.replica_identity_name]
        with self.assertRaises(RuntimeError):
            activation.require_preserved(before, missing_replica_identity)
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

    def test_checkpoint_admits_reader_after_stop_before_lock_and_restores_on_rejection(self):
        root, store = self.fixture()
        events = []

        @contextlib.contextmanager
        def lock(_):
            events.append('lock')
            try:
                yield
            finally:
                events.append('unlock')

        def inspect(_):
            events.append('inventory')
            return {}

        def copier(*_):
            events.append('copy')
            return root / 'backup.json'

        activation.checkpoint_backup(
            store, root / 'backup', lambda: events.append('stop'), lambda: events.append('restore'),
            lock=lock, inspect=inspect, copier=copier,
            admit_reader=lambda: events.append('admit'))
        self.assertEqual(events, ['stop', 'admit', 'lock', 'inventory', 'copy', 'unlock'])

        events.clear()
        with self.assertRaisesRegex(RuntimeError, 'reader incompatible'):
            activation.checkpoint_backup(
                store, root / 'rejected', lambda: events.append('stop'), lambda: events.append('restore'),
                lock=lock, inspect=inspect, copier=copier,
                admit_reader=lambda: (events.append('admit'), (_ for _ in ()).throw(RuntimeError('reader incompatible'))))
        self.assertEqual(events, ['stop', 'admit', 'restore'])

    def test_reader_marker_change_requires_monotonic_requirement_proof(self):
        _, store = self.fixture()
        before = activation.inventory(store, metadata)
        prior = activation.format_guard.load_requirement(store)
        marker = store / self.reader_requirement_name
        raised = dict(prior, minimumReaderLevel=2, recordFormats=[1, 2])
        marker.write_text(json.dumps(raised, sort_keys=True) + '\n')
        after = activation.inventory(store, metadata)
        changed = activation.require_preserved(
            before, after, reader_change=lambda: activation.format_guard.require_monotonic(
                prior, activation.format_guard.load_requirement(store)))
        self.assertEqual(changed, [self.reader_requirement_name])

        prior = activation.format_guard.load_requirement(store)
        marker.write_text(json.dumps(dict(prior, minimumReaderLevel=1, recordFormats=[1]), sort_keys=True) + '\n')
        regressed = activation.inventory(store, metadata)
        with self.assertRaisesRegex(RuntimeError, 'moved backward'):
            activation.require_preserved(
                after, regressed, reader_change=lambda: activation.format_guard.require_monotonic(
                    prior, activation.format_guard.load_requirement(store)))

    def test_tiny_backup_retains_store_and_reader_marker_bytes(self):
        root, store = self.fixture()
        before = activation.inventory(store, metadata)
        destination = root / 'verified-backup'

        class FinishedCopy:
            returncode = 0
            def poll(self): return 0
            def wait(self): return 0

        def copy_runner(arguments, **_):
            shutil.copytree(arguments[-2], arguments[-1])
            return FinishedCopy()

        with patch.object(activation.subprocess, 'Popen', side_effect=copy_runner), \
                patch.object(activation, 'acl_text_fd', return_value=''):
            proof = activation.copy_backup(
                store, destination, before,
                available=lambda _: activation.BACKUP_RESERVE + before['copyEstimateBytes'] + 1,
                metadata=metadata)
        self.assertEqual(json.loads(proof.read_text())['status'], 'verified')
        backup_store = destination / 'store'
        for name in (self.store_identity_name, self.replica_identity_name, self.reader_requirement_name):
            self.assertEqual((backup_store / name).read_bytes(), (store / name).read_bytes())

    def test_incompatible_or_unbound_old_reader_cannot_reach_service_restart(self):
        root, store = self.fixture()
        marker = store / self.reader_requirement_name
        marker.write_text(json.dumps({
            'profile': activation.format_guard.MARKER_PROFILE, 'storeID': self.store_id,
            'minimumReaderLevel': 2, 'recordFormats': [1, 2], 'capabilities': [],
        }) + '\n')
        release = root / 'old-release'
        client = release / 'bin' / 'tractanda'
        client.parent.mkdir(parents=True)
        client.write_bytes(b'legacy reader')
        manifest = release / 'bundle-manifest.json'
        manifest.write_text(json.dumps({'files': [{
            'path': 'bin/tractanda', 'sha256': hashlib.sha256(client.read_bytes()).hexdigest(),
        }]}) + '\n')  # Verified legacy manifest defaults to format 1.
        definition = root / 'old-service.plist'
        definition.write_bytes(plistlib.dumps({
            'ProgramArguments': [str(client), 'daemon', str(store), '/tmp/fixture.sock'],
        }))
        with patch.object(activation.subprocess, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'newer reader'):
                activation.restore_service(
                    'fixture', definition, activation.digest(definition), client, '/tmp/fixture.sock',
                    hashlib.sha256(manifest.read_bytes()).hexdigest())
            run.assert_not_called()
            marker.write_text(json.dumps({
                'profile': activation.format_guard.MARKER_PROFILE, 'storeID': self.store_id,
                'minimumReaderLevel': 1, 'recordFormats': [1], 'capabilities': [],
            }) + '\n')
            with self.assertRaisesRegex(RuntimeError, 'binding is missing or changed'):
                activation.restore_service(
                    'fixture', definition, activation.digest(definition), client, '/tmp/fixture.sock', None)
            run.assert_not_called()

    def test_preparing_receipt_stops_before_any_activation_or_service_subprocess(self):
        root, _ = self.fixture()
        real_path_type = activation.Path
        managed_root = Path('/Users/Shared/Library/Application Support/Tractanda')
        fake_root = root / 'managed'
        receipt_path = fake_root / 'receipts' / 'production.json'
        receipt_path.parent.mkdir(parents=True)
        receipt_path.write_text(json.dumps({'state': 'preparing'}))
        receipt_path.chmod(0o600)

        def mapped_path(value, *args, **kwargs):
            raw = os.fspath(value)
            prefix = os.fspath(managed_root)
            if raw == prefix or raw.startswith(prefix + os.sep):
                raw = os.fspath(fake_root) + raw[len(prefix):]
            return real_path_type(raw, *args, **kwargs)

        original_lstat = real_path_type.lstat
        def receipt_lstat(path, *args, **kwargs):
            if path == receipt_path:
                return SimpleNamespace(st_mode=stat.S_IFREG | 0o600, st_uid=0)
            return original_lstat(path, *args, **kwargs)

        arguments = [
            'activate-release.py', '--bundle', str(root / 'unused-bundle'),
            '--software-root', str(managed_root), '--instance', 'production',
            '--manifest-sha256', '0' * 64, '--package', str(root / 'unused.pkg'),
            '--package-sha256', '0' * 64,
        ]
        with patch.object(real_path_type, 'lstat', new=receipt_lstat), \
                patch.object(activation, 'Path', mapped_path), \
                patch.object(activation.platform, 'system', return_value='Darwin'), \
                patch.object(activation.os, 'geteuid', return_value=0), \
                patch.object(sys, 'argv', arguments), \
                patch.object(activation.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'existing active installations'):
                activation.main()
            run.assert_not_called()

    def test_stopped_recovery_binds_receipt_and_preserves_unowned_definition(self):
        root, store = self.fixture()
        release = root / 'release'
        definition = root / 'service.plist'
        definition.write_bytes(plistlib.dumps({'ProgramArguments': ['fixture']}))
        expected_definition = activation.digest(definition)
        receipt_path = root / 'receipt.json'
        expected = {
            'instance': 'fixture', 'manifestSHA256': 'a' * 64,
            'release': str(release), 'state': 'active', 'definitionSHA256': expected_definition,
        }
        receipt_path.write_text(json.dumps(expected) + '\n')
        receipt_path.chmod(0o600)
        backup = root / 'backup'
        backup.mkdir()
        (backup / 'one.bin').write_bytes(b'backup bytes')

        changed_receipt = dict(expected, manifestSHA256='b' * 64)
        receipt_path.write_text(json.dumps(changed_receipt) + '\n')
        changed_bytes = receipt_path.read_bytes()
        with patch.object(activation.subprocess, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'Receipt changed'):
                activation.retain_stopped_recovery(
                    receipt_path, expected, definition, expected_definition, 'incompatible reader')
            run.assert_not_called()
        self.assertEqual(receipt_path.read_bytes(), changed_bytes)
        self.assertTrue(definition.exists())

        receipt_path.write_text(json.dumps(expected) + '\n')
        definition.write_bytes(plistlib.dumps({'ProgramArguments': ['externally changed']}))
        unowned_definition = definition.read_bytes()
        with patch.object(activation.subprocess, 'run') as run, \
                patch.object(activation.subprocess, 'check_output') as check_output:
            activation.retain_stopped_recovery(
                receipt_path, expected, definition, expected_definition, 'incompatible reader')
            run.assert_not_called()
            check_output.assert_not_called()
        updated = json.loads(receipt_path.read_text())
        self.assertEqual(updated['state'], 'preparing')
        self.assertIsNone(updated['definitionSHA256'])
        self.assertEqual(definition.read_bytes(), unowned_definition)
        self.assertEqual((backup / 'one.bin').read_bytes(), b'backup bytes')
        self.assertEqual((store / 'items/one.tractanda').read_bytes(), b'synthetic-items/one.tractanda')

    def test_stopped_recovery_boots_out_owned_writer_and_preserves_live_store_and_backup(self):
        root, store = self.fixture()
        release = root / 'previous-release'
        definition = root / 'service.plist'
        definition.write_bytes(plistlib.dumps({'ProgramArguments': [
            str(release / 'bin/tractanda'), 'daemon', str(store), '/tmp/fixture.sock',
        ]}))
        expected_definition = activation.digest(definition)
        receipt_path = root / 'receipt.json'
        expected = {
            'instance': 'fixture', 'manifestSHA256': 'c' * 64,
            'release': str(release), 'state': 'active', 'definitionSHA256': expected_definition,
        }
        receipt_path.write_text(json.dumps(expected) + '\n')
        receipt_path.chmod(0o600)
        backup = root / 'backup'
        backup.mkdir()
        (backup / 'checkpoint.bin').write_bytes(b'original backup')
        store_before = {
            path.relative_to(store).as_posix(): path.read_bytes()
            for path in store.rglob('*') if path.is_file()
        }
        backup_before = (backup / 'checkpoint.bin').read_bytes()
        label = 'system/ai.tractanda.server.fixture'
        run_calls = []
        def run(arguments, **_):
            run_calls.append(arguments)
            if arguments[:3] == ['/bin/launchctl', 'print', label]:
                return SimpleNamespace(returncode=0)
            if arguments[:3] == ['/bin/launchctl', 'bootout', label]:
                return SimpleNamespace(returncode=0)
            if arguments[:2] == ['/bin/ps', '-p']:
                return SimpleNamespace(returncode=1)
            raise AssertionError('Unexpected subprocess: ' + repr(arguments))

        def check_output(arguments, **_):
            if arguments[:3] == ['/bin/launchctl', 'print', label]:
                return 'service\n    pid = 4321\n'
            if arguments[:2] == ['/bin/ps', '-p']:
                return 'Mon Jan  1 00:00:00 2026 ' + str(release / 'bin/tractanda') + ' daemon\n'
            raise AssertionError('Unexpected subprocess: ' + repr(arguments))

        with patch.object(activation.subprocess, 'run', side_effect=run), \
                patch.object(activation.subprocess, 'check_output', side_effect=check_output):
            activation.retain_stopped_recovery(
                receipt_path, expected, definition, expected_definition, 'rollback reader is too old')

        self.assertEqual([call[1] for call in run_calls], ['print', 'bootout', '-p'])
        self.assertFalse(definition.exists())
        stopped = json.loads(receipt_path.read_text())
        self.assertEqual(stopped['state'], 'preparing')
        self.assertIsNone(stopped['definitionSHA256'])
        self.assertIn('rollback reader is too old', stopped['recoveryReason'])
        self.assertEqual({
            path.relative_to(store).as_posix(): path.read_bytes()
            for path in store.rglob('*') if path.is_file()
        }, store_before)
        self.assertEqual((backup / 'checkpoint.bin').read_bytes(), backup_before)

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
        self.assertEqual(
            (root / 'backup' / 'store' / self.replica_identity_name).read_bytes(),
            (store / self.replica_identity_name).read_bytes())
        self.assertEqual(proof.stat().st_mode & 0o777, 0o600)
        self.assertEqual(proof.parent.stat().st_mode & 0o777, 0o700)
        self.assertLess(before['logicalBytes'], 4096)


class RestoreStartupWaitTests(unittest.TestCase):
    def run_wait(self, root, mode='slow'):
        definition = root / 'service.plist'; client = root / 'tractanda'
        definition.write_bytes(plistlib.dumps({'ProgramArguments': [str(client), 'daemon', str(root / 'store'), str(root / 'sock')]}))
        clock = [0.0]; probes = [0]; observations = [0]
        def run(argv, **kwargs):
            if argv[0] == '/bin/launchctl':
                observations[0] += 1
                if mode == 'slow' and observations[0] == 1: raise subprocess.TimeoutExpired('observation', 5)
                text = 'state = running\npid = 123\nlast exit code = (never exited)\n'
                if mode == 'exit' and probes[0]: text = 'state = waiting\nlast exit code = 3\n'
                return subprocess.CompletedProcess(argv, 0, stdout=text, stderr='')
            self.assertEqual(argv[:4], ['/usr/bin/sudo', '-n', '-u', 'fixture-owner'])
            probes[0] += 1
            if mode == 'slow' and probes[0] == 1: raise subprocess.TimeoutExpired('bounded readiness', 5)
            if clock[0] <= 7200 or mode == 'exit': return subprocess.CompletedProcess(argv, 1, stdout='', stderr='socket not published')
            return subprocess.CompletedProcess(argv, 0, stdout=json.dumps({'server': {'executableSHA256': 'h', 'processID': 123}}), stderr='')
        with patch.object(activation, 'digest', return_value='h'), patch.object(activation.format_guard, 'require_owned_reader'), \
                patch.object(activation, 'service_pid', return_value=123), patch.object(activation.subprocess, 'run', side_effect=run), \
                patch.object(activation.time, 'monotonic', side_effect=lambda: clock[0]), \
                patch.object(activation.time, 'sleep', side_effect=lambda _: clock.__setitem__(0, clock[0] + 300)), \
                patch.object(activation, 'CANCELLED', mode == 'cancel'):
            activation.restore_service('owned', definition, 'h', client, str(root / 'sock'), 'manifest', owner='fixture-owner')
        return clock[0], probes[0]

    def test_healthy_restore_can_exceed_two_hours(self):
        with tempfile.TemporaryDirectory() as temporary:
            clock, probes = self.run_wait(Path(temporary))
            self.assertGreater(clock, 7200); self.assertEqual(probes, 25)

    def test_actual_exit_and_operator_cancellation_stop_restore(self):
        for mode, error in [('exit', RuntimeError), ('cancel', KeyboardInterrupt)]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                with self.assertRaises(error): self.run_wait(Path(temporary), mode)

class ProtectedStageTests(unittest.TestCase):
    def fixture(self, root):
        root = root.resolve(); bundle = root / 'operator-private/bundle'; (bundle / 'bin').mkdir(parents=True)
        program = bundle / 'bin/probe'
        program.write_text('#!/bin/sh\nexec /usr/bin/id -u\n'); program.chmod(0o755)
        manifest = {'files': [{'path': 'bin/probe', 'size': program.stat().st_size,
                               'sha256': activation.digest(program), 'mode': 0o755}]}
        (bundle / 'bundle-manifest.json').write_text(json.dumps(manifest)); (bundle / 'bundle-manifest.json').chmod(0o644)
        package = root / 'operator-private/release.pkg'; package.write_bytes(b'tiny public package fixture')
        return bundle, package, activation.digest(bundle / 'bundle-manifest.json'), activation.digest(package)

    @unittest.skipUnless(os.geteuid() == 0 and platform.system() == 'Darwin', 'Actual root-to-daemon macOS execution required')
    def test_real_daemon_executes_root_controlled_software_not_private_control(self):
        with tempfile.TemporaryDirectory(prefix='td-stage-uid-', dir='/private/tmp') as temporary:
            root = Path(temporary); bundle, package, manifest_hash, package_hash = self.fixture(root)
            daemon = pwd.getpwnam('daemon')
            denied = subprocess.run(['/usr/bin/sudo', '-n', '-u', 'daemon', str(bundle / 'bin/probe')], capture_output=True)
            self.assertNotEqual(denied.returncode, 0, 'Original private parent must reject daemon traversal')
            with activation.protected_candidate_stage(bundle, package, manifest_hash, package_hash) as (software, protected_package):
                result = subprocess.run(['/usr/bin/sudo', '-n', '-u', 'daemon', str(software / 'bin/probe')], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr); self.assertEqual(result.stdout.strip(), str(daemon.pw_uid))
                self.assertEqual(software.stat().st_uid, 0)
                self.assertEqual((software / 'bin/probe').stat().st_uid, 0)
                self.assertEqual(subprocess.run(['/usr/bin/sudo', '-n', '-u', 'daemon', '/bin/test', '-w', str(software)], capture_output=True).returncode, 1)
                self.assertEqual(subprocess.run(['/usr/bin/sudo', '-n', '-u', 'daemon', '/bin/test', '-r', str(protected_package)], capture_output=True).returncode, 1)
            self.assertFalse(software.parent.exists())

    def test_cleanup_failure_preserves_original_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); bundle, package, manifest_hash, package_hash = self.fixture(root)
            controlled = root / 'root-stage'; controlled.mkdir()
            with patch.object(activation.os, 'geteuid', return_value=0), patch.object(activation.os, 'chown'), \
                    patch.object(activation, 'require_capacity'), patch.object(activation.tempfile, 'mkdtemp', return_value=str(controlled)), \
                    patch.object(activation.shutil, 'rmtree', side_effect=PermissionError('secondary cleanup')):
                with self.assertRaisesRegex(RuntimeError, 'original activation error'):
                    with activation.protected_candidate_stage(bundle, package, manifest_hash, package_hash):
                        raise RuntimeError('original activation error')

    def test_external_software_symlink_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); bundle, package, manifest_hash, package_hash = self.fixture(root)
            (bundle / 'outside').symlink_to(package)
            with patch.object(activation.os, 'geteuid', return_value=0), patch.object(activation.os, 'chown'), patch.object(activation, 'require_capacity'):
                with self.assertRaises(ValueError):
                    with activation.protected_candidate_stage(bundle, package, manifest_hash, package_hash):
                        self.fail('Escaped software tree was admitted')

if __name__ == '__main__':
    unittest.main()
