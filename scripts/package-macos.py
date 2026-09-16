#!/usr/bin/env python3
"""Assemble a self-contained, signed macOS preview. Does not install, notarize, or publish.

Requires built first-party executables and Apple's command-line tools. Optional Qwen
weights/runtime are explicit inputs; this script never downloads or chooses a model.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


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
    parser.add_argument('--model-notices', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    products = args.build_products.resolve()
    if output.exists():
        parser.error('Output must be a new directory; existing releases are not overwritten.')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._+-]{0,79}', args.version):
        parser.error('Invalid release version.')
    if bool(args.embeddings_host) != bool(args.model_directory) or bool(args.model_directory) != bool(args.model_notices):
        parser.error('Embedding runtime, weights and notices must be supplied together.')
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
    for bundle in products.glob('*.bundle'):
        if 'Tests' not in bundle.name:
            copy_tree(bundle, output / 'bin' / bundle.name)
    copy_public_source(root, output)
    embedding = None
    if args.embeddings_host:
        host = args.embeddings_host.resolve()
        shutil.copy2(host, output / 'bin/tractanda-embeddings')
        identifiers['tractanda-embeddings'] = 'ai.tractanda.embeddings'
        for bundle in host.parent.glob('*.bundle'):
            destination = output / 'bin' / bundle.name
            if not destination.exists():
                copy_tree(bundle, destination)
        copy_tree(args.model_directory.resolve(), output / 'models/qwen3-embedding-0.6b')
        copy_tree(args.model_notices.resolve(), output / 'licenses/Qwen3')
        embedding = {
            'backend': 'vmlx-qwen3-f32-v1', 'modelDirectory': 'models/qwen3-embedding-0.6b',
            'model': 'tractanda-qwen3-embedding-0.6b-vmlx-fp32-97b0c614',
            'modelRevision': '97b0c614be4d77ee51c0cef4e5f07c00f9eb65b3:weights-bf16:compute-f32:0437e45c94563b09e13cb7a64478fc406947a93cb34a7e05870fc8dcd48e23fd:vmlx-d47c8d0dad91d8c0628a24a5a2c4cada082dc2ee',
            'dimensions': 1024,
        }
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
        path.chmod(0o755 if path.is_dir() or path.parent == output / 'bin' or path.name == 'install.sh' else 0o644)
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
    (output / 'bundle-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (output / 'bundle-manifest.json').chmod(0o644)
    # The shipped installer validates its own finished payload without root or installation.
    run(str(output / 'bin/tractanda-setup'), 'plan', '--bundle', str(output))
    print(json.dumps({'bundle': str(output), 'manifestSHA256': digest(output / 'bundle-manifest.json'),
                      'files': len(files), 'embeddedModel': embedding and embedding['model'],
                      'signed': args.sign_identity != '-', 'notarized': False, 'published': False}, indent=2))


if __name__ == '__main__':
    main()
