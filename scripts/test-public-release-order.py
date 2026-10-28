#!/usr/bin/env python3
"""The authorized public sequence publishes and verifies before any live update."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('public_release', Path(__file__).with_name('release-macos.py'))
R = importlib.util.module_from_spec(spec); spec.loader.exec_module(R)


class PublicReleaseTests(unittest.TestCase):
    def test_publication_and_source_pages_verification_precede_install(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = {'directory': temporary, 'configuration': {}, 'version': '0.1.0-poc.16',
                     'commit': 'a' * 40, 'tree': 'b' * 40, 'status': 'ready', 'steps': {},
                     'delivery': R.delivery.public_fresh()}
            p = R.Pipeline(state); observed = []
            p.save = lambda: None
            for name in ('build', 'assemble', 'build_package', 'notarize_package', 'build_apt',
                         'package_artifacts', 'push', 'publish', 'verify_published_source',
                         'published_pages', 'install', 'health', 'cleanup'):
                setattr(p, name, lambda n=name: observed.append(n) or {})
            p.run_command = lambda *args: observed.append('verify')
            p.verify_artifacts = lambda: None
            p.wait_for_ci = lambda timeout: state['steps'].update(ci={})
            with patch.object(R, 'git', side_effect=['a' * 40, '']), patch.object(R, 'record_release_retention'):
                p.run()
            self.assertEqual(list(state['steps']), list(R.PUBLIC_STEPS))
            self.assertLess(observed.index('publish'), observed.index('install'))
            self.assertLess(observed.index('published_pages'), observed.index('install'))
            self.assertLess(observed.index('verify_published_source'), observed.index('install'))
            self.assertNotIn('install-authorization', state['steps'])
            self.assertEqual(state['status'], 'complete')

    def test_install_refuses_missing_published_source_or_pages(self):
        with tempfile.TemporaryDirectory() as temporary:
            p = R.Pipeline({'directory': temporary, 'configuration': {}, 'version': '0.1.0-poc.16',
                            'steps': {}, 'delivery': R.delivery.public_fresh()})
            with self.assertRaisesRegex(RuntimeError, 'Published source'):
                p.verify_published_package()

    def test_source_ci_repair_needs_terminal_failure_absence_and_closed_runner(self):
        with tempfile.TemporaryDirectory() as temporary:
            control = Path(temporary)
            (control / 'runner.json').write_text(json.dumps({'version': '0.1.0-poc.16', 'pid': 123,
                                                           'status': 'failed', 'stoppedAt': 'now'}))
            state = {'version': '0.1.0-poc.16', 'commit': 'a' * 40, 'status': 'failed', 'activeStep': 'ci',
                     'configuration': {'repository': 'owner/repo'}, 'delivery': R.delivery.public_fresh(),
                     'steps': {s: {} for s in R.PUBLIC_STEPS[:R.PUBLIC_STEPS.index('ci')]}}
            failed = [{'headSha': 'a' * 40, 'status': 'completed', 'conclusion': 'failure'}]
            with patch.object(R, 'CONTROL', control), patch.object(R.os, 'kill', side_effect=ProcessLookupError), \
                    patch.object(R, 'command', return_value=json.dumps(failed)), \
                    patch.object(R, 'require_unpublished_version', return_value={'remoteReleaseAbsent': True}) as absent:
                self.assertEqual(R.require_public_ci_repair(state)['gate'], 'public-pre-update-ci')
                absent.assert_called_once_with(state)
                state['steps']['publish'] = {}
                with self.assertRaisesRegex(RuntimeError, 'pre-publication'):
                    R.require_public_ci_repair(state)


if __name__ == '__main__': unittest.main(verbosity=2)
