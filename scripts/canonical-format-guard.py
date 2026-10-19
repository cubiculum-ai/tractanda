#!/usr/bin/env python3
"""Read-only compatibility gates for already stopped managed activation/rollback paths."""
import hashlib
import json
import os
from pathlib import Path
import stat
import uuid

PROFILE = 'tractanda.canonical-formats.v1'
MARKER_PROFILE = 'tractanda.canonical-reader.v1'
MARKER_NAME = 'canonical-reader.json'
LEGACY = {'profile': PROFILE, 'readerLevel': 1, 'writerLevel': 1, 'read': [1], 'write': [1],
          'capabilities': [], 'writeCapabilities': []}


def bounded_bytes(path, maximum, owner=None):
    path = Path(path)
    if not path.is_absolute():
        raise RuntimeError('Canonical proof paths must be absolute.')
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for component in path.parts[1:-1]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            os.close(fd)
            fd = child
        source = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
    finally:
        os.close(fd)
    with os.fdopen(source, 'rb') as stream:
        before = os.fstat(stream.fileno())
        if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size > maximum
                or owner is not None and (before.st_uid != owner or before.st_mode & 0o077)):
            raise RuntimeError('Canonical compatibility proof is not a bounded private regular file.')
        raw = stream.read(maximum + 1)
        after = os.fstat(stream.fileno())
        if len(raw) > maximum or (before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_ino, after.st_size, after.st_mtime_ns):
            raise RuntimeError('Canonical compatibility proof changed during reading.')
    return raw


def bounded_json(path, maximum, owner=None):
    return json.loads(bounded_bytes(path, maximum, owner))


def digest_executable(path):
    path = Path(path)
    if not path.is_absolute():
        raise RuntimeError('Owned reader path must be absolute.')
    parent = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for component in path.parts[1:-1]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
            os.close(parent)
            parent = child
        descriptor = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
    finally:
        os.close(parent)
    with os.fdopen(descriptor, 'rb') as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size > 512 * 1024**2 or before.st_mode & 0o022:
            raise RuntimeError('Owned reader executable is unsafe or exceeds its hash window.')
        digest = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024**2), b''):
            digest.update(chunk)
        after = os.fstat(stream.fileno())
        if (before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_ino, after.st_size, after.st_mtime_ns):
            raise RuntimeError('Owned reader executable changed during hashing.')
        return digest.hexdigest()


def integers(values):
    return (isinstance(values, list) and bool(values) and len(values) <= 1024
            and all(type(v) is int and 1 <= v <= 1024 for v in values) and values == sorted(set(values)))


def capabilities(values):
    return (isinstance(values, list) and len(values) <= 64
            and all(isinstance(v, str) and 0 < len(v.encode()) <= 128 for v in values) and values == sorted(set(values)))


def validate_support(value):
    if (not isinstance(value, dict) or set(value) != set(LEGACY) or value['profile'] != PROFILE
            or type(value['readerLevel']) is not int or not 1 <= value['readerLevel'] <= 1024
            or type(value['writerLevel']) is not int or not 1 <= value['writerLevel'] <= value['readerLevel']
            or not integers(value['read']) or not integers(value['write'])
            or not set(value['write']) <= set(value['read'])
            or not capabilities(value['capabilities']) or not capabilities(value['writeCapabilities'])
            or not set(value['writeCapabilities']) <= set(value['capabilities'])):
        raise RuntimeError('Unknown canonical reader declaration.')
    return value


def support_from_manifest(manifest):
    return validate_support(manifest.get('canonicalFormats', LEGACY))


def validate_requirement(value):
    if (not isinstance(value, dict) or set(value) != {'profile', 'storeID', 'minimumReaderLevel', 'recordFormats', 'capabilities'}
            or value['profile'] != MARKER_PROFILE or type(value['minimumReaderLevel']) is not int
            or not 1 <= value['minimumReaderLevel'] <= 1024 or not integers(value['recordFormats'])
            or max(value['recordFormats']) > value['minimumReaderLevel'] or not capabilities(value['capabilities'])):
        raise RuntimeError('Unknown canonical reader requirement; leave services stopped.')
    identity = uuid.UUID(value['storeID'])
    if identity.version != 1 or str(identity) != value['storeID']:
        raise RuntimeError('Invalid canonical reader StoreID.')
    return value


def load_requirement(store):
    store = Path(store)
    root = store.lstat()
    if not stat.S_ISDIR(root.st_mode) or root.st_mode & 0o077:
        raise RuntimeError('Canonical store root is not private.')
    marker = validate_requirement(bounded_json(store / MARKER_NAME, 16 * 1024, root.st_uid))
    identity = bounded_json(store / '.tractanda-store-identity.json', 4096, root.st_uid)
    if identity.get('formatVersion') != 1 or marker['storeID'] != identity.get('storeID'):
        raise RuntimeError('Canonical reader requirement belongs to another store.')
    return marker


def require_reader(reader, requirement, writer=None):
    validate_support(reader)
    validate_requirement(requirement)
    if (reader['readerLevel'] < requirement['minimumReaderLevel']
            or not set(requirement['recordFormats']) <= set(reader['read'])
            or not set(requirement['capabilities']) <= set(reader['capabilities'])):
        raise RuntimeError('Canonical data needs a newer reader. Services must remain stopped; keep live data and backups intact.')
    if writer is not None:
        validate_support(writer)
        if (reader['readerLevel'] < writer['writerLevel'] or not set(writer['write']) <= set(reader['read'])
                or not set(writer['writeCapabilities']) <= set(reader['capabilities'])):
            raise RuntimeError('Shared reader cannot cover the registered writer future publications.')


def require_monotonic(previous, current):
    validate_requirement(previous)
    validate_requirement(current)
    if (current['storeID'] != previous['storeID'] or current['minimumReaderLevel'] < previous['minimumReaderLevel']
            or not set(previous['recordFormats']) <= set(current['recordFormats'])
            or not set(previous['capabilities']) <= set(current['capabilities'])):
        raise RuntimeError('Canonical reader requirement changed identity or moved backward.')


def require_owned_reader(client, store, expected_manifest=None):
    client = Path(client)
    manifest_path = client.parent.parent / 'bundle-manifest.json'
    encoded_manifest = bounded_bytes(manifest_path, 4 * 1024 * 1024)
    manifest = json.loads(encoded_manifest)
    if expected_manifest is None or hashlib.sha256(encoded_manifest).hexdigest() != expected_manifest:
        raise RuntimeError('Owned reader manifest binding is missing or changed.')
    entry = next((v for v in manifest['files'] if v['path'] == 'bin/tractanda'), None)
    if entry is None or digest_executable(client) != entry['sha256']:
        raise RuntimeError('Owned reader executable differs from its declaration.')
    require_reader(support_from_manifest(manifest), load_requirement(store))
