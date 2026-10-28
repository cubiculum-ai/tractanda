#!/usr/bin/env python3
"""Finite source-template normalization must not hide compiler-input changes."""
import hashlib, importlib.util, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('normalization', ROOT / 'scripts/linux-docling-provenance.py')
N = importlib.util.module_from_spec(spec); spec.loader.exec_module(N)

class TemplateNormalizationTests(unittest.TestCase):
    def test_only_architecture_digests_are_normalized(self):
        for path in (N.CLIENT, N.CONVERTER):
            with self.subTest(path=path):
                source = (ROOT / path).read_bytes(); normalized, original = N.normalize(path, source)
                changed = source.replace(original['amd64'].encode(), b'a' * 64).replace(original['arm64'].encode(), b'b' * 64)
                normalized_changed, values = N.normalize(path, changed)
                self.assertEqual(normalized, normalized_changed)
                self.assertEqual(values, {'amd64': 'a' * 64, 'arm64': 'b' * 64})
                altered = changed.replace(b'owner', b'ownerX') if b'owner' in changed else changed.replace(b'Finite', b'FinitE')
                other, _ = N.normalize(path, altered)
                self.assertNotEqual(hashlib.sha256(normalized).digest(), hashlib.sha256(other).digest())
    def test_missing_or_extra_digest_fields_fail(self):
        for path in (N.CLIENT, N.CONVERTER):
            source = (ROOT / path).read_bytes(); _, values = N.normalize(path, source)
            with self.subTest(path=path):
                with self.assertRaises(AssertionError): N.normalize(path, source.replace(values['arm64'].encode(), b'not-a-digest'))
                with self.assertRaises(AssertionError): N.normalize(path, source + b'\n' + b'c' * 64 + b'\n')
    def test_mismatched_architecture_values_fail_capture(self):
        # The row capture cross-checks both independently normalized templates.
        class Component: SOURCE_ROOTS = (N.CLIENT, N.CONVERTER, N.REGISTRY)
        class Producer:
            SKIP = set()
            @staticmethod
            def rows(root, roots, skip):
                rows=[]
                for name in roots:
                    p=root/name; rows.append({'path':name,'mode':0o644,'size':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
                return rows
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            for name in (N.CLIENT,N.CONVERTER,N.REGISTRY):
                p=root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((ROOT/name).read_bytes())
            expected={name:hashlib.sha256(N.normalize(name,(root/name).read_bytes())[0]).hexdigest() for name in (N.CLIENT,N.CONVERTER)}
            rows,actual=N.normalized_rows(Producer,Component,root,expected);self.assertEqual(len(rows),2)
            p=root/N.CLIENT;old=actual[N.CLIENT]['digests']['arm64'];p.write_bytes(p.read_bytes().replace(old.encode(),b'f'*64))
            with self.assertRaises(AssertionError):N.normalized_rows(Producer,Component,root,expected)

if __name__ == '__main__': unittest.main(verbosity=2)
