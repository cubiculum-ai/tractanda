#!/usr/bin/env python3
"""Audit tracked/candidate source files without printing potential secret values."""
import argparse, hashlib, json, re, subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ALLOWED_ROOT = {'install.sh', '.gitignore', '.gitattributes', '.swift-format', 'Package.swift', 'Package.resolved',
                'README.md', 'LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES.md', 'CONTRIBUTING.md',
                'SECURITY.md', 'CHANGELOG.md', 'RELEASING.md', 'VERSION'}
ALLOWED_DIRS = {'Sources', 'Tests', 'Packages', 'scripts', 'templates', 'examples', 'containers',
                'docs', '.github', 'LICENSES', 'plugins'}
PUBLIC_CATALOGS = {'.agents/plugins/marketplace.json', '.claude-plugin/marketplace.json'}
PUBLIC_SKILL_REFERENCES = {'plugins/tractanda/skills/tractanda/references/connection.md'}
PRIVATE_DIRS = {'work', 'outputs', 'output', 'references', 'tmp', 'data', 'domain-research',
                '.build', '.swiftpm', '.agents', '.codex', '__pycache__', 'node_modules'}
SECRET = re.compile(r'-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----|github_pat_[A-Za-z0-9_]{30,}|gh[pousr]_[A-Za-z0-9]{30,}|\bAKIA[A-Z0-9]{16}\b|\bsk-[A-Za-z0-9_-]{32,}')
PERSONAL = re.compile(r'/Users/(?!Shared(?:/|\b)|USER(?:/|\b)|example(?:/|\b)|<)[A-Za-z0-9_.-]+/|iCloud~com~apple')


def git_paths(*args):
    result = subprocess.run(['git', *args, '-z'], cwd=ROOT, check=True, capture_output=True)
    return [p.decode() for p in result.stdout.split(b'\0') if p]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--staged', action='store_true', help='Inspect exact index contents, excluding working-tree changes')
    p.add_argument('--output', type=Path)
    args = p.parse_args()
    names = set(git_paths('ls-files', '--cached'))
    staged = {}
    if args.staged:
        for entry in git_paths('ls-files', '--stage'):
            metadata, name = entry.split('\t', 1)
            mode, object_id, stage = metadata.split()
            if stage != '0':
                p.error('Resolve merge conflicts before auditing a release.')
            staged[name] = (mode, object_id)
    if not args.staged:
        names.update(git_paths('ls-files', '--others', '--exclude-standard'))
    findings, manifest = [], []
    if not names:
        findings.append({'path': '.', 'rule': 'empty release file set'})
    for name in sorted(names):
        path = ROOT / name
        parts = Path(name).parts
        if not args.staged and not path.exists():
            findings.append({'path': name, 'rule': 'missing tracked file'})
            continue
        if (args.staged and staged[name][0] not in {'100644', '100755'}) or (not args.staged and path.is_symlink()):
            findings.append({'path': name, 'rule': 'symlink requires explicit review'})
            continue
        if parts[0] not in ALLOWED_DIRS and name not in ALLOWED_ROOT and name not in PUBLIC_CATALOGS:
            findings.append({'path': name, 'rule': 'unexpected release path'})
        if any(part in PRIVATE_DIRS for part in parts) and name not in PUBLIC_CATALOGS | PUBLIC_SKILL_REFERENCES:
            findings.append({'path': name, 'rule': 'private/development directory'})
        if any('lotus' in part.lower() for part in parts) or path.suffix.lower() in {'.pdf', '.epub', '.emlx', '.tractanda', '.sqlite', '.sqlite3', '.pem', '.key', '.p12', '.pfx', '.safetensors', '.gguf'}:
            findings.append({'path': name, 'rule': 'excluded reference/runtime/secret format'})
        data = (subprocess.run(['git', 'cat-file', 'blob', staged[name][1]], cwd=ROOT,
                               check=True, capture_output=True).stdout
                if args.staged else path.read_bytes())
        manifest.append({'path': name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
        if len(data) > 2_000_000:
            findings.append({'path': name, 'rule': 'large source file requires review'})
        try:
            text = data.decode('utf-8')
        except UnicodeDecodeError:
            findings.append({'path': name, 'rule': 'binary file requires explicit review'})
            continue
        for line, content in enumerate(text.splitlines(), 1):
            if SECRET.search(content): findings.append({'path': name, 'line': line, 'rule': 'possible credential'})
            if PERSONAL.search(content) and not (name == 'scripts/audit-release.py' and content.startswith('PERSONAL = ')): findings.append({'path': name, 'line': line, 'rule': 'personal filesystem path'})
            if (name == 'README.md' or name.startswith('docs/') or name.endswith('Manual.html')) and re.search(r'\bLotus\b|\bAgenda\b', content, re.I):
                findings.append({'path': name, 'line': line, 'rule': 'excluded public-description reference'})
    result = {'status': 'passed' if not findings else 'reviewRequired', 'files': len(manifest),
              'bytes': sum(p['bytes'] for p in manifest), 'findings': findings, 'manifest': manifest}
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'manifest'}, indent=2))
    raise SystemExit(0 if not findings else 1)


if __name__ == '__main__':
    main()
