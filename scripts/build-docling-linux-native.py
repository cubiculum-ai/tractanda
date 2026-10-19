#!/usr/bin/env python3
"""Build the single reviewed private Linux raster closure, never run a target.

Must be a child of the existing resource/deadline/process-group supervisor.
This source is staged, not an authorization to compile or adopt its outputs.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import shlex
import subprocess
import time
from pathlib import Path


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()



# Exact already reviewed R1 CPU ABI delta. Neither a matching diff filename nor
# a newly observed current digest is authority for this source change.
CPU_ABI_APPROVAL = {
    'sourceCommit': 'ebdaeefa62db7c40f27cacb0eb034db3a5cdb849',
    'sourcePath': 'config/compiler_cpu_abi.gn',
    'beforeSHA256': '64796f42db27b2e143c7f69ddc3bae1c25dfce16cb86e5d9a72eec4d823b1554',
    'afterSHA256': '42a931a5ae897dd2cf009b8db8edcd1dc6704614012fda869c9da63809ee5b1d',
    'patchSHA256': 'c131eb53c0e1849544145387043f53087a3a49724ca33c6fe89263b68e47fd16',
}


def verify_source_checkout(checkout, expected_commit, cpu_abi=False):
    checkout = Path(checkout)
    git = ['/usr/bin/git', '-C', str(checkout)]
    head = subprocess.check_output(git + ['rev-parse', 'HEAD'], text=True).strip()
    assert head == expected_commit, 'Source HEAD differs from the admitted checkpoint'
    combined = subprocess.check_output(git + ['diff', '--name-only', 'HEAD', '--'], text=True).splitlines()
    staged = subprocess.check_output(git + ['diff', '--cached', '--name-only', '--'], text=True).splitlines()
    summary = subprocess.check_output(git + ['diff', '--summary', 'HEAD', '--'], text=True).strip()
    staged_summary = subprocess.check_output(git + ['diff', '--cached', '--summary', '--'], text=True).strip()
    assert not summary and not staged_summary, 'Unexpected working/staged mode or structural difference'
    record = {'commit': expected_commit, 'trackedDifferences': combined, 'stagedDifferences': staged,
              'trackedSummary': summary, 'stagedSummary': staged_summary}
    if not cpu_abi:
        assert not combined and not staged, 'Unexpected working or staged source difference'
        return record
    approved = CPU_ABI_APPROVAL
    assert expected_commit == approved['sourceCommit']
    assert combined == [approved['sourcePath']] and staged in [[], [approved['sourcePath']]], 'Unexpected CPU ABI working/staged difference'
    path = checkout / approved['sourcePath']
    assert path.is_file() and not path.is_symlink() and digest(path) == approved['afterSHA256'], 'CPU ABI patch bytes differ'
    original = subprocess.check_output(git + ['show', 'HEAD:' + approved['sourcePath']])
    assert hashlib.sha256(original).hexdigest() == approved['beforeSHA256'], 'CPU ABI original bytes differ'
    index = subprocess.check_output(git + ['show', ':' + approved['sourcePath']])
    wanted_index = approved['afterSHA256'] if staged else approved['beforeSHA256']
    assert hashlib.sha256(index).hexdigest() == wanted_index, 'CPU ABI staged bytes differ'
    record['cpuABIApproval'] = dict(approved)
    return record


def verify_r1_link_inputs(root, admitted, target):
    root = Path(root).resolve()
    matches = [x for x in admitted['nativeArchiveInputs'] if x['arch'] == target]
    assert len(matches) == 1, 'Missing or duplicate admitted architecture'
    base = 'checkout/pdfium/out/r1-library-' + target
    expected_paths = {base + '/obj/libpdfium.a', base + '/obj/buildtools/third_party/libc++/libc++.a',
                      base + '/obj/buildtools/third_party/libc++abi/libc++abi.a'}
    archives = matches[0]['archives']
    assert len(archives) == 3 and {x['path'] for x in archives} == expected_paths, 'Unexpected R1 archive set'
    commitments = []
    for entry in archives:
        archive = root / entry['path']
        assert archive.resolve().is_relative_to(root / base) and archive.is_file() and not archive.is_symlink()
        assert digest(archive) == entry['sha256'], 'Admitted R1 archive digest differs: ' + entry['path']
        with archive.open('rb') as stream:
            assert stream.read(8) == (b'!<thin>\n' if entry['thin'] else b'!<arch>\n'), 'Archive kind differs'
        members = entry['members']
        assert members, 'Missing admitted archive members'
        if entry['thin']:
            assert len({x['member'] for x in members}) == len(members), 'Duplicate admitted thin member path'
            for member in members:
                name = Path(member['member'])
                assert not name.is_absolute() and '..' not in name.parts, 'Unsafe thin member path'
                path = archive.parent / name
                assert path.resolve().is_relative_to(root / base) and path.is_file() and not path.is_symlink()
                assert digest(path) == member['sha256'], 'Admitted thin member digest differs: ' + member['member']
        # Record exactly the admitted commitments, never substitute observed bytes
        # as a new expected hash. The regular archive digest binds all its members.
        commitments.append(entry)
    return {'arch': target, 'archives': commitments}


def map_symbol_provider(text, symbol, expected_archive):
    # Version scripts intentionally localize third-party symbols, so LLD's
    # cross-reference table omits them. Its address/section map still records
    # their exact owning input section. Require one definition in that section.
    owner = None
    matches = []
    for line in text.splitlines():
        row = re.fullmatch(r'\s*([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9]+)\s+(.*?)\s*', line)
        if not row:
            continue
        address, size, label = int(row[1], 16), int(row[3], 16), row[5]
        section = re.fullmatch(r'(.+?\.a)\(([^()]+)\):\(([^()]+)\)', label)
        if section:
            owner = {'archive': section[1], 'member': section[2], 'section': section[3],
                     'address': address, 'size': size}
        elif ':(' in label or label.startswith('.'):
            owner = None
        elif label == symbol:
            assert owner is not None, 'No owning input section: ' + symbol
            assert owner['address'] <= address and address + size <= owner['address'] + owner['size'], 'Symbol outside owning section'
            matches.append(dict(owner, symbolAddress=address, symbolSize=size))
    assert len(matches) == 1, 'Missing or duplicate map definition: ' + symbol
    assert matches[0]['archive'] == str(expected_archive), 'Unexpected static symbol provider: ' + symbol
    return matches[0]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--native-root', type=Path, required=True)
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--target', choices=['amd64', 'arm64'], required=True)
    parser.add_argument('--supervisor-phase', required=True)
    parser.add_argument('--host-tools', type=Path, required=True)
    parser.add_argument('--cmake-resources', type=Path, required=True)
    parser.add_argument('--admitted-inputs', type=Path, required=True)
    parser.add_argument('--admitted-inputs-sha256', required=True)
    args = parser.parse_args()
    root = args.native_root.resolve()
    assert root.parent == Path('/tmp') and root.name.startswith('tractanda-docling-r1-')
    assert root.stat().st_uid == os.getuid() and not args.native_root.is_symlink()
    owner = json.loads((root / (args.supervisor_phase + '.status.json')).read_text())
    assert owner['running'] and owner['ownerPID'] == os.getppid()
    assert Path('/proc/' + str(os.getppid()) + '/stat').read_text().split()[21] == owner['ownerStartTicks']
    capacity = owner['capacity']
    assert capacity['cap'] == 24 * 1024**3 and capacity['reserve'] == 10 * 1024**3
    space = os.statvfs(root)
    assert space.f_bavail * space.f_frsize > 11 * 1024**3
    tools = json.loads(args.host_tools.read_text())
    resources = json.loads(args.cmake_resources.read_text())
    for row in tools['tools'] + resources['files'] + [resources['readelf']]:
        path = Path(row['path'])
        assert digest(path) == row['sha256'] and path.stat().st_uid == 0
        assert path.stat().st_mode & 0o022 == 0
    assert digest(args.admitted_inputs) == args.admitted_inputs_sha256, 'Reviewed normalized inventory differs'
    admitted = json.loads(args.admitted_inputs.read_text())
    assert admitted['trackedRecipe']['sha256'] == digest(Path(__file__)), 'Reviewed build recipe differs'
    assert admitted['permittedCPUABIChange'] == CPU_ABI_APPROVAL, 'Reviewed CPU ABI commitment differs'
    patch = root / 'pdfium-x64-sse2.proposed.patch'
    assert digest(patch) == CPU_ABI_APPROVAL['patchSHA256'], 'Reviewed CPU ABI patch artifact differs'
    sources = json.loads((root / 'source-git-checkpoint.json').read_text())
    source_preflight = []
    for row in sources:
        checkout = root / row['path']
        result = verify_source_checkout(checkout, row['commit'], row['path'] == 'checkout/pdfium/build')
        source_preflight.append({'path': row['path'], **result})
    # This also binds generated LCMS configure/libtool support from its already
    # acquired fixed maintainer archive, not an unpinned autotools regeneration.
    acquisition = json.loads((root / 'tool-acquisition-posix-complete.json').read_text())
    archive_inputs = 0
    for item in acquisition['objects']:
        if item['archive'].endswith('.tar.gz') or 'lcms' in item.get('sourceURL', '').lower():
            archive_inputs += 1
            for row in item.get('files', []):
                if 'sha256' in row: assert digest(root / row['path']) == row['sha256']
    assert archive_inputs > 0, 'Fixed maintainer source archive input is missing'
    native_tools = json.loads((root / 'native-tool-inputs.json').read_text())
    for path, row in native_tools['tools'].items():
        assert digest(path) == row['sha256']
    source = root / 'checkout/pdfium'
    bin_path = source / 'third_party/llvm-build/Release+Asserts/bin'
    clang, clangxx, ar = [bin_path / name for name in ['clang', 'clang++', 'llvm-ar']]
    ninja = source / 'third_party/ninja/ninja'
    cmake = next(Path(x['path']) for x in tools['tools'] if x['name'] == 'cmake')
    make = next(Path(x['path']) for x in tools['tools'] if x['name'] == 'make')
    triple = 'x86_64-unknown-linux-gnu' if args.target == 'amd64' else 'aarch64-unknown-linux-gnu'
    cpu = ['-march=x86-64', '-msse2'] if args.target == 'amd64' else ['-march=armv8-a']
    sysroot = source / ('build/linux/debian_bullseye_' + args.target + '-sysroot')
    flags = ['--no-default-config', '--target=' + triple, '--sysroot=' + str(sysroot), '-O2', '-fPIC', '-fno-fast-math', '-ffp-contract=off', *cpu]
    work = root / ('codec-build-' + args.target)
    prefix = root / ('codec-prefix-' + args.target)
    work.mkdir(exist_ok=True); prefix.mkdir(exist_ok=True)
    adapter = args.package.resolve() / 'Sources/CDoclingRaster'
    source_files = sorted(p for p in adapter.rglob('*') if p.is_file())
    inputs = {'adapter': [{'path': str(p), 'sha256': digest(p)} for p in source_files],
              'hostToolsSHA256': digest(args.host_tools), 'cmakeResourcesSHA256': digest(args.cmake_resources),
              'toolReceiptSHA256': digest(root / 'native-tool-inputs.json'), 'flags': flags,
              'sourceHEADs': sources, 'sourcePreflight': source_preflight,
              'admittedInputsSHA256': args.admitted_inputs_sha256,
              'admittedR1LinkInputs': verify_r1_link_inputs(root, admitted, args.target)}
    state_path = work / 'state.json'
    if state_path.exists():
        assert json.loads(state_path.read_text())['inputs'] == inputs, 'Foreign or changed build directory'
    state = {'status': 'building-not-adopted', 'inputs': inputs, 'commands': []}
    ranlib = work / 'llvm-ranlib'
    ranlib_text = '#!/bin/sh\nexec ' + shlex.quote(str(ar)) + ' s "$@"\n'
    if ranlib.exists(): assert ranlib.read_text() == ranlib_text
    else: ranlib.write_text(ranlib_text); ranlib.chmod(0o500)
    state['fixedRanlibWrapperSHA256'] = digest(ranlib)

    def save():
        tmp = state_path.with_suffix('.tmp'); tmp.write_text(json.dumps(state, indent=2) + '\n'); tmp.replace(state_path)
    save()
    # No ambient include/library/preload/compiler options, CMake registries,
    # config.site, host pkg-config library search, target emulator or downloads.
    env = {key: value for key, value in os.environ.items() if key in [
        'LANG', 'LC_ALL', 'TMPDIR', 'PYTHONNOUSERSITE', 'PYTHONDONTWRITEBYTECODE',
        'PYTHONPATH', 'TRACTANDA_R1_ROOT', 'GIT_CONFIG_NOSYSTEM', 'GIT_CONFIG_GLOBAL']}
    env.update({'PATH': str(bin_path) + ':/usr/bin:/bin', 'CC': str(clang), 'CXX': str(clangxx),
                'AR': str(ar), 'RANLIB': str(ranlib), 'CFLAGS': ' '.join(flags),
                'CPPFLAGS': '-I' + str(prefix / 'include'), 'LDFLAGS': '--target=' + triple + ' --sysroot=' + str(sysroot) + ' -fuse-ld=lld',
                'CONFIG_SITE': '/dev/null', 'PKG_CONFIG': '/usr/bin/false', 'CMAKE_BUILD_PARALLEL_LEVEL': '2'})
    def run(argv, cwd=None):
        entry = {'argv': list(map(str, argv)), 'cwd': str(cwd or work), 'started': time.time()}
        state['commands'].append(entry); save()
        result = subprocess.run(entry['argv'], cwd=cwd or work, env=env, timeout=900)
        entry['exit'] = result.returncode; save(); result.check_returncode()
    common = [str(cmake), '-G', 'Ninja', '-DCMAKE_MAKE_PROGRAM=' + str(ninja),
        '-DCMAKE_SYSTEM_NAME=Linux', '-DCMAKE_SYSTEM_PROCESSOR=' + ('x86_64' if args.target == 'amd64' else 'aarch64'),
        '-DCMAKE_C_COMPILER=' + str(clang), '-DCMAKE_CXX_COMPILER=' + str(clangxx),
        '-DCMAKE_C_COMPILER_TARGET=' + triple, '-DCMAKE_CXX_COMPILER_TARGET=' + triple,
        '-DCMAKE_SYSROOT=' + str(sysroot), '-DCMAKE_AR=' + str(ar), '-DCMAKE_RANLIB=' + str(ranlib),
        '-DCMAKE_C_ARCHIVE_FINISH=<CMAKE_AR> s <TARGET>', '-DCMAKE_CXX_ARCHIVE_FINISH=<CMAKE_AR> s <TARGET>',
        '-DCMAKE_C_FLAGS=' + ' '.join(flags), '-DCMAKE_CXX_FLAGS=' + ' '.join(flags),
        '-DCMAKE_POSITION_INDEPENDENT_CODE=ON', '-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY',
        '-DCMAKE_CROSSCOMPILING_EMULATOR=', '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_POLICY_VERSION_MINIMUM=3.10',
        '-DCMAKE_INSTALL_PREFIX=' + str(prefix), '-DCMAKE_INSTALL_LIBDIR=lib',
        '-DCMAKE_FIND_ROOT_PATH=' + str(prefix) + ';' + str(sysroot),
        '-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY', '-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY',
        '-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY', '-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER',
        '-DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF', '-DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF',
        '-DFETCHCONTENT_FULLY_DISCONNECTED=ON', '-DFETCHCONTENT_UPDATES_DISCONNECTED=ON']
    plans = [
        ('zlib', ['ZLIB_BUILD_SHARED=OFF', 'ZLIB_BUILD_STATIC=ON', 'ZLIB_BUILD_TESTING=OFF']),
        ('libpng', ['PNG_SHARED=OFF', 'PNG_STATIC=ON', 'PNG_TESTS=OFF', 'PNG_TOOLS=OFF', 'PNG_HARDWARE_OPTIMIZATIONS=OFF',
                    'ZLIB_ROOT=' + str(prefix), 'ZLIB_LIBRARY=' + str(prefix / 'lib/libz.a'), 'ZLIB_INCLUDE_DIR=' + str(prefix / 'include')]),
        ('libjpeg-turbo', ['ENABLE_SHARED=OFF', 'ENABLE_STATIC=ON', 'WITH_TURBOJPEG=OFF', 'WITH_TOOLS=OFF', 'WITH_TESTS=OFF', 'WITH_SIMD=OFF']),
    ]
    for name, options in plans:
        directory = work / name
        run(common + ['-S', str(root / 'standalone' / name), '-B', str(directory)] + ['-D' + x for x in options])
        cache = (directory / 'CMakeCache.txt').read_text()
        for option in options:
            name_key, wanted = option.split('=', 1)
            if wanted in ['ON', 'OFF']:
                assert re.search(r'(?m)^' + re.escape(name_key) + r':BOOL=(?:' + ('ON|TRUE|1' if wanted == 'ON' else 'OFF|FALSE|0') + r')$', cache, re.I), option
        state.setdefault('generatedBuildMetadata', []).append({'path': str(directory / 'CMakeCache.txt'), 'sha256': digest(directory / 'CMakeCache.txt')}); save()
        run([cmake, '--build', directory, '--parallel', '2'])
        run([cmake, '--install', directory])
    lcms = work / 'lcms2'; lcms.mkdir(exist_ok=True)
    # Explicit unequal build/host triples force Autoconf cross mode even for
    # amd64. No generated target probe is run during configure.
    run([root / 'standalone/lcms-release/configure', '--build=x86_64-pc-linux-gnu', '--host=' + triple,
         '--prefix=' + str(prefix), '--libdir=' + str(prefix / 'lib'), '--disable-shared', '--enable-static', '--with-pic',
         '--without-jpeg', '--without-tiff'], cwd=lcms)
    run([make, '-C', lcms / 'src', '-j2', 'liblcms2.la'])
    shutil.copyfile(lcms / 'src/.libs/liblcms2.a', prefix / 'lib/liblcms2.a')
    shutil.copyfile(root / 'standalone/lcms2/include/lcms2.h', prefix / 'include/lcms2.h')
    objects = {}
    for name in ['metadata', 'color', 'png', 'jpeg', 'raster']:
        path = work / (name + '.o')
        run([clang, *flags, '-std=c11', '-I' + str(prefix / 'include'), '-I' + str(source / 'public'), '-c', adapter / (name + '.c'), '-o', path])
        objects[name] = path
    image = prefix / 'lib/libtractanda_docling_images.so.1'
    pdf = prefix / 'lib/libtractanda_docling_pdf.so.1'
    image_exports = ['tdr_png', 'tdr_jpeg']
    pdf_exports = ['tdr_open', 'tdr_render', 'tdr_close', 'tdr_backend_version']
    link = [*flags, '-rtlib=compiler-rt', '--unwindlib=libgcc', '-shared', '-fuse-ld=lld', '-Wl,-z,defs', '-Wl,--gc-sections', '-Wl,-z,relro,-z,now', '-Wl,--exclude-libs,ALL', '-Wl,--enable-new-dtags', '-Wl,-rpath,$ORIGIN']
    run([clang, *link, '-Wl,-Map=' + str(work / 'images.link.map') + ',--cref', '-Wl,-soname,' + image.name, '-Wl,--version-script=' + str(adapter / 'images.exports'),
         *[objects[n] for n in ['metadata', 'color', 'png', 'jpeg']],
         *[prefix / ('lib/lib' + n + '.a') for n in ['png16', 'jpeg', 'lcms2', 'z']], '-lm', '-lpthread', '-o', image])
    build = source / ('out/r1-library-' + args.target)
    # These remain in place: the two libc++ archives are thin and reference
    # their hash-bound original member paths. Never copy their .a files alone.
    state['r1LinkInputsAtConsumption'] = verify_r1_link_inputs(root, admitted, args.target)
    state['cpuABIAtLinkConsumption'] = verify_source_checkout(source / 'build', CPU_ABI_APPROVAL['sourceCommit'], True)
    save()
    run([clangxx, *link, '-Wl,-Map=' + str(work / 'pdf.link.map') + ',--cref', '-nostdlib++', '-Wl,-soname,' + pdf.name,
         '-Wl,--version-script=' + str(adapter / 'pdf.exports'), objects['raster'],
         build / 'obj/libpdfium.a', build / 'obj/buildtools/third_party/libc++/libc++.a',
         build / 'obj/buildtools/third_party/libc++abi/libc++abi.a', image,
         '-lm', '-ldl', '-lpthread', '-lrt', '-o', pdf])
    provider_checks = {}
    for domain, requirements in [
        ('images', {'png_create_read_struct': 'libpng16.a', 'jpeg_CreateDecompress': 'libjpeg.a',
                    'cmsCreateContext': 'liblcms2.a', 'inflate': 'libz.a'}),
        ('pdf', {'FPDF_RenderPageBitmapWithMatrix': 'libpdfium.a'}),
    ]:
        link_map = work / (domain + '.link.map')
        text = link_map.read_text()
        providers = {}
        for symbol, archive in requirements.items():
            archive_path = (prefix / 'lib' / archive) if domain == 'images' else build / 'obj' / archive
            providers[symbol] = map_symbol_provider(text, symbol, archive_path)
        provider_checks[domain] = {'mapSHA256': digest(link_map), 'staticProviders': providers}
    readelf = Path(resources['readelf']['path']); outputs = []
    for library, expected_exports in [(image, image_exports), (pdf, pdf_exports)]:
        dynamic = subprocess.check_output([readelf, '-d', library], env=env, text=True)
        symbols = subprocess.check_output([readelf, '--dyn-syms', '--wide', library], env=env, text=True)
        machine = int.from_bytes(library.read_bytes()[18:20], 'little')
        assert machine == (62 if args.target == 'amd64' else 183)
        needed = re.findall(r'\(NEEDED\).*\[(.*?)\]', dynamic)
        paths = re.findall(r'\((?:RPATH|RUNPATH)\).*\[(.*?)\]', dynamic)
        assert paths == ['$ORIGIN'] and '(RPATH)' not in dynamic
        assert not any(re.search(r'lib(?:stdc\+\+|c\+\+|png|jpeg|lcms|z\.)', name) for name in needed)
        allowed = {'libc.so.6', 'libm.so.6', 'libgcc_s.so.1', 'libpthread.so.0', 'librt.so.1', 'libdl.so.2'}
        if library == pdf: allowed.add(image.name); assert image.name in needed
        # Exact observed existing libc/loader OS edges, independently checked
        # against each target's pinned provider, ELF machine and symbol version.
        loader_evidence = None
        loader_name, loader_rel, loader_machine, loader_symbol, loader_version = (
            ('ld-linux-x86-64.so.2', 'lib64/ld-linux-x86-64.so.2', 62, '__tls_get_addr', 'GLIBC_2.3')
            if args.target == 'amd64' else
            ('ld-linux-aarch64.so.1', 'lib/ld-linux-aarch64.so.1', 183, '__stack_chk_guard', 'GLIBC_2.17'))
        if loader_name in needed:
            assert library == pdf
            loader = sysroot / loader_rel
            assert int.from_bytes(loader.read_bytes()[18:20], 'little') == loader_machine
            assert re.search(r'\bUND\s+' + re.escape(loader_symbol + '@' + loader_version) + r'(?:\s|$)', symbols)
            definitions = re.findall(r'(?m)^' + re.escape(loader_symbol) + r'\s+(\S+)$', (work / 'pdf.link.map').read_text())
            assert definitions == [str(loader)], 'Unexpected OS loader symbol provider'
            loader_evidence = {'soname': loader.name, 'path': str(loader), 'sha256': digest(loader),
                               'ELFMachine': loader_machine, 'symbol': loader_symbol, 'version': loader_version}
            allowed.add(loader.name)
        assert set(needed) <= allowed
        assert re.findall(r'\(SONAME\).*\[(.*?)\]', dynamic) == [library.name]
        defined = set()
        for line in symbols.splitlines():
            fields = line.split()
            if len(fields) >= 8 and fields[4] in ['GLOBAL', 'WEAK'] and fields[6] not in ['UND', 'ABS']:
                defined.add(fields[7].split('@')[0])
        assert defined == set(expected_exports), (library, defined)
        versions = subprocess.check_output([readelf, '--version-info', library], env=env, text=True)
        outputs.append({'path': str(library), 'sha256': digest(library), 'size': library.stat().st_size,
                        'mode': library.stat().st_mode & 0o777, 'ELFMachine': machine, 'needed': needed,
                        'runpath': paths, 'exports': sorted(defined), 'versionInfo': versions,
                        'providerIsolation': provider_checks['pdf' if library == pdf else 'images'],
                        'osLoaderEvidence': loader_evidence})
        unversioned = library.with_name(library.name.removesuffix('.1'))
        if not unversioned.exists(): unversioned.symlink_to(library.name)
    state['status'] = 'linked-and-statically-inspected-not-adopted-no-target-execution'
    state['outputs'] = outputs; save()
    print(json.dumps({'target': args.target, 'state': str(state_path), 'outputs': outputs}, indent=2))


if __name__ == '__main__':
    main()
