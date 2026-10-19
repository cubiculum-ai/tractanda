#!/usr/bin/env python3
"""Compile an isolated pinned Linux ML helper; never admit/package/run its model.

Both components use the same Swift/MLX source pins and toolchain. The D4
registry and document runtime expected identity are intentionally untouched.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import stat
import sys

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('linux_producer', ROOT / 'scripts/produce-linux-payload.py')
P = importlib.util.module_from_spec(spec)
spec.loader.exec_module(P)
B = P.B
ROLES = {'documents': ('TractandaDocuments', 'tractanda-document-converter'),
         'embeddings': ('TractandaEmbeddings', 'TractandaEmbeddingsHost')}
SOURCE_ROOTS = ('Packages/TractandaDocuments', 'Packages/TractandaEmbeddings', 'Packages/TractandaClient',
                'scripts', 'Package.swift', 'Package.resolved', 'VERSION', 'debian/linux-runtime-inputs.json')


# One shared scratch policy, passed explicitly; immutable payload guards stay strict.
build_storage = P.build_storage


def compile_child(*arguments, **keywords):
    return P.child(*arguments, storage_guard=build_storage, **keywords)


def compiled_artifact(bin_path_output, work, product, arch):
    lines = bin_path_output.strip().splitlines()
    if len(lines) != 1 or not Path(lines[0]).is_absolute() or Path(product).name != product:
        raise ValueError('Swift must report exactly one absolute binary directory.')
    directory = Path(lines[0]).resolve(strict=True)
    if not directory.is_relative_to((work / 'scratch').resolve(strict=True)):
        raise ValueError('Swift binary directory escapes the owned scratch root.')
    artifact = directory / product
    info = artifact.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or not info.st_mode & 0o111:
        raise ValueError('Swift helper artifact is not an owned regular file.')
    with artifact.open('rb') as stream:
        header = stream.read(20)
    if (len(header) != 20 or header[:7] != b'\x7fELF\x02\x01\x01'
            or int.from_bytes(header[16:18], 'little') not in (2, 3)
            or int.from_bytes(header[18:20], 'little') != {'amd64': 62, 'arm64': 183}[arch]):
        raise ValueError('Swift helper artifact is not the selected target ELF.')
    return artifact



def build_arguments(swift, common, arch, product):
    """Pinned native backend preserves release WMO and honors the CPU budget.

    Swift6.4.1's default Swift Build backend appends its host-visible thread
    count after forwarded flags. The pinned native backend was checked with
    an actual four-thread frontend and a complete two-object static archive.
    Discovery must append --show-bin-path to this same command.
    """
    isa = '-march=' + B.ARCH[arch][2]
    B.global_isa_flags([isa, '-target-cpu', 'generic'], arch)
    return [swift, 'build', *common, '--build-system', 'native',
            '--force-resolved-versions', '--skip-update', '--disable-dependency-cache',
            '--disable-build-manifest-caching', '--manifest-cache', 'local',
            '--disable-index-store', '-c', 'release', '-debug-info-format', 'none', '-j', '1',
            '-Xcc', isa, '-Xcxx', isa, '-Xswiftc', '-target-cpu', '-Xswiftc', 'generic',
            '-Xswiftc', '-num-threads', '-Xswiftc', '4', '--product', product]


def stop(signum, frame):
    raise InterruptedError('Signal ' + str(signum))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--component', choices=ROLES, required=True)
    parser.add_argument('--arch', choices=B.ARCH, required=True)
    parser.add_argument('--build-timeout-seconds', type=P.timeout_seconds, default=P.DEFAULT_BUILD_TIMEOUT_SECONDS)
    parser.add_argument('--swift', type=Path, required=True)
    parser.add_argument('--expected-toolchain', type=Path, required=True)
    parser.add_argument('--mirrors', type=Path, required=True)
    parser.add_argument('--git-config', type=Path, required=True)
    parser.add_argument('--native-prefix', type=Path)
    parser.add_argument('--native-inputs', type=Path)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--max-work-bytes', type=int, required=True)
    args = parser.parse_args()
    if sys.platform != 'linux' or os.uname().machine != {'amd64': 'x86_64', 'arm64': 'aarch64'}[args.arch]:
        raise ValueError('Run natively on the selected Linux architecture.')
    release = dict(line.split('=', 1) for line in Path('/etc/os-release').read_text().splitlines() if '=' in line)
    if release.get('ID', '').strip('"') != 'debian' or release.get('VERSION_ID', '').strip('"') != '13':
        raise ValueError('Use the pinned Debian13 native build environment.')
    swift, tools = P.toolchain(args.swift)
    if tools != B.read_json(args.expected_toolchain) or not tools['version'].startswith('Swift version 6.4.1 '):
        raise ValueError('Concrete Swift toolchain differs from the frozen build input.')
    work = args.work.absolute()
    if work.exists() or work.is_symlink() or work.is_relative_to(ROOT) or args.max_work_bytes > 8 * 1024**3:
        raise ValueError('Use a fresh isolated work root and the admitted at-most8GiB cap.')
    original = P.rows(ROOT, roots=SOURCE_ROOTS, skip=P.SKIP)
    B.capacity(work.parent, 512 * 1024**2, args.max_work_bytes)
    work.mkdir(mode=0o700)
    for name in ('source', 'home', 'tmp', 'modules', 'cache', 'config', 'security'):
        (work / name).mkdir(mode=0o700)
    P.write_json(work / 'source-inputs.json', {'status': 'COMPILE_ONLY_UNADMITTED', 'files': original,
                 'component': args.component, 'arch': args.arch, 'toolchain': tools,
                 'buildTimeoutSeconds': args.build_timeout_seconds})
    P.merge_files(ROOT, work / 'source', original, args.max_work_bytes)
    package_name, product = ROLES[args.component]
    package = work / 'source/Packages' / package_name
    expected_pins = B.read_json(package / 'Package.resolved')['pins']
    P.write_json(package / '.swiftpm/configuration/mirrors.json', P.mirrored_pins(package, args.mirrors))
    environment = P.controlled_environment(work, swift.parent)
    if args.git_config.is_symlink() or not args.git_config.is_file():
        raise ValueError('Use the frozen isolated file-only submodule Git configuration.')
    environment['GIT_CONFIG_GLOBAL'] = str(args.git_config.resolve())
    if args.component == 'documents':
        if args.native_prefix is None or args.native_inputs is None or not args.native_prefix.is_absolute():
            raise ValueError('Documents require their reviewed private native prefix and receipt.')
        entries = B.read_json(args.native_inputs)['outputs'][args.arch]
        if {Path(x['path']).name for x in entries} != {'libtractanda_docling_pdf.so.1', 'libtractanda_docling_images.so.1'}:
            raise ValueError('Unexpected native raster library set.')
        for entry in entries:
            library = args.native_prefix / 'lib' / Path(entry['path']).name
            if library.is_symlink() or B.digest(library) != entry['sha256'] or library.stat().st_size != entry['size']:
                raise ValueError('Reviewed native raster bytes differ.')
        environment['TRACTANDA_DOCLING_NATIVE_PREFIX'] = str(args.native_prefix)
    common = ['--package-path', package, '--scratch-path', work / 'scratch', '--cache-path', work / 'cache',
              '--config-path', work / 'config', '--security-path', work / 'security', '--disable-sandbox']
    # Original upstream Linux metadata prunes MLXVLM. Resolve the unchanged
    # locked graph without that pruning, then patch only the isolated checkout.
    environment['VMLX_LINUX_PROFILE'] = '0'
    compile_child([swift, 'package', *common, '--force-resolved-versions', '--skip-update', 'resolve'],
            work, environment, args.max_work_bytes, timeout=args.build_timeout_seconds)
    if B.read_json(package / 'Package.resolved')['pins'] != expected_pins:
        raise ValueError('SwiftPM changed a selected source revision/version.')
    patch_root = work / 'source/Packages/TractandaDocuments/RuntimePatches'
    spec = importlib.util.spec_from_file_location('isolated_linux_runtime_patch', patch_root / 'apply.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    old_environment = dict(os.environ)
    try:
        os.environ.clear(); os.environ.update(environment)
        patch_receipt = module.apply(work / 'scratch/checkouts/vmlx-swift')
    finally:
        os.environ.clear(); os.environ.update(old_environment)
    P.write_json(work / 'runtime-patch.json', patch_receipt)
    environment['VMLX_LINUX_PROFILE'] = '1'
    command = build_arguments(swift, common, args.arch, product)
    compile_child(command, work, environment, args.max_work_bytes, timeout=args.build_timeout_seconds)
    bin_path = compile_child([*command, '--show-bin-path'], work, environment,
                             args.max_work_bytes, timeout=args.build_timeout_seconds, capture=True)
    artifact = compiled_artifact(bin_path, work, product, args.arch)
    if P.toolchain(args.swift)[1] != tools or P.rows(ROOT, roots=SOURCE_ROOTS, skip=P.SKIP) != original:
        raise ValueError('Compiler or original source changed during compilation.')
    if B.read_json(package / 'Package.resolved')['pins'] != expected_pins:
        raise ValueError('Selected dependency graph changed during compilation.')
    P.write_json(work / 'result.json', {'status': 'NATIVE_HELPER_COMPILED_NOT_RUNTIME_ADMITTED_NOT_MODEL_EXECUTED',
                 'component': args.component, 'arch': args.arch, 'toolchain': tools,
                 'artifact': {'path': str(artifact), 'sha256': B.digest(artifact), 'size': artifact.stat().st_size},
                 'runtimePatch': patch_receipt, 'registryUpdated': False, 'documentIdentityAdmitted': False})
    print(json.dumps({'component': args.component, 'result': str(work / 'result.json'), 'runtimeAdmitted': False}))


if __name__ == '__main__':
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, stop)
    main()
