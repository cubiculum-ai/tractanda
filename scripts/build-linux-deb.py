#!/usr/bin/env python3
"""Build one complete Debian package from an admitted Linux bundle; never install.

Package Maintainer metadata has a verified project default and may be overridden. Source/binary
release, signing and publication are separate actions. The producer/assembler gate cannot be disabled.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('tractanda_linux_bundle', ROOT / 'scripts/package-linux.py')
B = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(B)
COMMANDS = ('tractanda', 'tractanda-tui', 'tractanda-mcp', 'tractanda-setup')
DEFAULT_MAINTAINER = 'rcfa - Cubiculum-AI <1831995+rcfa@users.noreply.github.com>'
BUGS_URL = 'https://github.com/cubiculum-ai/tractanda/issues'
HOOKS = {'preinst': 'tractanda.preinst.in', 'prerm': 'tractanda.prerm',
         'postinst': 'tractanda.postinst.in', 'postrm': 'tractanda.postrm'}
DEFAULT_BUILD_TIMEOUT_SECONDS = 24 * 60 * 60
MAX_TIMEOUT_SECONDS = 7 * 24 * 60 * 60


def positive_timeout_seconds(value):
    try:
        seconds = int(value)
    except (TypeError, ValueError) as error:
        raise argparse.ArgumentTypeError('timeout must be a finite positive integer number of seconds') from error
    if seconds <= 0 or seconds > MAX_TIMEOUT_SECONDS:
        raise argparse.ArgumentTypeError(f'timeout must be between 1 and {MAX_TIMEOUT_SECONDS} seconds')
    return seconds


def render(source, values):
    for key, value in values.items():
        source = source.replace('@' + key + '@', value)
    if re.search(r'@TRACTANDA_[A-Z0-9_]+@', source):
        raise ValueError('Unresolved packaging placeholder.')
    return source.encode()


def package_descriptor(manifest, digest, upgrade):
    if upgrade not in ('compatible', 'coordinated-maintenance'):
        raise ValueError('Explicit reviewed upgrade classification is required.')
    result = dict(profile='tractanda.linux-package.v1', manifestSHA256=digest,
                  version=manifest['version'], arch=manifest['arch'],
                  canonicalFormats=manifest['canonicalFormats'], semanticProfile=B.SEMANTIC_PROFILE,
                  upgrade=upgrade, embedding=manifest['embedding'], documentExtraction=manifest['documentExtraction'])
    encoded = B.canonical(result)
    if len(encoded) > 65_536 or b'\n' in encoded:
        raise ValueError('Compatibility descriptor must be bounded one-line canonical JSON.')
    return encoded.decode()


def debian_version(version, revision):
    if not re.fullmatch(r'[0-9][A-Za-z0-9.+\-]{0,79}', version) or not re.fullmatch(r'[1-9][0-9A-Za-z.+]*', revision):
        raise ValueError('Invalid source version or Debian packaging revision.')
    return version.replace('-poc.', '~poc.') + '-' + revision


def maintainer_field(value):
    if (not isinstance(value, str) or len(value.encode()) > 254
            or not value.isprintable() or not re.fullmatch(r'[^<>\r\n\x00-\x1f]+ <[^<>\s@]+@[^<>\s@]+>', value)):
        raise ValueError('Maintainer must use the Name <email> format.')
    return value


def write(path, data, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    path.chmod(mode)


def stage_package(bundle, stage, snapshot, arch, maintainer, copyright_bytes, revision, upgrade, epoch, maximum):
    if not isinstance(snapshot, B.ManifestSnapshot):
        raise ValueError('An immutable admitted manifest snapshot is required.')
    B.unchanged_manifest(bundle, snapshot)
    manifest = snapshot.manifest()
    if stage.exists() or stage.is_symlink():
        raise ValueError('Debian stage must be a fresh private path.')
    maintainer_field(maintainer)
    version = debian_version(manifest['version'], revision)
    if (type(epoch) is not int or epoch < 0 or epoch > 2**63 - 1
            or not copyright_bytes or len(copyright_bytes) > 262_144 or b'\0' in copyright_bytes):
        raise ValueError('Explicit source epoch and bounded copyright notice are required.')
    copyright_bytes.decode('utf-8')
    B.capacity(stage.parent, sum(v['size'] for v in manifest['files']) + 1024**2, maximum)
    receipt = B.read_json(bundle / 'lib/tractanda/linux-bundle-build.json', 16 * 1024**2)
    if receipt.get('profile') != 'tractanda.linux-bundle-build.v1' or receipt['baseline']['os'] != 'debian13' or receipt['baseline']['arch'] != arch:
        raise ValueError('Bundle lacks its architecture-bound Debian13 assembly receipt.')
    # Reinspect before a potentially large copy; receipt assertions alone do not admit libraries.
    rows = B.inventory(bundle, exclude=('bundle-manifest.json',))
    closure = B.runtime_closure(bundle, rows, arch, receipt['input']['dynamicLoads'])
    if closure != receipt['runtimeClosure']:
        raise ValueError('Actual runtime closure differs from its admitted bundle receipt.')
    depends = sorted(set(closure['depends']) | {'ca-certificates', 'curl', 'lsof', 'sudo', 'uuid-runtime', 'init-system-helpers'})
    if any('\n' in value or ',' in value for value in depends):
        raise ValueError('Unsafe derived Debian dependency field.')
    stage.mkdir(mode=0o755)
    payload = stage / 'opt/tractanda/current'
    for row in manifest['files']:
        source, target = bundle / row['path'], payload / row['path']
        B.copy_verified(source, target, row, maximum)
    write(payload / 'bundle-manifest.json', snapshot.raw)
    for command in COMMANDS:
        write(stage / 'usr/bin' / command,
              ('#!/bin/sh\nexec /opt/tractanda/current/bin/' + command + ' "$@"\n').encode(), 0o755)
    write(stage / 'usr/share/doc/tractanda/copyright', copyright_bytes)
    descriptor = package_descriptor(manifest, snapshot.sha256, upgrade)
    fallback = (ROOT / 'debian/tractanda-package-hook-fallback.py.in').read_text()
    if '@TRACTANDA_' in fallback:
        raise ValueError('Embedded fallback source contains an unresolved marker.')
    for name, template in HOOKS.items():
        data = render((ROOT / 'debian' / template).read_text(), {
            'TRACTANDA_PACKAGE_DESCRIPTOR_JSON': descriptor,
            'TRACTANDA_PACKAGE_HOOK_FALLBACK_PY': fallback,
        })
        write(stage / 'DEBIAN' / name, data, 0o755)
    files = B.inventory(stage)
    installed_kib = sum((row['size'] + 1023) // 1024 for row in files if not row['path'].startswith('DEBIAN/'))
    control = render((ROOT / 'debian/tractanda.control.in').read_text(), {
        'TRACTANDA_DEBIAN_VERSION': version, 'TRACTANDA_DEBIAN_ARCH': arch,
        'TRACTANDA_MAINTAINER': maintainer, 'TRACTANDA_RUNTIME_DEPENDS': ', '.join(depends),
        'TRACTANDA_INSTALLED_KIB': str(installed_kib), 'TRACTANDA_BUGS_URL': BUGS_URL,
    })
    write(stage / 'DEBIAN/control', control)
    md5 = []
    for row in files:
        if not row['path'].startswith('DEBIAN/'):
            digest = hashlib.md5(usedforsecurity=False)
            with (stage / row['path']).open('rb') as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(block)
            md5.append(digest.hexdigest() + '  ' + row['path'])
    write(stage / 'DEBIAN/md5sums', ('\n'.join(md5) + '\n').encode())
    for directory, dirs, names in os.walk(stage, topdown=False):
        for name in names:
            os.utime(Path(directory) / name, (epoch, epoch), follow_symlinks=False)
        os.chmod(directory, 0o755)
        os.utime(directory, (epoch, epoch), follow_symlinks=False)
    B.owned_storage(stage.parent, maximum)
    return dict(version=version, arch=arch, depends=depends, installedKiB=installed_kib,
                sourceDateEpoch=epoch, inventory=B.inventory(stage))


def verify_archive(package, expected, control=False):
    flag = '--ctrl-tarfile' if control else '--fsys-tarfile'
    process = subprocess.Popen(['dpkg-deb', flag, str(package)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
    found = set()
    root_seen = False
    directories = {str(parent) for name in expected for parent in Path(name).parents if str(parent) != '.'}
    try:
        with tarfile.open(fileobj=process.stdout, mode='r|') as archive:
            for member in archive:
                name = member.name.removeprefix('./').rstrip('/')
                if member.uid != 0 or member.gid != 0 or member.mode & 0o7000 or not (member.isdir() or member.isfile()):
                    raise ValueError('Debian archive has unexpected ownership/type.')
                if member.name in ('.', './'):
                    if root_seen or not member.isdir() or member.size != 0 or member.mode & 0o777 != 0o755:
                        raise ValueError('Debian archive has unexpected root directory metadata.')
                    root_seen = True
                    continue
                B.safe_path(name)
                if member.isdir():
                    if name not in directories or member.mode & 0o777 != 0o755:
                        raise ValueError('Debian archive has an unexpected directory or mode.')
                    continue
                if name not in expected or name in found:
                    raise ValueError('Debian archive has an unexpected/duplicate file.')
                row = expected[name]
                if member.size != row['size'] or member.mode & 0o777 != row['mode']:
                    raise ValueError('Debian archive metadata differs from staged content.')
                digest = hashlib.sha256()
                stream = archive.extractfile(member)
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(block)
                if digest.hexdigest() != row['sha256']:
                    raise ValueError('Debian archive bytes differ from the closed stage.')
                found.add(name)
        if process.wait(timeout=30) != 0 or found != set(expected):
            raise ValueError('Debian archive is incomplete or unreadable.')
    finally:
        if process.poll() is None:
            os.killpg(process.pid, 15)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, 9)
                process.wait()
        process.stdout.close()


def build(bundle, output, arch, maintainer, copyright_file, revision, upgrade, epoch, maximum,
          build_timeout_seconds=DEFAULT_BUILD_TIMEOUT_SECONDS):
    if not 1 <= build_timeout_seconds <= MAX_TIMEOUT_SECONDS:
        raise ValueError('Configured package build timeout is invalid.')
    B.native_baseline(arch)
    bundle = bundle.resolve(strict=True)
    output = output.parent.resolve(strict=True) / output.name
    receipt = output.with_name(output.name + '.inventory.json')
    if output.exists() or output.is_symlink() or receipt.exists() or output.is_relative_to(bundle):
        raise ValueError('Package output must be new with an existing parent.')
    snapshot = B.capture_manifest(bundle)
    manifest = B.verify_bundle(bundle, arch, snapshot)  # No incomplete-package bypass.
    build_receipt = B.read_json(bundle / 'lib/tractanda/linux-bundle-build.json', 16 * 1024**2)
    spec = B.validate_spec(build_receipt['input'], arch)
    B.public_assets(bundle)
    embedding, document = B.full_components(bundle, spec, manifest['files'])
    if (embedding, document) != (manifest['embedding'], manifest['documentExtraction']):
        raise ValueError('Pinned component descriptors differ from the admitted bundle manifest.')
    info = copyright_file.lstat()
    if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= 262_144:
        raise ValueError('Copyright must be an explicit bounded regular UTF-8 input.')
    copyright_bytes = copyright_file.read_bytes()
    total = sum(row['size'] for row in manifest['files'])
    B.capacity(output.parent, total * 2 + 64 * 1024**2, maximum)
    env = dict(os.environ, SOURCE_DATE_EPOCH=str(epoch), DPKG_DEB_THREADS_MAX='1', LC_ALL='C')
    # A retained stage is useful only on failure; successful reproducible staging is disposable.
    stage = Path(tempfile.mkdtemp(prefix='.tractanda-deb-', dir=output.parent)) / 'root'
    success = False
    artifact = stage.parent / 'package.deb'
    try:
        result = stage_package(bundle, stage, snapshot, arch, maintainer, copyright_bytes, revision, upgrade, epoch, maximum)
        B.verify_bundle(stage / 'opt/tractanda/current', arch, snapshot)
        compression_tmp = stage.parent / 'tmp'
        compression_tmp.mkdir(mode=0o700)
        env['TMPDIR'] = str(compression_tmp)
        B.owned_storage(stage.parent, maximum)  # Includes directory allocation before any child.
        command = ['dpkg-deb', '--root-owner-group', '--uniform-compression', '--threads-max=1',
                   '-Zxz', '-z6', '--build', str(stage), str(artifact)]
        process = subprocess.Popen(command, env=env, start_new_session=True)
        started = time.monotonic()
        try:
            while process.poll() is None:
                B.owned_storage(stage.parent, maximum)
                if time.monotonic() - started > build_timeout_seconds:
                    raise ValueError('Configured package compression deadline exceeded.')
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    pass
            B.owned_storage(stage.parent, maximum)  # Also mandatory for an already-exited child.
            if time.monotonic() - started > build_timeout_seconds:
                raise ValueError('Configured package compression deadline exceeded.')
            if process.returncode:
                raise ValueError('dpkg-deb failed; retain stage/package for diagnosis.')
        finally:
            if process.poll() is None:
                os.killpg(process.pid, 15)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, 9)
                    process.wait()
        for control in (False, True):
            prefix = 'DEBIAN/'
            expected = {row['path'][len(prefix):] if control else row['path']: row for row in result['inventory']
                        if row['path'].startswith(prefix) == control}
            verify_archive(artifact, expected, control)
        B.verify_bundle(bundle, arch, snapshot)
        result.update(package=str(output), packageSHA256=B.digest(artifact), packageBytes=artifact.stat().st_size,
                      bundleManifestSHA256=snapshot.sha256,
                      installed=False, signed=False, published=False)
        encoded = B.canonical(result) + b'\n'
        B.owned_storage(stage.parent, maximum, additional=len(encoded))
        # Same filesystem, no replacement: only a fully verified archive receives the final name.
        os.link(artifact, output)
        with receipt.open('xb') as stream:
            stream.write(encoded)
        success = True
        return result
    finally:
        if success:
            shutil.rmtree(stage.parent)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--arch', choices=B.ARCH, required=True)
    parser.add_argument('--maintainer', default=DEFAULT_MAINTAINER,
                        help='Package identity override (default: verified project Git noreply identity).')
    parser.add_argument('--copyright-file', type=Path, required=True)
    parser.add_argument('--debian-revision', default='1')
    parser.add_argument('--upgrade-class', choices=('compatible', 'coordinated-maintenance'), required=True)
    parser.add_argument('--source-date-epoch', type=int, required=True)
    parser.add_argument('--max-stage-bytes', type=int, required=True)
    parser.add_argument('--build-timeout-seconds', type=positive_timeout_seconds,
                        default=DEFAULT_BUILD_TIMEOUT_SECONDS,
                        help='Finite package compression/build budget (default: 24 hours).')
    args = parser.parse_args(argv)
    value = build(args.bundle, args.output, args.arch, args.maintainer, args.copyright_file,
                  args.debian_revision, args.upgrade_class, args.source_date_epoch, args.max_stage_bytes,
                  args.build_timeout_seconds)
    print(json.dumps({k: v for k, v in value.items() if k != 'inventory'}, indent=2))


if __name__ == '__main__':
    main()
