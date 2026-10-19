"""Exact isolated-checkout Linux Docling patch; never update an upstream pin."""
import hashlib
import json
import stat
import subprocess
from pathlib import Path


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def apply(checkout, base_apply):
    checkout = Path(checkout).resolve()
    root = Path(__file__).resolve().parent
    manifest = json.loads((root / 'linux-portability.json').read_text())
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=checkout, text=True).strip()
    if revision != manifest['runtimeBaseRevision']:
        raise RuntimeError('Unsupported runtime revision')
    patch = root / manifest['patchFile']
    if digest(patch) != manifest['patchSHA256']:
        raise RuntimeError('Linux portability patch artifact changed')
    entries = manifest['files']
    for entry in entries:
        path = Path(entry['sourcePath'])
        if path.is_absolute() or '..' in path.parts or '.' in path.parts:
            raise RuntimeError('Unsafe patch source path')
        source = checkout / path
        if source.is_symlink() or not source.resolve().is_relative_to(checkout):
            raise RuntimeError('Symbolic/escaping runtime source')
    actual = lambda entry: digest(checkout / entry['sourcePath']) if (checkout / entry['sourcePath']).exists() else None
    already = all(actual(entry) == entry['afterSHA256'] for entry in entries)
    if not already:
        # Preflight every other source before the known GELU helper may write.
        # The model source alone may start at the original pre-GELU revision.
        original = json.loads((root / 'manifest.json').read_text())
        gelu = original['patches'][0]
        for entry in entries:
            allowed = [entry['beforeSHA256']]
            if entry['sourcePath'] == gelu['sourcePath']:
                allowed.append(gelu['beforeSHA256'])
            if actual(entry) not in allowed:
                raise RuntimeError('Foreign or partially applied runtime source; refusing overwrite')
        base_apply(checkout)
        if not all(actual(entry) == entry['beforeSHA256'] for entry in entries):
            raise RuntimeError('Linux portability preimage differs after known GELU patch')
        subprocess.run(['git', 'apply', '--check', str(patch)], cwd=checkout, check=True)
        modes = {}
        try:
            for entry in entries:
                source = checkout / entry['sourcePath']
                if source.exists():
                    mode = stat.S_IMODE(source.stat().st_mode)
                    modes[source] = mode
                    source.chmod(mode | stat.S_IWUSR)
            subprocess.run(['git', 'apply', str(patch)], cwd=checkout, check=True)
        finally:
            for source, mode in modes.items():
                source.chmod(mode)
    if not all(actual(entry) == entry['afterSHA256'] for entry in entries):
        raise RuntimeError('Linux portability postimage differs')
    model = (checkout / gelu['sourcePath']).read_text() if not already else (
        checkout / 'Libraries/MLXVLM/Models/Idefics3.swift').read_text()
    region = model[model.index('// MARK: - Configuration'):model.index('// MARK: - Processor Configuration')].encode()
    if hashlib.sha256(region).hexdigest() != manifest['protectedIdeficsRegionSHA256']:
        raise RuntimeError('Protected Idefics3 configuration/model arithmetic changed')
    return {
        'runtimeBaseRevision': revision,
        'converterIdentity': None,  # Assigned only by reviewed native closure admission.
        'linuxPortability': {
            'identifier': manifest['identifier'],
            'status': 'already-applied' if already else 'applied',
            'manifestSHA256': digest(root / 'linux-portability.json'),
            'patchSHA256': digest(patch),
            'sources': [{'path': e['sourcePath'], 'sha256': actual(e)} for e in entries],
        },
    }
