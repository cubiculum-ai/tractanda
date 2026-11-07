#!/usr/bin/env python3
"""Tiny source-contract tests. Never execute dpkg, Setup, systemd or a model."""
import importlib.util
import json
import os
from pathlib import Path
import io
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import contextlib

spec = importlib.util.spec_from_file_location('deb_validation', Path(__file__).with_name('verify-linux-deb.py'))
V = importlib.util.module_from_spec(spec); spec.loader.exec_module(V)


class ValidationTests(unittest.TestCase):
    def setUp(self):
        fs = os.statvfs(tempfile.gettempdir())
        self.assertGreaterEqual(fs.f_frsize * fs.f_bavail, V.RESERVE + 64 * 1024)
        self.tmp = tempfile.TemporaryDirectory(prefix='tractanda-d5-source-')
        self.addCleanup(self.tmp.cleanup); self.root = Path(self.tmp.name)

    def test_timeout_cli_defaults_overrides_and_rejects_nonpositive_or_nonfinite_values(self):
        args = ['verify-linux-deb.py', '--package', 'fixture.deb']
        with patch.object(V.sys, 'argv', args), contextlib.redirect_stdout(io.StringIO()) as output:
            V.main()
        self.assertEqual(json.loads(output.getvalue())['timeoutSeconds'], 24 * 60 * 60)
        self.assertEqual(json.loads(output.getvalue())['commandTimeoutSeconds'], 24 * 60 * 60)
        with patch.object(V.sys, 'argv', args + ['--timeout-seconds', '7200', '--command-timeout-seconds', '14400']), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            V.main()
        parsed = json.loads(output.getvalue())
        self.assertEqual(parsed['timeoutSeconds'], 7200)
        self.assertEqual(parsed['commandTimeoutSeconds'], 7200)
        for invalid in ('0', '-1', 'nan', 'inf'):
            with self.subTest(invalid=invalid), patch.object(V.sys, 'argv', args + ['--timeout-seconds', invalid]), \
                    contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                V.main()

    def test_command_budget_is_capped_by_whole_validation_budget(self):
        check = V.Validation({'runID': '012345abcdef'}, self.root, 1800, 7200)
        self.assertEqual(check.timeout_seconds, 1800)
        self.assertEqual(check.command_timeout_seconds, 1800)
        short = V.Validation({'runID': '012345abcdef'}, self.root, 7200, 5400)
        self.assertEqual(short.command_timeout_seconds, 5400)

    def test_command_uses_remaining_whole_run_budget(self):
        check = V.Validation({'runID': '012345abcdef'}, self.root, 100, 90)
        check.deadline = 100.0
        class Process:
            pid = 999998
            def __init__(self, _argv, **kwargs):
                kwargs['stdout'].write(b'bounded command\n')
            def poll(self): return 0
            def wait(self): return 0
        with patch.object(check, 'guard'), patch.object(V.time, 'monotonic', side_effect=[40.0, 41.0, 42.0]), \
                patch.object(V.subprocess, 'Popen', Process), patch.object(V.os, 'killpg'):
            check.command(['/fixed/mock'], timeout=check.command_timeout_seconds)
        self.assertEqual(check.result['commands'][0]['timeoutSeconds'], 60.0)

    def package(self):
        p = self.root / 'fixture.deb'; p.write_bytes(b'synthetic fixture, not a Debian archive')
        names = ['bin/' + n for n in ('tractanda', 'tractanda-tui', 'tractanda-mcp', 'tractanda-setup',
                 'tractanda-auth-helper', 'tractanda-embeddings', 'tractanda-document-converter')]
        names += ['models/granite-embedding-311m-multilingual-r2/model.safetensors',
                  'models/granite-docling-258m-mlx/model.safetensors', 'bundle-manifest.json']
        receipt = {'packageSHA256': V.digest(p), 'packageBytes': p.stat().st_size,
                   'bundleManifestSHA256': 'a' * 64, 'version': '0.1.0~poc.14-1', 'arch': 'amd64',
                   'installedKiB': 1, 'inventory': [{'path': 'opt/tractanda/current/' + n, 'sha256': 'a' * 64} for n in names]}
        Path(str(p) + '.inventory.json').write_text(json.dumps(receipt)); return p, receipt

    def test_package_is_bound_to_d3_bytes_and_full_capability_inventory(self):
        p, _ = self.package(); self.assertEqual(V.artifact(p)['serverSHA256'], 'a' * 64)
        p.write_bytes(b'altered')
        with self.assertRaisesRegex(ValueError, 'differs'): V.artifact(p)

    def test_core_only_artifact_is_not_accepted_as_finished_package(self):
        p, r = self.package(); r['inventory'] = [x for x in r['inventory'] if '/models/' not in x['path']]
        Path(str(p) + '.inventory.json').write_text(json.dumps(r))
        with self.assertRaisesRegex(ValueError, 'Both bundled models'): V.artifact(p)

    def test_slim_artifact_requires_workers_and_catalog_but_no_weight_trees(self):
        p, receipt = self.package()
        receipt['inventory'] = [x for x in receipt['inventory'] if '/models/' not in x['path']]
        receipt['inventory'].append({'path': 'opt/tractanda/current/models/manifest.json', 'sha256': 'b' * 64})
        Path(str(p) + '.inventory.json').write_text(json.dumps(receipt))
        self.assertEqual(V.artifact(p, 'slim')['serverSHA256'], 'a' * 64)
        receipt['inventory'].append({'path': 'opt/tractanda/current/models/granite-docling-258m-mlx/partial', 'sha256': 'c' * 64})
        Path(str(p) + '.inventory.json').write_text(json.dumps(receipt))
        with self.assertRaisesRegex(ValueError, 'omit both'): V.artifact(p, 'slim')

    def test_explicit_guest_and_bound_manifest_baseline_are_not_interchangeable(self):
        V.require_guest_baseline('kali-rolling', {'ID': 'kali', 'VERSION_ID': '2026.3', 'VERSION_CODENAME': 'kali-rolling'})
        V.require_guest_baseline('debian13', {'ID': 'debian', 'VERSION_ID': '13'})
        with self.assertRaisesRegex(ValueError, 'baseline'): V.require_guest_baseline('debian13', {'ID': 'kali'})
        with self.assertRaisesRegex(ValueError, 'baseline'): V.require_guest_baseline('kali-rolling', {'ID': 'debian', 'VERSION_ID': '13'})
        path = self.root / 'manifest.json'; path.write_text(json.dumps({'linuxBuildOS': 'kali-rolling'}))
        package = {'receipt': {'bundleManifestSHA256': V.digest(path)}}
        V.require_package_baseline(package, 'kali-rolling', path)
        with self.assertRaisesRegex(ValueError, 'baseline'): V.require_package_baseline(package, 'debian13', path)
        path.write_text('{}')
        with self.assertRaisesRegex(ValueError, 'commitment'): V.require_package_baseline(package, 'kali-rolling', path)

    def test_slim_context_requires_first_source_offline_inputs(self):
        value = {'schema': 'tractanda.package-validation.v1', 'runID': '012345abcdef',
                 'fixtureCapBytes': V.FIXTURE_CAP, 'reserveBytes': V.RESERVE,
                 'softwareAllowanceBytes': 32 * 1024**3, 'selection': 'first-source',
                 'port': 49179, 'expiresAt': time.time() + 600, 'buildOS': 'kali-rolling',
                 'artifactBindings': {'package': {'payloadMode': 'slim'}}, 'uuidNode': '00:11:22:33:44:55', 'offlineModelSource': '/inputs/models', 'offlineModelCatalog': '/inputs/catalog.json'}
        V.validate_context(value)
        with self.assertRaisesRegex(ValueError, 'sample'): V.validate_context(dict(value, selection='prepared'))
        with self.assertRaisesRegex(ValueError, 'absolute'): V.validate_context(dict(value, offlineModelSource='relative'))
        with self.assertRaisesRegex(ValueError, 'binding'): V.validate_context(dict(value, artifactBindings=None))
        with self.assertRaisesRegex(ValueError, 'UUID node'): V.validate_context({k: v for k, v in value.items() if k != 'uuidNode'})

    def test_slim_catalog_and_status_require_exact_artifact_set(self):
        names = ['granite-embedding-311m-multilingual-r2', 'granite-docling-258m-mlx']
        path = self.root / 'catalog.json'
        path.write_text(json.dumps({'artifacts': [{'identifier': n, 'files': [{'size': 17}]} for n in names]}))
        manifest = {'modelProvisioningManifestSHA256': V.digest(path)}
        self.assertEqual(V.model_catalog_bytes(path, manifest), 34)
        status = [{'artifact': n, 'phase': 'ready'} for n in names]
        self.assertTrue(V.model_status_complete(status, True))
        self.assertFalse(V.model_status_complete([status[0], status[0]], True))
        self.assertFalse(V.model_status_complete(status, False))
        path.write_text('{}')
        with self.assertRaisesRegex(ValueError, 'commitment'): V.model_catalog_bytes(path, manifest)

    def test_artifact_roles_preserve_debian_old_and_kali_target_provenance(self):
        old, old_receipt = self.package()
        new = self.root / 'new.deb'; new.write_bytes(b'new package fixture')
        old_manifest = self.root / 'old.json'; old_manifest.write_text('{}')
        new_manifest = self.root / 'new.json'; new_manifest.write_text(json.dumps({'linuxBuildOS': 'kali-rolling'}))
        def item(path, mode):
            return {'path': path, 'receipt': {'packageSHA256': V.digest(path),
                    'bundleManifestSHA256': V.digest(old_manifest if path == old else new_manifest)}, 'serverSHA256': 'a' * 64}
        context = {'artifactBindings': {
            'package': {'packageSHA256': V.digest(old), 'manifest': str(old_manifest), 'buildOS': 'debian13', 'payloadMode': 'slim'},
            'upgrade': {'packageSHA256': V.digest(new), 'manifest': str(new_manifest), 'buildOS': 'kali-rolling', 'payloadMode': 'slim'}}}
        with patch.object(V, 'artifact', side_effect=item):
            result = V.bind_artifacts(context, [('package', old), ('upgrade', new)])
            self.assertEqual([p['buildOS'] for p in result], ['debian13', 'kali-rolling'])
            V.require_target_baseline('kali-rolling', result)
            with self.assertRaisesRegex(ValueError, 'Target package'): V.require_target_baseline('kali-rolling', result[:1])
            bad = json.loads(json.dumps(context)); bad['artifactBindings']['package']['buildOS'] = 'kali-rolling'
            with self.assertRaisesRegex(ValueError, 'baseline'): V.bind_artifacts(bad, [('package', old), ('upgrade', new)])
            with self.assertRaisesRegex(ValueError, 'roles'): V.bind_artifacts(context, [('package', old)])

    def test_revision_or_filename_changes_are_not_an_older_binary(self):
        first = {'serverSHA256': 'a' * 64, 'receipt': {'packageSHA256': 'b' * 64}}
        second = {'serverSHA256': 'a' * 64, 'receipt': {'packageSHA256': 'c' * 64}}
        with self.assertRaisesRegex(ValueError, 'different binary'): V.distinct_binary(first, second)

    def test_actual_reader_requirement_not_semver_decides_refusal_applicability(self):
        support = {'profile': 'tractanda.canonical-formats.v1', 'readerLevel': 14, 'read': [1, 2], 'capabilities': ['one']}
        required = {'profile': 'tractanda.canonical-reader.v1', 'minimumReaderLevel': 11, 'recordFormats': [1], 'capabilities': ['one']}
        self.assertTrue(V.can_read(support, required))
        self.assertFalse(V.can_read(dict(support, readerLevel=10), required))
        self.assertFalse(V.can_read(dict(support, capabilities=[]), required))

    def test_hidden_canonical_credentials_and_custody_are_preserved_without_copy(self):
        secret = self.root / '.private'; secret.write_bytes(b'owned test fixture')
        secret.chmod(0o600); before = V.inventory([self.root])
        self.assertNotIn('owned test fixture', json.dumps(before))
        V.retained(before, V.inventory([self.root]))
        secret.chmod(0o644)
        with self.assertRaisesRegex(ValueError, 'custody'): V.retained(before, V.inventory([self.root]))

    def test_snapshot_rejects_links_and_fixture_growth(self):
        f = self.root / 'file'; f.write_bytes(b'five!')
        (self.root / 'link').symlink_to(f)
        with self.assertRaisesRegex(ValueError, 'special'): V.inventory([self.root])
        (self.root / 'link').unlink()
        with patch.object(V, 'FIXTURE_CAP', 4), self.assertRaisesRegex(ValueError, 'cap'): V.inventory([self.root])

    def test_only_transient_checkpoint_marker_may_vanish_during_soft_monitor(self):
        marker = self.root / '.tractanda-checkpoint-dirty'
        other = self.root / 'other'
        for target, hashes, allowed in ((marker, False, True), (marker, True, False), (other, False, False)):
            target.write_bytes(b'x')
            def disappearing_walk(root, **kwargs):
                target.unlink()
                yield str(root), [], [target.name]
            with self.subTest(target=target.name, hashes=hashes), patch.object(V.os, 'walk', disappearing_walk):
                if allowed:
                    self.assertNotIn(str(target), V.inventory([self.root], hashes=hashes))
                else:
                    with self.assertRaises(FileNotFoundError):
                        V.inventory([self.root], hashes=hashes)

    def test_nested_checkpoint_marker_disappearance_is_not_suppressed(self):
        nested = self.root / 'nested'
        nested.mkdir()
        marker = nested / '.tractanda-checkpoint-dirty'
        marker.write_bytes(b'x')
        def disappearing_walk(root, **kwargs):
            yield str(root), ['nested'], []
            marker.unlink()
            yield str(nested), [], [marker.name]
        with patch.object(V.os, 'walk', disappearing_walk), self.assertRaises(FileNotFoundError):
            V.inventory((root for root in [self.root]), hashes=False)

    def test_regular_managed_leaf_has_presence_and_deletion_witness(self):
        leaf = self.root / 'd5-012345abcdef.json'
        absent = V.inventory([leaf]); self.assertEqual(absent[str(leaf)]['kind'], 'absent')
        leaf.write_bytes(b'owned managed configuration fixture'); leaf.chmod(0o600)
        present = V.inventory([leaf]); self.assertEqual(present[str(leaf)]['kind'], 'file')
        with self.assertRaisesRegex(ValueError, 'record set'): V.retained(absent, present)
        leaf.unlink()
        with self.assertRaisesRegex(ValueError, 'record set'): V.retained(present, V.inventory([leaf]))

    def test_directory_custody_is_recorded_but_timestamps_are_not_identity(self):
        private = self.root / '.peer-credentials'; private.mkdir(mode=0o700)
        (private / 'fixture.key').write_bytes(b'owned private fixture')
        before = V.inventory([self.root])
        os.utime(private, (1000, 1000)); V.retained(before, V.inventory([self.root]))
        private.chmod(0o755)
        with self.assertRaisesRegex(ValueError, 'custody'): V.retained(before, V.inventory([self.root]))

    def test_directory_owner_change_is_not_ignored(self):
        before = V.inventory([self.root]); real = Path.lstat
        def changed(path, *args, **kwargs):
            value = real(path, *args, **kwargs)
            if path == self.root:
                from types import SimpleNamespace
                return SimpleNamespace(st_mode=value.st_mode, st_uid=value.st_uid + 1, st_gid=value.st_gid)
            return value
        with patch.object(Path, 'lstat', changed): after = V.inventory([self.root])
        with self.assertRaisesRegex(ValueError, 'custody'): V.retained(before, after)

    def test_snapshot_reports_actual_private_coverage_including_absence(self):
        check = V.Validation({'runID': '012345abcdef'}, self.root)
        self.assertEqual(check.private.name, check.name + '.json')
        check.store = self.root / 'store'; check.store.mkdir(mode=0o700)
        check.private = self.root / 'peer-runtime' / (check.name + '.json')
        for name in ('.tractanda-store-identity.json', '.tractanda-replica-identity.json', 'fixture.tractanda'):
            (check.store / name).write_bytes(b'owned non-native canonical fixture')
        check.snapshot()
        self.assertEqual(check.result['privateCoverage']['managedPeerConfiguration'], 'absent')
        self.assertEqual(check.result['privateCoverage']['canonicalCredentialFiles'], 0)
        keys = check.store / '.peer-credentials'; keys.mkdir(mode=0o700)
        (keys / 'fixture.key').write_bytes(b'owned private fixture')
        check.private.parent.mkdir(mode=0o700); check.private.write_bytes(b'owned managed config fixture')
        check.snapshot()
        self.assertEqual(check.result['privateCoverage']['managedPeerConfiguration'], 'file')
        self.assertEqual(check.result['privateCoverage']['canonicalCredentialFiles'], 1)

    def test_appended_deletion_or_other_history_is_not_data_preservation(self):
        (self.root / 'old.tractanda').write_bytes(b'owned history fixture')
        before = V.inventory([self.root])
        (self.root / 'new.tractanda').write_bytes(b'owned appended record fixture')
        with self.assertRaisesRegex(ValueError, 'record set'): V.retained(before, V.inventory([self.root]))

    def test_context_has_fixed_reserve_and_independent_software_budget(self):
        value = {'schema': 'tractanda.package-validation.v1', 'runID': '012345abcdef',
                 'fixtureCapBytes': V.FIXTURE_CAP, 'reserveBytes': V.RESERVE,
                 'softwareAllowanceBytes': 32 * 1024**3, 'selection': 'first-source',
                 'port': 49179, 'expiresAt': time.time() + 600}
        V.validate_context(value)
        with self.assertRaisesRegex(ValueError, 'fixed'): V.validate_context(dict(value, reserveBytes=1))
        with self.assertRaisesRegex(ValueError, 'validity'): V.validate_context(dict(value, expiresAt=0))

    def test_context_uuid_node_rejects_nonhardware_values_and_accepts_synthetic_hardware(self):
        base = {'schema': 'tractanda.package-validation.v1', 'runID': '012345abcdef',
                'fixtureCapBytes': V.FIXTURE_CAP, 'reserveBytes': V.RESERVE,
                'softwareAllowanceBytes': 32 * 1024**3, 'selection': 'first-source',
                'port': 49179, 'expiresAt': time.time() + 600}
        for node in ('00:11:22:33:44:55', '001122334455'):
            V.validate_context(dict(base, uuidNode=node))
        for node in (None, True, 123, '', '00:00:00:00:00:00', '01:11:22:33:44:55',
                     '02:11:22:33:44:55', 'ff:ff:ff:ff:ff:ff', '00:11:22:33:44', '00112233445566',
                     '00:11:22:33:44:gg', '00:11:22:33:44:55;other'):
            with self.subTest(node=node), self.assertRaisesRegex(ValueError, 'hardware MAC'):
                V.validate_context(dict(base, uuidNode=node))

    def test_setup_forwards_only_context_hardware_node_through_normal_option(self):
        context = {'owner': 'fixture-owner', 'port': 49179, 'selection': 'first-source'}
        with patch.dict(os.environ, {'TRACTANDA_UUID_NODE': '02:11:22:33:44:55'}):
            without = V.setup_arguments(context, 'd5-012345abcdef')
            with_node = V.setup_arguments(dict(context, uuidNode='00:11:22:33:44:55'), 'd5-012345abcdef')
        self.assertNotIn('--uuid-node', without)
        self.assertEqual(with_node[with_node.index('--uuid-node') + 1], '00:11:22:33:44:55')
        self.assertEqual(with_node[-2:], ['--first-source', '--sample'])
        prepared = V.setup_arguments(dict(context, selection='prepared', uuidNode='001122334455',
                                         storeID='fixture-store', replicaID='fixture-replica'), 'd5-012345abcdef')
        self.assertEqual(prepared[prepared.index('--uuid-node') + 1], '001122334455')
        self.assertEqual(prepared[-6:], ['--adopt-prepared', '--store-id', 'fixture-store',
                                        '--replica-id', 'fixture-replica', '--empty'])
        with self.assertRaisesRegex(ValueError, 'hardware MAC'):
            V.setup_arguments(dict(context, uuidNode='02:11:22:33:44:55'), 'd5-012345abcdef')

    def test_owned_policy_fixture_is_removed_and_foreign_bytes_are_retained(self):
        # Policy path is fixed in production; redirect only this test's Path constructor.
        real_path = V.Path; policy = self.root / 'policy'
        with patch.object(V, 'Path', side_effect=lambda p: policy if p == '/usr/sbin/policy-rc.d' else real_path(p)):
            with V.denied_policy('012345abcdef'): self.assertIn(b'exit 101', policy.read_bytes())
            self.assertFalse(policy.exists())
            with self.assertRaisesRegex(ValueError, 'drifted'):
                with V.denied_policy('012345abcdef'): policy.write_bytes(b'foreign fixture change')
            self.assertEqual(policy.read_bytes(), b'foreign fixture change')

    def test_ready_binds_native_binary_version_pid_and_process_instance(self):
        c = V.Validation({'runID': '012345abcdef'}, self.root)
        package = {'serverSHA256': 'a' * 64}
        info = {'server': {'executableSHA256': 'a' * 64, 'version': 'fixture', 'processID': 12, 'instanceID': 'new'},
                'accessMode': 'multi-user', 'callerIsAdministrator': True}
        responses = ['LoadState=loaded\nActiveState=active\nMainPID=12\n', json.dumps(info), 'active', 'active', 'active']
        with patch.object(c, 'command', side_effect=responses) as command, patch.object(V, 'read_json', return_value={'version': 'fixture'}):
            c.ready(package, {'instanceID': 'old', 'processID': 11})
        self.assertEqual(command.call_args_list[1].kwargs, {'server_probe': True})
        info['server']['executableSHA256'] = 'b' * 64
        with patch.object(c, 'command', side_effect=[responses[0], json.dumps(info)]), patch.object(V, 'read_json', return_value={'version': 'fixture'}):
            with self.assertRaisesRegex(ValueError, 'old/unbound'): c.ready(package)

    def test_stopped_accepts_missing_registration_but_rejects_live_support_role(self):
        c = V.Validation({'runID': '012345abcdef'}, self.root)
        with patch.object(c, 'command', return_value='LoadState=not-found\nActiveState=inactive\nMainPID=0\n'): c.stopped()
        with patch.object(c, 'command', side_effect=['LoadState=loaded\nActiveState=inactive\nMainPID=0\n',
                                                   'LoadState=loaded\nActiveState=active\nMainPID=9\n']):
            with self.assertRaisesRegex(ValueError, 'not stopped'): c.stopped()

    def test_pending_or_failed_configuration_must_also_block_boot(self):
        c = V.Validation({'runID': '012345abcdef'}, self.root)
        with patch.object(c, 'command', return_value='LoadState=loaded\nActiveState=inactive\nMainPID=0\nUnitFileState=enabled\n'):
            with self.assertRaisesRegex(ValueError, 'boot'): c.stopped(disabled=True)

    def test_systemd_status_allows_blank_lines_but_rejects_bad_or_duplicate_fields(self):
        status = 'LoadState=loaded\nActiveState=active\nMainPID=422\nUnitFileState=enabled\n\n'
        self.assertEqual(V.status_fields(status)['MainPID'], '422')
        for value in ('LoadState=loaded\ninvalid\n', 'MainPID=1\nMainPID=2\n', '=value\n'):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'Malformed or duplicate'):
                V.status_fields(value)

    def test_missing_boot_state_is_not_proof_of_disabled_loaded_service(self):
        c = V.Validation({'runID': '012345abcdef'}, self.root)
        with patch.object(c, 'command', return_value='LoadState=loaded\nActiveState=inactive\nMainPID=0\n'):
            with self.assertRaisesRegex(ValueError, 'boot'): c.stopped(disabled=True)

    def test_native_probe_actual_launch_environment_binds_daemon_without_inheritance(self):
        c = V.Validation({'runID': '012345abcdef'}, self.root); launched = []
        class Process:
            pid = 999999
            def __init__(self, argv, **kwargs):
                launched.append(kwargs['env']); kwargs['stdout'].write(b'{}'); kwargs['stdout'].flush()
            def poll(self): return 0
            def wait(self): return 0
        argv = [V.CLI, '--no-start', '--socket', '/run/tractanda/' + c.name + '/server.sock', 'info']
        with patch.object(c, 'guard'), patch.object(V.subprocess, 'Popen', Process), patch.object(V.os, 'killpg'), \
             patch.dict(os.environ, {'TRACTANDA_SERVER_USER': 'root', 'LD_PRELOAD': 'foreign'}):
            c.command(argv, server_probe=True)
        self.assertEqual(launched[0]['TRACTANDA_SERVER_USER'], 'daemon')
        self.assertNotIn('LD_PRELOAD', launched[0])
        self.assertEqual(c.result['commands'][0]['serverUser'], 'daemon')

    def test_dpkg_and_setup_receive_only_validated_context_uuid_node(self):
        for argv in (["/usr/bin/dpkg", "--install", "/fixture.deb"], [V.SETUP, "status", "--name", "fixture"]):
            for node in (None, "38:05:25:32:10:ca"):
                with self.subTest(argv=argv, node=node), tempfile.TemporaryDirectory() as temp:
                    context = {"runID": "012345abcdef"}
                    if node is not None:
                        context["uuidNode"] = node
                    check = V.Validation(context, Path(temp)); launched = []
                    class Process:
                        pid = 123
                        returncode = 0
                        def __init__(self, *args, **kwargs): launched.append(kwargs["env"])
                        def wait(self, timeout=None): return 0
                        def poll(self): return 0
                    with patch.object(check, "guard"), patch.object(V.subprocess, "Popen", Process), \
                         patch.dict(os.environ, {"TRACTANDA_UUID_NODE": "foreign", "LD_PRELOAD": "foreign"}):
                        check.command(argv)
                    self.assertEqual(launched[0].get("TRACTANDA_UUID_NODE"), node)
                    self.assertNotIn("LD_PRELOAD", launched[0])

    def test_invalid_context_uuid_node_refuses_before_launch(self):
        check = V.Validation({"runID": "012345abcdef", "uuidNode": "02:00:00:00:00:01"}, self.root)
        with patch.object(check, "guard"), patch.object(V.subprocess, "Popen") as launch:
            with self.assertRaisesRegex(ValueError, "globally administered"):
                check.command(["/usr/bin/dpkg", "--install", "/fixture.deb"])
            launch.assert_not_called()

    def test_echoed_canonical_filename_and_unrelated_failure_never_pass_refusal(self):
        c = V.Validation({'runID': '012345abcdef'}, self.root)
        def failed(argv, **kwargs):
            self.assertTrue(kwargs['failure'])
            c.result['commands'].append({'log': '/fixed/dpkg-refusal.log'})
            return 'dpkg: error processing archive /inputs/canonical-old.deb: dependency failure'
        with patch.object(c, 'command', side_effect=failed), patch.object(c, 'stopped') as stopped:
            result = c.attempt_older_refusal({'path': Path('/inputs/canonical-old.deb'),
                                            'receipt': {'bundleManifestSHA256': 'a' * 64}})
        self.assertEqual(result['status'], 'REVIEW_REQUIRED')
        self.assertEqual(result['log'], '/fixed/dpkg-refusal.log')
        stopped.assert_called_once_with(disabled=True)

    def test_review_required_execution_is_not_a_successful_cli_exit(self):
        with patch.object(V.sys, 'argv', ['verify-linux-deb.py', '--package', '/unused.deb', '--execute']), \
             patch.object(V.signal, 'signal'), patch.object(V, 'execute', return_value=False):
            with self.assertRaises(SystemExit) as exit_status: V.main()
        self.assertEqual(exit_status.exception.code, 2)

    def test_fast_expected_failure_is_recorded_guarded_and_reaped(self):
        c = V.Validation({'runID': '012345abcdef'}, self.root)
        class Process:
            pid = 999999
            def __init__(self, argv, **kwargs):
                kwargs['stdout'].write(b'controlled fixture failure\n')
                kwargs['stdout'].flush()  # Real child writes use the inherited OS descriptor.
            def poll(self): return 7
            def wait(self): return 7
        with patch.object(c, 'guard') as guard, patch.object(V.subprocess, 'Popen', Process), \
             patch.object(V.os, 'killpg') as kill:
            self.assertIn('controlled fixture', c.command(['/fixed/mock'], failure=True,
                                                           timeout=c.command_timeout_seconds))
        self.assertGreaterEqual(guard.call_count, 2)
        kill.assert_called_once_with(999999, V.signal.SIGKILL)
        self.assertEqual(V.read_json(self.root / 'RESULT.json')['commands'][0]['exit'], 7)
        recorded_timeout = V.read_json(self.root / 'RESULT.json')['commands'][0]['timeoutSeconds']
        self.assertLessEqual(recorded_timeout, c.command_timeout_seconds)
        self.assertGreater(recorded_timeout, c.command_timeout_seconds - 1)


if __name__ == '__main__': unittest.main(verbosity=2)
