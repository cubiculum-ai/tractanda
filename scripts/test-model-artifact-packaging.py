#!/usr/bin/env python3
"""Tiny metadata fixtures for slim/full model package contracts; no model weights are downloaded."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('mac_package_model_tests', Path(__file__).with_name('package-macos.py'))
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)
LINUX_SPEC = importlib.util.spec_from_file_location('linux_package_model_tests', Path(__file__).with_name('package-linux.py'))
L = importlib.util.module_from_spec(LINUX_SPEC)
LINUX_SPEC.loader.exec_module(L)


class ModelArtifactPackagingTests(unittest.TestCase):
    def test_checked_in_catalog_matches_pinned_docling_source_manifest(self):
        artifacts = M.model_artifacts()
        self.assertEqual(set(artifacts), {
            'granite-embedding-311m-multilingual-r2', 'granite-docling-258m-mlx'})
        self.assertEqual(artifacts['granite-docling-258m-mlx']['revision'],
                         'a8b999991fe8c521a0cec749973414eaaf823731')
        self.assertEqual(artifacts['granite-embedding-311m-multilingual-r2']['revision'],
                         '44399559930365213510b1ee2eb15ded83374f0e')
        M.validate_docling_source_artifact(artifacts['granite-docling-258m-mlx'])
        for artifact in artifacts.values():
            self.assertEqual(len(artifact['revision']), 40)
            self.assertTrue(artifact['files'])
            for row in artifact['files']:
                self.assertGreater(row['size'], 0)
                self.assertEqual(len(row['sha256']), 64)

    def test_complete_optional_offline_artifact_is_verified(self):
        artifact = {'files': [
            {'path': 'config.json', 'size': 4, 'sha256': 'a' * 64},
            {'path': 'model.safetensors', 'size': 3, 'sha256': 'b' * 64},
        ]}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'config.json').write_bytes(b'conf')
            (root / 'model.safetensors').write_bytes(b'mdl')
            with patch.object(M, 'digest', side_effect=lambda path: {'config.json': 'a' * 64,
                                                                      'model.safetensors': 'b' * 64}[path.name]):
                self.assertTrue(M.validate_artifact_directory(root, artifact))
            (root / 'config.json').write_bytes(b'bad!')
            with patch.object(M, 'digest', side_effect=lambda path: {'config.json': '0' * 64,
                                                                      'model.safetensors': 'b' * 64}[path.name]):
                with self.assertRaisesRegex(ValueError, 'differs'):
                    M.validate_artifact_directory(root, artifact)

    def test_embedding_descriptor_allows_weights_omitted_but_binds_hash_inventory(self):
        artifact = M.model_artifacts()['granite-embedding-311m-multilingual-r2']
        profile = {
            'alias': 'tractanda-granite-embedding-311m-multilingual-r2-vmlx-fp32-44399559',
            'modelRevision': artifact['revision'], 'revision': artifact['revision'],
            'vmlxRevision': '61a4b20d4ad01b10466e8fc94c50402a9f994430',
            'dimensions': 768, 'pooling': 'cls', 'normalization': 'l2',
            'assets': {row['path']: row['sha256'] for row in artifact['files']},
        }
        result = M.embedding_descriptor(Path('/unused/helper'), None, runner=lambda *_: __import__('json').dumps(profile))
        self.assertEqual(result['modelRevision'], artifact['revision'])
        profile['assets']['model.safetensors'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'asset set'):
            M.embedding_descriptor(Path('/unused/helper'), None, runner=lambda *_: __import__('json').dumps(profile))

    def test_linux_standard_bundle_accepts_no_weights_but_refuses_one_artifact_only(self):
        document = {
            'converterPath': 'bin/tractanda-document-converter',
            'modelDirectory': 'models/granite-docling-258m-mlx',
            'modelManifestSHA256': M.MODEL_MANIFEST_SHA,
            'runtimePatchManifestSHA256': M.PATCH_MANIFEST_SHA,
            'modelManifestPath': 'licenses/Docling/ModelAssets.json',
            'runtimePatchManifestPath': 'licenses/Docling/runtime-patches.json',
            'runtimePatchPath': 'licenses/Docling/runtime.patch',
            'runtimePatchSHA256': 'c' * 64,
            'noticePaths': [],
        }
        required = [
            'licenses/Granite/' + name for name in (
                'LICENSE', 'README.md', 'NOTICE', 'Gemma-Terms.html', 'Gemma-Prohibited-Use-Policy.html')]
        required += ['licenses/runtime/NOTICE', document['modelManifestPath'],
                     document['runtimePatchManifestPath'], 'licenses/Docling/runtime.patch']
        spec = {'documentExtraction': document, 'runtimeNotices': ['licenses/runtime/NOTICE']}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            names = set(required + ['bin/Tractanda_TractandaWeb.resources/index.html'])
            for name in names:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'fixture')
            rows = [{'path': name} for name in names]
            with patch.object(L.MAC, 'embedding_descriptor', return_value={'model': 'pinned'}), \
                    patch.object(L.MAC, 'validate_docling_source_artifact'), \
                    patch.object(L, 'digest', side_effect=lambda path: {
                        L.ROOT / L.MAC.MODEL_MANIFEST: L.MAC.MODEL_MANIFEST_SHA,
                        root / document['modelManifestPath']: L.MAC.MODEL_MANIFEST_SHA,
                        root / document['runtimePatchManifestPath']: L.MAC.PATCH_MANIFEST_SHA,
                        root / 'licenses/Docling/runtime.patch': document['runtimePatchSHA256'],
                    }.get(path, 'd' * 64)):
                self.assertEqual(L.full_components(root, spec, rows)[0], {'model': 'pinned'})
                (root / 'models/granite-embedding-311m-multilingual-r2').mkdir(parents=True)
                with self.assertRaisesRegex(ValueError, 'both pinned model artifacts'):
                    L.full_components(root, spec, rows)

    def test_linux_assembler_requires_explicit_full_weight_mode(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            payload = base / 'payload'; payload.mkdir()
            spec = base / 'spec.json'; spec.write_text('{}')
            common = (payload, spec, base / 'bundle', 'amd64', 1024**2)
            with patch.object(L, 'native_baseline', return_value={}), patch.object(L, 'validate_spec', return_value={}):
                with self.assertRaisesRegex(ValueError, '--include-model-weights'):
                    L.assemble(*common, include_model_weights=True)
                for identifier in ('granite-embedding-311m-multilingual-r2', 'granite-docling-258m-mlx'):
                    (payload / 'models' / identifier).mkdir(parents=True)
                with self.assertRaisesRegex(ValueError, '--include-model-weights'):
                    L.assemble(*common, include_model_weights=False)


if __name__ == '__main__':
    unittest.main()
