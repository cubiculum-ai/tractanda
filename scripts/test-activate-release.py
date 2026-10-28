#!/usr/bin/env python3
"""Offline managed binary-upgrade checks; no installation or service mutation."""
import contextlib
import copy
import importlib.util
import json
import os
from pathlib import Path
import platform
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


class UpgradeTests(unittest.TestCase):
    def test_obsolete_releases_preserves_current_previous_and_other_instance_references(self):
        receipt = {'release': '/current', 'releases': {
            '/current': 'a', '/previous': 'b', '/shared': 'c', '/older': 'd'}}
        other = {'release': '/shared', 'releases': {'/shared': 'c'}}
        self.assertEqual(activation.obsolete_releases(receipt, '/previous', [other]), {'/older': 'd'})

    def fixture(self):
        temporary = tempfile.TemporaryDirectory(prefix='activation-upgrade-')
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name).resolve()
        store = root / 'store'; store.mkdir(mode=0o700)
        identity = str(uuid.uuid1())
        for name, value in {
            '.tractanda-store-identity.json': {'formatVersion': 1, 'storeID': identity},
            'canonical-reader.json': {'profile': activation.format_guard.MARKER_PROFILE,
                'storeID': identity, 'minimumReaderLevel': 1, 'recordFormats': [1], 'capabilities': []},
        }.items():
            path = store / name; path.write_text(json.dumps(value)); path.chmod(0o600)
        return root, store

    def candidate(self, default=True):
        root, store = self.fixture()
        bundle = root / 'bundle'; (bundle / 'bin').mkdir(parents=True)
        (bundle / 'bin/tractanda-setup').write_bytes(b'never executed')
        (bundle / 'bundle-manifest.json').write_text(json.dumps({'files': []}))
        package = root / 'candidate.pkg'; package.write_bytes(b'never installed')
        base = root / 'managed/Software'; base.mkdir(parents=True)
        (base.parent / 'Installation/receipts').mkdir(parents=True)
        (base.parent / 'Configuration').mkdir()
        (base.parent / 'Configuration/connections.json').write_text(json.dumps({'defaultProfile': 'production' if default else 'other'}))
        receipt = {'state': 'active', 'instance': 'production', 'store': str(store),
                   'indexDirectory': str(root / 'index'), 'owner': 'rcfa', 'port': 48728,
                   'socket': str(root / 'server.sock'), 'manifestSHA256': 'old',
                   'release': str(base / 'releases/old'), 'releases': {}}
        receipt_path = base.parent / 'Installation/receipts/production.json'; receipt_path.write_text(json.dumps(receipt))
        args = SimpleNamespace(bundle=bundle, package=package, instance='production',
                    manifest_sha256=activation.digest(bundle / 'bundle-manifest.json'),
                    package_sha256=activation.digest(package))
        updated = {**receipt, 'release': str(base / 'releases/new'), 'manifestSHA256': args.manifest_sha256}
        return base, receipt_path, receipt, args, updated

    def activate(self, fixture, change=None, failure=None):
        base, receipt_path, receipt, args, updated = fixture
        calls = []
        def run(argv, **kwargs):
            calls.append(argv)
            if argv[0] == '/usr/sbin/installer' or 'upgrade' in argv:
                if failure: raise failure
                if change: change(updated)
                receipt_path.write_text(json.dumps(updated))
        with patch.object(activation, 'active_installation', return_value=(base, receipt_path, receipt)), \
             patch.object(activation.subprocess, 'run', side_effect=run), \
             patch.object(activation, 'prune_releases', return_value=[]), \
             patch.object(activation.os, 'walk', side_effect=AssertionError('No canonical inventory/copy')), \
             contextlib.redirect_stdout(__import__('io').StringIO()) as output:
            activation.activate_candidate(args)
        return calls, json.loads(output.getvalue())

    def test_default_and_named_upgrade_only_delegate_installation_to_setup(self):
        for default in (True, False):
            with self.subTest(default=default):
                fixture = self.candidate(default)
                store = Path(fixture[2]['store'])
                # Ordinary content, credentials and pending files are never traversed.
                for name in ('items', 'credentials', 'pending'):
                    (store / name).mkdir(); (store / name / 'opaque').write_bytes(b'unchanged')
                before = {str(p): p.read_bytes() for p in store.glob('*/*')}
                calls, result = self.activate(fixture)
                self.assertEqual(sum(c[0] == '/usr/sbin/installer' or 'upgrade' in c for c in calls), 1)
                self.assertFalse(any('launchctl' in c[0] or '--canonical-reader-admit' in c for c in calls))
                self.assertEqual(result['status'], 'passed'); self.assertNotIn('backupProof', result)
                self.assertEqual(before, {str(p): p.read_bytes() for p in store.glob('*/*')})

    def test_incompatible_candidate_stops_before_installer(self):
        fixture = self.candidate(); store = Path(fixture[2]['store'])
        marker = store / 'canonical-reader.json'; value = json.loads(marker.read_text())
        value.update(minimumReaderLevel=2, recordFormats=[1, 2]); marker.write_text(json.dumps(value))
        with self.assertRaisesRegex(RuntimeError, 'newer reader'):
            self.activate(fixture)
        self.assertEqual(json.loads(fixture[1].read_text())['manifestSHA256'], 'old')

    def test_failed_installer_is_not_reported_ready_or_restarted_by_python(self):
        fixture = self.candidate()
        with self.assertRaisesRegex(RuntimeError, 'installer failed'):
            self.activate(fixture, failure=RuntimeError('installer failed'))
        self.assertEqual(json.loads(fixture[1].read_text())['manifestSHA256'], 'old')

    def test_installer_success_requires_active_candidate_and_same_installation(self):
        for key, value in (('state', 'failed'), ('manifestSHA256', 'wrong'), ('store', '/other'),
                           ('indexDirectory', '/other'), ('owner', 'other'), ('port', 1), ('socket', '/other')):
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                self.activate(self.candidate(), change=lambda r: r.update({key: value}))

    def test_marker_cannot_move_backwards_or_change_store_identity(self):
        fixture = self.candidate(); marker = Path(fixture[2]['store']) / 'canonical-reader.json'
        def change(_):
            value = json.loads(marker.read_text()); value['storeID'] = str(uuid.uuid1())
            marker.write_text(json.dumps(value))
        with self.assertRaises(RuntimeError): self.activate(fixture, change=change)

    def test_changed_package_cannot_reach_installer(self):
        fixture = self.candidate(); fixture[3].package.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'native package changed'): self.activate(fixture)

    def test_unknown_capacity_and_reserve_reject(self):
        with self.assertRaises(RuntimeError): activation.require_capacity(Path('/unused'), 1, lambda _: 0)
        with self.assertRaises(RuntimeError): activation.require_capacity(Path('/unused'), activation.STAGING_COPY_CAP + 1, lambda _: 10**15)

    def test_symlink_hashing_rejects(self):
        root, _ = self.fixture(); target = root / 'target'; target.write_bytes(b'value')
        link = root / 'link'; link.symlink_to(target)
        with self.assertRaises(OSError): activation.digest(link)

    def test_preparing_receipt_stops_before_any_activation_or_service_subprocess(self):
        root, _ = self.fixture()
        real_path_type = activation.Path
        managed_root = Path('/Library/Tractanda/Software')
        fake_root = root / 'managed/Software'
        receipt_path = fake_root.parent / 'Installation/receipts/production.json'
        receipt_path.parent.mkdir(parents=True)
        receipt_path.write_text(json.dumps({'state': 'preparing'}))
        receipt_path.chmod(0o600)

        def mapped_path(value, *args, **kwargs):
            raw = os.fspath(value)
            prefix = '/Library/Tractanda'
            if raw == prefix or raw.startswith(prefix + os.sep):
                raw = os.fspath(fake_root.parent) + raw[len(prefix):]
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
            with patch.object(activation.os, 'geteuid', return_value=0), patch.object(activation.os, 'chown'), patch.object(activation, 'require_capacity'), \
                    patch.object(activation.tempfile, 'mkdtemp', return_value=str(root / 'stage')):
                (root / 'stage').mkdir()
                with self.assertRaises(ValueError):
                    with activation.protected_candidate_stage(bundle, package, manifest_hash, package_hash):
                        self.fail('Escaped software tree was admitted')

if __name__ == '__main__':
    unittest.main()
