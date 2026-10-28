#!/usr/bin/env python3
"""Assemble manual plus the latest signed APT release without committing packages."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('apt_repository', ROOT / 'scripts/apt-repository.py')
apt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(apt)


def assemble(output, repository, tag=None, public_key=None, trusted_fingerprint=None):
    apt.require(re.fullmatch(r'[\w.-]+/[\w.-]+', repository), 'Invalid repository identity')
    output = Path(output)
    apt.require(not output.exists(), 'Pages output must be new')
    output.mkdir(parents=True)
    for source, target in (('docs/index.html', 'index.html'), ('LICENSE', 'LICENSE'), ('NOTICE', 'NOTICE')):
        shutil.copyfile(ROOT / source, output / target)
    (output / '.nojekyll').touch()
    releases = json.loads(apt.run(['gh', 'api', f'repos/{repository}/releases?per_page=100']))
    releases = [r for r in releases if not r['draft']]
    if tag:
        releases = [r for r in releases if r['tag_name'] == tag]
        apt.require(len(releases) == 1, 'Requested published release absent')
    else:
        releases.sort(key=lambda r: r['published_at'], reverse=True)
    selected = next((r for r in releases if any(a['name'] == 'apt-site.tar.gz' for a in r['assets'])), None)
    if selected is None:
        apt.require(not tag, 'Published release lacks its signed APT site asset')
        return {'apt': None, 'manual': 'docs/index.html'}
    names = [a['name'] for a in selected['assets']]
    apt.require(len(names) == len(set(names)) and 'SHA256SUMS' in names, 'Ambiguous release assets')
    apt.require((public_key is None) == (trusted_fingerprint is None), 'Explicit previous public key and fingerprint are a pair')
    fingerprint = trusted_fingerprint or (ROOT / 'docs/apt/fingerprint.txt').read_text().strip()
    key = Path(public_key) if public_key else ROOT / 'docs/apt/tractanda-archive-keyring.asc'
    with tempfile.TemporaryDirectory(prefix='tractanda-pages-') as temporary:
        temporary = Path(temporary)
        apt.run(['gh', 'release', 'download', selected['tag_name'], '--repo', repository,
                 '--pattern', 'apt-site.tar.gz', '--pattern', 'SHA256SUMS', '--dir', temporary])
        sums = {}
        for line in (temporary / 'SHA256SUMS').read_text().splitlines():
            digest, name = line.split('  ', 1)
            apt.require(name not in sums and re.fullmatch('[a-f0-9]{64}', digest), 'Invalid release checksum inventory')
            sums[name] = digest
        archive = temporary / 'apt-site.tar.gz'
        apt.require(apt.sha(archive) == sums.get(archive.name), 'APT site release checksum differs')
        with tarfile.open(archive, 'r:gz') as stream:
            count, total = 0, 0
            for member in stream:
                count += 1; total += member.size
                apt.require(count <= 10000 and total < apt.SITE_LIMIT, 'APT archive exceeds bounded Pages budget')
                relative = apt.safe_relative(member.name)
                apt.require(relative.parts[0] == 'apt' and (member.isfile() or member.isdir()), 'Unsafe APT site archive member')
                target = output / relative
                if member.isdir(): target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with stream.extractfile(member) as source, target.open('xb') as destination:
                        shutil.copyfileobj(source, destination)
        verified = apt.verify(output / 'apt', key, fingerprint)
        apt.require((output / 'apt/tractanda-archive-keyring.asc').read_bytes() == key.read_bytes(), 'Site key differs from reviewed source key')
    apt.require(sum(p.stat().st_size for p in output.rglob('*') if p.is_file()) < apt.SITE_LIMIT, 'Manual plus APT exceed Pages budget')
    return {'release': selected['tag_name'], 'apt': verified, 'manual': 'docs/index.html'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('_site'))
    parser.add_argument('--repository', required=True)
    parser.add_argument('--tag')
    parser.add_argument('--public-key', type=Path, help='Explicit reviewed prior public key for a key-rotation preparation')
    parser.add_argument('--fingerprint', help='Full fingerprint paired with the explicit prior public key')
    args = parser.parse_args()
    print(json.dumps(assemble(args.output, args.repository, args.tag, args.public_key, args.fingerprint), indent=2))
