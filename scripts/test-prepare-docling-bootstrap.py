#!/usr/bin/env python3
import copy
import importlib.util
import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('bootstrap', ROOT / 'scripts/prepare-docling-bootstrap.py')
M = importlib.util.module_from_spec(spec)
spec.loader.exec_module(M)


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='docling-bootstrap-test-')
        self.parent = Path(self.temp.name)
        self.source = self.parent / 'source'
        self.source.mkdir()
        for row in M.P.rows(ROOT, roots=M.SOURCE_ROOTS, skip=M.P.SKIP):
            path = self.source / row['path']
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / row['path'], path)
            path.chmod(row['mode'])

    def tearDown(self):
        self.temp.cleanup()

    def inputs(self, arch='amd64'):
        rows = M.P.rows(self.source, roots=M.SOURCE_ROOTS, skip=M.P.SKIP)
        registry = M.validated_registry(self.source / M.N.REGISTRY)
        _, values = M.N.normalized_rows(M.P, M.C, self.source, M.G.TEMPLATES)
        return (M.P.sha(M.B.canonical(rows)), M.B.digest(self.source / M.N.REGISTRY),
                registry['baselines']['kali-rolling'][arch]['documents'],
                values[M.N.CLIENT]['digests']['kali-' + arch])

    def prepare(self, arch='amd64', values=None):
        return M.prepare(self.source, self.parent / 'staged', self.parent / 'report', arch,
                         *(values or self.inputs(arch)))

    def test_existing_binding_is_staged_and_receipted_without_changing_source(self):
        before = self.inputs()
        result = self.prepare()
        self.assertEqual(self.inputs(), before)
        self.assertEqual(result['previousSlot'], before[3])
        self.assertEqual(result['selectedRegistryCell'], before[2])
        self.assertFalse(result['runtimeAdmission'])
        self.assertEqual(result['changedPaths'], sorted([M.N.CLIENT, M.N.CONVERTER]))
        self.assertEqual(result['bootstrapSlot'], M.SENTINEL)
        self.assertEqual(result, json.loads((self.parent / 'report/RESULT.json').read_text()))

    def test_initial_empty_slot_and_registry_are_supported(self):
        for relative in (M.N.CLIENT, M.N.CONVERTER):
            path = self.source / relative
            text = path.read_text()
            _, values = M.N.normalize(relative, text.encode())
            text = text.replace('kaliAMD64: String? = "' + values['kali-amd64'] + '"',
                                'kaliAMD64: String? = nil')
            path.write_text(text)
        path = self.source / M.N.REGISTRY
        registry = json.loads(path.read_text())
        registry['baselines']['kali-rolling']['amd64']['documents'] = None
        path.write_text(json.dumps(registry))
        result = self.prepare()
        self.assertIsNone(result['previousSlot'])
        self.assertIsNone(result['selectedRegistryCell'])

    def test_wrong_source_registry_cell_slot_and_other_arch_rejected(self):
        actual = self.inputs()
        cases = [tuple('a' * 64 if i == 0 else v for i, v in enumerate(actual)),
                 tuple('b' * 64 if i == 1 else v for i, v in enumerate(actual)),
                 tuple('c' * 64 if i == 2 else v for i, v in enumerate(actual)),
                 tuple('d' * 64 if i == 3 else v for i, v in enumerate(actual)),
                 self.inputs('arm64')]
        for values in cases:
            with self.subTest(values=values), self.assertRaises(ValueError):
                self.prepare(values=values)
            self.assertFalse((self.parent / 'staged').exists())

    def test_unexpected_staged_mutation_is_rejected(self):
        original = M.P.merge_files
        def corrupt(source, target, rows, limit):
            original(source, target, rows, limit)
            path = target / M.N.CLIENT
            path.write_bytes(path.read_bytes() + b'\n')
        with patch.object(M.P, 'merge_files', side_effect=corrupt), self.assertRaises((ValueError, AssertionError)):
            self.prepare()
        self.assertFalse((self.parent / 'report/RESULT.json').exists())


if __name__ == '__main__':
    unittest.main()
