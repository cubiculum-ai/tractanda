#!/usr/bin/env python3
"""Portable, side-effect-free checks for the release controller's safety gates."""
import importlib.util
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


class ReleaseTests(unittest.TestCase):
    def test_release_configuration_does_not_require_a_notary_profile(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'config.json'
            settings = {key: 'configured' for key in (
                'branch', 'softwareRoot', 'applicationIdentity', 'installerIdentity',
                'embeddingHost', 'modelDirectory', 'modelNotices')}
            settings.update(repository='owner/repo', instance='production', developerTeamID='ABCDE12345')
            release.write(path, settings)
            self.assertEqual(release.config(path), settings)

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

    def test_versions_and_scope(self):
        self.assertEqual(release.next_version('0.1.0-poc.9'), '0.1.0-poc.10')
        with self.assertRaises(ValueError):
            release.next_version('../bad')
        self.assertTrue(release.significant(['Sources/TractandaCore/Service.swift']))
        self.assertTrue(release.significant(['plugins/tractanda/skills/tractanda/SKILL.md']))
        self.assertFalse(release.significant(['work/notes.md', 'outputs/Tractanda-Resume.md']))

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
