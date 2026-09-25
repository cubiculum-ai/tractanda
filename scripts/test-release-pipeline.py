#!/usr/bin/env python3
"""Portable, side-effect-free checks for the release controller's safety gates."""
import importlib.util
import json
import subprocess
import shutil
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


class ReleaseTests(unittest.TestCase):
    def test_declared_plan_matches_every_executed_stage(self):
        # Run the actual orchestration with side effects replaced, so adding a
        # stage without updating the plan cannot silently misstate progress.
        pipeline = object.__new__(release.Pipeline)
        pipeline.state = {'status': 'ready', 'commit': 'test', 'steps': {}}
        pipeline.source = Path('/unused')
        pipeline.save = lambda: None
        pipeline.step = lambda name, action: pipeline.state['steps'].update({name: {}})
        pipeline.verify_artifacts = lambda: None
        pipeline.health = lambda: {}
        pipeline.wait_for_ci = lambda timeout: pipeline.state['steps'].update({'ci': {}})
        with patch.object(release, 'git', side_effect=['test', '']):
            pipeline.run()
        self.assertEqual(pipeline.state['plannedSteps'], list(release.RELEASE_STEPS))
        self.assertEqual(list(pipeline.state['steps']), list(release.RELEASE_STEPS))
        self.assertEqual(pipeline.state['status'], 'complete')

    def test_release_configuration_does_not_require_a_notary_profile(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'config.json'
            settings = {key: 'configured' for key in (
                'branch', 'softwareRoot', 'applicationIdentity', 'installerIdentity',
                'modelDirectory')}
            settings.update(repository='owner/repo', instance='production', developerTeamID='ABCDE12345')
            release.write(path, settings)
            self.assertEqual(release.config(path), settings)

    def test_release_builds_the_embedding_host_from_the_sealed_source(self):
        pipeline = release.Pipeline({'directory': '/unused', 'configuration': {'modelDirectory': '/model'},
                                    'version': 'test', 'steps': {}})
        with patch.object(pipeline, 'run_command') as run, patch.object(release, 'command', return_value='/built'):
            pipeline.build()
        self.assertEqual(run.call_count, 3)
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
                vmlxRevision='b7a2b97efc2d8ed44ddf3c4b7af25766b372339f', dimensions=768,
                pooling='cls', normalization='l2', revision='fixture',
                assets={'model.safetensors': packager.digest(weights)})
            with patch.object(packager, 'run', return_value=json.dumps(profile)):
                self.assertEqual(packager.embedding_descriptor(Path('/helper'), directory)['dimensions'], 768)
                weights.write_bytes(b'changed')
                with self.assertRaisesRegex(ValueError, 'pinned hashes'):
                    packager.embedding_descriptor(Path('/helper'), directory)
                weights.write_bytes(b'fixture weights')
                (directory / 'extra.json').write_text('{}')
                with self.assertRaisesRegex(ValueError, 'pinned hashes'):
                    packager.embedding_descriptor(Path('/helper'), directory)
            with patch.object(packager, 'run', return_value=json.dumps({**profile, 'alias': 'old-model'})):
                with self.assertRaisesRegex(ValueError, 'Granite profile'):
                    packager.embedding_descriptor(Path('/helper'), directory)

    def test_health_rejects_a_live_server_still_using_the_previous_model(self):
        pipeline = release.Pipeline({'directory': '/unused', 'version': 'test', 'steps': {},
            'configuration': {'softwareRoot': '/installed', 'instance': 'production'}})
        manifest = {'files': [{'path': 'bin/tractanda', 'sha256': 'signed'}],
                    'embedding': {'model': 'granite'}}
        native = json.dumps({'server': {'executableSHA256': 'signed'}})
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

    def test_versions_and_scope(self):
        self.assertEqual(release.next_version('0.1.0-poc.9'), '0.1.0-poc.10')
        with self.assertRaises(ValueError):
            release.next_version('../bad')
        self.assertTrue(release.significant(['Sources/TractandaCore/Service.swift']))
        self.assertTrue(release.significant(['plugins/tractanda/skills/tractanda/SKILL.md']))
        self.assertFalse(release.significant(['work/notes.md', 'outputs/Tractanda-Resume.md']))

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
            with patch.object(release, 'git', return_value=''):
                result = release.prune_releases()
            self.assertEqual(result['removed'], ['0.1.0-poc.9'])
            self.assertFalse((old / 'bundle').exists())
            self.assertFalse((newest / 'bundle').exists())
            self.assertTrue(malformed.exists())

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
        pipeline.state = {'status': 'ready', 'commit': 'test', 'steps': {}}
        pipeline.save = lambda: None
        pipeline.step = lambda name, action: pipeline.state['steps'].update({name: {}})
        pipeline.verify_artifacts = lambda: None
        pipeline.health = lambda: {}
        pipeline.wait_for_ci = lambda timeout: pipeline.state['steps'].update({'ci': {}})
        seen = []
        def retention(value):
            self.assertEqual(value.state['status'], 'complete')
            self.assertEqual(set(value.state['steps']), set(release.RELEASE_STEPS))
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
            with patch.object(release, 'CONTROL', control), patch.object(release, 'git', side_effect=adapter):
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

    def test_canonical_preservation_accepts_append_only_and_rejects_rewrites(self):
        before = {'items/old.tractanda': 'a'}
        activate.require_preserved(before, {**before, 'items/new.tractanda': 'b'})
        for after in ({}, {'items/old.tractanda': 'changed'}):
            with self.assertRaises(RuntimeError):
                activate.require_preserved(before, after)

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
