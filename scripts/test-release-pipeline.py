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
