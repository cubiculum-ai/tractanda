#!/usr/bin/env python3
"""Pages retains the manual and authenticates/extracts only bounded APT files."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('assemble_pages', Path(__file__).with_name('assemble-pages.py'))
P = importlib.util.module_from_spec(spec); spec.loader.exec_module(P)


class PagesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); (self.root / 'docs/apt').mkdir(parents=True)
        for name in ('docs/index.html', 'LICENSE', 'NOTICE'):
            (self.root / name).write_text(name)
        (self.root / 'docs/apt/fingerprint.txt').write_text('A' * 40)
        (self.root / 'docs/apt/tractanda-archive-keyring.asc').write_bytes(b'pinned public key')

    def archive(self, name='apt/tractanda-archive-keyring.asc'):
        target = self.root / 'apt-site.tar.gz'
        with tarfile.open(target, 'w:gz') as stream:
            raw = b'pinned public key'; info = tarfile.TarInfo(name); info.size = len(raw)
            stream.addfile(info, io.BytesIO(raw))
        (self.root / 'SHA256SUMS').write_text(hashlib.sha256(target.read_bytes()).hexdigest() + '  apt-site.tar.gz\n')

    def tool_run(self, args, **kwargs):
        if args[:2] == ['gh', 'api']:
            return json.dumps([{'draft': False, 'published_at': '2026-10-28', 'tag_name': 'v0.1.0-poc.16',
                                'assets': [{'name': 'apt-site.tar.gz'}, {'name': 'SHA256SUMS'}]}]).encode()
        target = Path(args[args.index('--dir') + 1])
        for name in ('apt-site.tar.gz', 'SHA256SUMS'): shutil.copyfile(self.root / name, target / name)

    def test_combined_manual_and_verified_apt(self):
        self.archive(); output = self.root / 'site'
        with patch.object(P, 'ROOT', self.root), patch.object(P.apt, 'run', side_effect=self.tool_run), \
                patch.object(P.apt, 'verify', return_value={'verified': True}) as verify:
            result = P.assemble(output, 'owner/repo')
        self.assertEqual((output / 'index.html').read_text(), 'docs/index.html')
        self.assertEqual((output / 'apt/tractanda-archive-keyring.asc').read_bytes(), b'pinned public key')
        self.assertEqual(result['release'], 'v0.1.0-poc.16')
        verify.assert_called_once_with(output / 'apt', self.root / 'docs/apt/tractanda-archive-keyring.asc', 'A' * 40)

    def test_checksum_traversal_and_missing_release_fail(self):
        for defect in ('checksum', 'traversal', 'missing'):
            with self.subTest(defect=defect):
                self.archive('apt/../../escape' if defect == 'traversal' else 'apt/tractanda-archive-keyring.asc')
                if defect == 'checksum': (self.root / 'apt-site.tar.gz').write_bytes(b'changed')
                with patch.object(P, 'ROOT', self.root), patch.object(P.apt, 'run', side_effect=self.tool_run):
                    with self.assertRaises(ValueError):
                        P.assemble(self.root / defect, 'owner/repo', 'v0.1.0-poc.99' if defect == 'missing' else None)
        self.assertFalse((self.root / 'escape').exists())


if __name__ == '__main__': unittest.main(verbosity=2)
