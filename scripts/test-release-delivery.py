#!/usr/bin/env python3
"""Tiny synthetic asset/receipt and mocked release-flow checks; no releases."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import uuid
from types import SimpleNamespace
from unittest.mock import call, patch, Mock

spec = importlib.util.spec_from_file_location('delivery_release', Path(__file__).with_name('release-macos.py'))
R = importlib.util.module_from_spec(spec); spec.loader.exec_module(R)
D = R.delivery
V = '0.1.0-poc.15'


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='tractanda-release-delivery-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.context = {'files': [{'path': 'Sources/Core.swift', 'size': 1, 'mode': 0o644, 'sha256': 'a' * 64}],
                        'buildOS': 'kali-rolling',
                        'components': {a: {'embeddings': 'e' * 64, 'documents': 'd' * 64} for a in D.ARCHES},
                        'flags': {a: ['-march=' + ('x86-64' if a == 'amd64' else 'armv8-a'), '-target-cpu', 'generic',
                                      '--build-system', 'native', '-num-threads', '4'] for a in D.ARCHES}}
        self.state = {'directory': str(self.root / 'candidate'), 'version': V, 'commit': 'a' * 40, 'tree': 'b' * 40,
                      'status': 'ready', 'configuration': {'repository': 'owner/repo', 'instance': 'production',
                                                          'softwareRoot': str(self.root / 'installed')}, 'steps': {},
                      'notes': 'candidate fixture', 'delivery': D.fresh()}
        Path(self.state['directory']).mkdir()
        self.raven = {'storeID': str(uuid.uuid1()), 'replicaID': str(uuid.uuid1())}

    def write(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(D.canonical(value) + b'\n')
        return path

    def asset(self, arch, defect=None):
        p = self.root / ('input-' + arch)
        p.mkdir()
        baseline = {'os': self.context['buildOS'], 'arch': arch, 'glibcVersion': '2.43'}
        source = {'profile': 'tractanda.linux-producer-source.v1', 'files': copy.deepcopy(self.context['files']),
                  'componentManifests': copy.deepcopy(self.context['components'][arch]),
                  'toolchain': {'version': 'fixed synthetic tool'}, 'buildEnvironment': {'fixture': True},
                  'baseline': baseline}
        if defect == 'source': source['files'][0]['sha256'] = 'f' * 64
        if defect == 'components': source['componentManifests']['documents'] = 'f' * 64
        flags = self.context['flags'][arch]
        normalized = {'files': source['files'], 'components': source['componentManifests'], 'toolchain': source['toolchain'],
                      'buildFlags': flags, 'buildEnvironment': source['buildEnvironment'], 'baseline': baseline}
        h = D.digest(D.canonical(normalized))
        build = {'profile': 'tractanda.linux-bundle-build.v1', 'baseline': baseline,
                 'input': {'profile': 'tractanda.linux-bundle-input.v2', 'buildOS': baseline['os'],
                           'version': V, 'arch': arch, 'buildFlags': flags, 'sourceInputsSHA256': h}}
        build_path = self.write(p / 'bundle-build.json', build)
        names = ['bin/' + n for n in ('tractanda', 'tractanda-tui', 'tractanda-mcp', 'tractanda-setup',
                                    'tractanda-auth-helper', 'tractanda-embeddings', 'tractanda-document-converter')]
        names += ['models/granite-embedding-311m-multilingual-r2/weights', 'models/granite-docling-258m-mlx/weights']
        files = [{'path': n, 'sha256': 'c' * 64, 'size': 4, 'mode': 0o755 if n.startswith('bin/') else 0o644} for n in names]
        files.append({'path': 'lib/tractanda/linux-bundle-build.json', 'sha256': R.sha(build_path),
                      'size': build_path.stat().st_size, 'mode': 0o644})
        manifest = {'profile': 'tractanda.bundle.v1', 'version': V, 'platform': 'linux', 'arch': D.ARCHES[arch],
                    'embedding': {'fixture': True}, 'documentExtraction': {'fixture': True}, 'files': files}
        manifest_path = self.write(p / 'bundle-manifest.json', manifest)
        package = p / 'fixture.deb'; package.write_bytes(('synthetic non-deb ' + arch).encode())
        receipt = {'version': V.replace('-poc.', '~poc.') + '-1', 'arch': arch,
                   'packageSHA256': R.sha(package), 'packageBytes': package.stat().st_size,
                   'bundleManifestSHA256': R.sha(manifest_path),
                   'inventory': [{**row, 'path': 'opt/tractanda/current/' + row['path']} for row in files] +
                                [{'path': 'opt/tractanda/current/bundle-manifest.json', 'sha256': R.sha(manifest_path),
                                  'size': manifest_path.stat().st_size, 'mode': 0o644}]}
        self.write(Path(str(package) + '.inventory.json'), receipt)
        result = {'profile': 'tractanda.linux-payload-result.v1', 'sourceInputsSHA256': h,
                  'bundle': {'manifestSHA256': R.sha(manifest_path)}, 'components': normalized['components'],
                  'toolchain': source['toolchain'], 'buildEnvironment': source['buildEnvironment'],
                  'baseline': dict(baseline, os='debian13') if defect == 'baseline' else baseline}
        if defect == 'commitment': result['sourceInputsSHA256'] = 'f' * 64
        return {'arch': arch, 'package': str(package), 'bundleManifest': str(manifest_path),
                'bundleBuildReceipt': str(build_path), 'producerSourceInputs': str(self.write(p / 'source-inputs.json', source)),
                'producerResult': str(self.write(p / 'result.json', result))}

    def attach(self, defect=None):
        entries = [self.asset(a, defect if a == 'amd64' else None) for a in D.ARCHES]
        path = self.write(self.root / 'inputs.json', {'profile': 'tractanda.release-linux-input.v1', 'assets': entries})
        D.attach(self.state, path, self.context)
        return entries

    def transport_names(self, artifacts):
        """Mirror the admitted V15 GitHub filename contract in synthetic expectations."""
        linux_names = {row['name'] for row in self.state['delivery']['linuxAssets']}
        return {name: name.replace('~', '.') if name in linux_names else name for name in artifacts}

    def expected_remote_hashes(self, artifacts):
        transport = self.transport_names(artifacts)
        return {transport[name]: digest for name, digest in artifacts.items()}

    def expected_checksum_file(self, artifacts):
        transport = self.transport_names(artifacts)
        return ''.join(f'{digest}  {transport[name]}\n' for name, digest in artifacts.items())

    def pipeline(self):
        self.attach()
        p = R.Pipeline(self.state)
        p.bundle.mkdir()
        payload = p.bundle / 'fixture'; payload.write_bytes(b'mac fixture'); payload.chmod(0o644)
        self.write(p.bundle / 'bundle-manifest.json', {'fixture': 'mac manifest', 'files': [
            {'path': 'fixture', 'size': payload.stat().st_size, 'mode': 0o644, 'sha256': R.sha(payload)}]})
        p.package.write_bytes(b'stapled mac package'); p.archive.write_bytes(b'mac archive')
        self.state['steps']['bundle'] = {'result': {'manifestSHA256': R.sha(p.bundle / 'bundle-manifest.json')}}
        hashes = {x.name: R.sha(x) for x in (p.package, p.archive)}
        hashes.update({r['name']: r['sha256'] for r in self.state['delivery']['linuxAssets']})
        self.state['steps']['artifacts'] = {'result': hashes}
        (p.directory / 'SHA256SUMS').write_text(self.expected_checksum_file(hashes))
        for n in ('verify', 'release-build', 'package', 'notarization'):
            self.state['steps'][n] = {'result': {}}
        p.linux_context = lambda: self.context
        p.save = lambda: None
        p.source.mkdir()
        self.write(p.source / 'unused.json', {})
        (p.source / 'docs').mkdir()
        (p.source / 'docs/github-release-template.md').write_text('{{VERSION}} {{SOURCE_COMMIT}} {{CHANGES}} {{TAG_URL}}')
        path, value = self.install_acceptance()
        accepted = D.allow_install(self.state, path, value['candidateID'])
        self.state['steps']['install-authorization'] = {'result': accepted}
        for n in ('install', 'health'): self.state['steps'][n] = {'result': {}}
        return p

    def install_acceptance(self):
        value = D.install_challenge(self.state); value['raven'] = self.raven.copy()
        for i, check in enumerate(value['checks']):
            evidence = self.root / ('install-proof-' + str(i) + '.json')
            self.write(evidence, {'scope': 'synthetic retained operator verification', 'stage': check['name']})
            check.update(status='PASS', completedAt='2026-01-01T00:00:00+00:00',
                         evidence=[{'path': str(evidence), 'sha256': R.sha(evidence)}])
        return self.write(self.root / 'install-acceptance.json', value), value

    def acceptance(self):
        value = D.challenge(self.state)
        value['cluster'] = {'storeID': self.raven['storeID'], 'ravenReplicaID': self.raven['replicaID'],
                            'stashReplicaID': str(uuid.uuid1())}
        for i, check in enumerate(value['checks']):
            evidence = self.root / ('proof-' + str(i) + '.json')
            self.write(evidence, {'scope': 'synthetic nonsecret operator receipt', 'stage': check['name']})
            check.update(status='PASS', completedAt='2026-01-01T00:00:00+00:00',
                         evidence=[{'path': str(evidence), 'sha256': R.sha(evidence)}])
        path = self.write(self.root / 'acceptance.json', value)
        return path, value

    def test_both_real_contract_inputs_are_staged_and_independent_of_later_input_mutation(self):
        entries = self.attach()
        for entry in entries: Path(entry['package']).write_bytes(b'changed external source')
        self.assertEqual(len(D.verify_linux(self.state, self.context)), 2)

    def test_internally_bound_but_different_core_source_or_components_are_rejected(self):
        for defect in ('source', 'components', 'commitment', 'baseline'):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as d:
                old = self.root; self.root = Path(d)
                try:
                    with self.assertRaises(RuntimeError): self.attach(defect)
                finally: self.root = old

    def test_missing_duplicate_architecture_and_missing_producer_receipts_fail(self):
        entries = [self.asset(a) for a in D.ARCHES]
        for entries2 in (entries[:1], [entries[0], entries[0]], [{k: v for k, v in x.items() if k != 'producerResult'} for x in entries]):
            path = self.write(self.root / 'bad-input.json', {'profile': 'tractanda.release-linux-input.v1', 'assets': entries2})
            with self.assertRaises(RuntimeError): D.attach(self.state, path, self.context)

    def test_package_and_bundle_version_bytes_and_inventory_mismatch_fail(self):
        entry = self.asset('amd64'); rpath = Path(entry['package'] + '.inventory.json')
        original = json.loads(rpath.read_text())
        for field, value in (('arch', 'arm64'), ('version', '0.1.0~poc.14-1'), ('packageSHA256', 'f' * 64),
                             ('packageBytes', 0), ('bundleManifestSHA256', 'f' * 64)):
            row = copy.deepcopy(original); row[field] = value; self.write(rpath, row)
            with self.subTest(field=field), self.assertRaises(RuntimeError): D.inspect_asset(entry, V, self.context)
        row = copy.deepcopy(original); row['inventory'].append(row['inventory'][0]); self.write(rpath, row)
        with self.assertRaisesRegex(RuntimeError, 'Duplicate'): D.inspect_asset(entry, V, self.context)

    def test_staged_package_receipt_or_sealed_source_drift_is_rejected(self):
        self.attach(); row = self.state['delivery']['linuxAssets'][0]
        package = Path(self.state['directory']) / row['name']; original = package.read_bytes()
        package.write_bytes(b'mutated')
        with self.assertRaises(RuntimeError): D.verify_linux(self.state, self.context)
        package.write_bytes(original)
        changed = copy.deepcopy(self.context); changed['files'][0]['mode'] = 0o755
        with self.assertRaises(RuntimeError): D.verify_linux(self.state, changed)
        receipt = Path(self.state['directory']) / 'linux-evidence' / row['evidence']['inventory']['name']
        receipt.write_bytes(b'changed receipt')
        with self.assertRaises(RuntimeError): D.verify_linux(self.state, self.context)

    def test_artifact_sealing_adds_both_debs_and_checksums_and_rechecks_changes(self):
        p = self.pipeline()
        with patch.object(p, 'verify_notarization'), patch.object(p, 'run_command', side_effect=lambda *_: p.archive.write_bytes(b'fresh archive')):
            hashes = p.package_artifacts()
        self.assertEqual(sum(n.endswith('.deb') for n in hashes), 2)
        sums = (p.directory / 'SHA256SUMS').read_text()
        for row in self.state['delivery']['linuxAssets']:
            transport_name = row['name'].replace('~', '.')
            self.assertIn(f"{row['sha256']}  {transport_name}\n", sums)
            self.assertNotIn(f"{row['sha256']}  {row['name']}\n", sums)
        self.assertEqual(sums, self.expected_checksum_file(hashes))
        self.state['steps']['artifacts'] = {'result': hashes}
        p.verify_artifacts()
        (p.directory / 'SHA256SUMS').write_text('changed')
        with self.assertRaisesRegex(RuntimeError, 'checksums'): p.verify_artifacts()

    def test_linux_context_uses_candidate_algorithm_only_after_exact_git_seal_check(self):
        p = self.pipeline()
        producer = SimpleNamespace(source_rows=lambda: self.context['files'],
                                   B=SimpleNamespace(PRIMARY_BUILD_OS=self.context['buildOS'], PUBLIC=('docs',)),
                                   SOURCE_ROOTS=('Sources', 'Tests', 'scripts'), SOURCE_FILES=('Package.swift',), SKIP={'.git'},
                                   require_admitted=Mock(side_effect=lambda a, _: self.context['components'][a]),
                                   core_build_flags=Mock(side_effect=lambda a, _: self.context['flags'][a]))
        with patch.object(R, 'git', side_effect=[self.state['commit'], self.state['tree'], '']), \
             patch.object(R.importlib.util, 'spec_from_file_location', return_value=Mock()), \
             patch.object(R.importlib.util, 'module_from_spec', return_value=producer):
            self.assertEqual(R.Pipeline.linux_context(p), dict(self.context, sourceRoot=str(p.source),
                sourceRoots=producer.SOURCE_ROOTS, sourceFiles=producer.SOURCE_FILES,
                publicRoots=producer.B.PUBLIC, sourceSkip=sorted(producer.SKIP)))
        self.assertEqual(producer.require_admitted.call_args_list,
                         [call(arch, self.context['buildOS']) for arch in D.ARCHES])
        self.assertEqual(producer.core_build_flags.call_args_list,
                         [call(arch, self.context['buildOS']) for arch in D.ARCHES])
        for values in (['c' * 40], [self.state['commit'], 'c' * 40], [self.state['commit'], self.state['tree'], 'dirty']):
            with patch.object(R, 'git', side_effect=values), patch.object(R.importlib.util, 'spec_from_file_location') as load, self.assertRaises(RuntimeError):
                R.Pipeline.linux_context(p)
            load.assert_not_called()

    def test_direct_publication_without_cluster_acceptance_has_no_external_effect(self):
        p = self.pipeline()
        with patch.object(p, 'verify_notarization'), patch.object(p, 'run_command') as run, \
             patch.object(R, 'release_info') as remote, self.assertRaisesRegex(RuntimeError, 'cluster acceptance'):
            p.publish()
        run.assert_not_called(); remote.assert_not_called()

    def test_pipeline_pauses_after_health_before_push_and_plain_resume_cannot_accept(self):
        p = self.pipeline(); p.health = Mock(return_value={'fixture': 'healthy'}); p.push = Mock(); p.publish = Mock()
        with patch.object(R, 'git', side_effect=[self.state['commit'], '', self.state['commit'], '']):
            p.run(); p.run()
        self.assertEqual(self.state['status'], 'paused')
        self.assertEqual(p.health.call_count, 2)
        p.push.assert_not_called(); p.publish.assert_not_called()
        self.assertNotIn('cluster-acceptance', self.state['steps'])

    def test_pipeline_stops_before_install_until_explicit_allow_then_still_stops_for_cluster(self):
        p = self.pipeline()
        for n in ('install-authorization', 'install', 'health'): self.state['steps'].pop(n)
        self.state['delivery'].pop('installAuthorization')
        p.install = Mock(return_value={}); p.health = Mock(return_value={}); p.push = Mock(); p.publish = Mock()
        with patch.object(R, 'git', side_effect=[self.state['commit'], ''] * 3):
            p.run(); p.run()
            self.assertEqual(self.state['activeStep'], 'install-authorization')
            p.install.assert_not_called(); p.health.assert_not_called(); p.push.assert_not_called()
            path, value = self.install_acceptance(); D.allow_install(self.state, path, value['candidateID'])
            p.run()
        p.install.assert_called_once(); p.health.assert_called_once(); p.push.assert_not_called()
        self.assertEqual(self.state['activeStep'], 'cluster-acceptance')

    def test_direct_install_refuses_without_candidate_authorization_before_external_command(self):
        p = self.pipeline()
        self.state['steps'].pop('install-authorization')
        self.state['delivery'].pop('installAuthorization')
        p.verify_notarization = Mock()
        p.run_command = Mock()
        with self.assertRaisesRegex(RuntimeError, 'Explicit candidate-bound allow-install'):
            p.install()
        p.verify_notarization.assert_called_once_with()
        p.run_command.assert_not_called()

    def test_install_authorization_rejects_pending_wrong_candidate_changed_target_and_stale_evidence(self):
        self.pipeline()
        for n in ('install-authorization', 'install', 'health'): self.state['steps'].pop(n)
        self.state['delivery'].pop('installAuthorization')
        path, value = self.install_acceptance()
        with self.assertRaises(RuntimeError): D.allow_install(self.state, path, 'f' * 64)
        pending = copy.deepcopy(value); pending['checks'][0]['status'] = 'PENDING'; self.write(path, pending)
        with self.assertRaises(RuntimeError): D.allow_install(self.state, path, value['candidateID'])
        self.write(path, value); D.allow_install(self.state, path, value['candidateID'])
        self.state['configuration']['instance'] = 'another-store'
        with self.assertRaises(RuntimeError): D.verify_install(self.state)
        self.state['configuration']['instance'] = 'production'
        Path(value['checks'][0]['evidence'][0]['path']).write_bytes(b'changed verification receipt')
        with self.assertRaises(RuntimeError): D.verify_install(self.state)

    def test_current_checks_do_not_require_backup_initialization_or_enrollment(self):
        self.pipeline()
        self.assertEqual(D.INSTALL_CHECKS, ('candidate-compatibility-and-maintenance', 'current-installation-identity'))
        self.assertEqual(D.CHECKS, ('raven-candidate-runtime', 'stash-candidate-runtime',
                                  'current-membership-and-peer-runtime', 'bidirectional-verification'))

    def test_pending_v1_candidate_cannot_run_install_or_publish(self):
        p = self.pipeline(); self.state['delivery']['profile'] = 'tractanda.release-delivery.v1'
        with self.assertRaisesRegex(RuntimeError, 'legacy candidate'): p.run()
        with patch.object(p, 'verify_notarization'), patch.object(p, 'verify_artifacts'), \
             patch.object(p, 'run_command') as run, patch.object(R, 'release_info') as remote:
            with self.assertRaisesRegex(RuntimeError, 'legacy candidate'): p.install()
            with self.assertRaisesRegex(RuntimeError, 'legacy candidate'): p.publish()
        run.assert_not_called(); remote.assert_not_called()

    def test_cluster_acceptance_must_keep_the_preinstall_raven_identity(self):
        self.pipeline(); path, value = self.acceptance(); value['cluster']['ravenReplicaID'] = str(uuid.uuid1())
        self.write(path, value)
        with self.assertRaisesRegex(RuntimeError, 'authorized Raven identity'): D.accept(self.state, path, value['candidateID'])

    def test_pending_template_wrong_candidate_wrong_order_or_non_uuid_pins_cannot_accept(self):
        self.pipeline(); path, valid = self.acceptance()
        for defect in ('pending', 'candidate', 'order', 'pins'):
            value = copy.deepcopy(valid)
            if defect == 'pending': value['checks'][0]['status'] = 'PENDING'
            if defect == 'candidate': value['candidate']['commit'] = 'c' * 40
            if defect == 'order': value['checks'][0], value['checks'][1] = value['checks'][1], value['checks'][0]
            if defect == 'pins': value['cluster']['storeID'] = str(uuid.uuid4())
            self.write(path, value)
            with self.subTest(defect=defect), self.assertRaises(RuntimeError): D.accept(self.state, path, valid['candidateID'])
        self.write(path, valid)
        with self.assertRaises(RuntimeError): D.accept(self.state, path, 'f' * 64)

    def test_acceptance_rechecks_retained_evidence_and_candidate_revision(self):
        self.pipeline(); path, value = self.acceptance(); D.accept(self.state, path, value['candidateID'])
        self.assertIsNotNone(D.verify_acceptance(self.state))
        self.state['commit'] = 'c' * 40
        with self.assertRaisesRegex(RuntimeError, 'stale'): D.verify_acceptance(self.state)
        self.state['commit'] = 'a' * 40
        Path(value['checks'][0]['evidence'][0]['path']).write_bytes(b'changed live receipt')
        with self.assertRaisesRegex(RuntimeError, 'evidence'): D.verify_acceptance(self.state)

    def test_explicit_acceptance_resumes_with_fresh_health_and_full_fourteen_step_plan(self):
        p = self.pipeline(); path, value = self.acceptance(); D.accept(self.state, path, value['candidateID'])
        p.health = Mock(return_value={'fixture': 'fresh health'}); p.push = Mock(return_value={}); p.publish = Mock(return_value={}); p.cleanup = Mock(return_value={})
        p.wait_for_ci = lambda _: self.state['steps'].update({'ci': {'result': {}}})
        with patch.object(R, 'git', side_effect=[self.state['commit'], '']), patch.object(R, 'record_release_retention'):
            p.run()
        self.assertEqual(self.state['status'], 'complete')
        self.assertEqual(len(self.state['plannedSteps']), 14)
        p.health.assert_called_once(); p.push.assert_called_once(); p.publish.assert_called_once()

    def test_revision_archives_linux_and_acceptance_files_and_fresh_contract_is_empty(self):
        self.pipeline()
        self.assertIn('installAuthorization', self.state['delivery'])
        path, value = self.acceptance(); D.accept(self.state, path, value['candidateID'])
        prior_install_candidate_id = self.state['delivery']['installAuthorization']['candidateID']
        prior_acceptance_candidate_id = self.state['delivery']['acceptance']['candidateID']
        for name in ('install-authorization', 'install', 'health', 'cluster-acceptance'):
            self.state['steps'].pop(name, None)
        (self.root / 'VERSION').write_text(V + '\n')
        control = self.root / 'release-control'

        def command(arguments, **_kwargs):
            if '--output' in arguments:
                return self.write(Path(arguments[arguments.index('--output') + 1]), {'manifest': []})
            return ''

        def git(*arguments, **_kwargs):
            if arguments[:2] == ('rev-parse', 'HEAD'):
                return 'c' * 40
            if arguments[:2] == ('rev-parse', 'HEAD^{tree}'):
                return 'd' * 40
            return ''

        with patch.object(R, 'ROOT', self.root), patch.object(R, 'CONTROL', control), \
                patch.object(R, 'command', side_effect=command), patch.object(R, 'git', side_effect=git):
            revised = R.revise(self.state, 'focused delivery-gate reset test')

        previous = revised['previousCandidates'][-1]
        history = Path(previous['deliveryEvidence'])
        self.assertTrue((history / 'linux-evidence').is_dir())
        self.assertTrue((history / 'install-evidence').is_dir())
        self.assertTrue((history / 'cluster-evidence').is_dir())
        self.assertEqual(previous['delivery']['installAuthorization']['candidateID'], prior_install_candidate_id)
        self.assertEqual(previous['delivery']['acceptance']['candidateID'], prior_acceptance_candidate_id)
        self.assertEqual(revised['steps'], {})
        self.assertEqual(revised['delivery'], {'profile': D.PROFILE, 'linuxAssets': []})
        self.assertIsNone(D.verify_install(revised))
        self.assertIsNone(D.verify_acceptance(revised))

    def test_private_upload_and_remote_digest_resume_include_linux_without_second_publisher(self):
        p = self.pipeline(); path, value = self.acceptance(); D.accept(self.state, path, value['candidateID'])
        canonical = {**self.state['steps']['artifacts']['result'], 'SHA256SUMS': R.sha(p.directory / 'SHA256SUMS')}
        expected = self.expected_remote_hashes(canonical)
        uploaded = []
        temporary_directory = tempfile.TemporaryDirectory

        def upload_directory(*, prefix, dir):
            self.assertEqual((prefix, dir), ('tractanda-upload-', '/private/tmp'))
            return temporary_directory(prefix=prefix, dir=self.root)

        def run(name, arguments, *unused):
            if name.startswith('upload-'):
                staged = Path(arguments[4])
                self.assertEqual(staged.parent.parent, self.root)
                self.assertTrue(staged.parent.name.startswith('tractanda-upload-'))
                self.assertEqual(R.sha(staged), expected[staged.name]); uploaded.append(staged.name)
        remote = {'target_commitish': self.state['commit'], 'assets': [], 'draft': True}
        final = {'assets': [{'name': n, 'digest': 'sha256:' + h} for n, h in expected.items()],
                 'draft': False, 'html_url': 'https://github.com/owner/repo/releases/tag/v' + V}
        with patch.object(R.tempfile, 'TemporaryDirectory', side_effect=upload_directory):
            with patch.object(p, 'verify_notarization'), patch.object(p, 'run_command', side_effect=run), \
                 patch.object(R.subprocess, 'run', return_value=Mock(returncode=0)), patch.object(R, 'release_info', side_effect=[remote, final]):
                result = p.publish()
            self.assertEqual(set(uploaded), set(expected)); self.assertEqual(result['sha256'], expected)
            remote['assets'] = final['assets']; uploaded.clear()
            with patch.object(p, 'verify_notarization'), patch.object(p, 'run_command', side_effect=run), \
                 patch.object(R.subprocess, 'run', return_value=Mock(returncode=0)), patch.object(R, 'release_info', side_effect=[remote, final]):
                p.publish()
        self.assertEqual(uploaded, [])

    def test_duplicate_or_changed_remote_assets_never_overwrite(self):
        p = self.pipeline(); path, value = self.acceptance(); D.accept(self.state, path, value['candidateID'])
        name = self.state['delivery']['linuxAssets'][0]['name']
        for assets in ([{'name': name, 'digest': 'sha256:' + 'f' * 64}], [{'name': name}, {'name': name}]):
            with patch.object(p, 'verify_notarization'), patch.object(p, 'run_command') as run, \
                 patch.object(R.subprocess, 'run', return_value=Mock(returncode=0)), \
                 patch.object(R, 'release_info', return_value={'target_commitish': self.state['commit'], 'assets': assets}), \
                 self.assertRaises(RuntimeError):
                p.publish()
            run.assert_not_called()

    def test_completed_legacy_release_needs_no_new_options_and_stays_unchanged(self):
        state = {'directory': '/unused', 'version': '0.1.0-poc.14', 'status': 'complete', 'configuration': {}, 'steps': {}}
        before = copy.deepcopy(state)
        p = R.Pipeline(state)
        with patch.object(p, 'prepare_disposable') as prepare, patch.object(R.storage, 'select') as select:
            p.run()
        prepare.assert_not_called(); select.assert_not_called(); self.assertEqual(state, before)

    def test_completed_release_reconciles_only_registered_scratch(self):
        identity = {'path': str(self.root / 'known-run')}
        state = {'directory': str(self.root), 'version': V, 'status': 'complete', 'configuration': {},
                 'steps': {}, 'retiredDisposableStorage': [identity]}
        p = R.Pipeline(state); p.save = Mock()
        with patch.object(p, 'prepare_disposable') as prepare, patch.object(R.storage, 'select') as select, \
                patch.object(R.storage, 'dispose') as dispose:
            p.run()
        prepare.assert_not_called(); select.assert_not_called()
        dispose.assert_called_once_with(identity, self.root / 'disposable-fallback')
        self.assertEqual(state['retiredDisposableStorage'], [])

    def test_new_published_receipt_requires_both_linux_assets_and_exact_used_acceptance(self):
        p = self.pipeline(); path, value = self.acceptance(); accepted = D.accept(self.state, path, value['candidateID'])
        self.state['steps']['cluster-acceptance'] = {'result': accepted}
        canonical = {**self.state['steps']['artifacts']['result'], 'SHA256SUMS': R.sha(p.directory / 'SHA256SUMS')}
        hashes = self.expected_remote_hashes(canonical)
        self.state['steps']['publish'] = {'result': {'url': 'https://github.com/owner/repo/releases/tag/v' + V, 'sha256': hashes}}
        self.state['status'] = 'complete'
        self.assertTrue(R.is_verified_published(self.state))
        self.state['steps']['cluster-acceptance'] = {'result': {}}
        self.assertFalse(R.is_verified_published(self.state))
        self.state['steps']['cluster-acceptance'] = {'result': accepted}
        first_linux_name = self.state['delivery']['linuxAssets'][0]['name']
        hashes.pop(self.transport_names({first_linux_name: 'unused'})[first_linux_name])
        self.assertFalse(R.is_verified_published(self.state))



class SourceEquivalenceTests(unittest.TestCase):
    """Actual tiny Git histories, synthetic immutable packages; no compiler."""
    write = DeliveryTests.write
    asset = DeliveryTests.asset

    def setUp(self):
        DeliveryTests.setUp(self)
        self.repo = self.root / 'git-source'; self.repo.mkdir()
        self.git('init', '-q')
        files = {'Package.swift': '.testTarget(name: "FixtureTests", dependencies: [])\n',
                 'Sources/Core.swift': 'shipping source',
                 'Tests/FixtureTests/Case.swift': 'original test',
                 'Package.resolved': 'locked dependency',
                 '.github/workflows/test.yml': 'original workflow'}
        files.update({p: 'original development tool' for p in D.DEVELOPMENT_ONLY})
        for path, value in files.items():
            target = self.repo / path; target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(value)
        policy = patch.object(D, 'REVIEWED_PACKAGE_SHA256', {D.digest(files['Package.swift'].encode())})
        policy.start(); self.addCleanup(policy.stop)
        self.commit()
        self.origin = self.git('rev-parse', 'HEAD').strip()
        self.context.update(sourceRoot=str(self.repo), sourceRoots=('Sources', 'Tests', 'scripts'),
                            sourceFiles=('Package.swift', 'Package.resolved'),
                            publicRoots=('docs',), sourceSkip=('.git', '.build', '.swiftpm', '__pycache__'))
        self.capture()
        self.entries = [self.asset(a) for a in D.ARCHES]
        (self.repo / 'Tests/FixtureTests/Case.swift').write_text('corrected test')
        self.commit(); self.capture()
        self.proof, _ = D.source_equivalence(self.state, self.context, self.origin,
                                            [D.asset_binding(e) for e in self.entries])

    def git(self, *args):
        return D.git_bytes(self.repo, '-c', 'user.name=Release fixture', '-c',
                           'user.email=fixture@example.invalid', *args).decode()

    def commit(self):
        self.git('add', '-A'); self.git('commit', '-qm', 'fixture revision')

    def capture(self):
        self.state.update(commit=self.git('rev-parse', 'HEAD').strip(),
                          tree=self.git('rev-parse', 'HEAD^{tree}').strip())
        inventory = D.git_inventory(self.repo, self.state['commit'])
        self.context['files'] = D.git_rows(self.repo, inventory, D.selected_source_paths(inventory, self.context))

    def attach(self, proof=None, profile='tractanda.release-linux-input.v2'):
        value = {'profile': profile, 'assets': self.entries}
        if profile.endswith('.v2'): value['sourceEquivalence'] = self.proof if proof is None else proof
        D.attach(self.state, self.write(self.root / 'reuse.json', value), self.context)

    def regenerate(self):
        return D.source_equivalence(self.state, self.context, self.origin,
                                    [D.asset_binding(e) for e in self.entries])[0]

    def test_explicit_proof_retains_exact_origin_receipts_and_reverifies_after_resume(self):
        original = {p: Path(p).read_bytes() for e in self.entries for k, p in e.items() if k != 'arch'}
        with self.assertRaises(RuntimeError): self.attach(profile='tractanda.release-linux-input.v1')
        self.attach()
        resumed = json.loads(json.dumps(self.state))
        self.assertEqual(len(D.verify_linux(resumed, self.context)), 2)
        for row in resumed['delivery']['linuxAssets']:
            self.assertEqual(row['artifactOrigin']['commit'], self.origin)
            self.assertNotEqual(row['artifactOrigin']['commit'], resumed['commit'])
            self.assertEqual(row['sourceEquivalenceSHA256'], D.digest(D.canonical(self.proof)))
        self.assertTrue(all(Path(p).read_bytes() == raw for p, raw in original.items()))

    def test_changed_shipping_dependency_recipe_or_unmapped_test_is_rejected(self):
        for path in ('Sources/Core.swift', 'Package.resolved', 'Package.swift',
                     'scripts/produce-linux-payload.py', 'Tests/UnknownTests/New.swift',
                     'Tests/FixtureTests/fixture.json'):
            with self.subTest(path=path):
                target = self.repo / path; target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text('ineligible correction'); self.commit(); self.capture()
                with self.assertRaises(RuntimeError): self.regenerate()
                self.git('reset', '--hard', self.proof['candidate']['commit']); self.capture()

    def test_mode_add_delete_symlink_and_explicit_tests_mapping_fail_closed(self):
        target = self.repo / 'Tests/FixtureTests/Case.swift'
        actions = (lambda: target.chmod(0o755), lambda: target.unlink(),
                   lambda: (self.repo / 'Tests/FixtureTests/Added.swift').write_text('added'),
                   lambda: (target.unlink(), target.symlink_to('../../Sources/Core.swift')),
                   lambda: (self.repo / 'Package.swift').write_text('.target(name: "Core", path: "Tests/FixtureTests")'))
        for action in actions:
            action(); self.commit()
            with self.assertRaises(RuntimeError):
                self.capture(); self.regenerate()
            self.git('reset', '--hard', self.proof['candidate']['commit']); self.capture()

    def test_omitted_diff_forged_origin_final_identity_and_nonancestor_are_rejected(self):
        for key in ('changes', 'origin', 'candidate'):
            proof = copy.deepcopy(self.proof)
            if key == 'changes': proof[key] = []
            else: proof[key]['tree'] = 'f' * 40
            with self.subTest(key=key), self.assertRaises(RuntimeError): self.attach(proof)
        unrelated = self.git('commit-tree', self.state['tree'], '-m', 'unrelated root').strip()
        with self.assertRaises(RuntimeError):
            D.source_equivalence(self.state, self.context, unrelated, [])

    def test_dirty_final_checkout_rejected_at_attachment_and_resume(self):
        self.attach()
        (self.repo / 'Tests/FixtureTests/Case.swift').write_text('dirty source')
        with self.assertRaises(RuntimeError): self.attach()
        with self.assertRaises(RuntimeError): D.verify_linux(self.state, self.context)

    def test_every_package_and_receipt_hash_is_bound_and_origin_rows_are_not_overridable(self):
        for e in self.entries:
            paths = [Path(v) for k, v in e.items() if k != 'arch'] + [Path(e['package'] + '.inventory.json')]
            for path in paths:
                raw = path.read_bytes(); path.write_bytes(raw + b' ')
                with self.subTest(path=path), self.assertRaises(RuntimeError): self.attach()
                path.write_bytes(raw)
        path = Path(self.entries[0]['producerSourceInputs'])
        value = json.loads(path.read_text()); value['files'][0]['sha256'] = 'f' * 64
        self.write(path, value)
        # Even an operator regenerating fingerprints cannot forge Git source rows.
        self.proof = self.regenerate()
        with self.assertRaises(RuntimeError): self.attach()

    def test_resume_rejects_missing_proof_origin_metadata_and_tampered_evidence(self):
        self.attach()
        missing = copy.deepcopy(self.state); del missing['delivery']['sourceEquivalence']
        with self.assertRaises(RuntimeError): D.verify_linux(missing, self.context)
        changed = copy.deepcopy(self.state); changed['delivery']['linuxAssets'][0]['artifactOrigin']['commit'] = 'f' * 40
        with self.assertRaises(RuntimeError): D.verify_linux(changed, self.context)
        row = self.state['delivery']['linuxAssets'][0]
        evidence = Path(self.state['directory']) / 'linux-evidence' / row['evidence']['producer-result']['name']
        evidence.write_bytes(evidence.read_bytes() + b' ')
        with self.assertRaises(RuntimeError): D.verify_linux(self.state, self.context)

    def test_malformed_proof_shapes_and_asset_entries_fail_explicitly(self):
        for proof in (None, {}, [], dict(self.proof, origin='invalid'), dict(self.proof, origin={'commit': [], 'tree': ''})):
            with self.subTest(proof=proof), self.assertRaises(RuntimeError):
                D.equivalent_context(self.state, self.context, proof, [])
        for entry in ({}, [], dict(self.entries[0], arch='unknown')):
            with self.assertRaises(RuntimeError): D.asset_binding(entry)

    def test_artifacts_changed_between_fingerprint_and_inspection_cannot_be_admitted(self):
        actual = D.inspect_asset
        def changed(entry, version, context):
            row, package, metadata = actual(entry, version, context)
            metadata['producer-result'] += b' '
            return row, package, metadata
        with patch.object(D, 'inspect_asset', side_effect=changed), self.assertRaisesRegex(RuntimeError, 'changed during'):
            self.attach()

    def test_existing_workflow_and_fixed_development_tools_can_be_reviewed(self):
        for path in ('.github/workflows/test.yml', *sorted(D.DEVELOPMENT_ONLY)):
            (self.repo / path).write_text('corrected development source')
        self.commit(); self.capture(); self.proof = self.regenerate()
        self.attach()
        self.assertEqual(len(D.verify_linux(self.state, self.context)), 2)

if __name__ == '__main__': unittest.main(verbosity=2)
