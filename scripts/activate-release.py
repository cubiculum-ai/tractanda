#!/usr/bin/env python3
"""Upgrade one existing installation and verify immutable record preservation.

Invoked by release-macos.py through normal macOS administrator authentication.
No persistent privileged service or authorization exception is installed.
"""
import argparse
import hashlib
import ctypes
import fcntl
import errno
import json
import importlib.util
import plistlib
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess
import tempfile
import time
import uuid
from contextlib import contextmanager

_FORMAT_SPEC = importlib.util.spec_from_file_location('canonical_format_guard', Path(__file__).with_name('canonical-format-guard.py'))
format_guard = importlib.util.module_from_spec(_FORMAT_SPEC)
_FORMAT_SPEC.loader.exec_module(format_guard)


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


BACKUP_RESERVE = 10 * 1024**3
BACKUP_COPY_CAP = 32 * 1024**3
BACKUP_ENTRY_CAP = 100_000
BACKUP_MANIFEST_CAP = 64 * 1024**2
OPERATIONAL_NAMES = {'.writer.lock', '.tractanda-index-binding.json', 'semantic-maintenance.json'}
OPERATIONAL_PREFIXES = ('attachments/.staging/', 'attachments/.uploads/', 'documents/.staging/',
                        'document-jobs/', 'copies/')


def acl_text_fd(fd):
    """Darwin extended ACL, without path-dependent ls output or credential access."""
    if platform.system() != 'Darwin':
        raise RuntimeError('ACL-preserving release backup requires macOS.')
    library = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    library.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
    library.acl_get_fd_np.restype = ctypes.c_void_p
    library.acl_to_text.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ssize_t)]
    library.acl_to_text.restype = ctypes.c_void_p
    library.acl_free.argtypes = [ctypes.c_void_p]
    library.acl_free.restype = ctypes.c_int
    acl = library.acl_get_fd_np(fd, 0x100)  # ACL_TYPE_EXTENDED
    if not acl:
        code = ctypes.get_errno()
        if code == errno.ENOENT:
            value = os.fstat(fd)
            if stat.S_ISREG(value.st_mode) or stat.S_ISDIR(value.st_mode):
                return ''  # Existing Darwin file/directory without an extended ACL.
        raise OSError(code, 'Cannot read canonical extended ACL.')
    try:
        length = ctypes.c_ssize_t()
        text = library.acl_to_text(acl, ctypes.byref(length))
        if not text:
            raise RuntimeError('Canonical ACL text is unavailable.')
        try:
            if not 0 <= length.value <= 1024**2:
                raise RuntimeError('Canonical ACL exceeds its metadata bound.')
            return ctypes.string_at(text, length.value).decode('utf-8')
        finally:
            library.acl_free(text)
    finally:
        library.acl_free(acl)


def acl_text(path):
    value = Path(path).lstat()
    fd = secure_open(path, stat.S_ISDIR(value.st_mode))
    try:
        return acl_text_fd(fd)
    finally:
        os.close(fd)


def xattr_hashes(fd):
    if platform.system() != 'Darwin':
        raise RuntimeError('Native extended-attribute backup requires macOS.')
    library = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    library.flistxattr.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    library.flistxattr.restype = ctypes.c_ssize_t
    library.fgetxattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p,
                                 ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    library.fgetxattr.restype = ctypes.c_ssize_t
    length = library.flistxattr(fd, None, 0, 0)
    if not 0 <= length <= 256 * 1024:
        raise RuntimeError('Extended-attribute names are unavailable or exceed their bound.')
    names = ctypes.create_string_buffer(length)
    if library.flistxattr(fd, names, length, 0) != length:
        raise RuntimeError('Extended-attribute names changed during stopped backup.')
    result, total = {}, 0
    for key in sorted(k for k in names.raw.split(b'\0') if k):
        size = library.fgetxattr(fd, key, None, 0, 0, 0)
        if not 0 <= size <= 1024**2 or total + size > 1024**2:
            raise RuntimeError('Extended-attribute value is unavailable or exceeds its metadata bound.')
        data = ctypes.create_string_buffer(size)
        if library.fgetxattr(fd, key, data, size, 0, 0) != size:
            raise RuntimeError('Extended attribute changed during stopped backup.')
        total += size
        result[os.fsdecode(key)] = {'bytes': size, 'sha256': hashlib.sha256(data.raw).hexdigest()}
    return result


def file_metadata(path):
    initial = Path(path).lstat()
    if not stat.S_ISDIR(initial.st_mode) and not stat.S_ISREG(initial.st_mode):
        raise RuntimeError('Metadata requires a nofollow regular file or directory.')
    fd = secure_open(path, stat.S_ISDIR(initial.st_mode))
    try:
        value = os.fstat(fd)
        attributes = xattr_hashes(fd)
        return {'mode': stat.S_IMODE(value.st_mode), 'uid': value.st_uid, 'gid': value.st_gid,
                'flags': getattr(value, 'st_flags', 0), 'acl': acl_text_fd(fd), 'xattrs': attributes}
    finally:
        os.close(fd)


def inventory(store, metadata=file_metadata, hashes=True):
    """A stopped/locked inventory includes pending operational work for recovery."""
    store = Path(store)
    entries, logical, receipt_bytes, attribute_bytes = {}, 0, 0, 0
    for directory, folders, files in os.walk(store, followlinks=False):
        for path in [Path(directory), *(Path(directory) / name for name in folders + files)]:
            key = path.relative_to(store).as_posix()
            if key in entries:
                continue
            value = path.lstat()
            if not stat.S_ISDIR(value.st_mode) and not stat.S_ISREG(value.st_mode):
                raise RuntimeError('Canonical root contains a symlink or special file; inspect before upgrade.')
            if len(entries) >= BACKUP_ENTRY_CAP:
                raise RuntimeError('Canonical backup entry bound exceeded; no upgrade performed.')
            entry = {'kind': 'directory' if stat.S_ISDIR(value.st_mode) else 'file'}
            if entry['kind'] == 'file':
                logical += value.st_size
                entry['bytes'] = value.st_size
                if hashes:
                    entry['sha256'] = digest(path)
            if logical > BACKUP_COPY_CAP:
                raise RuntimeError('Canonical backup ordinary-copy cap exceeded; no upgrade performed.')
            if hashes:
                entry['metadata'] = metadata(path)
                attribute_bytes += sum(a['bytes'] for a in entry['metadata']['xattrs'].values())
                receipt_bytes += len(json.dumps(entry).encode()) + len(os.fsencode(key))
                if receipt_bytes > BACKUP_MANIFEST_CAP - 1024**2:
                    raise RuntimeError('Canonical backup inventory receipt bound exceeded.')
            entries[key] = entry
    estimate = logical + attribute_bytes + 16_384 * len(entries) + BACKUP_MANIFEST_CAP
    if estimate > BACKUP_COPY_CAP:
        raise RuntimeError('Canonical backup copy/metadata estimate exceeds its cap.')
    return {'entries': entries, 'logicalBytes': logical, 'copyEstimateBytes': estimate}


def available_bytes(path):
    value = os.statvfs(path)
    if value.f_frsize <= 0 or value.f_bavail < 0:
        raise RuntimeError('Genuine available filesystem capacity is unavailable.')
    return value.f_frsize * value.f_bavail


def require_capacity(path, estimate, available=available_bytes):
    if not 0 <= estimate <= BACKUP_COPY_CAP or available(path) < BACKUP_RESERVE + estimate:
        raise RuntimeError('Backup requires its ordinary-copy estimate plus genuine10GiB reserve.')


def write_private(path, value):
    data = (json.dumps(value, indent=2) + '\n').encode()
    if len(data) > BACKUP_MANIFEST_CAP:
        raise RuntimeError('Private backup receipt exceeds its bound.')
    with path.open('xb') as stream:
        os.chmod(path, 0o600)
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    synchronize(path.parent)


def synchronize(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


@contextmanager
def existing_writer_lock(store):
    path = Path(store) / '.writer.lock'
    fd = secure_open(path, writable=True)
    try:
        value = os.fstat(fd)
        if not stat.S_ISREG(value.st_mode) or value.st_nlink != 1 or value.st_uid != Path(store).lstat().st_uid or value.st_mode & 0o022:
            raise RuntimeError('Existing canonical writer lock is unsafe.')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


def copy_backup(store, destination, before, available=available_bytes, metadata=file_metadata):
    require_capacity(destination.parent, before['copyEstimateBytes'], available)
    destination.mkdir(mode=0o700)
    container = destination.lstat()
    if container.st_uid != os.geteuid() or stat.S_IMODE(container.st_mode) != 0o700 or acl_text(destination).strip() not in ('', '!#acl 1'):
        raise RuntimeError('New backup container is not private; no copy performed.')
    process = subprocess.Popen(['/usr/bin/ditto', '--rsrc', '--extattr', '--acl', str(store),
                                str(destination / 'store')], stdout=subprocess.DEVNULL)
    deadline = time.monotonic() + 600
    try:
        while process.poll() is None:
            require_capacity(destination, 0, available)
            if time.monotonic() >= deadline:
                raise TimeoutError('Bounded canonical backup copy did not finish.')
            time.sleep(.2)
        if process.wait() != 0:
            raise RuntimeError('Native metadata-preserving canonical copy failed.')
    except BaseException:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        raise
    observed = inventory(destination / 'store', metadata)
    if observed['entries'] != before['entries']:
        raise RuntimeError('Canonical backup bytes or ownership/mode/ACL/xattrs differ.')
    for key, entry in observed['entries'].items():
        if entry['kind'] == 'file':
            synchronize(destination / 'store' / key)
    for directory, _, _ in os.walk(destination / 'store', topdown=False):
        synchronize(Path(directory))
    require_capacity(destination, 0, available)
    write_private(destination / 'backup.json', {'status': 'verified', 'canonicalRoot': str(store),
                  'ordinaryCopyEstimateBytes': before['copyEstimateBytes'], 'inventory': before})
    return destination / 'backup.json'


def operational_path(path, index_relative=None):
    return (path in OPERATIONAL_NAMES or any(path == prefix.rstrip('/') or path.startswith(prefix) for prefix in OPERATIONAL_PREFIXES)
            or index_relative is not None and (path == index_relative or path.startswith(index_relative + '/')))


def require_preserved(before, after, index_relative=None, semantic_change=None, reader_change=None):
    """Immutable content/identity/settings are distinct from recoverable operation checkpoints."""
    changed = []
    for path, entry in before['entries'].items():
        if operational_path(path, index_relative):
            continue
        current = after['entries'].get(path)
        if path == format_guard.MARKER_NAME and reader_change and entry != current:
            if current is None or entry['metadata'] != current['metadata']:
                raise RuntimeError('Canonical reader requirement ownership/mode/ACL/xattrs changed.')
            reader_change()
            changed.append(path)
            continue
        if path == 'semantic.json' and semantic_change and entry != current:
            if current is None or entry['metadata'] != current['metadata']:
                raise RuntimeError('Semantic setting ownership/mode/ACL/xattrs changed.')
            semantic_change(entry, current)
            changed.append(path)
            continue
        if current != entry:
            raise RuntimeError('Pre-existing canonical bytes or meaningful metadata changed/disappeared: ' + path)
    return changed


def service_pid(label):
    output = subprocess.check_output(['/bin/launchctl', 'print', label], text=True)
    found = re.search(r'^\s*pid = (\d+)\s*$', output, re.M)
    if not found:
        raise RuntimeError('Managed writer process cannot be identified.')
    return int(found.group(1))


def wait_writer_exit(pid, identity, timeout=30):
    deadline = time.monotonic() + timeout
    while True:
        result = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'lstart=,command='],
                                capture_output=True, text=True)
        if result.returncode:
            return
        if result.stdout.strip() != identity:
            return  # Original process exited; never signal a reused PID.
        if time.monotonic() >= deadline:
            raise TimeoutError('Graceful managed writer shutdown did not complete.')
        time.sleep(.05)


def retain_stopped_recovery(receipt_path, expected, definition, expected_definition, reason):
    """Persist an actionable stopped state; never restore canonical data from the backup."""
    current = format_guard.bounded_json(receipt_path, 1024**2)
    if current.get('instance') != expected['instance'] or current.get('manifestSHA256') != expected['manifestSHA256']:
        raise RuntimeError('Receipt changed while stopping incompatible reader; inspect retained data.')
    if definition.exists() and digest(definition) == expected_definition:
        label = 'system/ai.tractanda.server.' + expected['instance']
        running = subprocess.run(['/bin/launchctl', 'print', label], capture_output=True)
        if running.returncode == 0:
            pid = service_pid(label)
            identity = subprocess.check_output(['/bin/ps', '-p', str(pid), '-o', 'lstart=,command='], text=True).strip()
            if str(Path(expected['release']) / 'bin/tractanda') not in identity:
                raise RuntimeError('Restored process identity is unknown; operator must inspect without data restoration.')
            subprocess.run(['/bin/launchctl', 'bootout', label], check=True)
            wait_writer_exit(pid, identity)
        definition.unlink()
        synchronize(definition.parent)
    current['state'] = 'preparing'
    current['definitionSHA256'] = None
    current['recoveryReason'] = ('Canonical reader restoration blocked; writer is stopped. Keep live data/backups intact and retry with a compatible reader. ' + str(reason))[:4096]
    metadata = receipt_path.lstat()
    with tempfile.NamedTemporaryFile(mode='w', dir=receipt_path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        os.chmod(temporary, 0o600)
        os.chown(temporary, metadata.st_uid, metadata.st_gid)
        json.dump(current, stream, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    try:
        temporary.replace(receipt_path)
        synchronize(receipt_path.parent)
    finally:
        if temporary.exists():
            temporary.unlink()


def restore_service(label, definition, expected_definition, old_client, socket, expected_manifest=None):
    if digest(definition) != expected_definition:
        raise RuntimeError('Old owned service definition changed; restoration requires inspection.')
    specification = plistlib.loads(Path(definition).read_bytes())
    arguments = specification.get('ProgramArguments', [])
    if len(arguments) < 4 or arguments[0] != str(old_client) or arguments[1] not in ('daemon', 'serve'):
        raise RuntimeError('Old writer store binding is unknown; leave it stopped.')
    format_guard.require_owned_reader(old_client, Path(arguments[2]), expected_manifest)
    status = subprocess.run(['/bin/launchctl', 'print', label], capture_output=True)
    if status.returncode:
        subprocess.run(['/bin/launchctl', 'bootstrap', 'system', str(definition)], check=True)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        result = subprocess.run([str(old_client), 'info', socket], capture_output=True, text=True,
                                env={**os.environ, 'TRACTANDA_SERVER_USER': 'daemon'}, timeout=5)
        if result.returncode == 0:
            info = json.loads(result.stdout)
            if info.get('server', {}).get('executableSHA256') == digest(old_client) and info.get('server', {}).get('processID') == service_pid(label):
                return
        time.sleep(.1)
    raise RuntimeError('Old managed writer restoration did not become ready.')


def backup_before_upgrade(receipt, base, candidate_setup):
    store = Path(receipt['store']).resolve(strict=True)
    index = Path(receipt['indexDirectory']).resolve(strict=True)
    backup_parent = Path('/Users/Shared/Library/Tractanda/Backups') / receipt['instance']
    for reserved in (store, index, base / 'releases'):
        if backup_parent == reserved or reserved in backup_parent.parents or backup_parent in reserved.parents:
            raise RuntimeError('Private backup overlaps canonical/index/software-release trees.')
    for path in (backup_parent.parent, backup_parent):
        if not path.exists():
            path.mkdir(mode=0o700)
            subprocess.run(['/bin/chmod', '-N', str(path)], check=True)
            synchronize(path.parent)
        value = path.lstat()
        if not stat.S_ISDIR(value.st_mode) or value.st_uid != 0 or value.st_mode & 0o077:
            raise RuntimeError('Backup parent must be a private root-owned directory.')
        if acl_text(path).strip() not in ('', '!#acl 1'):
            raise RuntimeError('Backup parent has an extended ACL requiring inspection.')
    require_capacity(backup_parent, inventory(store, hashes=False)['copyEstimateBytes'])
    label = 'system/ai.tractanda.server.' + receipt['instance']
    definition = Path('/Library/LaunchDaemons/ai.tractanda.server.' + receipt['instance'] + '.plist')
    expected_definition = receipt['definitionSHA256']
    if digest(definition) != expected_definition:
        raise RuntimeError('Managed writer definition differs from its owned receipt.')
    pid = service_pid(label)
    identity = subprocess.check_output(['/bin/ps', '-p', str(pid), '-o', 'lstart=,command='], text=True).strip()
    if str(Path(receipt['release']) / 'bin/tractanda') not in identity:
        raise RuntimeError('Managed writer is not the receipt-owned executable.')
    destination = backup_parent / (time.strftime('%Y%m%dT%H%M%SZ', time.gmtime()) + '-' + str(uuid.uuid4()))
    def stop_writer():
        subprocess.run(['/bin/launchctl', 'bootout', label], check=True)
        wait_writer_exit(pid, identity)
    def restore_writer():
        try:
            restore_service(label, definition, expected_definition,
                            Path(receipt['release']) / 'bin/tractanda', receipt['socket'], receipt['manifestSHA256'])
        except BaseException as failure:
            # Backup already stopped the owned writer. A failed compatibility proof must
            # not leave an active receipt that a later outer catch could restart.
            retain_stopped_recovery(base / 'receipts' / (receipt['instance'] + '.json'), receipt,
                                    definition, expected_definition, failure)
            raise
    def admit_reader():
        subprocess.run(['/usr/bin/sudo', '-n', '-u', 'daemon', '--', str(candidate_setup),
                        '--canonical-reader-admit', str(store)], check=True)
    before, proof = checkpoint_backup(store, destination, stop_writer, restore_writer, admit_reader=admit_reader)
    return before, proof, store, index


def checkpoint_backup(store, destination, stop_writer, restore_writer,
                      lock=existing_writer_lock, inspect=inventory, copier=copy_backup, admit_reader=None):
    try:
        stop_writer()
        if admit_reader is not None:
            admit_reader()
        with lock(store):
            before = inspect(store)
            proof = copier(store, destination, before)
        return before, proof
    except BaseException as original:
        if destination.exists() and not (destination / 'failure.json').exists():
            try:
                write_private(destination / 'failure.json', {'status': 'failed', 'reason': type(original).__name__,
                              'partialCopyRetained': True})
            except OSError:
                pass  # Failure evidence must not bypass mandatory old-service restoration.
        try:
            restore_writer()
        except BaseException as restored:
            raise RuntimeError('Backup failed and old writer restoration failed: ' + str(restored)) from original
        raise


def preserved_after_upgrade(store, before, index_relative=None):
    entries = {}
    for path, entry in before['entries'].items():
        if operational_path(path, index_relative):
            continue
        target = store / path
        try:
            value = target.lstat()
        except FileNotFoundError:
            continue
        kind = 'directory' if stat.S_ISDIR(value.st_mode) else 'file' if stat.S_ISREG(value.st_mode) else 'unsafe'
        current = {'kind': kind, 'metadata': file_metadata(target)}
        if kind == 'file':
            current.update(bytes=value.st_size, sha256=digest(target))
        entries[path] = current
    return {'entries': entries}


def verify_semantic_migration(store, before_receipt, after_receipt, previous, current):
    payload = after_receipt.get('embedding')
    if not payload or payload.get('backend') != 'vmlx-granite-embedding-f32-v1':
        raise RuntimeError('Unrecognized semantic settings migration.')
    configuration = json.loads((store / 'semantic.json').read_text())
    expected = {'formatVersion': 2, 'configurationID': after_receipt['embeddingConfigurationID'],
                'operationID': 'setup-embedding-v2-' + after_receipt['instance'] + '-' + after_receipt['embeddingConfigurationID'],
                'endpoint': 'http://127.0.0.1:' + str(after_receipt['port'] + 1) + '/v1/embeddings',
                'model': payload['model'], 'modelRevision': payload['modelRevision'],
                'dimensions': payload['dimensions'], 'documentPrefix': '', 'queryPrefix': '',
                'chunkBytes': 384, 'overlapBytes': 64, 'pooling': 'cls', 'normalization': 'l2',
                'inputEncoding': 'item-text-utf8-v2'}
    if configuration != expected:
        raise RuntimeError('Semantic setting change is not the supported installer-owned bundled migration.')
    return {'path': 'semantic.json', 'beforeSHA256': previous['sha256'], 'afterSHA256': current['sha256'],
            'reason': 'supported installer-managed bundled embedding configuration'}


def obsolete_releases(receipt, previous_release, other_receipts):
    keep = {receipt['release'], previous_release}
    for other in other_receipts:
        keep.add(other['release'])
        keep.update(other['releases'])
    return {path: digest for path, digest in receipt['releases'].items() if path not in keep}


def prune_releases(base, receipt_path, receipt, previous_release, setup):
    others = []
    for path in (base / 'receipts').glob('*.json'):
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
    base = Path('/Users/Shared/Library/Application Support/Tractanda')
    if args.software_root != base or not re.fullmatch(r'[a-z0-9-]+', args.instance):
        parser.error('Choose an existing managed Tractanda installation.')
    receipt_path = base / 'receipts' / (args.instance + '.json')
    mode = receipt_path.lstat()
    if not stat.S_ISREG(mode.st_mode) or mode.st_uid != 0 or mode.st_mode & 0o022:
        raise ValueError('Installation receipt must be a protected root-owned regular file.')
    receipt = json.loads(receipt_path.read_text())
    if receipt['state'] != 'active':
        raise ValueError('Only existing active installations can be upgraded by this workflow.')
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
    registry = json.loads((base / 'connections.json').read_text())
    before, backup_proof, store, index = backup_before_upgrade(receipt, base, setup)
    before_reader = format_guard.load_requirement(store)
    try:
        if registry.get('defaultProfile') == args.instance:
            subprocess.run(['/usr/sbin/installer', '-pkg', str(args.package), '-target', '/'], check=True)
        else:
            # The native package targets the system default; other databases use explicit setup.
            subprocess.run([str(setup), 'upgrade', '--bundle', str(bundle), '--name', args.instance], check=True)
    except BaseException:
        # Setup owns installation rollback. Restore a stopped old writer only when its exact
        # previous active receipt/definition still apply; never force an old binary over a candidate.
        current = json.loads(receipt_path.read_text())
        if current.get('state') == 'active' and current.get('manifestSHA256') == receipt['manifestSHA256']:
            definition = Path('/Library/LaunchDaemons/ai.tractanda.server.' + args.instance + '.plist')
            try:
                restore_service('system/ai.tractanda.server.' + args.instance, definition,
                                receipt['definitionSHA256'], Path(receipt['release']) / 'bin/tractanda', receipt['socket'], receipt['manifestSHA256'])
            except BaseException as failure:
                retain_stopped_recovery(receipt_path, receipt, definition, receipt['definitionSHA256'], failure)
                raise
        raise
    updated = json.loads(receipt_path.read_text())
    index_relative = index.relative_to(store).as_posix() if store in index.parents else None
    after = preserved_after_upgrade(store, before, index_relative)
    semantic_changes = []
    def allow_semantic(previous, current):
        semantic_changes.append(verify_semantic_migration(store, receipt, updated, previous, current))
    require_preserved(before, after, index_relative, allow_semantic,
                      lambda: format_guard.require_monotonic(before_reader, format_guard.load_requirement(store)))
    for key in ('store', 'indexDirectory', 'owner', 'port', 'socket'):
        if updated[key] != receipt[key]:
            raise RuntimeError('Upgrade changed an existing installation property: ' + key)
    if updated['manifestSHA256'] != args.manifest_sha256 or updated['state'] != 'active':
        raise RuntimeError('Installation did not activate the prepared bundle.')
    cleanup_warnings = []
    try:
        removed = prune_releases(base, receipt_path, updated, receipt['release'], setup)
    except Exception as error:
        removed = []
        cleanup_warnings.append(str(error))
    print(json.dumps({'status': 'passed', 'preservedCanonicalEntries': len(after['entries']),
                      'backupProof': str(backup_proof), 'backupProofSHA256': digest(backup_proof),
                      'semanticSettingsChanges': semantic_changes, 'release': updated['release'],
                      'manifestSHA256': args.manifest_sha256, 'removedOldReleases': removed,
                      'cleanupWarnings': cleanup_warnings}))


if __name__ == '__main__':
    main()
