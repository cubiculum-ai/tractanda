#!/usr/bin/env python3
"""Build and verify a signed, bounded APT repository from admitted release packages.

The signing key stays in the caller's private GNUPGHOME or existing GPG agent.
Only the exported public key, signed metadata and package bytes enter the site.
"""
import argparse
from datetime import datetime, timedelta, timezone
import email.utils
import hashlib
import io
import json
import lzma
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import tarfile

ARCHES = ('amd64', 'arm64')
SITE_LIMIT = 950 * 1024**2  # Includes manual, signatures and metadata below Pages' 1 GB cap.


def run(args, **kwargs):
    return subprocess.check_output(list(map(str, args)), **kwargs)


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def require(value, message):
    if not value:
        raise ValueError(message)


def paragraphs(raw):
    result = []
    for block in raw.strip().split('\n\n'):
        row = {}
        for line in block.splitlines():
            if line.startswith((' ', '\t')):
                require(bool(row), 'Malformed continuation')
                row[next(reversed(row))] += '\n' + line
            else:
                key, value = line.split(':', 1)
                require(key not in row, 'Duplicate control field')
                row[key] = value.strip()
        result.append(row)
    return result


def safe_relative(name):
    path = Path(name)
    require(not path.is_absolute() and '..' not in path.parts and '\\' not in name
            and bool(re.fullmatch(r'[A-Za-z0-9._~+/-]+', name)), 'Unsafe repository path')
    return path


def package(path):
    path = Path(path).resolve(strict=True)
    require(path.is_file() and not path.is_symlink(), 'Regular Debian package required')
    # Debian's ar envelope and xz/gzip control archives are portable on macOS too.
    # Do not decompress the potentially large data archive just to read metadata.
    control = None
    with path.open('rb') as stream:
        require(stream.read(8) == b'!<arch>\n', 'Invalid Debian ar envelope')
        while header := stream.read(60):
            require(len(header) == 60 and header[58:] == b'`\n', 'Invalid ar member')
            name, size = header[:16].decode().strip().rstrip('/'), int(header[48:58])
            require(0 <= size < 2**31, 'Unbounded ar member')
            if name.startswith('control.tar'):
                require(size <= 4 * 1024**2, 'Unbounded Debian control archive')
                raw = stream.read(size)
                with tarfile.open(fileobj=io.BytesIO(raw), mode='r:*') as archive:
                    entries = [m for m in archive.getmembers() if m.name.lstrip('./') == 'control']
                    require(len(entries) == 1 and entries[0].isfile() and entries[0].size < 1024**2,
                            'Invalid Debian control member')
                    control = archive.extractfile(entries[0]).read().decode()
                break
            stream.seek(size + size % 2, 1)
    require(control is not None, 'Missing Debian control archive')
    fields = paragraphs(control)[0]
    require(fields.get('Package') == 'tractanda' and fields.get('Architecture') in ARCHES,
            'Only Tractanda amd64/arm64 packages are admitted')
    require(re.fullmatch(r'[0-9][A-Za-z0-9.+~:-]*', fields.get('Version', '')), 'Invalid Debian version')
    name = f"tractanda_{fields['Version'].replace(':', '%3a')}_{fields['Architecture']}.deb"
    require('%' not in name, 'Epoch versions require an explicit repository naming policy')
    return path, fields, 'pool/main/t/tractanda/' + name


def build(output, packages, fingerprint, gpg='gpg', previous=(), limit=SITE_LIMIT):
    require(re.fullmatch(r'[A-Fa-f0-9]{40,64}', fingerprint), 'Full signing-key fingerprint required')
    output = Path(output)
    require(not output.exists(), 'Build into a new directory; publish as one complete site')
    current = [package(p) for p in packages]
    require(len(current) == 2 and {r[1]['Architecture'] for r in current} == set(ARCHES)
            and len({r[1]['Version'] for r in current}) == 1, 'One current version, both architectures required')
    rows = current
    retained = False
    if previous:
        old = [package(p) for p in previous]
        require(len(old) == 2 and {r[1]['Architecture'] for r in old} == set(ARCHES)
                and len({r[1]['Version'] for r in old}) == 1
                and old[0][1]['Version'] != current[0][1]['Version'], 'One previous version, both architectures required')
        if sum(r[0].stat().st_size for r in current + old) + 8 * 1024**2 < limit:
            rows += old
            retained = True
    require(sum(r[0].stat().st_size for r in rows) + 8 * 1024**2 < limit, 'Current packages exceed bounded site capacity')
    output.mkdir(parents=True)
    key = run([gpg, '--batch', '--armor', '--export', fingerprint])
    require(b'BEGIN PGP PUBLIC KEY BLOCK' in key, 'Signing public key unavailable')
    (output / 'tractanda-archive-keyring.asc').write_bytes(key)
    for source, fields, name in rows:
        target = output / safe_relative(name)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        require(sha(target) == sha(source), 'Package changed during copy')
    dist = output / 'dists/preview'
    metadata = []
    for arch in ARCHES:
        directory = dist / f'main/binary-{arch}'
        directory.mkdir(parents=True)
        blocks = []
        for source, fields, name in rows:
            if fields['Architecture'] != arch:
                continue
            fields = {k: v for k, v in fields.items() if k not in ('Filename', 'Size', 'SHA256', 'MD5sum', 'SHA1')}
            fields.update(Filename=name, Size=str(source.stat().st_size), SHA256=sha(source))
            blocks.append(''.join(f'{k}: {v}\n' for k, v in fields.items()))
        raw = ('\n'.join(blocks) + '\n').encode()
        (directory / 'Packages').write_bytes(raw)
        (directory / 'Packages.xz').write_bytes(lzma.compress(raw))
        for path in (directory / 'Packages', directory / 'Packages.xz'):
            hashed = directory / 'by-hash/SHA256' / sha(path)
            hashed.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, hashed)
            metadata.append(path)
    stamp = datetime.now(timezone.utc)
    release = ('Origin: Tractanda\nLabel: Tractanda preview\nSuite: preview\nCodename: preview\n'
               'Architectures: amd64 arm64\nComponents: main\nAcquire-By-Hash: yes\n'
               'Description: Signed Tractanda preview packages\n'
               f'Date: {email.utils.format_datetime(stamp, usegmt=True)}\n'
               f'Valid-Until: {email.utils.format_datetime(stamp + timedelta(days=90), usegmt=True)}\nSHA256:\n')
    release += ''.join(f' {sha(p)} {p.stat().st_size:16d} {p.relative_to(dist).as_posix()}\n' for p in metadata)
    (dist / 'Release').write_text(release)
    for mode, destination in (('--clearsign', 'InRelease'), ('--detach-sign', 'Release.gpg')):
        run([gpg, '--batch', '--yes', '--local-user', fingerprint, '--digest-algo', 'SHA256',
             '--output', dist / destination, mode, dist / 'Release'])
    receipt = verify(output, output / 'tractanda-archive-keyring.asc', fingerprint, gpg=gpg)
    receipt.update(retainedPrevious=retained, bytes=sum(p.stat().st_size for p in output.rglob('*') if p.is_file()))
    require(receipt['bytes'] < limit, 'Complete site exceeds capacity')
    (output / 'repository.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return receipt


def verify(root, public_key, fingerprint, gpg='gpg'):
    root = Path(root)
    require(re.fullmatch(r'[A-Fa-f0-9]{40,64}', fingerprint), 'Full trusted fingerprint required')
    with tempfile.TemporaryDirectory(prefix='trac-apt-v-', dir='/tmp') as temporary:
        os.chmod(temporary, 0o700)
        base = [gpg, '--batch', '--homedir', temporary]
        run([*base, '--import', public_key], stderr=subprocess.PIPE)
        keys = run([*base, '--with-colons', '--fingerprint']).decode()
        require(f':{fingerprint.upper()}:' in keys, 'Trusted public-key fingerprint differs')
        status = run([*base, '--status-fd', '1', '--verify', root / 'dists/preview/Release.gpg',
                      root / 'dists/preview/Release'], stderr=subprocess.PIPE).decode()
        require('VALIDSIG ' + fingerprint.upper() + ' ' in status, 'Release signature does not match trusted key')
        clear = run([*base, '--decrypt', root / 'dists/preview/InRelease'], stderr=subprocess.PIPE)
        require(clear == (root / 'dists/preview/Release').read_bytes(), 'Inline/detached Release content differs')
    release = paragraphs((root / 'dists/preview/Release').read_text())[0]
    require(release.get('Architectures') == 'amd64 arm64' and release.get('Acquire-By-Hash') == 'yes', 'Release architecture/by-hash contract differs')
    require(email.utils.parsedate_to_datetime(release['Valid-Until']) > datetime.now(timezone.utc), 'Expired repository metadata')
    dist = root / 'dists/preview'
    signed_paths = set()
    for line in release['SHA256'].splitlines():
        if not line.strip(): continue
        digest, size, relative = line.split()
        require(relative not in signed_paths, 'Duplicate signed index')
        signed_paths.add(relative)
        path = dist / safe_relative(relative)
        require(path.stat().st_size == int(size) and sha(path) == digest, 'Signed index size/hash differs')
        require(sha(path.parent / 'by-hash/SHA256' / digest) == digest, 'Missing/inconsistent by-hash index')
    require(signed_paths == {f'main/binary-{a}/Packages{s}' for a in ARCHES for s in ('', '.xz')},
            'Signed Release must bind every published architecture index')
    found = []
    for arch in ARCHES:
        directory = dist / f'main/binary-{arch}'
        raw = (directory / 'Packages').read_bytes()
        require(lzma.decompress((directory / 'Packages.xz').read_bytes()) == raw, 'Compressed index differs')
        for row in paragraphs(raw.decode()):
            require(row['Package'] == 'tractanda' and row['Architecture'] == arch, 'Package architecture differs')
            path = root / safe_relative(row['Filename'])
            require(row['Filename'].startswith('pool/main/t/tractanda/'), 'Package outside repository pool')
            require(path.stat().st_size == int(row['Size']) and sha(path) == row['SHA256'], 'Package size/hash differs')
            found.append({k: row[k] for k in ('Architecture', 'Version', 'Filename', 'SHA256')})
    require({r['Architecture'] for r in found} == set(ARCHES) and len(found) <= 4, 'Bounded multiarch inventory required')
    require(len({(r['Architecture'], r['Version']) for r in found}) == len(found), 'Duplicate indexed package version')
    return {'profile': 'tractanda.apt-repository.v1', 'fingerprint': fingerprint.upper(), 'packages': found}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('build', 'verify'))
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--fingerprint', required=True)
    parser.add_argument('--gpg', default='gpg')
    parser.add_argument('--package', action='append', default=[])
    parser.add_argument('--previous-package', action='append', default=[])
    parser.add_argument('--public-key', type=Path)
    args = parser.parse_args()
    result = (build(args.root, args.package, args.fingerprint, args.gpg, args.previous_package)
              if args.action == 'build' else verify(args.root, args.public_key or args.root / 'tractanda-archive-keyring.asc', args.fingerprint, args.gpg))
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
