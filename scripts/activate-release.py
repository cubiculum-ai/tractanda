#!/usr/bin/env python3
"""Upgrade an existing installation through its managed stop/swap/start workflow.

Invoked by release-macos.py through normal macOS administrator authentication.
No persistent privileged service or authorization exception is installed.
"""
import argparse
import hashlib
import json
import importlib.util
import os
from pathlib import Path
import platform
import pwd
import signal
import sys
import re
import shutil
import stat
import subprocess
import tempfile
from contextlib import contextmanager

_FORMAT_SPEC = importlib.util.spec_from_file_location('canonical_format_guard', Path(__file__).with_name('canonical-format-guard.py'))
format_guard = importlib.util.module_from_spec(_FORMAT_SPEC)
_FORMAT_SPEC.loader.exec_module(format_guard)


def cancel_startup(_signal, _frame):
    raise KeyboardInterrupt('Operator cancelled activation.')


@contextmanager
def protected_candidate_stage(bundle, package, manifest_sha256, package_sha256):
    """Root-owned software is daemon-readable; package/control data stays root-private."""
    if os.geteuid() != 0:
        raise RuntimeError('Protected candidate staging requires root.')
    bundle, package = Path(bundle).resolve(strict=True), Path(package).resolve(strict=True)
    if digest(bundle / 'bundle-manifest.json') != manifest_sha256 or digest(package) != package_sha256:
        raise RuntimeError('Candidate inputs changed before protected staging.')
    manifest = json.loads((bundle / 'bundle-manifest.json').read_text())
    require_capacity(Path('/private/var/tmp'), sum(int(v['size']) for v in manifest['files']) + package.stat().st_size)
    group = pwd.getpwnam('daemon').pw_gid
    root = Path(tempfile.mkdtemp(prefix='tractanda-install-', dir='/private/var/tmp')).resolve(strict=True)
    try:
        os.chown(root, 0, group); root.chmod(0o710)
        control = root / 'control'; control.mkdir(mode=0o700)
        protected_package = control / 'release.pkg'
        shutil.copyfile(package, protected_package); protected_package.chmod(0o600)
        software = root / 'bundle'; shutil.copytree(bundle, software, symlinks=True)
        for parent, directories, files in os.walk(software, followlinks=False):
            for path in [Path(parent)] + [Path(parent) / n for n in directories + files]:
                mode = path.lstat()
                if stat.S_ISLNK(mode.st_mode):
                    path.resolve(strict=True).relative_to(software.resolve())
                    os.chown(path, 0, group, follow_symlinks=False)
                elif stat.S_ISDIR(mode.st_mode):
                    os.chown(path, 0, group); path.chmod(0o750)
                elif stat.S_ISREG(mode.st_mode):
                    if mode.st_mode & 0o022:
                        raise RuntimeError('Candidate software has writable group/world mode.')
                    os.chown(path, 0, group)  # Preserve signed inventory file modes.
                else:
                    raise RuntimeError('Candidate software contains a special file.')
        if digest(software / 'bundle-manifest.json') != manifest_sha256 or digest(protected_package) != package_sha256:
            raise RuntimeError('Protected candidate copy changed.')
        # activate_candidate verifies the full copied inventory/signature before stopping anything.
        yield software, protected_package
    finally:
        try:
            shutil.rmtree(root)
        except OSError as error:
            print('Secondary protected-stage cleanup warning: ' + str(error), file=sys.stderr)


def secure_open(path, directory=False, writable=False):
    path = Path(path)
    if not path.is_absolute():
        raise ValueError('Release paths must be absolute.')
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for component in path.parts[1:-1]:
            next_fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                              dir_fd=fd)
            os.close(fd)
            fd = next_fd
        flags = (os.O_RDWR if writable else os.O_RDONLY) | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC
        if directory:
            flags |= os.O_DIRECTORY
        return os.open(path.name, flags, dir_fd=fd)
    finally:
        os.close(fd)


def digest(path):
    fd = secure_open(path)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise RuntimeError('Release hashing requires a regular file.')
        result = hashlib.file_digest(stream, 'sha256').hexdigest()
        after = os.fstat(fd)
        fields = ('st_dev', 'st_ino', 'st_size', 'st_mode', 'st_uid', 'st_gid', 'st_mtime_ns', 'st_ctime_ns')
        if any(getattr(before, field) != getattr(after, field) for field in fields):
            raise RuntimeError('File changed during bounded release hashing.')
        return result


STAGING_RESERVE = 10 * 1024**3
STAGING_COPY_CAP = 32 * 1024**3


def available_bytes(path):
    value = os.statvfs(path)
    if value.f_frsize <= 0 or value.f_bavail < 0:
        raise RuntimeError('Genuine available filesystem capacity is unavailable.')
    return value.f_frsize * value.f_bavail


def require_capacity(path, estimate, available=available_bytes):
    if not 0 <= estimate <= STAGING_COPY_CAP or available(path) < STAGING_RESERVE + estimate:
        raise RuntimeError('Software staging requires its copy estimate plus genuine 10 GiB reserve.')


def obsolete_releases(receipt, previous_release, other_receipts):
    keep = {receipt['release'], previous_release}
    for other in other_receipts:
        keep.add(other['release'])
        keep.update(other['releases'])
    return {path: digest for path, digest in receipt['releases'].items() if path not in keep}


def prune_releases(base, receipt_path, receipt, previous_release, setup):
    others = []
    for path in receipt_path.parent.glob('*.json'):
        if path != receipt_path:
            others.append(json.loads(path.read_text()))
    removed = []
    try:
        for name, expected in obsolete_releases(receipt, previous_release, others).items():
            target = Path(name)
            if target.is_symlink() or target.parent != base / 'releases':
                raise ValueError('An obsolete release path requires manual inspection.')
            if target.exists():
                if not target.is_dir() or digest(target / 'bundle-manifest.json') != expected:
                    raise ValueError('An obsolete release differs from its ownership receipt.')
                # Validate the full owned inventory before deleting a version, just as setup does.
                subprocess.run([str(setup), 'plan', '--bundle', str(target)], check=True,
                               stdout=subprocess.DEVNULL)
                shutil.rmtree(target)
            # A missing owned directory also reconciles an interrupted earlier cleanup.
            del receipt['releases'][name]
            removed.append(name)
    finally:
        if removed:
            metadata = receipt_path.stat()
            with tempfile.NamedTemporaryFile(mode='w', dir=receipt_path.parent, delete=False) as stream:
                json.dump(receipt, stream, indent=2)
                stream.write('\n')
                temporary = Path(stream.name)
            os.chown(temporary, metadata.st_uid, metadata.st_gid)
            os.chmod(temporary, 0o600)
            temporary.replace(receipt_path)
    return removed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--software-root', type=Path, required=True)
    parser.add_argument('--instance', required=True)
    parser.add_argument('--manifest-sha256', required=True)
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--package-sha256', required=True)
    args = parser.parse_args()
    if platform.system() != 'Darwin' or os.geteuid() != 0:
        parser.error('Run this upgrade through macOS administrator authentication.')
    signal.signal(signal.SIGTERM, cancel_startup)
    signal.signal(signal.SIGINT, cancel_startup)
    signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM, signal.SIGINT})
    active_installation(args)
    with protected_candidate_stage(args.bundle, args.package, args.manifest_sha256, args.package_sha256) as (bundle, package):
        args.bundle, args.package = bundle, package
        activate_candidate(args)


def active_installation(args):
    base = Path('/Library/Tractanda/Software')
    if args.software_root != base or not re.fullmatch(r'[a-z0-9-]+', args.instance):
        raise ValueError('Choose an existing managed Tractanda installation.')
    receipt_path = base.parent / 'Installation' / 'receipts' / (args.instance + '.json')
    mode = receipt_path.lstat()
    if not stat.S_ISREG(mode.st_mode) or mode.st_uid != 0 or mode.st_mode & 0o022:
        raise ValueError('Installation receipt must be a protected root-owned regular file.')
    receipt = json.loads(receipt_path.read_text())
    if receipt['state'] != 'active':
        raise ValueError('Only existing active installations can be upgraded by this workflow.')
    return base, receipt_path, receipt


def activate_candidate(args):
    base, receipt_path, receipt = active_installation(args)
    bundle = args.bundle.resolve(strict=True)
    if digest(bundle / 'bundle-manifest.json') != args.manifest_sha256:
        raise ValueError('The prepared bundle changed before activation.')
    setup = bundle / 'bin/tractanda-setup'
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(setup)], check=True)
    subprocess.run([str(setup), 'plan', '--bundle', str(bundle), '--name', args.instance], check=True)
    if digest(args.package) != args.package_sha256:
        raise ValueError('The prepared native package changed before activation.')
    subprocess.run(['/usr/sbin/pkgutil', '--check-signature', str(args.package)], check=True)
    subprocess.run(['xcrun', 'stapler', 'validate', str(args.package)], check=True)
    subprocess.run(['/usr/sbin/spctl', '--assess', '--type', 'install', '--verbose=4', str(args.package)], check=True)
    registry = json.loads((base.parent / 'Configuration' / 'connections.json').read_text())
    store = Path(receipt['store']).resolve(strict=True)
    before_reader = format_guard.load_requirement(store)
    manifest = json.loads((bundle / 'bundle-manifest.json').read_text())
    format_guard.require_reader(format_guard.support_from_manifest(manifest), before_reader)
    # Setup owns drain/stop/swap/start and fail-closed recovery. The release helper
    # never copies, restores or inventories canonical content for a binary update.
    if registry.get('defaultProfile') == args.instance:
        subprocess.run(['/usr/sbin/installer', '-pkg', str(args.package), '-target', '/'], check=True)
    else:
        subprocess.run([str(setup), 'upgrade', '--bundle', str(bundle), '--name', args.instance], check=True)
    updated = json.loads(receipt_path.read_text())
    format_guard.require_monotonic(before_reader, format_guard.load_requirement(store))
    for key in ('store', 'indexDirectory', 'owner', 'port', 'socket'):
        if updated[key] != receipt[key]:
            raise RuntimeError('Upgrade changed an existing installation property: ' + key)
    if updated['manifestSHA256'] != args.manifest_sha256 or updated['state'] != 'active':
        raise RuntimeError('Installation did not activate the prepared bundle.')
    cleanup_warnings = []
    removed = []
    try:
        removed = prune_releases(base, receipt_path, updated, receipt['release'], setup)
    except Exception as error:
        cleanup_warnings.append(str(error))
    print(json.dumps({'status': 'passed', 'canonicalStoreID': before_reader['storeID'],
                      'release': updated['release'],
                      'manifestSHA256': args.manifest_sha256, 'removedOldReleases': removed,
                      'cleanupWarnings': cleanup_warnings}))


if __name__ == '__main__':
    main()
