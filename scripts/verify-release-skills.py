#!/usr/bin/env python3
"""Validate release-aligned marketplace skills and their packaged references."""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def verify(root=ROOT, bundle=None):
    root = Path(root)
    version = (root / 'VERSION').read_text().strip()
    assert re.fullmatch(r'\d+\.\d+\.\d+-poc\.\d+(?:\.\d+)?', version), 'Invalid release version'
    for name in ('codex', 'claude'):
        manifest = json.loads((root / f'plugins/tractanda/.{name}-plugin/plugin.json').read_text())
        assert manifest['name'] == 'tractanda' and manifest['version'] == version, 'Plugin version differs'
        assert manifest['skills'] == './skills/', 'Plugin skill path differs'
    for name in ('.claude-plugin/marketplace.json', '.agents/plugins/marketplace.json'):
        manifest = json.loads((root / name).read_text())
        rows = [r for r in manifest['plugins'] if r['name'] == 'tractanda']
        assert len(rows) == 1, 'Marketplace Tractanda identity is ambiguous'
        row = rows[0]
        if name.startswith('.claude'): assert row['version'] == version, 'Marketplace version differs'
        source = row['source']
        assert (source if isinstance(source, str) else source['path']) == './plugins/tractanda', 'Marketplace source path differs'
    skill = root / 'plugins/tractanda/skills/tractanda'
    text = (skill / 'SKILL.md').read_text()
    assert text.startswith('---\n') and re.search(r'^name: tractanda$', text, re.M), 'Invalid skill metadata'
    assert '/Users/Shared/Library/' not in '\n'.join(p.read_text() for p in skill.rglob('*.md')), 'Obsolete installed path in skill'
    for path in skill.rglob('*.md'):
        for target in re.findall(r'\]\(([^)]+)\)', path.read_text()):
            if re.match(r'[a-zA-Z][a-zA-Z0-9+.-]*:', target) or target.startswith('#'): continue
            assert (path.parent / target.split('#')[0]).resolve().is_file(), f'Missing skill reference in {path.name}'
    files = sorted(p for p in (root / 'plugins/tractanda').rglob('*') if p.is_file())
    for path in files:
        if bundle:
            target = Path(bundle) / path.relative_to(root)
            assert target.is_file() and target.read_bytes() == path.read_bytes(), 'Packaged skill differs from sealed source'
    return {'version': version, 'files': [{'path': p.relative_to(root).as_posix(),
            'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in files]}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(bundle=args.bundle), indent=2))
