import importlib.util
from pathlib import Path
import tempfile
import unittest
import sys
from unittest.mock import patch


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


E = load('component_export', Path(__file__).with_name('export-linux-ml-component.py'))
# This test also runs from the frozen staging tree without changing active scripts.
REPO = next(parent for parent in Path(__file__).resolve().parents if (parent / 'debian/linux-runtime-inputs.json').is_file())
P = E.producer(REPO)


class ExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'artifacts'
        self.source.mkdir()
        (self.source / 'bin').mkdir()
        (self.source / 'bin/helper').write_bytes(b'unchanged-verified-artifact')
        (self.source / 'bin/helper').chmod(0o755)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        for name in E.OUTER_DOCLING.values():
            target = self.repo / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(name)
            target.chmod(0o644)
        self.root_patch = patch.object(P, 'ROOT', self.repo)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)
        rows = P.rows(self.source)
        for relative, source in E.OUTER_DOCLING.items():
            row = P.rows(self.repo, roots=[source])[0]
            rows.append({**row, 'path': relative})
        self.value = dict(component='documents', arch='amd64', files=sorted(rows, key=lambda row: row['path']))

    def project(self):
        return E.projection(P, self.value, self.source, 'documents', 'amd64', P.sha(P.B.canonical(self.value)))

    def test_complete_projection_preserves_artifact_and_adds_six_exact_outer_files(self):
        before = P.rows(self.source)
        actual, selected = self.project()
        self.assertEqual(actual, before)
        self.assertEqual(len(selected), 7)
        self.assertEqual(P.rows(self.source), before)
        self.assertEqual(selected[0][1]['mode'], 0o755)

    def test_rejects_changed_artifact_and_undeclared_file(self):
        (self.source / 'bin/helper').write_bytes(b'changed')
        with self.assertRaises(ValueError):
            self.project()
        (self.source / 'bin/helper').write_bytes(b'unchanged-verified-artifact')
        (self.source / 'extra').write_text('unreviewed')
        with self.assertRaises(ValueError):
            self.project()

    def test_rejects_outer_source_drift_and_link(self):
        target = self.repo / next(iter(E.OUTER_DOCLING.values()))
        target.write_text('changed-source')
        with self.assertRaises(ValueError):
            self.project()
        target.unlink()
        target.symlink_to(self.source / 'bin/helper')
        with self.assertRaises(ValueError):
            self.project()

    def test_rejects_unapproved_wrapper_and_missing_outer_commitment(self):
        with self.assertRaises(ValueError):
            E.projection(P, self.value, self.source, 'documents', 'amd64', '0' * 64)
        self.value['files'] = self.value['files'][:1]
        with self.assertRaises(ValueError):
            self.project()

    def test_rejects_duplicate_inventory(self):
        self.value['files'].append(self.value['files'][-1])
        with self.assertRaises(ValueError):
            self.project()

    def test_cli_refuses_null_registry_before_reading_artifacts(self):
        args = ['export', '--arch', 'amd64', '--component', 'documents',
                '--manifest', 'absent', '--component-root', 'absent', '--output', 'absent']
        with patch.object(E, 'producer', return_value=P), \
                patch.object(P, 'registry', return_value={'documents': None, 'embeddings': None}), \
                patch.object(sys, 'argv', args):
            with self.assertRaisesRegex(ValueError, 'Unadmitted'):
                E.main()

    def test_export_reuses_d4_validation_and_refuses_existing_output(self):
        manifest = self.root / 'manifest.json'
        P.write_json(manifest, self.value)
        output = self.root / 'output'
        checksum = P.sha(P.B.canonical(self.value))
        # Synthetic bytes test export containment/copy behavior only; they do
        # not pretend to be an admitted executable or runtime proof.
        with patch.object(P, 'component', return_value=self.value) as validate:
            self.assertEqual(E.export(P, manifest, self.source, output, 'documents', 'amd64', checksum, 8 * 1024**3), self.value)
            validate.assert_called_once()
        self.assertEqual(P.rows(output), self.value['files'])
        with self.assertRaises(ValueError):
            E.export(P, manifest, self.source, output, 'documents', 'amd64', checksum, 8 * 1024**3)


if __name__ == '__main__':
    unittest.main()
