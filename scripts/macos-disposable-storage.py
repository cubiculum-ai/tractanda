#!/usr/bin/env python3
"""Select and recheck an owned macOS build directory, without following links."""
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile

RESERVE = 10 * 1024 ** 3


def physical(path):
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts:
        raise RuntimeError('Disposable paths must be absolute and normalized.')
    for component in (path, *path.parents):
        if component.is_symlink():
            raise RuntimeError('Disposable paths may not contain symlinks: ' + str(component))
    return path


def volume_uuid(path):
    info = plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil', 'info', '-plist', str(path)]))
    return info.get('VolumeUUID', '')


def private_directory(path):
    info = physical(path).lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise RuntimeError('Disposable root must be a current-user-owned 0700 directory: ' + str(path))
    return info


def validate_settings(configuration):
    keys = ('disposableVolumeMount', 'disposableRoot', 'disposableVolumeUUID')
    if not any(key in configuration for key in keys):
        return None
    values = [configuration.get(key) for key in keys]
    if not all(isinstance(value, str) and value for value in values):
        raise RuntimeError('Disposable root, volume mount and volume UUID must be configured together.')
    mount, root, expected = values
    mount, root = physical(mount), physical(root)
    if root == mount or mount not in root.parents or not re.fullmatch(r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}', expected):
        raise RuntimeError('Invalid disposable root or volume UUID.')
    return mount, root, expected


def select(configuration, fallback, *, mounted=os.path.ismount, uuid=volume_uuid):
    """Create a fresh run; create only a missing root leaf on the verified mount."""
    settings = validate_settings(configuration)
    mount, root, expected = settings if settings else (None, None, None)
    external = False
    if mount:
        if mounted(mount):
            if uuid(mount).upper() != expected.upper():
                raise RuntimeError('Mounted disposable volume UUID differs from configuration.')
            if not root.exists():
                parent = physical(root.parent)
                parent_info = parent.lstat()
                if (not stat.S_ISDIR(parent_info.st_mode) or parent_info.st_uid not in (0, os.getuid())
                        or stat.S_IMODE(parent_info.st_mode) & 0o022
                        or parent_info.st_dev != os.stat(mount).st_dev):
                    raise RuntimeError('Disposable root parent is not a safe directory on the configured volume.')
                parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                try:
                    fd_info = os.fstat(parent_fd)
                    if ((fd_info.st_dev, fd_info.st_ino) != (parent_info.st_dev, parent_info.st_ino)
                            or not mounted(mount) or uuid(mount).upper() != expected.upper()):
                        raise RuntimeError('Configured volume changed before root creation.')
                    os.mkdir(root.name, mode=0o700, dir_fd=parent_fd)
                finally:
                    os.close(parent_fd)
            private_directory(root)
            if os.stat(root).st_dev != os.stat(mount).st_dev:
                raise RuntimeError('Disposable root is not on the configured volume.')
            external = True
        else:
            # A directory with contents at the mount path is not an absent mount.
            # Never write into it, even if the OS has left a stale mountpoint.
            root = None
    if not external:
        root = physical(fallback)
        private_directory(root)
    fs = os.statvfs(root)
    if fs.f_frsize <= 0 or fs.f_bavail * fs.f_frsize < RESERVE:
        raise RuntimeError('Disposable volume lacks the 10 GiB free-space reserve.')
    if external and (not mounted(mount) or uuid(mount).upper() != expected.upper()
                     or os.stat(root).st_dev != os.stat(mount).st_dev):
        raise RuntimeError('Configured disposable volume changed before run creation.')
    run = Path(tempfile.mkdtemp(prefix='macos-release-', dir=root))
    info = private_directory(run)
    return {'path': str(run), 'device': info.st_dev, 'inode': info.st_ino,
            'mount': str(mount) if external else None,
            'volumeUUID': expected.upper() if external else None}


def verify(identity, *, mounted=os.path.ismount, uuid=volume_uuid):
    """Fail closed if the chosen volume or the owned directory has changed."""
    path = physical(identity['path'])
    mount = identity['mount']
    if mount and (not mounted(mount) or uuid(mount).upper() != identity['volumeUUID']):
        raise RuntimeError('Selected disposable volume is unavailable or changed.')
    try:
        info = private_directory(path)
    except FileNotFoundError as error:
        raise RuntimeError('Selected disposable directory disappeared.') from error
    if mount and os.stat(mount).st_dev != info.st_dev:
        raise RuntimeError('Disposable directory is not on its selected volume.')
    if (info.st_dev, info.st_ino) != (identity['device'], identity['inode']):
        raise RuntimeError('Selected disposable directory identity changed.')


def dispose(identity, allowed_parent, *, mounted=os.path.ismount, uuid=volume_uuid):
    """Remove the exact retired run, or accept its absence on the verified volume."""
    path = physical(identity['path'])
    parent = physical(allowed_parent)
    if path.parent != parent or not path.name.startswith('macos-release-'):
        raise RuntimeError('Refusing cleanup outside the configured run root.')
    mount = identity['mount']
    if mount:
        if not mounted(mount) or uuid(mount).upper() != identity['volumeUUID']:
            raise RuntimeError('Selected disposable volume is unavailable or changed.')
    parent_info = private_directory(parent)
    if mount and parent_info.st_dev != os.stat(mount).st_dev:
        raise RuntimeError('Cleanup parent is not on the selected volume.')
    parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        opened_parent = os.fstat(parent_fd)
        if (opened_parent.st_dev, opened_parent.st_ino) != (parent_info.st_dev, parent_info.st_ino):
            raise RuntimeError('Cleanup parent identity changed.')
        try:
            entry = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            # Only infer success after checking the real parent and mounted UUID.
            if mount and (not mounted(mount) or uuid(mount).upper() != identity['volumeUUID']):
                raise RuntimeError('Selected disposable volume disappeared during cleanup.')
            return
        if (not stat.S_ISDIR(entry.st_mode) or entry.st_uid != os.getuid()
                or stat.S_IMODE(entry.st_mode) != 0o700 or entry.st_ino != identity['inode']
                or entry.st_dev != opened_parent.st_dev
                or not mount and entry.st_dev != identity['device']):
            raise RuntimeError('Disposable directory identity changed before cleanup.')
        # UUID plus inode, private ownership, exact parent and path identify a
        # retired external run after a remount may change st_dev. Active runs
        # still require their originally recorded st_dev in verify().
        device = entry.st_dev
        for directory, subdirs, files in os.walk(path, followlinks=False):
            for name in subdirs + files:
                info = (Path(directory) / name).lstat()
                if not stat.S_ISLNK(info.st_mode) and info.st_dev != device:
                    raise RuntimeError('Refusing cleanup across a filesystem boundary.')
        if mount and (not mounted(mount) or uuid(mount).upper() != identity['volumeUUID']):
            raise RuntimeError('Selected disposable volume disappeared during cleanup.')
        current = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
        if (current.st_dev, current.st_ino) != (entry.st_dev, entry.st_ino):
            raise RuntimeError('Disposable directory identity changed before cleanup.')
        if not shutil.rmtree.avoids_symlink_attacks:
            raise RuntimeError('Safe descriptor-based directory cleanup is unavailable.')
        shutil.rmtree(path.name, dir_fd=parent_fd)
    finally:
        os.close(parent_fd)
