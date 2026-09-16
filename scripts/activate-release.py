#!/usr/bin/env python3
"""Upgrade one existing installation and verify immutable record preservation.

Invoked by release-macos.py through normal macOS administrator authentication.
No persistent privileged service or authorization exception is installed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import stat
import subprocess


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def canonical_manifest(store):
    result = {}
    for path in sorted((store / 'items').rglob('*')):
        if path.is_symlink():
            raise ValueError('Canonical-tree symbolic links require explicit review.')
        if path.is_file() and path.suffix == '.tractanda':
            result[path.relative_to(store).as_posix()] = digest(path)
    return result


def require_preserved(before, after):
    if any(after.get(path) != digest for path, digest in before.items()):
        raise RuntimeError('A pre-existing canonical file changed or disappeared during upgrade. Publication is stopped.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--software-root', type=Path, required=True)
    parser.add_argument('--instance', required=True)
    parser.add_argument('--manifest-sha256', required=True)
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
    store = Path(receipt['store'])
    before = canonical_manifest(store)
    subprocess.run([str(setup), 'upgrade', '--bundle', str(bundle), '--name', args.instance], check=True)
    after = canonical_manifest(store)
    require_preserved(before, after)
    updated = json.loads(receipt_path.read_text())
    for key in ('store', 'indexDirectory', 'owner', 'port', 'socket'):
        if updated[key] != receipt[key]:
            raise RuntimeError('Upgrade changed an existing installation property: ' + key)
    if updated['manifestSHA256'] != args.manifest_sha256 or updated['state'] != 'active':
        raise RuntimeError('Installation did not activate the prepared bundle.')
    print(json.dumps({'status': 'passed', 'preservedCanonicalFiles': len(before),
                      'canonicalFilesAfter': len(after), 'release': updated['release'],
                      'manifestSHA256': args.manifest_sha256}))


if __name__ == '__main__':
    main()
