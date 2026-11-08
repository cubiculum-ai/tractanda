import shlex
import hashlib
#!/usr/bin/env python3
"""Portable, side-effect-free checks for the release controller's safety gates."""
import importlib.util
import io
import json
import subprocess
import shutil
import sys
import tarfile
from contextlib import nullcontext
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release = load('release', 'release-macos.py')
activate = load('activate', 'activate-release.py')
packager = load('packager', 'package-macos.py')


class PublishedPagesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        directory = Path(self.tmp.name)
        self.state = {'directory': str(directory), 'configuration': {'repository': 'owner/repo', 'branch': 'main'},
                      'version': '0.1.0-poc.18', 'commit': 'a' * 40,
                      'steps': {'publish': {'result': {'sha256': {}}}}}
        self.pipeline = release.Pipeline(self.state); self.pipeline.save = lambda: None
        self.content = {'index.html': b'manual', 'apt/dists/preview/InRelease': b'signed-release',
                        'apt/dists/preview/main/binary-amd64/Packages.xz': b'amd64',
                        'apt/dists/preview/main/binary-arm64/Packages.xz': b'arm64',
                        'apt/tractanda-archive-keyring.asc': b'public-key'}
        for name, data in self.content.items():
            local = (self.pipeline.source / 'docs/index.html' if name == 'index.html'
                     else directory / 'apt-site' / name)
            local.parent.mkdir(parents=True, exist_ok=True); local.write_bytes(data)
        with tarfile.open(directory / 'apt-site.tar.gz', 'w:gz') as archive:
            for name, data in self.content.items():
                if name != 'index.html':
                    info = tarfile.TarInfo(name); info.size = len(data); archive.addfile(info, io.BytesIO(data))
        digest = release.sha(directory / 'apt-site.tar.gz')
        self.state['steps']['publish']['result']['sha256']['apt-site.tar.gz'] = digest
        self.published = {'id': 438031031, 'tag_name': 'v0.1.0-poc.18', 'draft': False,
                          'published_at': '2026-11-08T04:37:43Z',
                          'assets': [{'name': 'apt-site.tar.gz', 'digest': 'sha256:' + digest}]}
        self.pages_run = {'databaseId': 42448103745, 'event': 'workflow_dispatch', 'headBranch': 'main',
                    'headSha': 'a' * 40, 'createdAt': '2026-11-08T04:45:47Z',
                    'status': 'completed', 'conclusion': 'success'}

    def invoke(self, runs, releases=None, wrong_site=None):
        def api(args, **_):
            return json.dumps([releases or [self.published]] if args[1] == 'api' else runs)
        def get(args, **_):
            name = args[-1].split('/repo/', 1)[1]
            return b'wrong' if name == wrong_site else self.content[name]
        with patch.object(release, 'release_info', return_value=self.published), \
                patch.object(release, 'command', side_effect=api), patch.object(release.subprocess, 'check_output', side_effect=get), \
                patch.object(self.pipeline, 'run_command') as watch:
            result = self.pipeline.published_pages()
        return result, watch

    def test_actual_postpublication_dispatch_selects_current_site(self):
        failed = {**self.pages_run, 'databaseId': 42447584388, 'event': 'release',
                  'headBranch': 'v0.1.0-poc.18', 'createdAt': '2026-11-08T04:37:45Z', 'conclusion': 'failure'}
        result, watch = self.invoke([failed, self.pages_run])
        self.assertEqual((result['runID'], result['event'], result['releaseTag']),
                         (42448103745, 'workflow_dispatch', 'v0.1.0-poc.18'))
        self.assertIn('42448103745', watch.call_args.args[1])

    def test_stale_wrong_source_or_newer_failed_run_waits(self):
        cases = [[], [{**self.pages_run, 'createdAt': '2026-11-08T04:37:42Z'}],
                 [{**self.pages_run, 'headSha': 'b' * 40}], [{**self.pages_run, 'headBranch': 'other'}],
                 [self.pages_run, {**self.pages_run, 'databaseId': 42448103746, 'createdAt': '2026-11-08T04:46:00Z',
                             'conclusion': 'failure'}]]
        for runs in cases:
            with self.subTest(runs=runs):
                self.assertIsNone(self.invoke(runs)[0]); self.assertEqual(self.state['status'], 'waitingForPages')

    def test_latest_release_and_live_site_bytes_are_required(self):
        newer = {**self.published, 'id': 2, 'published_at': '2026-11-09T00:00:00Z'}
        self.assertIsNone(self.invoke([self.pages_run], releases=[self.published, newer])[0])
        self.assertIsNone(self.invoke([self.pages_run], wrong_site='apt/dists/preview/InRelease')[0])

    def test_postpublication_release_event_is_accepted(self):
        run = {**self.pages_run, 'event': 'release', 'headBranch': 'v0.1.0-poc.18'}
        self.assertEqual(self.invoke([run])[0]['event'], 'release')
        same_second = {**run, 'createdAt': self.published['published_at']}
        self.assertEqual(self.invoke([same_second])[0]['runID'], same_second['databaseId'])

    def test_run_order_uses_instants_not_timestamp_strings(self):
        earlier = {**self.pages_run, 'createdAt': '2026-11-08T06:45:47+02:00'}
        later = {**self.pages_run, 'databaseId': 42448103746, 'createdAt': '2026-11-08T04:46:00Z'}
        self.assertEqual(self.invoke([earlier, later])[0]['runID'], later['databaseId'])

    def test_missing_pages_run_pauses_before_install(self):
        for name in ('verify', 'release-build', 'bundle', 'package', 'notarization', 'apt',
                     'artifacts', 'push', 'ci', 'published-source'):
            self.state['steps'][name] = {'result': {}}
        self.pipeline.prepare_disposable = lambda: None
        self.pipeline.verify_promoted_bundle = lambda: None
        self.pipeline.verify_artifacts = lambda: None
        self.pipeline.published_pages = lambda: None
        with patch.object(release, 'git', side_effect=['a' * 40, '']), \
                patch.object(self.pipeline, 'install') as install:
            self.pipeline.run_public(0)
        install.assert_not_called()
        self.assertNotIn('pages', self.state['steps'])


class ReleaseTests(unittest.TestCase):
    def test_metal_selection_uses_working_default_without_component_query(self):
        with patch.object(release.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'metal v1', '')) as run:
            env, receipt = release.select_metal_toolchain({'PATH': '/fixture'})
        self.assertEqual(env, {'PATH': '/fixture'})
        self.assertEqual(receipt['selection'], 'default')
        self.assertEqual(run.call_count, 1)

    def test_metal_selection_uses_installed_component_only_with_matching_tools(self):
        def probe(args, env, **_):
            if args[:2] == ['xcodebuild', '-showComponent']:
                return subprocess.CompletedProcess(args, 0, json.dumps({'status': 'installed', 'toolchainIdentifier': 'metal.fixture'}), '')
            if args == ['xcrun', 'metal', '--version']:
                return subprocess.CompletedProcess(args, 0 if env.get('TOOLCHAINS') else 1, 'metal v1' if env.get('TOOLCHAINS') else '', 'missing')
            return subprocess.CompletedProcess(args, 0, '/fixture/' + args[-1], '')
        with patch.object(release.subprocess, 'run', side_effect=probe):
            env, receipt = release.select_metal_toolchain({'PATH': '/fixture'})
        self.assertEqual(env['TOOLCHAINS'], 'metal.fixture')
        self.assertEqual(receipt['selection'], 'installed-component')
        self.assertEqual(set(receipt['identities']), {'swift', 'clang', 'sdk'})

    def test_metal_selection_rejects_invalid_component_and_changed_tools(self):
        for defect in ('invalid', 'swift', 'clang', 'sdk', 'unusable'):
            def probe(args, env, **_):
                selected = bool(env.get('TOOLCHAINS'))
                if args[:2] == ['xcodebuild', '-showComponent']:
                    info = {'status': 'missing' if defect == 'invalid' else 'installed', 'toolchainIdentifier': 'metal.fixture'}
                    return subprocess.CompletedProcess(args, 0, json.dumps(info), '')
                if args == ['xcrun', 'metal', '--version']:
                    ok = selected and defect != 'unusable'
                    return subprocess.CompletedProcess(args, 0 if ok else 1, 'metal v1' if ok else '', 'missing')
                name = 'sdk' if '--show-sdk-path' in args else args[-1]
                return subprocess.CompletedProcess(args, 0, '/changed' if selected and defect == name else '/original', '')
            with self.subTest(defect=defect), patch.object(release.subprocess, 'run', side_effect=probe):
                with self.assertRaises(RuntimeError):
                    release.select_metal_toolchain({'PATH': '/fixture'})

    def transport_fixture(self, root):
        state = {'directory': str(root), 'configuration': {'repository': 'owner/repo'},
                 'version': '0.1.0-poc.16', 'commit': 'a' * 40, 'notes': 'Fixture',
                 'steps': {}, 'delivery': release.delivery.public_fresh()}
        pipeline = release.Pipeline(state)
        files = {pipeline.package.name: b'notarized fixture', 'apt-site.tar.gz': b'signed APT fixture'}
        assets = []
        for arch in ('amd64', 'arm64'):
            name = 'tractanda_0.1.0~poc.16-1_' + arch + '.deb'
            payload = ('Debian fixture ' + arch).encode()
            files[name] = payload
            assets.append({'arch': arch, 'name': name, 'debianVersion': '0.1.0~poc.16-1',
                           'sha256': hashlib.sha256(payload).hexdigest(), 'bytes': len(payload)})
        for name, payload in files.items():
            (root / name).write_bytes(payload)
        artifacts = {name: release.sha(root / name) for name in files}
        state['steps']['artifacts'] = {'result': artifacts}
        state['delivery']['linuxAssets'] = assets
        (root / 'SHA256SUMS').write_text(release.publication_checksums(artifacts, assets))
        pipeline.bundle.mkdir()
        manifest = pipeline.bundle / 'bundle-manifest.json'
        manifest.write_text('{}')
        state['steps']['bundle'] = {'result': {'manifestSHA256': release.sha(manifest)}}
        return pipeline, artifacts, assets

    def test_github_transport_names_bind_control_identity_and_reject_collision(self):
        with tempfile.TemporaryDirectory() as temporary:
            pipeline, artifacts, assets = self.transport_fixture(Path(temporary))
            names = release.publication_asset_names(artifacts, assets)
            for row in assets:
                self.assertEqual(names[row['name']], row['name'].replace('~', '.'))
            for defect in ('name', 'arch', 'debianVersion', 'sha256', 'bytes'):
                changed = [dict(row) for row in assets]
                changed[0][defect] = 0 if defect == 'bytes' else 'invalid'
                with self.subTest(defect=defect), self.assertRaises(RuntimeError):
                    release.publication_asset_names(artifacts, changed)
            with self.assertRaisesRegex(RuntimeError, 'collide'):
                release.publication_asset_names({**artifacts, assets[0]['name'].replace('~', '.'): 'b' * 64}, assets)

    def test_public_checksums_use_actual_transport_names_and_preserve_payload_hashes(self):
        with tempfile.TemporaryDirectory() as temporary:
            pipeline, artifacts, assets = self.transport_fixture(Path(temporary))
            text = (pipeline.directory / 'SHA256SUMS').read_text()
            parsed = {line.split('  ', 1)[1]: line.split('  ', 1)[0] for line in text.splitlines()}
            self.assertNotIn('~', text)
            self.assertEqual(set(parsed), set(release.publication_asset_names(artifacts, assets).values()))
            for row in assets:
                self.assertEqual(parsed[row['name'].replace('~', '.')], row['sha256'])
                self.assertTrue((pipeline.directory / row['name']).exists())

    def test_transport_checksum_guard_retains_canonical_byte_and_inventory_checks(self):
        with tempfile.TemporaryDirectory() as temporary:
            pipeline, artifacts, assets = self.transport_fixture(Path(temporary))
            linux = {row['name']: row['sha256'] for row in assets}
            with patch.object(pipeline, 'linux_context', return_value={}), \
                    patch.object(release.delivery, 'verify_linux', return_value=linux):
                pipeline.verify_artifacts()
                (pipeline.directory / 'SHA256SUMS').write_text(''.join(f'{digest}  {name}\n' for name, digest in artifacts.items()))
                with self.assertRaisesRegex(RuntimeError, 'checksums'):
                    pipeline.verify_artifacts()
                (pipeline.directory / 'SHA256SUMS').write_text(release.publication_checksums(artifacts, assets))
                (pipeline.directory / assets[0]['name']).write_bytes(b'changed bytes')
                with self.assertRaisesRegex(RuntimeError, 'artifact changed'):
                    pipeline.verify_artifacts()

    def test_publish_stages_exact_transport_names_and_rejects_remote_alias_or_hash(self):
        for defect in (None, 'unknown-alias', 'wrong-hash'):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                pipeline, artifacts, assets = self.transport_fixture(root)
                (pipeline.source / 'docs').mkdir(parents=True)
                shutil.copyfile(Path(__file__).parents[1] / 'docs/github-release-template.md',
                                pipeline.source / 'docs/github-release-template.md')
                names = release.publication_asset_names(artifacts, assets)
                expected = {names[name]: digest for name, digest in artifacts.items()}
                expected['SHA256SUMS'] = release.sha(root / 'SHA256SUMS')
                remote = {'target_commitish': pipeline.state['commit'], 'draft': False,
                          'html_url': 'https://github.com/owner/repo/releases/tag/v0.1.0-poc.16',
                          'assets': [{'name': name, 'digest': 'sha256:' + digest} for name, digest in expected.items()]}
                if defect == 'unknown-alias': remote['assets'][0]['name'] = 'unapproved.pkg'
                if defect == 'wrong-hash': remote['assets'][0]['digest'] = 'sha256:' + '0' * 64
                uploaded = []
                def run(label, args, cwd=None):
                    if label.startswith('upload-'):
                        path = Path(args[4]); uploaded.append(path.name)
                        self.assertEqual(release.sha(path), expected[path.name])
                        self.assertNotIn('~', path.name)
                temporary_directory = tempfile.TemporaryDirectory
                def portable(*args, **kwargs):
                    self.assertEqual(kwargs['dir'], '/private/tmp')
                    return temporary_directory(prefix='upload-', dir=root)
                first = {**remote, 'assets': []} if defect is None else remote
                with patch.object(pipeline, 'verify_artifacts'), patch.object(pipeline, 'verify_notarization'), \
                        patch.object(pipeline, 'run_command', side_effect=run), \
                        patch.object(release.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)), \
                        patch.object(release, 'release_info', side_effect=[first, remote]), \
                        patch.object(release.tempfile, 'TemporaryDirectory', side_effect=portable):
                    if defect is not None:
                        with self.assertRaises(RuntimeError): pipeline.publish()
                        self.assertEqual(uploaded, [])
                    else:
                        result = pipeline.publish()
                        self.assertEqual(result['sha256'], expected)
                        self.assertEqual(set(uploaded), set(expected))

    def test_completed_publication_retention_uses_exact_transport_inventory(self):
        with tempfile.TemporaryDirectory() as temporary:
            pipeline, artifacts, assets = self.transport_fixture(Path(temporary))
            state = pipeline.state
            state.update(status='complete', tree='b' * 40)
            hashes = {release.publication_asset_names(artifacts, assets)[name]: digest for name, digest in artifacts.items()}
            hashes.update({pipeline.archive.name: 'c' * 64, 'SHA256SUMS': release.sha(pipeline.directory / 'SHA256SUMS')})
            state['steps'].update({'publish': {'result': {'url': 'https://github.com/owner/repo/releases/tag/v0.1.0-poc.16', 'sha256': hashes}},
                                   'published-source': {'result': {'commit': state['commit'], 'tree': state['tree']}},
                                   'pages': {'result': {'runID': 1}}})
            self.assertTrue(release.is_verified_published(state))
            row = assets[0]
            actual = row['name'].replace('~', '.')
            hashes[row['name']] = hashes.pop(actual)
            self.assertFalse(release.is_verified_published(state), 'A canonical-name alias cannot replace actual remote identity')

    def test_install_stages_importable_activation_and_exact_source_guard(self):
        with tempfile.TemporaryDirectory() as temporary:
            pipeline = release.Pipeline({'directory': temporary, 'configuration': {
                'softwareRoot': '/unused', 'instance': 'production'}, 'version': 'test',
                'steps': {'bundle': {'result': {'manifestSHA256': 'manifest'}},
                          'artifacts': {'result': {'Tractanda-test-arm64.pkg': 'package'}}}})
            scripts = pipeline.source / 'scripts'
            scripts.mkdir(parents=True)
            for name in ('activate-release.py', 'canonical-format-guard.py'):
                shutil.copyfile(Path(__file__).with_name(name), scripts / name)
            pipeline.package.write_bytes(b'fixture package; never installed')
            observed = []

            def run_command(name, args, cwd=None):
                if name == 'stage-install':
                    return  # Bundle copying is unrelated to helper import resolution.
                self.assertEqual(name, 'install')
                self.assertEqual(shlex.split(args[-1])[1], '-B', 'Privileged Python must not create a root cache in the operator stage')
                observed.append(name)
                stage = Path(cwd)
                self.assertEqual(release.sha(stage / 'activate.py'), release.sha(scripts / 'activate-release.py'))
                self.assertEqual(release.sha(stage / 'canonical-format-guard.py'),
                                 release.sha(scripts / 'canonical-format-guard.py'))
                # A fresh interpreter imports the actual staged module and sibling.
                # No activation main, administrator prompt, installer or service runs.
                subprocess.run([sys.executable, '-c',
                    "import runpy; m=runpy.run_path('activate.py', run_name='staging_import_probe'); "
                    "assert callable(m['format_guard'].require_owned_reader)"],
                    cwd=stage, check=True, capture_output=True, text=True)

            temporary_directory = tempfile.TemporaryDirectory
            def portable_stage(*args, **kwargs):
                self.assertEqual(kwargs['dir'], '/private/var/tmp')
                return temporary_directory(prefix='activation-stage-', dir=temporary)

            with patch.object(release.tempfile, 'TemporaryDirectory', side_effect=portable_stage), \
                    patch.object(pipeline, 'verify_notarization') as notarization, \
                    patch.object(release.delivery, 'active', return_value=True), \
                    patch.object(release.delivery, 'verify_install', return_value={'fixture': 'authorized'}), \
                    patch.object(pipeline, 'run_command', side_effect=run_command):
                pipeline.install()
            notarization.assert_called_once_with()
            self.assertEqual(observed, ['install'])

    def descendant_fixture(self, root):
        control, directory, installed, live, base_command, git = self.ci_repair_fixture(root)
        executable = live.parent / 'bin/tractanda'
        executable.parent.mkdir()
        executable.write_bytes(b'signed ancestor executable')
        manifest = release.read(live)
        manifest.update(sourceCommit=installed['commit'], files=[{
            'path': 'bin/tractanda', 'sha256': release.sha(executable)}])
        release.write(live, manifest)
        digest = release.sha(live)
        installed['steps']['bundle']['result']['manifestSHA256'] = digest
        ancestor = {'commit': installed['commit'], 'steps': installed['steps'],
                    'unpublishedCIRepair': {'liveManifestSHA256': digest,
                        'failedCI': {'headSha': installed['commit']}, 'remoteReleaseAbsent': True,
                        'remoteTag': 'v' + installed['version']}}
        pending = {**installed, 'commit': 'b' * 40, 'steps': {}, 'status': 'ready',
                   'previousCandidates': [ancestor]}

        def command(args, **kwargs):
            if args[:3] == ['gh', 'run', 'list']:
                commit = args[args.index('--commit') + 1]
                return json.dumps([{'databaseId': 1, 'headSha': commit,
                                    'status': 'completed', 'conclusion': 'failure'}])
            return base_command(args, **kwargs)

        return control, directory, pending, live, command, git

    def test_ready_source_first_descendant_revalidates_installed_ancestor(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            control, directory, pending, live, command, git = self.descendant_fixture(root)
            before = live.read_bytes()
            absent = subprocess.CompletedProcess([], 2, stdout='', stderr='')
            with patch.object(release, 'ROOT', root), patch.object(release, 'CONTROL', control), \
                    patch.object(release, 'command', side_effect=command) as calls, \
                    patch.object(release, 'git', side_effect=git) as git_calls, \
                    patch.object(release.os, 'kill', side_effect=ProcessLookupError), \
                    patch.object(release.subprocess, 'run', return_value=absent):
                proof = release.require_ready_ci_descendant_repair(pending)
            self.assertEqual(proof['installedAncestorCommit'], 'a' * 40)
            self.assertEqual(proof['sourceFirstFailedCI']['headSha'], 'b' * 40)
            self.assertEqual(live.read_bytes(), before)
            self.assertTrue(any(call.args[0][:3] == ['/usr/bin/codesign', '--verify', '--strict']
                                for call in calls.call_args_list))
            git_calls.assert_any_call('merge-base', '--is-ancestor', 'a' * 40, 'b' * 40)
            self.assertEqual(pending['steps'], {})

    def test_ready_descendant_missing_ambiguous_or_changed_proof_fails_closed(self):
        for defect in ['state', 'gate', 'missing', 'ambiguous', 'source', 'executable', 'marker']:
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                control, _, pending, live, command, git = self.descendant_fixture(root)
                if defect == 'state': pending['status'] = 'running'
                if defect == 'gate': pending['steps'] = {'verify': {}}
                if defect == 'missing': pending['previousCandidates'] = []
                if defect == 'ambiguous': pending['previousCandidates'] *= 2
                if defect == 'marker': pending['previousCandidates'][0]['unpublishedCIRepair']['remoteReleaseAbsent'] = False
                if defect == 'source':
                    value = release.read(live); value['sourceCommit'] = 'c' * 40; release.write(live, value)
                if defect == 'executable': (live.parent / 'bin/tractanda').write_bytes(b'changed')
                with patch.object(release, 'ROOT', root), patch.object(release, 'CONTROL', control), \
                        patch.object(release, 'command', side_effect=command), \
                        patch.object(release, 'git', side_effect=git), \
                        patch.object(release.os, 'kill', side_effect=ProcessLookupError), \
                        patch.object(release.subprocess, 'run', return_value=subprocess.CompletedProcess([], 2, stdout='', stderr='')):
                    with self.assertRaises(RuntimeError): release.require_ready_ci_descendant_repair(pending)

    def test_ready_descendant_fresh_external_gates_fail_closed(self):
        for defect in ['runner', 'signature', 'ancestry', 'source-ci-green', 'source-ci-running',
                       'source-ci-wrong', 'offline', 'release', 'tag']:
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                control, _, pending, _, base_command, base_git = self.descendant_fixture(root)
                def command(args, **kwargs):
                    if args[0] == '/usr/bin/codesign' and defect == 'signature':
                        raise subprocess.CalledProcessError(1, args)
                    if args[:3] == ['gh', 'run', 'list'] and args[args.index('--commit') + 1] == 'b' * 40:
                        if defect == 'offline': raise RuntimeError('offline')
                        value = json.loads(base_command(args, **kwargs))
                        if defect == 'source-ci-green': value[0]['conclusion'] = 'success'
                        if defect == 'source-ci-running': value[0]['status'] = 'in_progress'
                        if defect == 'source-ci-wrong': value[0]['headSha'] = 'c' * 40
                        return json.dumps(value)
                    if args[:3] == ['gh', 'api', '--paginate'] and defect == 'release': return 'v0.1.0-poc.13'
                    return base_command(args, **kwargs)
                def git(*args, **kwargs):
                    if args[:2] == ('merge-base', '--is-ancestor') and defect == 'ancestry':
                        raise subprocess.CalledProcessError(1, args)
                    return base_git(*args, **kwargs)
                outcome = subprocess.CompletedProcess([], 0 if defect == 'tag' else 2, stdout='', stderr='')
                with patch.object(release, 'ROOT', root), patch.object(release, 'CONTROL', control), \
                        patch.object(release, 'command', side_effect=command), patch.object(release, 'git', side_effect=git), \
                        patch.object(release.os, 'kill', side_effect=None if defect == 'runner' else ProcessLookupError), \
                        patch.object(release.subprocess, 'run', return_value=outcome):
                    with self.assertRaises((RuntimeError, subprocess.CalledProcessError)):
                        release.require_ready_ci_descendant_repair(pending)

    def revision_fixture(self, root, old_commit='a' * 40):
        control = root / 'work/release-pipeline'
        directory = control / '0.1.0-poc.13'
        (directory / 'source').mkdir(parents=True)
        (root / 'VERSION').write_text('0.1.0-poc.13\n')
        state = {'directory': str(directory), 'version': '0.1.0-poc.13', 'commit': old_commit,
                 'configuration': {'softwareRoot': str(root / 'installed'),
                                   'applicationIdentity': 'Developer ID Application: Test',
                                   'developerTeamID': 'ABCDE12345', 'repository': 'owner/repo'}, 'status': 'failed',
                 'steps': {'package': {'result': {'sha256': '1' * 64}}}}

        def command(args, **_kwargs):
            if '--output' in args:
                release.write(Path(args[args.index('--output') + 1]), {'manifest': []})
            return ''

        next_commit = iter(('b' * 40, 'c' * 40))

        def git(*args, **_kwargs):
            if args[:2] == ('rev-parse', 'HEAD'):
                return next(next_commit)
            if args[:2] == ('rev-parse', 'HEAD^{tree}'):
                return 'd' * 40
            return ''

        return control, directory, state, command, git

    def ci_repair_fixture(self, root):
        control, directory, state, audit, git = self.revision_fixture(root)
        state['steps'] = {name: {'completedAt': 'verified', 'result': None} for name in (
            'verify', 'release-build', 'bundle', 'package', 'notarization',
            'artifacts', 'install', 'health', 'push')}
        state['activeStep'] = 'ci'
        state['error'] = 'GitHub verification did not pass'
        live = root / 'installed/current/bundle-manifest.json'
        live.parent.mkdir(parents=True)
        release.write(live, {'version': state['version'], 'files': []})
        state['steps']['bundle']['result'] = {'manifestSHA256': release.sha(live)}
        state['steps']['package']['result'] = {'sha256': '1' * 64}
        release.write(control / 'runner.json', {'pid': 123, 'version': state['version'],
                                              'status': 'failed', 'stoppedAt': 'verified'})

        def command(args, **kwargs):
            if args[:3] == ['gh', 'run', 'list']:
                return json.dumps([{'databaseId': 1, 'headSha': state['commit'],
                                    'status': 'completed', 'conclusion': 'failure'}])
            if args == ['gh', 'api', 'repos/owner/repo']:
                return json.dumps({'permissions': {'push': True}})
            if args[:3] == ['gh', 'api', '--paginate']:
                return ''
            return audit(args, **kwargs)

        return control, directory, state, live, command, git

    def test_terminal_installed_ci_failure_can_revise_without_mutating_live_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            control, directory, state, live, command, git = self.ci_repair_fixture(root)
            before = live.read_bytes()
            old_steps = state['steps'].copy()
            evidence = directory / 'notarization'; evidence.mkdir()
            release.write(evidence / 'notarization.json', {'inputSHA256': '1' * 64, 'submissionID': 'old-id'})
            absent_tag = subprocess.CompletedProcess([], 2, stdout='', stderr='')
            with patch.object(release, 'ROOT', root), patch.object(release, 'CONTROL', control), \
                    patch.object(release, 'command', side_effect=command), patch.object(release, 'git', side_effect=git), \
                    patch.object(release.os, 'kill', side_effect=ProcessLookupError), \
                    patch.object(release.subprocess, 'run', return_value=absent_tag):
                revised = release.revise(state, 'portable test fixture')
            self.assertEqual(revised['version'], '0.1.0-poc.13')
            self.assertEqual(revised['steps'], {})
            previous = revised['previousCandidates'][-1]
            self.assertEqual(previous['steps'], old_steps)
            self.assertIn('install', previous['steps'])
            self.assertIn('push', previous['steps'])
            self.assertEqual(previous['unpublishedCIRepair']['failedCI']['conclusion'], 'failure')
            self.assertTrue(Path(previous['notarizationEvidence']).is_dir())
            self.assertEqual(list((directory / 'notarization').iterdir()), [])
            self.assertEqual(live.read_bytes(), before)

    def test_installed_ci_repair_denies_active_tagged_released_or_uncertain_state(self):
        for cause in ('active', 'unobservable', 'tagged', 'release', 'network', 'pending-ci', 'no-push', 'live-drift'):
            with self.subTest(cause=cause), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                control, _directory, state, live, command, _git = self.ci_repair_fixture(root)
                if cause == 'live-drift':
                    live.write_text('{"version":"0.1.0-poc.13","changed":true}')

                def remote(args, **kwargs):
                    if cause == 'network':
                        raise subprocess.CalledProcessError(1, args, stderr='network unavailable')
                    if cause == 'release' and args[:3] == ['gh', 'api', '--paginate']:
                        return 'v0.1.0-poc.13'
                    if cause == 'pending-ci' and args[:3] == ['gh', 'run', 'list']:
                        return json.dumps([{'headSha': state['commit'], 'status': 'in_progress', 'conclusion': None}])
                    if cause == 'no-push' and args == ['gh', 'api', 'repos/owner/repo']:
                        return json.dumps({'permissions': {'push': False}})
                    return command(args, **kwargs)

                kill_error = None if cause == 'active' else (PermissionError if cause == 'unobservable' else ProcessLookupError)
                tag = subprocess.CompletedProcess([], 0 if cause == 'tagged' else 2, stdout='', stderr='')
                with patch.object(release, 'CONTROL', control), patch.object(release, 'command', side_effect=remote), \
                        patch.object(release.os, 'kill', side_effect=kill_error), \
                        patch.object(release.subprocess, 'run', return_value=tag):
                    with self.assertRaises((RuntimeError, subprocess.CalledProcessError)):
                        release.require_unpublished_ci_repair(state)

    def test_published_or_non_ci_deployment_cannot_be_revised(self):
        for cause in ('published', 'complete', 'not-ci'):
            with self.subTest(cause=cause), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                control, _directory, state, _live, _command, _git = self.ci_repair_fixture(root)
                if cause == 'published':
                    state['steps']['publish'] = {'result': {}}
                elif cause == 'complete':
                    state['status'] = 'complete'
                else:
                    state['activeStep'] = 'health'
                with patch.object(release, 'CONTROL', control), patch.object(release, 'git') as git:
                    with self.assertRaises(RuntimeError):
                        release.revise(state, 'must refuse')
                git.assert_not_called()

    def cluster_repair_fixture(self, root):
        control, directory, state, live, command, git = self.ci_repair_fixture(root)
        state['steps'].pop('push')
        state['steps']['install-authorization'] = {'result': {}}
        state.update(status='paused', activeStep='cluster-acceptance', delivery=release.delivery.fresh())
        state.pop('error')
        executable = live.parent / 'bin/tractanda'; executable.parent.mkdir()
        executable.write_bytes(b'exact installed candidate fixture')
        state['steps']['health']['result'] = {
            'release': str(live.parent.resolve()), 'server': {'executableSHA256': release.sha(executable)}}
        release.write(control / 'runner.json', {'pid': 123, 'version': state['version'],
                                              'status': 'paused', 'stoppedAt': 'verified'})
        return control, directory, state, live, command, git

    def test_unpublished_cluster_pause_can_revise_without_replacing_live_or_retaining_acceptance(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            control, directory, state, live, command, git = self.cluster_repair_fixture(root)
            before = live.read_bytes(); old_steps = state['steps'].copy()
            retained = directory / 'install-evidence'; retained.mkdir()
            (retained / 'receipt.json').write_text('historical canonical conversion/enrollment fact')
            absent = subprocess.CompletedProcess([], 2, stdout='', stderr='')
            def remote(args, **kwargs):
                self.assertNotEqual(args[:3], ['gh', 'run', 'list'], 'Cluster repair must not invent a CI failure')
                return command(args, **kwargs)
            with patch.object(release, 'ROOT', root), patch.object(release, 'CONTROL', control), \
                    patch.object(release, 'command', side_effect=remote), patch.object(release, 'git', side_effect=git), \
                    patch.object(release.delivery, 'verify_install', return_value={'candidateID': 'old-candidate'}), \
                    patch.object(release.os, 'kill', side_effect=ProcessLookupError), \
                    patch.object(release.subprocess, 'run', return_value=absent):
                revised = release.revise(state, 'owner-aware activated target validation')
            self.assertEqual(revised['steps'], {})
            self.assertEqual(revised['delivery'], release.delivery.fresh())
            self.assertEqual(revised['version'], '0.1.0-poc.13')
            previous = revised['previousCandidates'][-1]
            self.assertEqual(previous['steps'], old_steps)
            self.assertIsNone(previous['unpublishedCIRepair'])
            self.assertEqual(previous['unpublishedClusterRepair']['gate'], 'cluster-acceptance')
            self.assertTrue((Path(previous['deliveryEvidence']) / 'install-evidence/receipt.json').is_file())
            self.assertEqual(live.read_bytes(), before)

    def test_cluster_repair_refuses_live_accepted_published_or_uncertain_candidates(self):
        causes = ('active', 'unobservable', 'authorization', 'changed-proof', 'accepted', 'push',
                  'wrong-pause', 'inactive-delivery', 'live-drift', 'binary-drift', 'runner',
                  'release', 'tag', 'network', 'visibility')
        for cause in causes:
            with self.subTest(cause=cause), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                control, _directory, state, live, command, _git = self.cluster_repair_fixture(root)
                if cause == 'accepted': state['delivery']['acceptance'] = {'candidateID': 'accepted'}
                if cause == 'push': state['steps']['push'] = {'result': {}}
                if cause == 'wrong-pause': state['activeStep'] = 'install-authorization'
                if cause == 'inactive-delivery': state['delivery'] = {}
                if cause == 'live-drift': live.write_text('{"version":"changed"}')
                if cause == 'binary-drift': (live.parent / 'bin/tractanda').write_bytes(b'drift')
                if cause == 'runner': (control / 'runner.json').unlink()
                def remote(args, **kwargs):
                    if cause == 'release' and args[:3] == ['gh', 'api', '--paginate']: return 'v' + state['version']
                    if cause == 'visibility' and args == ['gh', 'api', 'repos/owner/repo']: return '{}'
                    return command(args, **kwargs)
                tag = subprocess.CompletedProcess([], 0 if cause == 'tag' else 128 if cause == 'network' else 2,
                                                  stdout='', stderr='network' if cause == 'network' else '')
                kill = None if cause == 'active' else PermissionError if cause == 'unobservable' else ProcessLookupError
                with patch.object(release, 'CONTROL', control), patch.object(release, 'command', side_effect=remote), \
                        patch.object(release.delivery, 'verify_install', return_value=None if cause == 'authorization' else {'candidateID': 'old'},
                                     side_effect=RuntimeError('changed proof') if cause == 'changed-proof' else None), \
                        patch.object(release.os, 'kill', side_effect=kill), \
                        patch.object(release.subprocess, 'run', return_value=tag):
                    with self.assertRaises(RuntimeError): release.require_unpublished_cluster_repair(state)

    def cluster_descendant_fixture(self, root):
        control, directory, ancestor, live, command, git = self.cluster_repair_fixture(root)
        ancestor['configuration']['instance'] = 'production'
        manifest = release.read(live); manifest['sourceCommit'] = ancestor['commit']; release.write(live, manifest)
        digest = release.sha(live)
        ancestor['steps']['bundle']['result']['manifestSHA256'] = digest
        candidate = {'commit': ancestor['commit'], 'version': ancestor['version'],
                     'macBundleManifestSHA256': digest,
                     'installation': {k: ancestor['configuration'][k] for k in ('instance', 'softwareRoot')}}
        candidate_id = release.delivery.digest(release.delivery.canonical(candidate))
        value = {'profile': 'tractanda.release-install-authorization.v1', 'candidateID': candidate_id,
                 'candidate': candidate, 'raven': {'storeID': 'store', 'replicaID': 'replica'}}
        raw = json.dumps(value).encode(); proof_sha = hashlib.sha256(raw).hexdigest()
        history = directory / 'delivery-history/installed-retained'; (history / 'install-evidence').mkdir(parents=True)
        (history / 'install-evidence' / (proof_sha + '.json')).write_bytes(raw)
        authorization = {'candidateID': candidate_id, 'sha256': proof_sha, 'raven': value['raven']}
        ancestor['delivery']['installAuthorization'] = authorization
        ancestor['steps']['install-authorization']['result'] = authorization
        ancestor['deliveryEvidence'] = str(history)
        ancestor['unpublishedClusterRepair'] = {'gate': 'cluster-acceptance', 'remoteReleaseAbsent': True,
            'remoteTag': 'v' + ancestor['version'], 'installCandidateID': candidate_id,
            'liveManifestSHA256': digest, 'liveExecutableSHA256': release.sha(live.parent / 'bin/tractanda')}
        state = {**ancestor, 'commit': 'b' * 40, 'steps': {'verify': {'result': {}}},
                 'status': 'failed', 'activeStep': 'archive', 'delivery': release.delivery.fresh(),
                 'previousCandidates': [ancestor]}
        release.write(control / 'runner.json', {'pid': 123, 'version': state['version'],
                                              'status': 'failed', 'stoppedAt': 'verified'})
        return control, directory, state, live, command, git

    def test_uninstalled_cluster_descendant_revision_retains_live_ancestor_and_invalidates_gates(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            control, directory, state, live, command, git = self.cluster_descendant_fixture(root)
            before = live.read_bytes()
            with patch.object(release, 'ROOT', root), patch.object(release, 'CONTROL', control), \
                    patch.object(release, 'command', side_effect=command), patch.object(release, 'git', side_effect=git), \
                    patch.object(release.os, 'kill', side_effect=ProcessLookupError), \
                    patch.object(release.subprocess, 'run', return_value=subprocess.CompletedProcess([], 2, stdout='', stderr='')):
                revised = release.revise(state, 'fix generated daemon arguments')
            self.assertEqual(revised['steps'], {})
            self.assertEqual(revised['delivery'], release.delivery.fresh())
            self.assertEqual(live.read_bytes(), before)
            retained = revised['previousCandidates'][-1]
            self.assertIsNone(retained['unpublishedCIRepair'])
            self.assertEqual(retained['unpublishedClusterDescendantRepair']['gate'], 'cluster-acceptance-descendant')
            self.assertEqual(len(revised['previousCandidates']), 2)

    def test_cluster_descendant_refuses_uncertain_owner_drift_missing_history_and_publication(self):
        for cause in ('active', 'uncertain', 'runner', 'running', 'installed', 'accepted', 'auth',
                      'duplicate', 'manifest', 'binary', 'proof', 'proof-link', 'ancestor-source',
                      'saved-proof', 'history', 'release', 'tag', 'network'):
            with self.subTest(cause=cause), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                control, directory, state, live, command, git = self.cluster_descendant_fixture(root)
                ancestor = state['previousCandidates'][0]
                if cause == 'running': state['status'] = 'running'
                if cause == 'installed': state['steps']['install'] = {'result': {}}
                if cause == 'accepted': state['delivery']['acceptance'] = {'candidateID': 'accepted'}
                if cause == 'auth': state['delivery']['installAuthorization'] = {'candidateID': 'unreviewed'}
                if cause == 'duplicate': state['previousCandidates'].append(ancestor)
                if cause == 'manifest': live.write_text('{}')
                if cause == 'binary': (live.parent / 'bin/tractanda').write_bytes(b'drift')
                if cause == 'ancestor-source': ancestor['commit'] = 'c' * 40
                if cause == 'saved-proof': ancestor['unpublishedClusterRepair']['remoteReleaseAbsent'] = False
                if cause == 'history': ancestor['deliveryEvidence'] = str(root / 'outside')
                if cause == 'runner': (control / 'runner.json').unlink()
                proof = Path(ancestor['deliveryEvidence']) / 'install-evidence' / (ancestor['delivery']['installAuthorization']['sha256'] + '.json')
                if cause == 'proof': proof.write_bytes(b'{}')
                if cause == 'proof-link':
                    raw = proof.read_bytes(); proof.unlink(); other = root / 'other'; other.write_bytes(raw); proof.symlink_to(other)
                def remote(args, **kwargs):
                    if cause == 'release' and args[:3] == ['gh', 'api', '--paginate']: return 'v' + state['version']
                    return command(args, **kwargs)
                kill = None if cause == 'active' else PermissionError if cause == 'uncertain' else ProcessLookupError
                tag = subprocess.CompletedProcess([], 0 if cause == 'tag' else 128 if cause == 'network' else 2, stdout='', stderr='')
                with patch.object(release, 'CONTROL', control), patch.object(release, 'command', side_effect=remote), \
                        patch.object(release, 'git', side_effect=git), patch.object(release.os, 'kill', side_effect=kill), \
                        patch.object(release.subprocess, 'run', return_value=tag):
                    with self.assertRaises((RuntimeError, OSError)): release.require_unpublished_cluster_descendant_repair(state)

    def test_revise_archives_uploaded_notarization_with_provenance_and_fresh_attempt(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            control, directory, state, command, git = self.revision_fixture(root)
            evidence = directory / 'notarization'; evidence.mkdir()
            receipt = {'inputSHA256': '1' * 64, 'submissionID': 'uploaded-id',
                       'submissionState': 'uploaded', 'archive': '/private/tmp/old-wrapper.xcarchive'}
            release.write(evidence / 'notarization.json', receipt)
            (directory / 'notarization.log').write_text('old account diagnostic')
            (directory / 'ticket-probe').mkdir()
            (directory / 'ticket-probe/result.json').write_text('{"ticket": "available"}')
            with patch.object(release, 'ROOT', root), patch.object(release, 'CONTROL', control), \
                    patch.object(release, 'command', side_effect=command), patch.object(release, 'git', side_effect=git):
                revised = release.revise(state, 'tested ticket fallback')
                old = Path(revised['previousCandidates'][0]['notarizationEvidence'])
                provenance = release.read(old / 'provenance.json')
                self.assertEqual(provenance['controllerCommit'], 'a' * 40)
                self.assertEqual(provenance['receiptOwnerCommit'], 'a' * 40)
                self.assertEqual(provenance['inputSHA256'], '1' * 64)
                self.assertEqual(provenance['submissionID'], 'uploaded-id')
                self.assertEqual(provenance['archive'], '/private/tmp/old-wrapper.xcarchive')
                self.assertEqual(release.read(old / 'notarization/notarization.json'), receipt)
                self.assertEqual((old / 'notarization.log').read_text(), 'old account diagnostic')
                self.assertTrue((old / 'ticket-probe/result.json').exists())
                self.assertEqual(list((directory / 'notarization').iterdir()), [])
                self.assertFalse((directory / 'notarization.log').exists())
                self.assertFalse((directory / 'ticket-probe').exists())
                self.assertEqual(revised['steps'], {})
                # A fresh attempt's receipt survives normal resume and is
                # archived separately if this unpublished candidate is revised again.
                fresh_input = directory / 'signed/Tractanda-0.1.0-poc.13-arm64.pkg'
                fresh_input.parent.mkdir()
                fresh_input.write_bytes(b'new signed package')
                fresh_output = directory / 'Tractanda-0.1.0-poc.13-arm64.pkg'
                fresh_output.write_bytes(b'new stapled package')
                fresh = {'inputSHA256': release.sha(fresh_input), 'submissionID': 'new-id',
                         'submissionState': 'accepted', 'notarized': True,
                         'outputSHA256': release.sha(fresh_output), 'teamID': 'ABCDE12345'}
                release.write(directory / 'notarization/notarization.json', fresh)
                revised['steps'] = {'package': {'result': {'sha256': release.sha(fresh_input)}}}
                pipeline = release.Pipeline(revised)
                with patch.object(pipeline, 'run_command') as run_command:
                    self.assertEqual(pipeline.notarize_package()['submissionID'], 'new-id')
                self.assertEqual(run_command.call_args.args[1][-1], directory / 'notarization')
                self.assertEqual(release.read(directory / 'notarization/notarization.json'), fresh)
                newer = release.revise(revised, 'second repair')
                self.assertEqual(release.read(old / 'notarization/notarization.json'), receipt)
                second = Path(newer['previousCandidates'][1]['notarizationEvidence'])
                self.assertNotEqual(old, second)
                self.assertEqual(release.read(second / 'notarization/notarization.json'), fresh)
                self.assertEqual(release.read(second / 'provenance.json')['receiptOwnerCommit'], 'b' * 40)

    def test_revise_before_notarization_creates_clean_attempt(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            control, directory, state, command, git = self.revision_fixture(root)
            with patch.object(release, 'ROOT', root), patch.object(release, 'CONTROL', control), \
                    patch.object(release, 'command', side_effect=command), patch.object(release, 'git', side_effect=git):
                revised = release.revise(state, 'pre-notary repair')
            self.assertIsNone(revised['previousCandidates'][0]['notarizationEvidence'])
            self.assertEqual(list((directory / 'notarization').iterdir()), [])

    def test_notarization_history_collision_preserves_current_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _control, directory, state, _command, _git = self.revision_fixture(root)
            evidence = directory / 'notarization'; evidence.mkdir()
            release.write(evidence / 'notarization.json', {'inputSHA256': '1' * 64})
            collision = directory / ('notarization-history/0001-' + 'a' * 12 + '-to-' + 'b' * 12)
            collision.mkdir(parents=True)
            (collision / 'keep').write_text('existing')
            with self.assertRaises(FileExistsError):
                release.archive_notarization_evidence(state, 'b' * 40)
            self.assertTrue((evidence / 'notarization.json').exists())
            self.assertEqual((collision / 'keep').read_text(), 'existing')

    def test_declared_plan_matches_every_executed_stage(self):
        # Run the actual orchestration with side effects replaced, so adding a
        # stage without updating the plan cannot silently misstate progress.
        pipeline = object.__new__(release.Pipeline)
        pipeline.state = {'status': 'ready', 'commit': 'test', 'steps': {}, 'delivery': release.delivery.fresh()}
        pipeline.source = Path('/unused')
        pipeline.save = lambda: None
        pipeline.step = lambda name, action: pipeline.state['steps'].update({name: {}})
        pipeline.verify_artifacts = lambda: None
        pipeline.health = lambda: {}
        pipeline.install_gate = lambda: pipeline.state['steps'].update({'install-authorization': {}}) or True
        pipeline.cluster_gate = lambda: pipeline.state['steps'].update({'cluster-acceptance': {}}) or True
        pipeline.wait_for_ci = lambda timeout: pipeline.state['steps'].update({'ci': {}})
        pipeline.prepare_disposable = lambda: None
        pipeline.verify_promoted_bundle = lambda: None
        with patch.object(release, 'git', side_effect=['test', '']):
            pipeline.run()
        self.assertEqual(pipeline.state['plannedSteps'], release.delivery.release_plan(release.RELEASE_STEPS))
        self.assertEqual(list(pipeline.state['steps']), release.delivery.release_plan(release.RELEASE_STEPS))
        self.assertEqual(pipeline.state['status'], 'complete')

    def test_disposable_loss_before_and_after_bundle_checkpoint(self):
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(release, 'CONTROL', Path(temporary) / 'control'):
            directory = Path(temporary).resolve()
            state = {'directory': str(directory), 'configuration': {}, 'version': 'test',
                     'steps': {'release-build': {'result': None}},
                     'disposableStorage': {'path': '/lost', 'device': 1, 'inode': 2,
                                           'mount': '/lost-volume', 'volumeUUID': 'uuid'}}
            pipeline = release.Pipeline(state)
            pipeline.save = lambda: None
            with patch.object(release.storage, 'verify', side_effect=RuntimeError('lost')), \
                    patch.object(release.storage, 'RESERVE', 0):
                pipeline.prepare_disposable()
            self.assertNotIn('release-build', state['steps'])
            self.assertEqual(pipeline.disposable.parent, directory / 'disposable-fallback')
            state['steps']['bundle'] = {'result': {'manifestSHA256': 'sealed'}}
            after = release.Pipeline(state)
            with patch.object(release.storage, 'dispose', side_effect=RuntimeError('volume unavailable')):
                after.prepare_disposable()
            self.assertTrue(state['retiredDisposableStorage'])
            self.assertIsNone(after.disposable)
            self.assertIn('bundle', state['steps'])
            self.assertTrue((release.CONTROL / 'current.json').is_file())

    def test_promoted_bundle_rejected_if_payload_missing_or_changed(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            state = {'directory': str(directory), 'configuration': {}, 'version': 'test', 'steps': {}}
            pipeline = release.Pipeline(state)
            pipeline.bundle.mkdir()
            payload = pipeline.bundle / 'payload'
            payload.write_bytes(b'candidate')
            payload.chmod(0o644)
            manifest = pipeline.bundle / 'bundle-manifest.json'
            release.write(manifest, {'files': [{'path': 'payload', 'size': 9, 'mode': 0o644,
                                                  'sha256': hashlib.sha256(b'candidate').hexdigest()}]})
            state['steps']['bundle'] = {'result': {'manifestSHA256': release.sha(manifest)}}
            pipeline.verify_promoted_bundle()
            payload.write_bytes(b'corrupt!!')
            with self.assertRaisesRegex(RuntimeError, 'missing or changed'):
                pipeline.verify_promoted_bundle()
            payload.unlink()
            with self.assertRaisesRegex(RuntimeError, 'missing or changed'):
                pipeline.verify_promoted_bundle()

    def test_bundle_retirement_queues_unavailable_and_reconciles_on_resume(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            state = {'directory': str(directory), 'configuration': {}, 'version': 'test', 'steps': {}}
            pipeline = release.Pipeline(state)
            pipeline.save = lambda: None
            with patch.object(release.storage, 'RESERVE', 0):
                pipeline.prepare_disposable()
            run = pipeline.disposable
            (run / 'derived').write_text('derived')
            with patch.object(release.storage, 'dispose', side_effect=RuntimeError('volume unavailable')):
                pipeline.step('bundle', lambda: {'manifestSHA256': 'sealed'})
            self.assertTrue(run.exists())
            self.assertNotIn('disposableStorage', state)
            self.assertEqual(len(state['retiredDisposableStorage']), 1)
            resumed = release.Pipeline(state)
            resumed.save = lambda: None
            resumed.prepare_disposable()
            self.assertFalse(run.exists())
            self.assertEqual(state['retiredDisposableStorage'], [])
            self.assertIn('bundle', state['steps'])

    def test_promotion_crash_keeps_internal_candidate_and_rebuilds_pre_side_effects(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            state = {'directory': str(directory), 'configuration': {}, 'version': 'test',
                     'steps': {'release-build': {'result': None}},
                     'disposableStorage': {'path': '/lost', 'device': 1, 'inode': 2,
                                           'mount': '/lost-volume', 'volumeUUID': 'uuid'}}
            pipeline = release.Pipeline(state)
            pipeline.save = lambda: None
            pipeline.bundle.mkdir()
            (pipeline.bundle / 'candidate').write_text('preserved pending rebuild')
            with patch.object(release.storage, 'verify', side_effect=RuntimeError('lost')), \
                    patch.object(release.storage, 'RESERVE', 0):
                pipeline.prepare_disposable()
            self.assertEqual((pipeline.bundle / 'candidate').read_text(), 'preserved pending rebuild')
            self.assertNotIn('release-build', state['steps'])
            self.assertNotIn('bundle', state['steps'])
            self.assertEqual(len(state['retiredDisposableStorage']), 1)
            self.assertFalse(any(step in state['steps'] for step in ('package', 'notarization', 'install', 'publish')))

    def test_running_disposable_child_stops_when_volume_is_lost(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            state = {'directory': str(directory), 'configuration': {}, 'version': 'test', 'steps': {}}
            pipeline = release.Pipeline(state)
            pipeline.source = directory
            pipeline.disposable = directory
            pipeline.save = lambda: None
            with patch.object(pipeline, 'verify_disposable', side_effect=[None, RuntimeError('volume lost')]):
                with self.assertRaisesRegex(RuntimeError, 'volume lost'):
                    pipeline.run_command('build', [sys.executable, '-c', 'import time; time.sleep(30)'])
            self.assertEqual(state['activeStep'], 'build')

    def test_promote_bundle_checks_copy_and_preserves_internal_candidate(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            pipeline = release.Pipeline({'directory': str(directory), 'configuration': {},
                                         'version': 'test', 'steps': {}})
            pipeline.disposable = directory / 'external'
            pipeline.save = lambda: None
            pipeline.disposable.mkdir()
            source = pipeline.disposable / pipeline.bundle.name
            source.mkdir()
            payload = source / 'payload'
            payload.write_bytes(b'signed candidate'); payload.chmod(0o751)
            (source / 'payload-link').symlink_to('payload')
            staging = pipeline.bundle.with_name(pipeline.bundle.name + '.incomplete-123456')
            def fixture_copy(name, args, cwd):
                self.assertEqual(name, 'bundle-promote')
                self.assertEqual(args, ['/usr/bin/ditto', str(source), str(staging)])
                self.assertEqual(cwd, directory)
                shutil.copytree(source, staging, symlinks=True, copy_function=shutil.copy2)
            linux = sys.platform.startswith('linux')
            with patch.object(pipeline, 'verify_disposable'), patch.object(release.storage, 'RESERVE', 0), \
                    (patch.object(release.time, 'time_ns', return_value=123456) if linux else nullcontext()), \
                    (patch.object(pipeline, 'run_command', side_effect=fixture_copy) if linux else nullcontext()):
                pipeline.promote_bundle(source)
            self.assertEqual((pipeline.bundle / 'payload').read_bytes(), b'signed candidate')
            self.assertEqual((pipeline.bundle / 'payload').stat().st_mode & 0o777, 0o751)
            self.assertEqual((pipeline.bundle / 'payload-link').readlink(), Path('payload'))
            self.assertTrue((source / 'payload').exists())

    def test_release_configuration_does_not_require_a_notary_profile(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'config.json'
            settings = {key: 'configured' for key in (
                'branch', 'softwareRoot', 'applicationIdentity', 'installerIdentity',
                'modelDirectory', 'documentModelDirectory')}
            settings.update(repository='owner/repo', instance='production', developerTeamID='ABCDE12345')
            release.write(path, settings)
            self.assertEqual(release.config(path), settings)
            settings.update(disposableVolumeMount='/Volumes/example',
                            disposableRoot='/Volumes/example/build',
                            disposableVolumeUUID='12345678-1234-4ABC-8DEF-1234567890AB')
            release.write(path, settings)
            self.assertEqual(release.config(path), settings)
            settings.pop('disposableRoot')
            release.write(path, settings)
            with self.assertRaisesRegex(RuntimeError, 'configured together'):
                release.config(path)

    def test_release_builds_the_embedding_host_from_the_sealed_source(self):
        pipeline = release.Pipeline({'directory': '/unused', 'configuration': {'modelDirectory': '/model', 'documentModelDirectory': '/documents'},
                                    'version': 'test', 'steps': {}})
        with patch.object(pipeline, 'run_command') as run, patch.object(release, 'command', return_value='/built'), \
                patch.object(pipeline, 'verify_document_model'), \
                patch.object(release, 'select_metal_toolchain', return_value=({}, {'selection': 'fixture'})), \
                patch.object(release, 'write'):
            pipeline.build()
        self.assertEqual(run.call_count, 4)
        provider = run.call_args_list[1].args[1]
        self.assertEqual(provider[provider.index('--package-path') + 1], 'Packages/TractandaEmbeddings')
        self.assertIn('--disable-automatic-resolution', provider)
        self.assertEqual(run.call_args_list[2].args[1], ['sh', 'scripts/validate-granite-runtime.sh',
                                                       '/built/TractandaEmbeddingsHost', '/model'])

    def test_embedding_package_rejects_stale_host_and_modified_or_extra_assets(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            weights = directory / 'model.safetensors'
            weights.write_bytes(b'fixture weights')
            profile = dict(alias='tractanda-granite-embedding-311m-multilingual-r2-vmlx-fp32-44399559',
                modelRevision='44399559930365213510b1ee2eb15ded83374f0e',
                vmlxRevision='61a4b20d4ad01b10466e8fc94c50402a9f994430', dimensions=768,
                pooling='cls', normalization='l2', revision='fixture',
                assets={'model.safetensors': packager.digest(weights)})
            artifacts = {'granite-embedding-311m-multilingual-r2': {'files': [
                {'path': 'model.safetensors', 'size': weights.stat().st_size,
                 'sha256': packager.digest(weights)}]}}
            with patch.object(packager, 'model_artifacts', return_value=artifacts), \
                    patch.object(packager, 'run', return_value=json.dumps(profile)):
                self.assertEqual(packager.embedding_descriptor(Path('/helper'), directory)['dimensions'], 768)
                weights.write_bytes(b'changed')
                with self.assertRaisesRegex(ValueError, 'pinned artifact manifest'):
                    packager.embedding_descriptor(Path('/helper'), directory)
                weights.write_bytes(b'fixture weights')
                (directory / 'extra.json').write_text('{}')
                with self.assertRaisesRegex(ValueError, 'pinned artifact manifest'):
                    packager.embedding_descriptor(Path('/helper'), directory)
            with patch.object(packager, 'model_artifacts', return_value=artifacts), \
                    patch.object(packager, 'run', return_value=json.dumps({**profile, 'alias': 'old-model'})):
                with self.assertRaisesRegex(ValueError, 'Granite profile'):
                    packager.embedding_descriptor(Path('/helper'), directory)

    def test_health_rejects_a_live_server_still_using_the_previous_model(self):
        pipeline = release.Pipeline({'directory': '/unused', 'version': 'test', 'steps': {},
            'configuration': {'softwareRoot': '/installed', 'instance': 'production'}})
        manifest = {'files': [{'path': 'bin/tractanda', 'sha256': 'signed'}],
                    'embedding': {'model': 'granite'}, 'canonicalFormats': {'profile': 'test-fixture'}}
        native = json.dumps({'server': {'executableSHA256': 'signed'}, 'canonicalFormats': manifest['canonicalFormats']})
        with patch.object(release, 'read', return_value=manifest), patch.object(release, 'sha', return_value='same'):
            for semantic in ({'enabled': False}, {'enabled': True, 'model': 'qwen'}):
                with patch.object(release, 'command', side_effect=[native, json.dumps(semantic)]):
                    with self.assertRaisesRegex(RuntimeError, 'bundled model'):
                        pipeline.health()
            with patch.object(release, 'command', side_effect=[native, json.dumps({'enabled': True, 'model': 'granite'})]):
                self.assertEqual(pipeline.health()['semantic']['model'], 'granite')

    def test_signing_preflight_requires_both_valid_identities_for_expected_team(self):
        settings = {'applicationIdentity': 'A' * 40, 'installerIdentity': 'B' * 40,
                    'developerTeamID': 'ABCDE12345'}
        identities = '\n'.join([
            '1) ' + 'A' * 40 + ' "Developer ID Application: Test (ABCDE12345)"',
            '2) ' + 'B' * 40 + ' "Developer ID Installer: Test (ABCDE12345)"'])
        with patch.object(release, 'command', side_effect=['Xcode 27.0', identities]):
            release.validate_signing_environment(settings)
        with patch.object(release, 'command', side_effect=['Xcode 27.0', identities.splitlines()[0]]):
            with self.assertRaisesRegex(RuntimeError, 'Installer'):
                release.validate_signing_environment(settings)
        with patch.object(release, 'command', side_effect=['Xcode 27.0', identities]):
            with self.assertRaisesRegex(RuntimeError, 'Application'):
                release.validate_signing_environment({**settings, 'developerTeamID': 'OTHER12345'})

    def test_missing_or_changed_notarization_blocks_installation_and_publication(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = {'directory': temporary, 'configuration': {}, 'version': 'test', 'steps': {}}
            pipeline = release.Pipeline(state)
            pipeline.package.write_bytes(b'signed, not yet notarized')
            with patch.object(pipeline, 'run_command') as run:
                with self.assertRaisesRegex(RuntimeError, 'notarized package'):
                    pipeline.verify_notarization()
                run.assert_not_called()
                state['steps']['notarization'] = {'result': {'notarized': True, 'sha256': 'wrong'}}
                with self.assertRaises(RuntimeError):
                    pipeline.verify_notarization()
                run.assert_not_called()
                state['steps']['notarization']['result']['sha256'] = release.sha(pipeline.package)
                pipeline.verify_notarization()
                self.assertEqual(run.call_args_list[0].args[1][:3], ['xcrun', 'stapler', 'validate'])
                self.assertEqual(run.call_args_list[1].args[1][0], '/usr/sbin/spctl')

    def test_checksums_cover_stapled_package_bytes(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(release, 'CONTROL', Path(temporary) / 'control'):
            state = {'directory': temporary, 'configuration': {}, 'version': 'test', 'steps': {}}
            pipeline = release.Pipeline(state)
            pipeline.package.write_bytes(b'signed package plus notarization ticket')
            pipeline.signed_package.parent.mkdir()
            pipeline.signed_package.write_bytes(b'signed package')
            with patch.object(pipeline, 'verify_notarization') as check, \
                    patch.object(pipeline, 'run_command', side_effect=lambda *_: pipeline.archive.write_bytes(b'archive')):
                checksums = pipeline.package_artifacts()
            check.assert_called_once()
            self.assertEqual(checksums[pipeline.package.name], release.sha(pipeline.package))
            self.assertNotEqual(checksums[pipeline.package.name], release.sha(pipeline.signed_package))

    def test_background_runner_is_detached_and_does_not_recurse(self):
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(release, 'CONTROL', Path(temporary)), \
                patch.object(release, 'ensure_dashboard', return_value='http://127.0.0.1:48730/'), \
                patch.object(release.subprocess, 'Popen') as popen:
            popen.return_value.pid = 123
            result = release.start_runner(900)
            self.assertEqual(result['pid'], 123)
            arguments = popen.call_args.args[0]
            self.assertEqual(arguments[-3:], ['run', '--ci-timeout', '900'])
            self.assertNotIn('--background', arguments)
            self.assertTrue(popen.call_args.kwargs['start_new_session'])
            self.assertEqual(popen.call_args.kwargs['stdin'], release.subprocess.DEVNULL)

    def test_ci_wait_runs_to_completion_without_an_agent(self):
        pipeline = release.Pipeline({'directory': '/unused', 'configuration': {}, 'version': 'test', 'steps': {}})
        with patch.object(pipeline, 'ci', side_effect=[False, False, True]) as ci, \
                patch.object(release.time, 'monotonic', return_value=0), \
                patch.object(release.time, 'sleep') as sleep:
            pipeline.wait_for_ci(3600)
            self.assertEqual(ci.call_count, 3)
            self.assertEqual(sleep.call_count, 2)

    def test_ci_wait_is_bounded_and_propagates_failure(self):
        pipeline = release.Pipeline({'directory': '/unused', 'configuration': {}, 'version': 'test', 'steps': {}})
        with patch.object(pipeline, 'ci', return_value=False), \
                patch.object(release.time, 'monotonic', side_effect=[0, 10]):
            with self.assertRaisesRegex(RuntimeError, 'timed out'):
                pipeline.wait_for_ci(10)
        with patch.object(pipeline, 'ci', side_effect=RuntimeError('CI failed')):
            with self.assertRaisesRegex(RuntimeError, 'CI failed'):
                pipeline.wait_for_ci(3600)

    def test_unpublished_draft_is_addressed_by_release_id(self):
        def github(args, **kwargs):
            if args[:3] == ['gh', 'release', 'view']:
                return '{"databaseId":123}'
            if args == ['gh', 'api', 'repos/owner/repo/releases/123']:
                return '{"id":123,"draft":true,"assets":[]}'
            raise RuntimeError('The draft is not available through a tag endpoint')
        with patch.object(release, 'command', side_effect=github):
            self.assertTrue(release.release_info('owner/repo', 'v0.1.0-poc.2')['draft'])

    def test_release_notes_are_self_contained_and_version_pinned(self):
        template = (Path(__file__).resolve().parents[1] / 'docs/github-release-template.md').read_text()
        rendered = release.render_release_notes(template, '0.1.0-poc.10', 'a' * 40,
                                                'Current diagnostic and UI improvements.', 'owner/repo')
        self.assertIn('Tractanda-0.1.0-poc.10-arm64.pkg', rendered)
        self.assertIn('tractanda-0.1.0-poc.10-macos-arm64.tar.gz', rendered)
        self.assertIn('blob/v0.1.0-poc.10/docs/install.md', rendered)
        self.assertIn('Current diagnostic and UI improvements.', rendered)
        for phrase in ('--empty', 'tractanda-tui --profile NAME', '127.0.0.1:48728',
                       'MCP', 'LaunchDaemons', 'canonical store', 'notarized', 'Linux',
                       'PolyForm', 'not a universal migration tool'):
            self.assertIn(phrase, rendered)
        self.assertNotIn('{{', rendered)
        self.assertNotIn('Tractanda-0.1.0-poc.1-arm64.pkg', rendered)
        with self.assertRaises(ValueError):
            release.render_release_notes(template + '{{UNKNOWN}}', '0.1.0-poc.10', 'a' * 40, '', 'owner/repo')

    def test_patch_preview_versions_are_valid_and_sort_after_their_base(self):
        self.assertEqual(release.next_version('0.1.0-poc.16.1'), '0.1.0-poc.17')
        self.assertEqual(release.release_version('0.1.0-poc.16'), (0, 1, 0, 16, 0))
        self.assertEqual(release.release_version('0.1.0-poc.16.1'), (0, 1, 0, 16, 1))
        self.assertGreater(release.release_version('0.1.0-poc.16.1'), release.release_version('0.1.0-poc.16'))
        self.assertLess(release.release_version('0.1.0-poc.16.1'), release.release_version('0.1.0-poc.17'))
        self.assertIsNone(release.release_version('0.1.0-poc.16.bad'))
        template = (Path(__file__).resolve().parents[1] / 'docs/github-release-template.md').read_text()
        self.assertIn('0.1.0-poc.16.1', release.render_release_notes(template, '0.1.0-poc.16.1', 'a' * 40, 'Patch', 'owner/repo'))

    def test_versions_and_scope(self):
        self.assertEqual(release.next_version('0.1.0-poc.9'), '0.1.0-poc.10')
        with self.assertRaises(ValueError):
            release.next_version('../bad')
        self.assertTrue(release.significant(['Sources/TractandaCore/Service.swift']))
        self.assertTrue(release.significant(['Tools/Layout17Bridge/main.swift']))
        self.assertTrue(release.significant(['plugins/tractanda/skills/tractanda/SKILL.md']))
        self.assertFalse(release.significant(['work/notes.md', 'outputs/Tractanda-Resume.md']))

    def test_unpublished_changes_checks_remote_and_history(self):
        remote = 'a' * 40
        row = remote + '\trefs/heads/main'
        def run_case(heads, ancestor, committed='', dirty='', untracked=''):
            def fake_git(*args):
                if args[0] == 'ls-remote': return heads.pop(0)
                if args[0] == 'fetch': return ''
                if args[0] == 'rev-parse': return remote
                if args[:3] == ('diff', '--name-only', remote): return committed
                if args[:3] == ('diff', '--name-only', 'HEAD'): return dirty
                if args[0] == 'ls-files': return untracked
                raise AssertionError(args)
            with patch.object(release, 'git', side_effect=fake_git), \
                    patch.object(release.subprocess, 'run') as run:
                run.return_value.returncode = ancestor
                return release.unpublished_changes('main')
        self.assertTrue(release.significant(run_case([row, row], 0, 'Sources/change.swift')))
        self.assertTrue(release.significant(run_case([row, row], 0, dirty='Package.swift')))
        self.assertFalse(release.significant(run_case([row, row], 0)))
        with self.assertRaisesRegex(RuntimeError, 'behind or diverged'):
            run_case([row, row], 1, 'Sources/change.swift')
        with self.assertRaisesRegex(RuntimeError, 'moved'):
            run_case([row, 'b' * 40 + '\trefs/heads/main'], 0)
        with self.assertRaisesRegex(RuntimeError, 'identity'):
            run_case(['malformed'], 0)

    def test_unpublished_changes_against_real_remote(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo, remote = root / 'repo', root / 'remote.git'
            subprocess.run(['git', 'init', '--bare', '-q', str(remote)], check=True)
            subprocess.run(['git', 'init', '-q', '-b', 'main', str(repo)], check=True)
            def git(*args):
                return subprocess.check_output(['git', *args], cwd=repo, text=True).strip()
            git('config', 'user.name', 'Test')
            git('config', 'user.email', 'test@example.invalid')
            (repo / 'README.md').write_text('base\n')
            git('add', 'README.md')
            git('commit', '-qm', 'base')
            git('remote', 'add', 'origin', str(remote))
            git('push', '-q', 'origin', 'main')
            with patch.object(release, 'ROOT', repo), patch.object(release, 'git', side_effect=git):
                self.assertFalse(release.significant(release.unpublished_changes('main')))
                (repo / 'README.md').write_text('committed change\n')
                git('commit', '-qam', 'change')
                self.assertTrue(release.significant(release.unpublished_changes('main')))
                git('reset', '--hard', '-q', 'HEAD^')
                (repo / 'README.md').write_text('dirty change\n')
                self.assertTrue(release.significant(release.unpublished_changes('main')))

    def test_prune_keeps_newest_verified_publication_and_preserves_malformed(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(release, 'CONTROL', Path(temporary)):
            root = Path(temporary)
            def published(version):
                directory = root / version; directory.mkdir()
                release.write(directory / 'state.json', {
                    'version': version, 'directory': str(directory), 'status': 'complete', 'commit': 'a' * 40,
                    'configuration': {'repository': 'owner/repo'},
                    'steps': {'publish': {'result': {
                        'url': f'https://github.com/owner/repo/releases/tag/v{version}', 'sha256': {
                            f'tractanda-{version}-macos-arm64.tar.gz': 'a' * 64,
                            f'Tractanda-{version}-arm64.pkg': 'b' * 64, 'SHA256SUMS': 'c' * 64,
                        },
                    }}},
                })
                (directory / 'bundle').mkdir(); (directory / 'bundle' / 'large').write_bytes(b'x')
                return directory
            old, newest = published('0.1.0-poc.9'), published('0.1.0-poc.10')
            malformed = root / '0.1.0-poc.8'; malformed.mkdir(); (malformed / 'state.json').write_text('{bad')
            with patch.object(release, 'git', return_value=''), patch.object(release.maintenance, 'maintain'):
                result = release.prune_releases()
            self.assertEqual(result['removed'], ['0.1.0-poc.9'])
            self.assertFalse((old / 'bundle').exists())
            self.assertFalse((newest / 'bundle').exists())
            self.assertTrue(malformed.exists())

    def test_prune_removes_only_hash_bound_retired_artifacts_after_publication(self):
        with tempfile.TemporaryDirectory() as temporary:
            control = Path(temporary)
            version = '0.1.0-poc.20'
            directory = control / version
            commit = 'a' * 40
            package = f'Tractanda-{version}-arm64.pkg'
            archive = f'tractanda-{version}-macos-arm64.tar.gz'
            linux = 'tractanda_0.1.0~poc.20-1_arm64.deb'
            artifact_history = directory / 'artifact-history' / commit
            delivery_history = directory / 'delivery-history' / (commit[:12] + '-archive-retained')
            artifact_history.mkdir(parents=True)
            delivery_history.mkdir(parents=True)
            (artifact_history / package).write_bytes(b'previous package')
            (artifact_history / archive).write_bytes(b'changed archive')
            (delivery_history / linux).write_bytes(b'previous Debian package')
            evidence = delivery_history / 'linux-evidence.json'
            evidence.write_text('{}')
            live_package = directory / package
            live_package.write_bytes(b'current package')
            unknown = directory / 'delivery-history/unregistered'
            unknown.mkdir()
            (unknown / linux).write_bytes((delivery_history / linux).read_bytes())
            flat_link = directory / 'artifact-history' / package
            flat_link.symlink_to(live_package)
            state = {'version': version, 'directory': str(directory), 'status': 'failed', 'commit': 'b' * 40,
                     'configuration': {'repository': 'owner/repo'}, 'steps': {'publish': {'result': {
                         'url': f'https://github.com/owner/repo/releases/tag/v{version}', 'sha256': {
                             package: release.sha(live_package), archive: '1' * 64, 'SHA256SUMS': '2' * 64}}}},
                     'previousCandidates': [{'commit': commit, 'deliveryEvidence': str(delivery_history),
                         'delivery': {'linuxAssets': [{'name': linux, 'sha256': release.sha(delivery_history / linux)}]},
                         'steps': {'artifacts': {'result': {package: release.sha(artifact_history / package),
                                                           archive: '3' * 64}}}}]}
            with patch.object(release, 'CONTROL', control), patch.object(release, 'git', return_value=''), \
                    patch.object(release.maintenance, 'maintain') as maintain:
                release.write(directory / 'state.json', state)
                self.assertEqual(release.prune_releases()['removedRetiredArtifacts'], [])
                maintain.assert_not_called()
                state['status'] = 'complete'
                release.write(directory / 'state.json', state)
                result = release.prune_releases()
                self.assertCountEqual(result['removedRetiredArtifacts'], [
                    str((artifact_history / package).relative_to(directory)),
                    str((delivery_history / linux).relative_to(directory)),
                ])
                self.assertEqual(release.prune_releases()['removedRetiredArtifacts'], [])
            self.assertEqual(live_package.read_bytes(), b'current package')
            self.assertEqual(evidence.read_text(), '{}')
            self.assertTrue(flat_link.is_symlink())
            self.assertTrue((artifact_history / archive).is_file())
            self.assertTrue((unknown / linux).is_file())
            self.assertEqual(len(result['skipped']), 3)

    def test_resource_retirement_uses_verified_receipts_and_protects_pending_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            control = Path(temporary)

            def published(version):
                return {'version': version, 'directory': str(control / version), 'status': 'complete',
                        'commit': 'a' * 40, 'configuration': {'repository': 'owner/repo'},
                        'steps': {'publish': {'result': {
                            'url': f'https://github.com/owner/repo/releases/tag/v{version}', 'sha256': {
                                f'Tractanda-{version}-arm64.pkg': '1' * 64,
                                f'tractanda-{version}-macos-arm64.tar.gz': '2' * 64,
                                'SHA256SUMS': '3' * 64,
                            }}}}}

            retired, verified, pending, malformed = (f'0.1.0-poc.{n}' for n in (17, 18, 19, 20))
            for version in (retired, verified, pending):
                release.write(control / 'receipts' / (version + '.json'), published(version))
            release.write(control / verified / 'state.json', published(verified))
            release.write(control / 'current.json', {**published(pending), 'status': 'failed'})
            (control / malformed).mkdir()
            (control / malformed / 'state.json').write_text('{')
            with patch.object(release, 'CONTROL', control), patch.object(release, 'git', return_value=''), \
                    patch.object(release.maintenance, 'maintain', return_value={'trimmed': []}) as maintain:
                release.prune_releases(maintain_resources=False)
                maintain.assert_not_called()
                report = release.prune_releases()
                maintain.assert_called_once_with(control, published(verified), {pending, malformed}, {retired, verified})
                self.assertEqual(report['buildResources'], {'trimmed': []})

    def test_malformed_runtime_inventory_leaves_published_release_complete(self):
        with tempfile.TemporaryDirectory() as temporary:
            control = Path(temporary)
            version = '0.1.0-poc.20'
            state = {'version': version, 'directory': str(control / version), 'status': 'complete',
                     'commit': 'a' * 40, 'configuration': {'repository': 'owner/repo'},
                     'steps': {'publish': {'result': {
                         'url': f'https://github.com/owner/repo/releases/tag/v{version}', 'sha256': {
                             f'Tractanda-{version}-arm64.pkg': '1' * 64,
                             f'tractanda-{version}-macos-arm64.tar.gz': '2' * 64,
                             'SHA256SUMS': '3' * 64,
                         }}}}}
            malformed = subprocess.CompletedProcess([], 0, stdout='[null]')
            with patch.object(release, 'CONTROL', control), patch.object(release, 'git', return_value=''), \
                    patch.object(release.maintenance, 'invoke', return_value=malformed) as invoke:
                pipeline = release.Pipeline(state)
                pipeline.save()
                release.record_release_retention(pipeline)
                invoke.assert_called()
            saved = release.read(control / 'current.json')
            self.assertEqual(saved['status'], 'complete')
            resources = saved['retention']['buildResources']
            self.assertTrue(resources.get('warning') or resources.get('warnings'), resources)

    def test_prune_does_not_follow_version_or_receipt_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            control = root / 'control'; control.mkdir()
            outside = root / 'outside'; outside.mkdir()
            important = outside / 'keep'; important.write_text('user data')
            (control / '0.1.0-poc.99').symlink_to(outside, target_is_directory=True)
            with patch.object(release, 'CONTROL', control), patch.object(release, 'git', return_value=''):
                self.assertEqual(release.prune_releases()['removed'], [])
                self.assertEqual(important.read_text(), 'user data')
                (control / 'receipts').symlink_to(outside, target_is_directory=True)
                with self.assertRaisesRegex(RuntimeError, 'symlinks'):
                    release.prune_releases()
                self.assertEqual(list(outside.iterdir()), [important])

    def test_manual_prune_and_release_share_the_same_exclusion_lock(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(release, 'CONTROL', Path(temporary)):
            with release.lock():
                with self.assertRaisesRegex(RuntimeError, 'Another release operation'):
                    with release.lock():
                        self.fail('Concurrent release mutation was admitted')

    def test_retention_runs_only_after_publication_is_marked_complete(self):
        pipeline = object.__new__(release.Pipeline)
        pipeline.directory = Path('/unused')
        pipeline.source = Path('/unused/source')
        pipeline.state = {'status': 'ready', 'commit': 'test', 'steps': {}, 'delivery': release.delivery.fresh()}
        pipeline.save = lambda: None
        pipeline.step = lambda name, action: pipeline.state['steps'].update({name: {}})
        pipeline.verify_artifacts = lambda: None
        pipeline.health = lambda: {}
        pipeline.install_gate = lambda: pipeline.state['steps'].update({'install-authorization': {}}) or True
        pipeline.cluster_gate = lambda: pipeline.state['steps'].update({'cluster-acceptance': {}}) or True
        pipeline.wait_for_ci = lambda timeout: pipeline.state['steps'].update({'ci': {}})
        pipeline.prepare_disposable = lambda: None
        pipeline.verify_promoted_bundle = lambda: None
        seen = []
        def retention(value):
            self.assertEqual(value.state['status'], 'complete')
            self.assertEqual(set(value.state['steps']), set(release.delivery.release_plan(release.RELEASE_STEPS)))
            seen.append(value)
        with patch.object(release, 'git', side_effect=['test', '']), \
                patch.object(release, 'record_release_retention', side_effect=retention):
            pipeline.run()
        self.assertEqual(seen, [pipeline])

    def test_verified_publication_requires_exact_receipt(self):
        version = '0.1.0-poc.10'
        hashes = {
            f'tractanda-{version}-macos-arm64.tar.gz': 'a' * 64,
            f'Tractanda-{version}-arm64.pkg': 'b' * 64, 'SHA256SUMS': 'c' * 64,
        }
        state = {'version': version, 'commit': 'd' * 40, 'status': 'complete',
                 'configuration': {'repository': 'owner/repo'},
                 'steps': {'publish': {'result': {
                     'url': f'https://github.com/owner/repo/releases/tag/v{version}', 'sha256': hashes}}}}
        self.assertTrue(release.is_verified_published(state))
        state['steps']['publish']['result']['url'] = 'https://example.invalid/'
        self.assertFalse(release.is_verified_published(state))

    def test_retention_warning_is_recorded_without_failing_published_pipeline(self):
        pipeline = type('Pipeline', (), {'state': {}, 'save': lambda self: None})()
        with patch.object(release, 'prune_releases', side_effect=RuntimeError('disk unavailable')):
            release.record_release_retention(pipeline)
        self.assertEqual(pipeline.state['retention'], {'warning': 'disk unavailable'})

    def test_prune_uses_real_git_worktrees_and_later_removes_compacted_release(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary) / 'repo'; repo.mkdir()
            def run(*args, cwd=repo):
                return subprocess.check_output(['git', *args], cwd=cwd, text=True).strip()
            run('init'); (repo / 'tracked').write_text('x')
            run('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'add', 'tracked')
            run('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-m', 'test')
            commit = run('rev-parse', 'HEAD')
            unrelated = repo / 'unrelated'
            run('worktree', 'add', '--detach', str(unrelated), commit)
            shutil.rmtree(unrelated)
            control = repo / 'work/release-pipeline'; control.mkdir(parents=True)
            def state(version, directory, complete=True):
                result = {'version': version, 'directory': str(directory), 'commit': commit,
                          'configuration': {'repository': 'owner/repo'}, 'status': 'complete' if complete else 'running',
                          'steps': {}}
                if complete:
                    result['steps']['publish'] = {'result': {'url': f'https://github.com/owner/repo/releases/tag/v{version}', 'sha256': {
                        f'tractanda-{version}-macos-arm64.tar.gz': 'a' * 64,
                        f'Tractanda-{version}-arm64.pkg': 'b' * 64, 'SHA256SUMS': 'c' * 64}}}
                return result
            directories = {}
            for suffix, complete in [('8', True), ('9', True), ('10', True), ('11', False), ('2', True)]:
                version = '0.1.0-poc.' + suffix; directory = control / version; directory.mkdir(); directories[suffix] = directory
                release.write(directory / 'state.json', state(version, directory, complete))
                run('worktree', 'add', '--detach', str(directory / 'source'), commit)
                (directory / f'Tractanda-{version}-arm64.pkg').write_bytes(b'pkg')
                (directory / f'tractanda-{version}-macos-arm64.tar.gz').write_bytes(b'tar')
            (directories['8'] / 'source' / 'dirty').write_text('dirty')
            shutil.rmtree(directories['2'] / 'source')
            release.write(control / 'current.json', state('0.1.0-poc.11', directories['11'], False))
            def adapter(*args, cwd=None): return run(*args, cwd=Path(cwd) if cwd else repo)
            with patch.object(release, 'CONTROL', control), patch.object(release, 'git', side_effect=adapter), \
                    patch.object(release.maintenance, 'maintain'):
                first = release.prune_releases()
                self.assertIn('0.1.0-poc.9', first['removed'], first)
                self.assertFalse(directories['9'].exists())
                self.assertFalse((directories['10'] / 'source').exists())
                self.assertTrue((directories['10'] / 'Tractanda-0.1.0-poc.10-arm64.pkg').exists())
                self.assertTrue(directories['11'].exists())
                self.assertTrue(directories['8'].exists())
                release.write(directories['11'] / 'state.json', state('0.1.0-poc.11', directories['11'], True))
                release.write(control / 'current.json', state('0.1.0-poc.11', directories['11'], True))
                second = release.prune_releases()
                self.assertIn('0.1.0-poc.10', second['removed'])
                self.assertFalse(directories['10'].exists())
                remaining = run('worktree', 'list', '--porcelain', '-z')
                self.assertIn(str(unrelated.resolve()), remaining)
                self.assertNotIn(str((directories['2'] / 'source').resolve()), remaining)

    def test_completed_steps_resume_and_failures_are_not_acknowledged(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            state = {'directory': str(root), 'configuration': {}, 'version': '0.1.0-poc.2', 'steps': {}}
            with patch.object(release, 'CONTROL', root / 'control'):
                pipeline = release.Pipeline(state)
                effects = []
                pipeline.step('first', lambda: effects.append('once'))
                pipeline.step('first', lambda: effects.append('twice'))
                self.assertEqual(effects, ['once'])
                def fail():
                    raise RuntimeError('interrupted')
                with self.assertRaises(RuntimeError):
                    pipeline.step('next', fail)
                self.assertNotIn('next', state['steps'])
                resumed = release.Pipeline(release.read(root / 'state.json'))
                resumed.step('first', lambda: effects.append('again'))
                self.assertEqual(effects, ['once'])

    def test_candidate_digest_guard_precedes_install_or_upload(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            state = {'directory': str(root), 'configuration': {}, 'version': '0.1.0-poc.2', 'steps': {}}
            pipeline = release.Pipeline(state)
            pipeline.bundle.mkdir()
            manifest = pipeline.bundle / 'bundle-manifest.json'
            manifest.write_text('{}')
            artifact = root / 'candidate.pkg'
            artifact.write_bytes(b'candidate')
            state['steps'] = {'bundle': {'result': {'manifestSHA256': release.sha(manifest)}},
                              'artifacts': {'result': {'candidate.pkg': release.sha(artifact)}}}
            pipeline.verify_artifacts()
            artifact.write_bytes(b'replaced')
            with self.assertRaises(RuntimeError):
                pipeline.verify_artifacts()

    def test_retention_keeps_current_previous_and_other_database_versions(self):
        receipt = {'release': 'current', 'releases': {'current': 'a', 'previous': 'b', 'obsolete': 'c', 'shared': 'd'}}
        other = {'release': 'shared', 'releases': {'shared': 'd'}}
        self.assertEqual(activate.obsolete_releases(receipt, 'previous', [other]), {'obsolete': 'c'})


if __name__ == '__main__':
    unittest.main()
