#!/usr/bin/env python3
"""Private package-choice and hook tests; no Installer or system paths are changed."""
import importlib.util
import hashlib
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('tractanda_pkg', ROOT / 'scripts/build-macos-pkg.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)

class PackageSelectionTests(unittest.TestCase):
    def test_distribution_requires_payload_and_defaults_sample_with_customization(self):
        manifest = {'version': '0.1.0', 'files': [{'size': 1024}]}
        root = builder.make_distribution(manifest, 'base.id', 'Tractanda.pkg', 'sample.id', 'Sample.pkg')
        self.assertEqual(root.find('options').get('customize'), 'allow')
        choices = {node.get('id'): node for node in root.findall('choice')}
        self.assertEqual(choices['tractanda'].get('selected'), 'true')
        self.assertEqual(choices['tractanda'].get('enabled'), 'false')
        self.assertEqual(choices['sample-store'].get('start_selected'), 'true')
        self.assertEqual(choices['sample-store'].find('pkg-ref').get('id'), 'sample.id')
        self.assertEqual([x.get('choice') for x in root.find('choices-outline')], ['tractanda', 'sample-store'])
        conclusion = builder.render_conclusion('@FRESH_TARGET_JOIN@', '/protected/release')
        self.assertIn('/protected/release/bin/tractanda', conclusion)
        self.assertIn('cluster join --prepare-new production', conclusion)
        self.assertIn('--hostname HOSTNAME', conclusion)
        self.assertNotIn('--store-id', conclusion)
        self.assertNotIn('--code', conclusion)

    def test_installer_only_targets_new_roots(self):
        for name in ('preinstall', 'postinstall', 'postinstall-sample'):
            source = (ROOT / 'scripts/macos-package' / name).read_text()
            self.assertNotIn('/Users/Shared', source)
            self.assertIn('/Library/Tractanda/', source)
        builder_source = (ROOT / 'scripts/build-macos-pkg.py').read_text()
        self.assertIn('/Library/Tractanda/Software/releases/', builder_source)
        self.assertNotIn('/Users/Shared/Library/Application Support', builder_source)

    def test_candidate_payload_already_present_does_not_discover_legacy_copy(self):
        # Simulate Installer's pre/post hooks with the candidate already in the
        # new release tree. The unselected cloud copy remains opaque and intact.
        with tempfile.TemporaryDirectory(prefix='tractanda-pkg-existing-payload-') as temp:
            root = Path(temp); base = root / 'Software'; installation = root / 'Installation'
            configuration = root / 'Configuration'; scripts = root / 'scripts'
            release = base / 'releases/candidate'; (release / 'bin').mkdir(parents=True)
            scripts.mkdir(); legacy = root / 'cloud-copy/receipts'; legacy.mkdir(parents=True)
            sentinel = legacy / 'production.json'; sentinel.write_bytes(b'opaque unselected copy')
            log = root / 'setup.log'; setup = release / 'bin/tractanda-setup'
            setup.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALL_LOG"\n'); setup.chmod(0o755)
            (scripts / 'release-path').write_text(str(release) + '\n')
            (scripts / 'setup-sha256').write_text(hashlib.sha256(setup.read_bytes()).hexdigest() + '\n')
            stat = root / 'stat'; stat.write_text('#!/bin/sh\ncase "$2" in %Op) echo 755;; *) echo 0;; esac\n'); stat.chmod(0o755)
            for name in ('preinstall', 'postinstall'):
                text = (ROOT / 'scripts/macos-package' / name).read_text()
                text = text.replace("base='/Library/Tractanda/Software'", 'base=' + shlex.quote(str(base)))
                text = text.replace("installation='/Library/Tractanda/Installation'", 'installation=' + shlex.quote(str(installation)))
                text = text.replace("configuration='/Library/Tractanda/Configuration'", 'configuration=' + shlex.quote(str(configuration)))
                text = text.replace('/Library /Library/Tractanda "$base"', shlex.quote(str(root)) + ' "$base"')
                text = text.replace('/usr/bin/stat', shlex.quote(str(stat)))
                path = scripts / name; path.write_text(text); path.chmod(0o755)
            env = dict(os.environ, CALL_LOG=str(log))
            for name in ('preinstall', 'postinstall'):
                subprocess.run(['/bin/sh', str(scripts / name), '', '', '/'], env=env,
                               text=True, capture_output=True, check=True)
            self.assertEqual(log.read_text().splitlines(), ['plan --bundle ' + str(release)])
            self.assertEqual(sentinel.read_bytes(), b'opaque unselected copy')
            self.assertFalse(installation.exists())

    def test_fresh_software_only_sample_and_existing_upgrade(self):
        with tempfile.TemporaryDirectory(prefix='tractanda-pkg-hook-') as temp:
            root = Path(temp); base = root / 'base'; bundle = root / 'release'; scripts = root / 'scripts'
            (bundle / 'bin').mkdir(parents=True); scripts.mkdir(); base.mkdir()
            log = root / 'setup.log'; setup = bundle / 'bin/tractanda-setup'
            setup.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALL_LOG"\n')
            setup.chmod(0o755); (scripts / 'release-path').write_text(str(bundle) + '\n')
            stat = root / 'stat'
            stat.write_text('#!/bin/sh\nif [ "$2" = "%Su" ]; then echo fixture; else echo 0; fi\n')
            stat.chmod(0o755)
            for source, name in [('postinstall', 'payload'), ('postinstall-sample', 'sample')]:
                text = (ROOT / 'scripts/macos-package' / source).read_text()
                text = text.replace("configuration='/Library/Tractanda/Configuration'", 'configuration=' + shlex.quote(str(base)))
                text = text.replace("installation='/Library/Tractanda/Installation'", 'installation=' + shlex.quote(str(base)))
                text = text.replace('/usr/bin/stat', shlex.quote(str(stat)))
                path = scripts / name; path.write_text(text); path.chmod(0o755)
            env = dict(os.environ, CALL_LOG=str(log))
            def run(name):
                return subprocess.run(['/bin/sh', str(scripts / name), '', '', '/'], env=env,
                                      text=True, capture_output=True, check=True)
            setup.chmod(0o644)
            missing = subprocess.run(['/bin/sh', str(scripts / 'sample'), '', '', '/'], env=env, capture_output=True)
            self.assertNotEqual(missing.returncode, 0, 'sample requires the payload first')
            setup.chmod(0o755)
            run('payload')
            self.assertFalse(log.exists(), 'software-only must not initialize a store')
            run('sample')
            self.assertIn('install --bundle ' + str(bundle) + ' --name default --owner fixture --sample', log.read_text())
            log.unlink(); (base / 'receipts').mkdir(); (base / 'receipts/default.json').write_text('{}')
            run('payload'); run('sample')
            self.assertEqual(log.read_text().splitlines(), ['upgrade --bundle ' + str(bundle) + ' --name default'])

if __name__ == '__main__':
    unittest.main()
