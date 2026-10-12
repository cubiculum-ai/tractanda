#!/usr/bin/env python3
"""Assemble a self-contained, signed macOS preview. Does not install, notarize, or publish.

Requires built first-party executables and Apple's command-line tools. Optional Granite
weights/runtime are explicit inputs; this script never downloads or chooses a model.
"""
import argparse
import importlib.util
import os
import stat
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[1]
MODEL_MANIFEST = "Packages/TractandaDocuments/Sources/TractandaDocumentConverter/Resources/ModelAssets.json"
MAX_CMLX_METALLIB_BYTES = 64 * 1024 * 1024
MODEL_MANIFEST_SHA = "64894c93726b0b76d2eb5c20f001c61d6fc2eea1ef848b23773ba60cae9e00ef"
PATCH_MANIFEST_SHA = "732b8d020e258b8ab5de5875f53bc3756143b089d9a1d7619f311ccbe4674635"

def run(*args):
    try:
        return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as error:
        # Keep the actual tool reason bounded and available in durable operator logs.
        output = (error.output or '')[:4096]
        raise RuntimeError(f'{Path(args[0]).name} failed ({error.returncode}): {output.strip()}') from error


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def copy_tree(source, target):
    if source.is_symlink():
        raise ValueError(f'Input must not be a symbolic link: {source}')
    for path in source.rglob('*'):
        if path.is_symlink():
            raise ValueError(f'Input contains a symbolic link: {path}')
    shutil.copytree(source, target, dirs_exist_ok=True)


def embedding_descriptor(host, model_directory):
    """Require the actual helper's pinned profile and exact verified model inputs."""
    profile = json.loads(run(str(host), '--describe'))
    if (profile.get('alias') != 'tractanda-granite-embedding-311m-multilingual-r2-vmlx-fp32-44399559'
            or profile.get('modelRevision') != '44399559930365213510b1ee2eb15ded83374f0e'
            or profile.get('vmlxRevision') != '61a4b20d4ad01b10466e8fc94c50402a9f994430'
            or profile.get('dimensions') != 768 or profile.get('pooling') != 'cls'
            or profile.get('normalization') != 'l2'):
        raise ValueError('The embedding helper does not describe the bundled Granite profile.')
    assets = profile.get('assets')
    if not isinstance(assets, dict) or not assets or 'model.safetensors' not in assets:
        raise ValueError('The embedding helper has no pinned model asset set.')
    actual = {}
    for path in model_directory.rglob('*'):
        if path.is_symlink():
            raise ValueError('Model assets must not be symbolic links.')
        if path.is_file():
            actual[path.relative_to(model_directory).as_posix()] = digest(path)
    if actual != assets:
        raise ValueError('Model assets differ from the embedding helper\'s pinned hashes.')
    return {
        'backend': 'vmlx-granite-embedding-f32-v1',
        'modelDirectory': 'models/granite-embedding-311m-multilingual-r2',
        'model': profile['alias'], 'modelRevision': profile['revision'],
        'dimensions': profile['dimensions'],
    }


def metal_resource_identity(path):
    metadata = path.lstat()
    if (not stat.S_ISREG(metadata.st_mode) or metadata.st_size <= 0
            or metadata.st_size > MAX_CMLX_METALLIB_BYTES
            or metadata.st_mode & 0o777 != 0o644):
        raise ValueError('Metal resource must be a bounded regular file with mode 0644.')
    return digest(path), metadata.st_size, metadata.st_mode & 0o777


def resource_bundle_inventory(root):
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Resource bundle must be a real directory.')
    entries = {'.': ('directory', root.stat().st_mode & 0o777)}
    for path in root.rglob('*'):
        if path.is_symlink() or not (path.is_dir() or path.is_file()):
            raise ValueError('Resource bundle contains a link or special file.')
        entries[path.relative_to(root).as_posix()] = (
            'directory' if path.is_dir() else digest(path), path.stat().st_mode & 0o777)
    if root.name == 'mlx-swift_Cmlx.bundle':
        # Terminal SwiftPM needs the known duplicate loader placement. Both
        # placements derive from the same verified source-bound Contents Metal library.
        metal = root / 'Contents/Resources/default.metallib'
        try:
            contents_identity = metal_resource_identity(metal)
        except (OSError, ValueError) as error:
            raise ValueError('Cmlx needs a validated source-bound Contents Metal resource.') from error
        expected = (contents_identity[0], contents_identity[2])
        if entries.get('Contents/Resources/default.metallib') != expected:
            raise ValueError('Cmlx Contents Metal resource changed during inventory.')
        duplicate = root / 'default.metallib'
        if 'default.metallib' in entries and metal_resource_identity(duplicate) != contents_identity:
            raise ValueError('Existing Cmlx duplicate Metal resource differs.')
        entries['default.metallib'] = expected
    return entries


def selected_resource_bundles(directory):
    return [bundle for bundle in sorted(directory.glob('*.bundle')) if 'Tests' not in bundle.name]


def validate_resource_collisions(bundles):
    """Fail before any large payload copies; only the known duplicate is projected."""
    seen = {}
    for bundle in bundles:
        inventory = resource_bundle_inventory(bundle)
        if bundle.name in seen and seen[bundle.name] != inventory:
            raise ValueError('Conflicting shared runtime resources: ' + bundle.name)
        seen[bundle.name] = inventory


def merge_resource_bundle(source, target):
    """Shared MLX resources must be byte/mode identical; never flatten-overwrite."""
    def prepare_known_duplicate(root):
        if root.name == 'mlx-swift_Cmlx.bundle' and not (root / 'default.metallib').exists():
            shutil.copyfile(root / 'Contents/Resources/default.metallib', root / 'default.metallib')
            (root / 'default.metallib').chmod(0o644)
    source_inventory = resource_bundle_inventory(source)
    if target.exists():
        if resource_bundle_inventory(target) != source_inventory:
            raise ValueError('Conflicting shared runtime resources: ' + target.name)
        prepare_known_duplicate(target)
        return
    copy_tree(source, target)
    prepare_known_duplicate(target)


def prepare_signed_metal_layout(output):
    """Keep a signable structured bundle and the pinned loader's first lookup path."""
    bundle = output / 'bin/mlx-swift_Cmlx.bundle'
    if not bundle.exists():
        return
    resource_bundle_inventory(bundle)  # Validate both placements before changing the copy.
    contents = bundle / 'Contents/Resources/default.metallib'
    colocated = output / 'bin/mlx.metallib'
    contents_identity = metal_resource_identity(contents)
    if colocated.exists() or colocated.is_symlink():
        if metal_resource_identity(colocated) != contents_identity:
            raise ValueError('Colocated source-bound Metal resource collision.')
    else:
        shutil.copyfile(contents, colocated)
        colocated.chmod(0o644)
        if metal_resource_identity(colocated) != contents_identity:
            raise ValueError('Colocated Metal resource copy differs.')
    redundant = bundle / 'default.metallib'
    if redundant.exists():
        # Already verified exact byte/type/mode equality; never remove another root entry.
        redundant.unlink()


def validate_docling_model(directory):
    spec = importlib.util.spec_from_file_location('docling_model_validator', ROOT / 'scripts/validate-docling-model.py')
    validator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(validator)
    return validator.validate_model_directory(directory)


def document_descriptor(converter, model_directory):
    if converter.is_symlink() or not stat.S_ISREG(converter.stat().st_mode) or not os.access(converter, os.X_OK):
        raise ValueError('Document converter must be a regular executable.')
    if run('/usr/bin/lipo', '-archs', str(converter)).strip() != 'arm64':
        raise ValueError('Document converter must target macOS arm64.')
    manifest = ROOT / MODEL_MANIFEST
    patches = ROOT / 'Packages/TractandaDocuments/RuntimePatches/manifest.json'
    if digest(manifest) != MODEL_MANIFEST_SHA or digest(patches) != PATCH_MANIFEST_SHA:
        raise ValueError('Pinned Docling model/runtime manifest differs.')
    proof = validate_docling_model(model_directory)
    return {
        'converterPath': 'bin/tractanda-document-converter',
        'identity': {'converter': 'tractanda.docling-native.v2-idefics3-gelu-f32',
                     'model': 'ibm-granite/granite-docling-258M-mlx',
                     'modelRevision': proof['revision'],
                     'runtimeRevision': '61a4b20d4ad01b10466e8fc94c50402a9f994430',
                     'preprocessing': 'opaque-rgb-content-crop-hf4561-pillow123-grid-v2',
                     'parser': 'doctags-strict-v1'},
        'workerProtocol': 'tractanda.native-document-worker.v1',
        'modelDirectory': 'models/granite-docling-258m-mlx',
        'modelManifestPath': 'licenses/Docling/ModelAssets.json',
        'modelManifestSHA256': MODEL_MANIFEST_SHA,
        'runtimeRepository': 'osaurus-ai/vmlx-swift',
        'runtimePatchManifestPath': 'licenses/Docling/runtime-patches.json',
        'runtimePatchManifestSHA256': PATCH_MANIFEST_SHA,
        'runtimePatchIdentifier': 'idefics3-vision-gelu-f32-v1',
        'runtimePatchPath': 'licenses/Docling/vmlx-61a4b20-idefics3-gelu-f32.patch',
        'runtimePatchSHA256': '4b45ae94cd5a9a2545025cf5165cd9e617f3c30c5a7b02e236c036ee943b9321',
        'noticePaths': ['licenses/Docling/Granite-Docling-LICENSE',
                        'licenses/Docling/Granite-Docling-MODEL-NOTICE.md',
                        'licenses/Docling/Pillow-LICENSE',
                        'licenses/optional-embedding-host/vmlx-swift/LICENSE',
                        'licenses/optional-embedding-host/vmlx-swift/ACKNOWLEDGMENTS.md'],
    }


def copy_docling_payload(converter, model_directory, output, descriptor):
    shutil.copy2(converter, output / descriptor['converterPath'])
    for bundle in selected_resource_bundles(converter.parent):
        merge_resource_bundle(bundle, output / 'bin' / bundle.name)
    copy_tree(model_directory, output / descriptor['modelDirectory'])
    proof = validate_docling_model(output / descriptor['modelDirectory'])
    notices = ROOT / 'Packages/TractandaDocuments/ThirdPartyNotices'
    destination = output / 'licenses/Docling'
    destination.mkdir(parents=True, exist_ok=True)
    for name in ('Granite-Docling-LICENSE', 'Granite-Docling-MODEL-NOTICE.md', 'Pillow-LICENSE'):
        shutil.copyfile(notices / name, destination / name)
    shutil.copyfile(ROOT / MODEL_MANIFEST, output / descriptor['modelManifestPath'])
    patches = ROOT / 'Packages/TractandaDocuments/RuntimePatches'
    shutil.copyfile(patches / 'manifest.json', output / descriptor['runtimePatchManifestPath'])
    shutil.copyfile(patches / 'vmlx-61a4b20-idefics3-gelu-f32.patch', output / descriptor['runtimePatchPath'])
    for path in descriptor['noticePaths']:
        if not (output / path).is_file():
            raise ValueError('Missing document runtime/model notice: ' + path)
    return proof


def copy_public_source(root, output):
    """Use the reviewed index, never ignored research files or Python caches."""
    selected = ['templates', 'examples', 'docs', 'plugins', 'LICENSES',
                'LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES.md', 'README.md', 'install.sh']
    subprocess.run(['git', 'diff', '--exit-code', '--quiet', '--', *selected], cwd=root, check=True)
    raw = subprocess.check_output(['git', 'ls-files', '--stage', '-z', '--', *selected], cwd=root)
    if not raw:
        raise ValueError('Package from a staged, audited Git source checkout.')
    for entry in raw.split(b'\0'):
        if not entry:
            continue
        metadata, relative = entry.decode().split('\t', 1)
        mode, object_id, stage = metadata.split()
        if stage != '0' or mode not in {'100644', '100755'}:
            raise ValueError('Public payload must contain only reviewed regular files.')
        path = Path(relative)
        if path.is_absolute() or '..' in path.parts:
            raise ValueError('Invalid public source path.')
        target = output / ('licenses' if path.parts[0] == 'LICENSES' else path.parts[0])
        target = target.joinpath(*path.parts[1:])
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(subprocess.check_output(['git', 'cat-file', 'blob', object_id], cwd=root))
        target.chmod(int(mode, 8) & 0o777)


def dependencies(binary):
    return [line.strip().split(' (', 1)[0] for line in run('/usr/bin/otool', '-L', str(binary)).splitlines()[1:]]


def rpaths(binary):
    lines = run('/usr/bin/otool', '-l', str(binary)).splitlines()
    paths = []
    for i, line in enumerate(lines):
        if line.strip() == 'cmd LC_RPATH':
            paths.append(lines[i + 2].strip().split('path ', 1)[1].split(' (offset ', 1)[0])
    return paths


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-products', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--version', default='0.1.0-poc.1')
    parser.add_argument('--sign-identity', default='-', help='Developer ID identity, or - for a local ad-hoc build')
    parser.add_argument('--embeddings-host', type=Path)
    parser.add_argument('--model-directory', type=Path)
    parser.add_argument('--document-converter', type=Path)
    parser.add_argument('--document-model-directory', type=Path)
    args = parser.parse_args()
    root = ROOT
    output = args.output.resolve()
    products = args.build_products.resolve()
    if output.exists():
        parser.error('Output must be a new directory; existing releases are not overwritten.')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._+-]{0,79}', args.version):
        parser.error('Invalid release version.')
    if bool(args.embeddings_host) != bool(args.model_directory):
        parser.error('Embedding runtime and weights must be supplied together.')
    if bool(args.document_converter) != bool(args.document_model_directory):
        parser.error('Document converter and pinned model must be supplied together.')
    document = (document_descriptor(args.document_converter, args.document_model_directory)
                if args.document_converter else None)
    resource_roots = [products]
    if args.embeddings_host:
        resource_roots.append(args.embeddings_host.resolve().parent)
    if args.document_converter:
        resource_roots.append(args.document_converter.parent)
    validate_resource_collisions([bundle for resource_root in resource_roots
                                  for bundle in selected_resource_bundles(resource_root)])
    output.mkdir(parents=True)
    (output / 'bin').mkdir()
    (output / 'lib').mkdir()
    identifiers = {
        'tractanda': 'ai.tractanda.server', 'tractanda-tui': 'ai.tractanda.tui',
        'tractanda-mcp': 'ai.tractanda.mcp', 'tractanda-setup': 'ai.tractanda.setup',
    }
    for name in identifiers:
        if run('/usr/bin/lipo', '-archs', str(products / name)).strip() != 'arm64':
            raise ValueError('The initial downloadable preview targets macOS arm64.')
        shutil.copy2(products / name, output / 'bin' / name)
    for bundle in selected_resource_bundles(products):
        merge_resource_bundle(bundle, output / 'bin' / bundle.name)
    copy_public_source(root, output)
    embedding = None
    if args.embeddings_host:
        host = args.embeddings_host.resolve()
        embedding = embedding_descriptor(host, args.model_directory.resolve())
        shutil.copy2(host, output / 'bin/tractanda-embeddings')
        identifiers['tractanda-embeddings'] = 'ai.tractanda.embeddings'
        for bundle in selected_resource_bundles(host.parent):
            destination = output / 'bin' / bundle.name
            merge_resource_bundle(bundle, destination)
        copy_tree(args.model_directory.resolve(), output / embedding['modelDirectory'])
        # Model/runtime notices come from the same audited source snapshot.
        for name in ('LICENSE', 'README.md', 'NOTICE', 'Gemma-Terms.html', 'Gemma-Prohibited-Use-Policy.html'):
            if not (output / 'licenses/Granite' / name).is_file():
                raise ValueError('Missing bundled Granite/tokenizer notice: ' + name)
    if document:
        copy_docling_payload(args.document_converter, args.document_model_directory, output, document)
        identifiers['tractanda-document-converter'] = 'ai.tractanda.document-converter'
    prepare_signed_metal_layout(output)
    scan = []
    for name in identifiers:
        scan += ['--scan-executable', str(output / 'bin' / name)]
    run('/usr/bin/xcrun', 'swift-stdlib-tool', '--copy', '--platform', 'macosx',
        '--destination', str(output / 'lib'), *scan)
    (output / 'lib/README.txt').write_text('Runtime libraries required beyond the supported macOS system libraries are retained here.\n')
    binaries = [output / 'bin' / name for name in identifiers] + list((output / 'lib').glob('*.dylib'))
    for binary in binaries:
        for dependency in dependencies(binary):
            if dependency.startswith(('/System/', '/usr/lib/')):
                continue
            if dependency.startswith('@rpath/') and (output / 'lib' / dependency.removeprefix('@rpath/')).is_file():
                continue
            if dependency.startswith('@loader_path/') and (binary.parent / dependency.removeprefix('@loader_path/')).is_file():
                continue
            raise ValueError(f'Unbundled dependency in {binary.name}: {dependency}')
        if binary.parent == output / 'bin':
            for path in dict.fromkeys(rpaths(binary)):
                run('/usr/bin/install_name_tool', '-delete_rpath', path, str(binary))
            run('/usr/bin/install_name_tool', '-add_rpath', '@executable_path/../lib', str(binary))
        elif any(path.startswith('/') and not path.startswith('/usr/lib/') for path in rpaths(binary)):
            raise ValueError(f'Unexpected absolute library search path in {binary.name}')
    # Stable, non-writable payload modes. No extended attributes or development data go into the manifest.
    for path in output.rglob('*'):
        if path.is_symlink():
            raise ValueError(f'Unexpected payload symlink: {path}')
        path.chmod(0o755 if path.is_dir() or (path.parent == output / 'bin' and path.name != 'mlx.metallib') or path.name == 'install.sh' else 0o644)
    signing = ['--force', '--sign', args.sign_identity, '--options', 'runtime']
    if args.sign_identity != '-':
        signing += ['--timestamp']
    for bundle in sorted((output / 'bin').glob('*.bundle')):
        run('/usr/bin/codesign', *signing, str(bundle))
    for binary in [p for p in binaries if p.suffix == '.dylib']:
        run('/usr/bin/codesign', *signing, str(binary))
    for name, identifier in identifiers.items():
        run('/usr/bin/codesign', *signing, '--identifier', identifier, str(output / 'bin' / name))
        run('/usr/bin/codesign', '--verify', '--strict', str(output / 'bin' / name))
    files = []
    for path in sorted(output.rglob('*')):
        if path.is_file():
            files.append({'path': path.relative_to(output).as_posix(), 'sha256': digest(path),
                          'size': path.stat().st_size, 'mode': path.stat().st_mode & 0o777})
    manifest = {'profile': 'tractanda.bundle.v1', 'version': args.version,
                'sourceCommit': run('git', '-C', str(root), 'rev-parse', 'HEAD').strip(), 'platform': 'macos',
                'arch': 'arm64', 'files': files}
    if embedding:
        manifest['embedding'] = embedding
    if document:
        manifest['documentExtraction'] = document
    (output / 'bundle-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (output / 'bundle-manifest.json').chmod(0o644)
    # The shipped installer validates its own finished payload without root or installation.
    run(str(output / 'bin/tractanda-setup'), 'plan', '--bundle', str(output))
    print(json.dumps({'bundle': str(output), 'manifestSHA256': digest(output / 'bundle-manifest.json'),
                      'files': len(files), 'embeddedModel': embedding and embedding['model'],
                      'documentModel': document and document['identity']['model'],
                      'signed': args.sign_identity != '-', 'notarized': False, 'published': False}, indent=2))


if __name__ == '__main__':
    main()
