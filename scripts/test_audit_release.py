#!/usr/bin/env python3
"""Focused release-audit allowlist and private-content regression tests."""
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
AUDIT_SCRIPT = ROOT / 'scripts/audit-release.py'
FIXTURE_DIR = ROOT / 'Packages/TractandaDocuments/Tests/DoclingRasterTests/Fixtures'
PDF_PATH = 'Packages/TractandaDocuments/Tests/DoclingRasterTests/Fixtures/three-pages.pdf'


def synthetic_three_page_pdf():
    """Create the tiny vector-only geometry/rotation/color fixture used by RasterTests."""
    objects = [
        b'<< /Type /Catalog /Pages 2 0 R >>',
        b'<< /Type /Pages /Kids [3 0 R 5 0 R 7 0 R] /Count 3 >>',
        b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] /CropBox [10 20 110 220] /Rotate 0 /Resources << >> /Contents 4 0 R >>',
        b'<< /Length 28 >>\nstream\n1 0 0 rg 10 20 100 200 re f\nendstream',
        b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] /CropBox [10 20 110 220] /Rotate 90 /Resources << >> /Contents 6 0 R >>',
        b'<< /Length 28 >>\nstream\n0 0 1 rg 10 20 100 200 re f\nendstream',
        b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] /CropBox [10 20 110 220] /Rotate 0 /Resources << >> /Contents 8 0 R >>',
        b'<< /Length 28 >>\nstream\n0 1 0 rg 10 20 100 200 re f\nendstream',
    ]
    output = bytearray(b'%PDF-1.7\n')
    offsets = [0]
    for index, body in enumerate(objects, 1):
        offsets.append(len(output))
        output.extend(f'{index} 0 obj\n'.encode() + body + b'\nendobj\n')
    xref = len(output)
    output.extend(b'xref\n0 9\n0000000000 65535 f \n')
    for offset in offsets[1:]:
        output.extend(f'{offset:010d} 00000 n \n'.encode())
    output.extend(f'trailer << /Size 9 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode())
    return bytes(output)


class ReleaseAuditTests(unittest.TestCase):
    def audit_fixture_repo(self):
        temporary = tempfile.TemporaryDirectory(prefix='tractanda-release-audit-')
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        (root / 'scripts').mkdir()
        shutil.copyfile(AUDIT_SCRIPT, root / 'scripts/audit-release.py')
        shutil.copyfile(ROOT / '.gitignore', root / '.gitignore')
        (root / 'debian').mkdir()
        (root / 'debian/tractanda.control.in').write_text('Package: tractanda\nVersion: 0.1.0-test\n')
        for relative in __import__('runpy').run_path(str(AUDIT_SCRIPT))['PUBLIC_BINARY_FIXTURES']:
            destination = root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            if relative == PDF_PATH:
                destination.write_bytes(synthetic_three_page_pdf())
            else:
                destination.write_bytes((ROOT / relative).read_bytes())
        subprocess.run(['git', 'init', '--quiet'], cwd=root, check=True)
        tracked = ['.gitignore', 'scripts/audit-release.py', 'debian/tractanda.control.in']
        tracked.extend(__import__('runpy').run_path(str(AUDIT_SCRIPT))['PUBLIC_BINARY_FIXTURES'])
        subprocess.run(['git', 'add', '--', *tracked], cwd=root, check=True)
        (root / '.facelift/cache').mkdir(parents=True)
        (root / '.facelift/cache/generated.json').write_text('{"generated":true}\n')
        return root

    def run_audit(self, root):
        output = root / 'work/release-audit.json'
        output.parent.mkdir(parents=True, exist_ok=True)
        result = subprocess.run(
            [sys.executable, str(root / 'scripts/audit-release.py'), '--output', str(output)],
            cwd=root, capture_output=True, text=True, timeout=20)
        return result, json.loads(output.read_text())

    def test_public_binary_fixture_bytes_are_exact_and_pdf_is_reproducible(self):
        namespace = __import__('runpy').run_path(str(AUDIT_SCRIPT))
        fixture_hashes = namespace['PUBLIC_BINARY_FIXTURES']
        for relative, expected in fixture_hashes.items():
            data = synthetic_three_page_pdf() if relative == PDF_PATH else (ROOT / relative).read_bytes()
            self.assertEqual((len(data), hashlib.sha256(data).hexdigest()), expected, relative)
        actual_pdf = (ROOT / PDF_PATH).read_bytes()
        self.assertEqual(synthetic_three_page_pdf(), actual_pdf)
        raster_tests = (ROOT / 'Packages/TractandaDocuments/Tests/DoclingRasterTests/RasterTests.swift').read_text()
        self.assertIn('fixture("three-pages.pdf")', raster_tests)
        for filename in (Path(path).name for path in fixture_hashes if path != PDF_PATH):
            self.assertIn(f'"{filename}"', raster_tests)

    def test_debian_source_and_exact_fixtures_pass_but_cache_is_ignored(self):
        root = self.audit_fixture_repo()
        ignored = subprocess.run(
            ['git', 'check-ignore', '--quiet', '.facelift/cache/generated.json'], cwd=root, check=False)
        self.assertEqual(ignored.returncode, 0)
        result, report = self.run_audit(root)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(report['status'], 'passed')
        paths = {row['path'] for row in report['manifest']}
        self.assertNotIn('.facelift/cache/generated.json', paths)
        self.assertIn('debian/tractanda.control.in', paths)
        self.assertTrue(set(__import__('runpy').run_path(str(AUDIT_SCRIPT))['PUBLIC_BINARY_FIXTURES']) <= paths)

    def test_changed_binary_private_large_and_noncache_paths_remain_rejected(self):
        root = self.audit_fixture_repo()
        alpha = root / 'Packages/TractandaDocuments/Tests/DoclingRasterTests/Fixtures/alpha.png'
        alpha.write_bytes(alpha.read_bytes() + b'changed')
        (root / '.facelift/notes.json').write_text('{"local":true}\n')
        (root / 'debian/reference.pdf').write_bytes(b'%PDF-1.7\nnot an admitted fixture\n')
        subprocess.run(['git', 'add', '--force', '--', 'debian/reference.pdf'], cwd=root, check=True)
        (root / 'debian/unapproved.bin').write_bytes(b'\x00\xff')
        (root / 'debian/work').mkdir()
        (root / 'debian/work/private.txt').write_text('private\n')
        (root / 'debian/large.txt').write_bytes(b'x' * 2_000_001)
        result, report = self.run_audit(root)
        self.assertEqual(result.returncode, 1)
        findings = {(row['path'], row['rule']) for row in report['findings']}
        self.assertIn(('Packages/TractandaDocuments/Tests/DoclingRasterTests/Fixtures/alpha.png',
                       'binary file requires explicit review'), findings)
        self.assertIn(('.facelift/notes.json', 'unexpected release path'), findings)
        self.assertIn(('debian/reference.pdf', 'excluded reference/runtime/secret format'), findings)
        self.assertIn(('debian/unapproved.bin', 'binary file requires explicit review'), findings)
        self.assertIn(('debian/work/private.txt', 'private/development directory'), findings)
        self.assertIn(('debian/large.txt', 'large source file requires review'), findings)
        self.assertNotIn(('.facelift/cache/generated.json', 'unexpected release path'), findings)

    def test_exact_public_model_catalog_passes(self):
        root = self.audit_fixture_repo()
        (root / 'config').mkdir()
        shutil.copyfile(ROOT / 'config/model-artifacts.json', root / 'config/model-artifacts.json')
        subprocess.run(['git', 'add', '--', 'config/model-artifacts.json'], cwd=root, check=True)
        result, report = self.run_audit(root)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(report['status'], 'passed')
        self.assertIn('config/model-artifacts.json', {row['path'] for row in report['manifest']})

    def test_unrelated_config_path_remains_rejected(self):
        root = self.audit_fixture_repo()
        (root / 'config').mkdir()
        (root / 'config/local-settings.json').write_text('{"private":true}\n')
        subprocess.run(['git', 'add', '--force', '--', 'config/local-settings.json'], cwd=root, check=True)
        result, report = self.run_audit(root)
        self.assertEqual(result.returncode, 1)
        self.assertIn(('config/local-settings.json', 'unexpected release path'),
                      {(row['path'], row['rule']) for row in report['findings']})


if __name__ == '__main__':
    unittest.main()
