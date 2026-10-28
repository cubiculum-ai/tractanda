#!/usr/bin/env python3
"""Finite source selection must bind real inputs without binding unrelated tests."""
import hashlib, importlib.util, shutil, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
N=load('normalization',ROOT/'scripts/linux-docling-provenance.py')
P=load('producer',ROOT/'scripts/produce-linux-payload.py')

class TemplateNormalizationTests(unittest.TestCase):
    def test_only_architecture_digests_are_normalized(self):
        for path in (N.CLIENT,N.CONVERTER):
            with self.subTest(path=path):
                source=(ROOT/path).read_bytes();normalized,original=N.normalize(path,source)
                changed=source.replace(original['amd64'].encode(),b'a'*64).replace(original['arm64'].encode(),b'b'*64)
                normalized_changed,values=N.normalize(path,changed)
                self.assertEqual(normalized,normalized_changed);self.assertEqual(values,{'amd64':'a'*64,'arm64':'b'*64})
                altered=changed.replace(b'owner',b'ownerX') if b'owner' in changed else changed.replace(b'Finite',b'FinitE')
                other,_=N.normalize(path,altered);self.assertNotEqual(hashlib.sha256(normalized).digest(),hashlib.sha256(other).digest())
    def test_missing_or_extra_digest_fields_fail(self):
        for path in (N.CLIENT,N.CONVERTER):
            source=(ROOT/path).read_bytes();_,values=N.normalize(path,source)
            with self.subTest(path=path):
                with self.assertRaises(AssertionError):N.normalize(path,source.replace(values['arm64'].encode(),b'not-a-digest'))
                with self.assertRaises(AssertionError):N.normalize(path,source+b'\n'+b'c'*64+b'\n')
    def fixture(self,root):
        for name in N.SOURCE_ROOTS:
            src=ROOT/name;dst=root/name;dst.parent.mkdir(parents=True,exist_ok=True)
            if src.is_dir():shutil.copytree(src,dst,symlinks=True)
            else:shutil.copy2(src,dst)
        return {name:hashlib.sha256(N.normalize(name,(root/name).read_bytes())[0]).hexdigest() for name in (N.CLIENT,N.CONVERTER)}
    def test_mismatched_architecture_values_fail_capture(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);expected=self.fixture(root);rows,actual=N.normalized_rows(P,None,root,expected);self.assertTrue(rows)
            p=root/N.CLIENT;old=actual[N.CLIENT]['digests']['arm64'];p.write_bytes(p.read_bytes().replace(old.encode(),b'f'*64))
            with self.assertRaises(AssertionError):N.normalized_rows(P,None,root,expected)
    def test_every_selected_source_and_recipe_root_is_sensitive(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);expected=self.fixture(root);baseline,_=N.normalized_rows(P,None,root,expected)
            for name in N.SOURCE_ROOTS:
                with self.subTest(root=name):
                    p=root/name
                    if p.is_dir():p=root/next(r['path'] for r in baseline if r['path'].startswith(name+'/') and r['path'] not in (N.CLIENT,N.CONVERTER))
                    data=p.read_bytes();p.write_bytes(data+b'\n')
                    try:changed,_=N.normalized_rows(P,None,root,expected);self.assertNotEqual(baseline,changed)
                    finally:p.write_bytes(data)
    def test_unrelated_tests_verifiers_and_embeddings_do_not_change_commitment(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);expected=self.fixture(root);before,_=N.normalized_rows(P,None,root,expected)
            for name in ('Packages/TractandaDocuments/Tests/unrelated.swift','Packages/TractandaClient/Tests/unrelated.swift','Packages/TractandaEmbeddings/Sources/irrelevant.swift','scripts/verify-unrelated-fixture.py','debian/linux-runtime-inputs.json'):
                p=root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('unrelated fixture edit\n')
            after,_=N.normalized_rows(P,None,root,expected);self.assertEqual(before,after)
    def test_selected_link_is_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);expected=self.fixture(root);p=root/'Packages/TractandaClient/Package.swift';p.unlink();p.symlink_to(ROOT/'Packages/TractandaClient/Package.swift')
            with self.assertRaises((AssertionError,ValueError)):N.normalized_rows(P,None,root,expected)
if __name__=='__main__':unittest.main(verbosity=2)
