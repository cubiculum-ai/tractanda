#!/usr/bin/env python3
"""Tiny offline package contract tests; no Apple tooling or weight files."""
import contextlib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name('package-macos.py')
spec = importlib.util.spec_from_file_location('docling_packager', SCRIPT)
packager = importlib.util.module_from_spec(spec); spec.loader.exec_module(packager)
ROOT = Path(os.environ.get('TRACTANDA_PACKAGING_SOURCE', Path(__file__).resolve().parents[1]))
packager.ROOT = ROOT
builder_spec = importlib.util.spec_from_file_location('native_package_builder', Path(__file__).with_name('build-macos-pkg.py'))
builder = importlib.util.module_from_spec(builder_spec); builder_spec.loader.exec_module(builder)
STAGE = Path(os.environ.get('TRACTANDA_PACKAGING_FIXTURES', Path(__file__).resolve().parents[1] / 'work/package-tests'))


def guard():
    STAGE.mkdir(parents=True, exist_ok=True)
    capacity = os.statvfs(STAGE)
    allocated = sum(p.stat().st_blocks * 512 for p in STAGE.rglob('*') if p.is_file())
    if capacity.f_bavail * capacity.f_frsize < 10 * 1024**3 or allocated > 16 * 1024**2:
        raise RuntimeError('Tiny packaging fixture capacity guard refused.')


class PackageTests(unittest.TestCase):
    def setUp(self):
        guard()
        self.temp = tempfile.TemporaryDirectory(dir=STAGE)
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup(); guard()

    def converter(self):
        p = self.root / 'converter'; p.write_bytes(b'tiny executable'); p.chmod(0o755); return p

    def test_all_or_none_rejected_before_creating_output(self):
        output = self.root / 'output'
        for arguments in (['--document-converter', '/converter'], ['--document-model-directory', '/model']):
            with patch.object(sys, 'argv', ['packager', '--build-products', '/products', '--output', str(output), *arguments]), contextlib.redirect_stderr(__import__('io').StringIO()):
                with self.assertRaises(SystemExit): packager.main()
            self.assertFalse(output.exists())

    def test_slim_descriptor_binds_current_identity_manifest_without_loading_weights(self):
        with patch.object(packager, 'run', return_value='arm64'), patch.object(packager, 'validate_docling_model') as validate:
            result = packager.document_descriptor(self.converter(), None)
        validate.assert_not_called()
        self.assertEqual(result['workerProtocol'], 'tractanda.native-document-worker.v1')
        self.assertEqual(result['modelManifestSHA256'], packager.digest(ROOT / packager.MODEL_MANIFEST))
        self.assertEqual(result['runtimePatchManifestSHA256'], packager.digest(ROOT / 'Packages/TractandaDocuments/RuntimePatches/manifest.json'))
        self.assertEqual(result['identity']['converter'], 'tractanda.docling-native.v2-idefics3-gelu-f32')

    def test_nonarm_or_nonexecutable_converter_rejected(self):
        converter = self.converter()
        with patch.object(packager, 'run', return_value='x86_64'):
            with self.assertRaisesRegex(ValueError, 'arm64'): packager.document_descriptor(converter, self.root)
        converter.chmod(0o644)
        with self.assertRaisesRegex(ValueError, 'executable'): packager.document_descriptor(converter, self.root)

    def test_converter_symlink_is_rejected_without_resolving(self):
        link = self.root / 'link'; link.symlink_to(self.converter())
        with self.assertRaisesRegex(ValueError, 'executable'): packager.document_descriptor(link, self.root)

    def test_identical_resources_merge_and_conflicts_fail(self):
        a = self.root / 'first.bundle'; a.mkdir(); (a / 'default.metallib').write_bytes(b'tiny metal')
        b = self.root / 'second.bundle'
        packager.merge_resource_bundle(a, b)
        packager.merge_resource_bundle(a, b)
        before = (b / 'default.metallib').read_bytes()
        (a / 'default.metallib').write_bytes(b'conflicting')
        with self.assertRaisesRegex(ValueError, 'Conflicting'): packager.merge_resource_bundle(a, b)
        self.assertEqual((b / 'default.metallib').read_bytes(), before)

    def test_mode_or_nested_symlink_collision_fails(self):
        a = self.root / 'first.bundle'; a.mkdir(); (a / 'file').write_bytes(b'tiny')
        b = self.root / 'second.bundle'; shutil.copytree(a, b)
        (b / 'file').chmod(0o600)
        with self.assertRaisesRegex(ValueError, 'Conflicting'): packager.merge_resource_bundle(a, b)
        (a / 'link').symlink_to(a / 'file')
        with self.assertRaisesRegex(ValueError, 'link'): packager.merge_resource_bundle(a, self.root / 'new.bundle')

    def test_copied_payload_runs_second_validator_and_keeps_metadata(self):
        converter = self.converter(); model = self.root / 'model'; model.mkdir(); (model / 'config.json').write_bytes(b'asset')
        output = self.root / 'output'; (output / 'bin').mkdir(parents=True)
        for path in ['licenses/optional-embedding-host/vmlx-swift/LICENSE', 'licenses/optional-embedding-host/vmlx-swift/ACKNOWLEDGMENTS.md']:
            p = output / path; p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(b'tiny notice')
        pinned = packager.model_artifacts()['granite-docling-258m-mlx']
        actual_validator = packager.validate_artifact_directory
        tiny = {'files': [{'path': 'config.json', 'size': 5, 'sha256': hashlib.sha256(b'asset').hexdigest()}]}
        def verify_tiny(directory, artifact):
            self.assertEqual(artifact, pinned, 'Both validations must use the selected pinned catalog artifact')
            return actual_validator(directory, tiny)
        with patch.object(packager, 'run', return_value='arm64'), \
                patch.object(packager, 'validate_artifact_directory', side_effect=verify_tiny) as inventory, \
                patch.object(packager, 'validate_docling_model', return_value={'revision': pinned['revision']}) as validate:
            descriptor = packager.document_descriptor(converter, model)
            packager.copy_docling_payload(converter, model, output, descriptor)
        self.assertEqual(inventory.call_count, 2)
        self.assertEqual((output / descriptor['modelDirectory'] / 'config.json').read_bytes(), b'asset')
        self.assertEqual(validate.call_args_list[0].args[0], model)
        self.assertEqual(validate.call_args_list[1].args[0], output / descriptor['modelDirectory'])
        self.assertEqual(packager.digest(output / descriptor['modelManifestPath']), descriptor['modelManifestSHA256'])
        self.assertEqual(packager.digest(output / descriptor['runtimePatchPath']), descriptor['runtimePatchSHA256'])

    def test_native_pkg_strictly_verifies_document_converter(self):
        bundle = self.root / 'bundle'; bundle.mkdir()
        names = ['bin/' + name for name in ('tractanda', 'tractanda-tui', 'tractanda-mcp', 'tractanda-setup', 'tractanda-document-converter')]
        entries = []
        for name in names:
            path = bundle / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(b'tiny executable')
            entries.append({'path': name, 'mode': 0o755})
        manifest = {'files': entries, 'documentExtraction': {'converterPath': names[-1]}}
        (bundle / 'bundle-manifest.json').write_text(json.dumps(manifest))
        target = self.root / 'payload'
        with patch.object(builder, 'run') as run:
            builder.stage_payload(bundle, target, manifest)
        run.assert_any_call('/usr/bin/codesign', '--verify', '--strict', target / names[-1])
        self.assertEqual((target / names[-1]).read_bytes(), b'tiny executable')

    def test_native_pkg_license_includes_document_attribution_and_terms(self):
        notices = self.root / 'notices'; notices.mkdir()
        for name, text in [('Granite-Docling-MODEL-NOTICE.md', 'IBM Granite <attribution>'),
                           ('Granite-Docling-LICENSE', 'Apache 2.0 <license>'),
                           ('Pillow-LICENSE', 'Pillow <terms>')]:
            (notices / name).write_text(text)
        document = builder.license_html('Tractanda notice', '# Main license', document_notices=notices)
        self.assertIn('IBM Granite &lt;attribution&gt;', document)
        self.assertIn('Apache 2.0 &lt;license&gt;', document)
        self.assertIn('Pillow &lt;terms&gt;', document)

    def test_cmlx_known_duplicate_is_prepared_only_from_identical_verified_contents(self):
        data = b'tiny pinned metal'; digest = hashlib.sha256(data).hexdigest()
        source = self.root / 'source/mlx-swift_Cmlx.bundle'
        metal = source / 'Contents/Resources/default.metallib'; metal.parent.mkdir(parents=True); metal.write_bytes(data)
        target = self.root / 'target/mlx-swift_Cmlx.bundle'; target.parent.mkdir()
        with contextlib.nullcontext():
            packager.merge_resource_bundle(source, target)
            self.assertEqual((target / 'default.metallib').read_bytes(), data)
            self.assertEqual((target / 'default.metallib').stat().st_mode & 0o777, 0o644)
            self.assertFalse((source / 'default.metallib').exists())
            packager.merge_resource_bundle(source, target)
            (source / 'default.metallib').write_bytes(b'differing')
            with self.assertRaises(ValueError): packager.merge_resource_bundle(source, target)
            self.assertEqual((target / 'default.metallib').read_bytes(), data)

    def test_cmlx_preparation_rejects_missing_wrong_contents_and_different_existing_modes(self):
        data = b'tiny pinned metal'; digest = hashlib.sha256(data).hexdigest()
        source = self.root / 'source/mlx-swift_Cmlx.bundle'; source.mkdir(parents=True)
        target = self.root / 'target/mlx-swift_Cmlx.bundle'; target.parent.mkdir()
        with contextlib.nullcontext():
            with self.assertRaisesRegex(ValueError, 'validated source-bound'): packager.merge_resource_bundle(source, target)
            contents = source / 'Contents/Resources/default.metallib'; contents.parent.mkdir(parents=True); contents.write_bytes(b'')
            with self.assertRaisesRegex(ValueError, 'validated source-bound'): packager.merge_resource_bundle(source, target)
            contents.write_bytes(data); (source / 'default.metallib').write_bytes(data); (source / 'default.metallib').chmod(0o600)
            with self.assertRaises(ValueError): packager.merge_resource_bundle(source, target)
            (source / 'default.metallib').chmod(0o644); contents.chmod(0o600)
            with self.assertRaisesRegex(ValueError, 'validated source-bound'): packager.merge_resource_bundle(source, target)

    def test_resource_preflight_rejects_conflicts_without_copying(self):
        bundles = []
        for root, data in [('one', b'same'), ('two', b'conflict')]:
            bundle = self.root / root / 'shared.bundle'; bundle.mkdir(parents=True); (bundle / 'resource').write_bytes(data); bundles.append(bundle)
        with self.assertRaisesRegex(ValueError, 'Conflicting'): packager.validate_resource_collisions(bundles)
        (bundles[1] / 'resource').write_bytes(b'same')
        packager.validate_resource_collisions(bundles)
        self.assertEqual(len(list(self.root.rglob('resource'))), 2)

    def test_main_flow_uses_same_selected_resources_and_rejects_before_output(self):
        products = self.root / 'products'; products.mkdir()
        for name in ('tractanda', 'tractanda-tui', 'tractanda-mcp', 'tractanda-setup'):
            (products / name).write_bytes(b'tiny binary')
        helper = self.root / 'embedding/helper'; helper.parent.mkdir(); helper.write_bytes(b'tiny helper')
        model = self.root / 'model'; model.mkdir(); (model / 'tiny').write_bytes(b'tiny asset')
        skipped = helper.parent / 'UnsafeTests.bundle'; skipped.mkdir(); (skipped / 'link').symlink_to(helper)
        selected = helper.parent / 'Selected.bundle'; selected.mkdir(); (selected / 'link').symlink_to(helper)
        output = self.root / 'output'
        canonical_formats = {
            'profile': 'tractanda.canonical-formats.v1',
            'readerLevel': 14,
            'writerLevel': 14,
            'read': [1, 2],
            'write': [2],
            'capabilities': [
                'tractanda.authority-causal.v1', 'tractanda.authority-review.v1',
                'tractanda.authority.v1', 'tractanda.document-placement.v1',
                'tractanda.peer-documents.v1', 'tractanda.peer-enrollment-approval.v1',
                'tractanda.peer-enrollment-activation.v1', 'tractanda.peer-enrollment-target.v1',
                'tractanda.peer-lifecycle.v1', 'tractanda.peer-origin-admission.v1',
                'tractanda.peer-originals.v1', 'tractanda.payload-placement.v1',
                'tractanda.shared-authority.v1',
            ],
            'writeCapabilities': [
                'tractanda.authority-causal.v1', 'tractanda.authority-review.v1',
                'tractanda.authority.v1', 'tractanda.document-placement.v1',
                'tractanda.peer-documents.v1', 'tractanda.peer-enrollment-approval.v1',
                'tractanda.peer-enrollment-activation.v1', 'tractanda.peer-enrollment-target.v1',
                'tractanda.peer-lifecycle.v1', 'tractanda.peer-origin-admission.v1',
                'tractanda.peer-originals.v1', 'tractanda.payload-placement.v1',
                'tractanda.shared-authority.v1',
            ],
        }
        source_commit = '0123456789abcdef0123456789abcdef01234567'
        argv = ['packager', '--build-products', str(products), '--output', str(output),
                '--embeddings-host', str(helper), '--document-converter', str(self.converter())]
        def public(_root, destination):
            for name in ('LICENSE', 'README.md', 'NOTICE', 'Gemma-Terms.html', 'Gemma-Prohibited-Use-Policy.html'):
                path = destination / 'licenses/Granite' / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(b'tiny notice')
            for name in ('LICENSE', 'ACKNOWLEDGMENTS.md'):
                path = destination / 'licenses/optional-embedding-host/vmlx-swift' / name
                path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(b'tiny notice')
        def run(*args):
            if args[0] == '/usr/bin/lipo' and len(args) == 3 and args[1] == '-archs':
                self.assertTrue(Path(args[2]).is_file())
                return 'arm64'
            if args[0] == '/usr/bin/otool' and len(args) == 3 and args[1] == '-L':
                return f'{args[2]}:\n'
            if args[0] == '/usr/bin/otool' and len(args) == 3 and args[1] == '-l':
                return ''
            if args[0] == '/usr/bin/xcrun' and args[1:4] == ('swift-stdlib-tool', '--copy', '--platform'):
                self.assertEqual(args[4], 'macosx')
                return ''
            if args[0] == '/usr/bin/install_name_tool' and args[1:3] == ('-add_rpath', '@executable_path/../lib'):
                self.assertTrue(Path(args[3]).is_file())
                return ''
            if args[0] == '/usr/bin/codesign':
                return ''
            if args[0] == 'git' and args[1:] == ('-C', str(packager.ROOT), 'rev-parse', 'HEAD'):
                return source_commit
            if args[0] == str(output / 'bin/tractanda-setup'):
                if args[1:] == ('--canonical-format-support',):
                    return json.dumps(canonical_formats)
                if args[1:] == ('plan', '--bundle', str(output)):
                    return ''
            raise AssertionError(f'Unexpected packaging command: {args!r}')
        with patch.object(sys, 'argv', argv), patch.object(packager, 'run', side_effect=run), \
                patch.object(packager, 'embedding_descriptor', return_value={'modelDirectory': 'models/tiny', 'model': 'fixture'}), \
                patch.object(packager, 'copy_public_source', side_effect=public), contextlib.redirect_stdout(__import__('io').StringIO()):
            with self.assertRaisesRegex(ValueError, 'link'): packager.main()
            self.assertFalse(output.exists())
            (selected / 'link').unlink(); (selected / 'resource').write_bytes(b'tiny selected resource')
            packager.main()
        self.assertTrue((output / 'bin/Selected.bundle/resource').is_file())
        self.assertFalse((output / 'bin/UnsafeTests.bundle').exists())
        manifest = json.loads((output / 'bundle-manifest.json').read_text())
        self.assertEqual(manifest['canonicalFormats'], canonical_formats)
        self.assertEqual(manifest['sourceCommit'], source_commit)
        inventory = manifest['files']
        self.assertFalse(any('UnsafeTests.bundle' in row['path'] for row in inventory))

    def test_signed_metal_layout_keeps_verified_contents_and_colocates_same_bytes(self):
        data = b'tiny pinned metal'; digest = hashlib.sha256(data).hexdigest()
        output = self.root / 'output'; bundle = output / 'bin/mlx-swift_Cmlx.bundle'
        contents = bundle / 'Contents/Resources/default.metallib'; contents.parent.mkdir(parents=True); contents.write_bytes(data)
        (bundle / 'default.metallib').write_bytes(data)
        (bundle / 'other').write_bytes(b'keep unrelated')
        with contextlib.nullcontext():
            packager.prepare_signed_metal_layout(output)
            packager.prepare_signed_metal_layout(output)
        self.assertFalse((bundle / 'default.metallib').exists())
        self.assertEqual(contents.read_bytes(), data)
        self.assertEqual((output / 'bin/mlx.metallib').read_bytes(), data)
        self.assertEqual((output / 'bin/mlx.metallib').stat().st_mode & 0o777, 0o644)
        self.assertEqual((bundle / 'other').read_bytes(), b'keep unrelated')

    def test_signed_metal_layout_rejects_sidecar_collision_before_removing_duplicate(self):
        data = b'tiny pinned metal'; digest = hashlib.sha256(data).hexdigest()
        output = self.root / 'output'; bundle = output / 'bin/mlx-swift_Cmlx.bundle'
        contents = bundle / 'Contents/Resources/default.metallib'; contents.parent.mkdir(parents=True); contents.write_bytes(data)
        duplicate = bundle / 'default.metallib'; duplicate.write_bytes(data)
        sidecar = output / 'bin/mlx.metallib'; sidecar.write_bytes(b'conflict')
        with contextlib.nullcontext():
            with self.assertRaises(ValueError): packager.prepare_signed_metal_layout(output)
            self.assertEqual(duplicate.read_bytes(), data)
            sidecar.write_bytes(data); sidecar.chmod(0o600)
            with self.assertRaises(ValueError): packager.prepare_signed_metal_layout(output)
            sidecar.unlink(); sidecar.symlink_to(contents)
            with self.assertRaises(ValueError): packager.prepare_signed_metal_layout(output)

    def test_operator_tool_failure_retains_bounded_reason(self):
        error = __import__('subprocess').CalledProcessError(1, ['codesign'], output='unsealed contents ' + 'x' * 5000)
        with patch.object(packager.subprocess, 'check_output', side_effect=error):
            with self.assertRaisesRegex(RuntimeError, 'unsealed contents') as caught: packager.run('/usr/bin/codesign', '--verify')
        self.assertLess(len(str(caught.exception)), 4150)

    def test_shader_identity_is_dynamic_bounded_and_shared_inputs_must_match(self):
        bundles = []
        for label, data in [('one', b'current toolchain shader'), ('two', b'other toolchain shader')]:
            bundle = self.root / label / 'mlx-swift_Cmlx.bundle'
            contents = bundle / 'Contents/Resources/default.metallib'; contents.parent.mkdir(parents=True); contents.write_bytes(data)
            self.assertEqual(packager.metal_resource_identity(contents)[0], hashlib.sha256(data).hexdigest())
            with patch.object(packager, 'MAX_CMLX_METALLIB_BYTES', len(data) - 1):
                with self.assertRaises(ValueError): packager.metal_resource_identity(contents)
            bundles.append(bundle)
        with self.assertRaisesRegex(ValueError, 'Conflicting'): packager.validate_resource_collisions(bundles)


if __name__ == '__main__': unittest.main()
