#!/usr/bin/env python3
"""Prepare a reviewed, finite Linux Docling descriptor; never admit or install it.

The compiler inputs include both generated Swift files. Only their two
self-referential digest literals are normalized; the packaging registry is an
output index and is excluded by exact path. All other source rows are bound.
A new converter must match the reviewed dynamic closure, except for the
independently audited direct zlib edge on the finite amd64 supplier bundle.
Any other difference requires a fresh full closure audit.
"""
import argparse, hashlib, importlib.util, json, os, re, stat, subprocess
from pathlib import Path

if not __debug__:
    raise RuntimeError("Docling provenance validation must not run with Python optimization enabled.")

ROOT = Path(__file__).resolve().parents[1]
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module
C = load('component', ROOT / 'scripts/build-linux-ml-component.py'); P = C.P; B = C.B
N = load('normalization', ROOT / 'scripts/linux-docling-provenance.py')
TEMPLATES = {
    N.CLIENT: '215503da6ad1906f1423ef6c172a6f3e4a8f092a5d39250a411a93861826c927',
    N.CONVERTER: '7ecc1d125d9a1edb278436ec78ee611a074d803fc46bdc8e9e8919d97d98f5c2',
}
def digest(path):
    with path.open('rb') as f: return hashlib.file_digest(f, 'sha256').hexdigest()
def write(path, value):
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + '\n')
def required_versions(path):
    text = subprocess.check_output(['readelf', '--wide', '--version-info', str(path)], text=True)
    mode = None; current = None; needs = {}
    for line in text.splitlines():
        if line.startswith('Version needs section'): mode = 'needs'
        elif line.startswith('Version definition section') or line.startswith('Version symbols section'): mode = 'other'
        f = re.search(r'File:\s*(\S+)', line)
        if f: current = f.group(1)
        n = re.search(r'Name:\s*(\S+)', line)
        if n and mode == 'needs' and current: needs.setdefault(current, set()).add(n.group(1))
    return needs

def check_converter_elf(arch, facts, recorded, old_descriptor):
    # This single compiler-output delta was audited against the finite Debian supplier bundle;
    # it is not a general allowlist for new dependencies.
    needed = facts['needed']
    direct_zlib = (arch == 'amd64' and needed.count('libz.so.1') == 1
                   and [name for name in needed if name != 'libz.so.1'] == recorded['needed'])
    assert (needed == recorded['needed'] or direct_zlib) and facts['soname'] == recorded['soname'] and facts['searchPaths'] == recorded['runpath'], 'New converter requires fresh ELF closure audit'
    if direct_zlib:
        old_zlib = [x for x in old_descriptor['osDependencies'] if x['soname'] == 'libz.so.1']
        assert len(old_zlib) == 1 and old_zlib[0]['provider'] == 'zlib1g' and old_zlib[0]['version'] == '1:1.3.dfsg+really1.3.1-1+b1'
        zlib_path, zlib_provider = B.system_library('libz.so.1', arch)
        assert zlib_provider['package'] == old_zlib[0]['provider'] and zlib_provider['version'] == old_zlib[0]['version']
        assert digest(zlib_path) == '85590dd58edf5445e18bc7193e5ebc01ac5841f1ae187e97705a662e90c6421e'
    return needed, direct_zlib

def prepare(arch, component_root, manifest, converter, toolchain, output):
    assert arch in ('arm64', 'amd64') and not output.exists() and not output.is_symlink()
    assert component_root.is_dir() and converter.is_file() and not converter.is_symlink()
    expected = P.require_admitted(arch)['documents']
    component = P.component(manifest, component_root, 'documents', arch, expected)
    old_descriptor = B.read_json(component_root / 'lib/tractanda/document-native-closure.json')
    old_provenance = B.read_json(component_root / 'licenses/Docling/linux-build-provenance.json')
    assert digest(component_root / 'lib/tractanda/document-native-closure.json') == component['documentExtraction']['identity']['converter'].rsplit('.', 1)[-1]
    assert P.sha(B.canonical(old_provenance)) == component['sourceInputsSHA256']
    actual_toolchain = B.read_json(toolchain); assert actual_toolchain == component['toolchain']
    recorded = next(x for x in old_descriptor['privateDependencies'] if x['path'] == 'bin/tractanda-document-converter')
    facts = B.elf(converter, arch)
    needed, direct_zlib = check_converter_elf(arch, facts, recorded, old_descriptor)
    allowed = {x['soname']: set(x['requiredSymbolVersions']) for x in old_descriptor['osDependencies']}
    previous_needs = required_versions(component_root / 'bin/tractanda-document-converter')
    for soname, versions in required_versions(converter).items():
        limit = allowed.get(soname, previous_needs.get(soname, set()))
        assert versions <= limit, (soname, versions - limit)
    rows, generated = N.normalized_rows(P, C, ROOT, TEMPLATES)
    provenance = {
        'profile': 'tractanda.linux-docling-normalized-build.v1', 'architecture': arch,
        'sourceSelectionProfile': N.SELECTION_PROFILE, 'sourceSelectionRoots': list(N.SOURCE_ROOTS),
        'sourceFiles': rows, 'generatedDigestNormalizations': {
            N.CLIENT: 'Only amd64 and arm64 digest literals replaced by fixed 64-byte placeholders.',
            N.CONVERTER: 'Only x86_64 and arm64 digest literals replaced by fixed 64-byte placeholders.',
        }, 'excludedOutputIndex': N.EXCLUDED, 'normalizedTemplateSHA256': TEMPLATES,
        'toolchain': actual_toolchain, 'buildFlags': C.build_arguments('/usr/bin/swift', [], arch, 'tractanda-document-converter'),
        'runtimePatchSHA256': digest(ROOT / 'Packages/TractandaDocuments/RuntimePatches/vmlx-61a4b20-linux-docling.patch'),
        'componentRecipeSHA256': digest(ROOT / 'scripts/build-linux-ml-component.py'),
        'normalizationRecipeSHA256': digest(ROOT / 'scripts/linux-docling-provenance.py'),
        'descriptorRecipeSHA256': digest(Path(__file__).resolve()),
        'nativeSourceCommitmentsSHA256': old_provenance['nativeSourceCommitmentsSHA256'],
        'nativeRecipeSHA256': old_provenance['nativeRecipeSHA256'],
        'baselineNativeEvidence': {'descriptorSHA256': digest(component_root / 'lib/tractanda/document-native-closure.json'),
                                   'provenanceSHA256': digest(component_root / 'licenses/Docling/linux-build-provenance.json'),
                                   'componentManifestSHA256': expected},
        'modelAssetsSHA256': old_descriptor['modelAssetsSHA256'],
    }
    output.mkdir(mode=0o700); prov = output / 'linux-build-provenance.json'; write(prov, provenance)
    desc = dict(old_descriptor); desc['buildProvenanceSHA256'] = digest(prov); files = []
    if direct_zlib:
        desc['privateDependencies'] = [dict(row, needed=needed) if row['path'] == recorded['path'] else row
                                       for row in old_descriptor['privateDependencies']]
    for row in old_descriptor['files']:
        name = B.safe_path(row['path']); entry = dict(row)
        if name == 'licenses/Docling/linux-build-provenance.json': entry.update(sha256=digest(prov), size=prov.stat().st_size, mode=0o644)
        else:
            p = component_root / name; assert p.is_file() and not p.is_symlink() and p.stat().st_size == row['size'] and stat.S_IMODE(p.stat().st_mode) == row['mode'] and digest(p) == row['sha256'], name
        files.append(entry)
    desc['files'] = files; descriptor = output / 'document-native-closure.json'; write(descriptor, desc)
    result = {'status': 'DESCRIPTOR_PREPARED_NOT_RUNTIME_ADMITTED', 'architecture': arch,
              'descriptorSHA256': digest(descriptor), 'provenanceSHA256': digest(prov),
              'normalizedProvenanceSHA256': P.sha(B.canonical(provenance)), 'generatedActual': generated,
              'candidateConverterSHA256': digest(converter), 'baselineManifestSHA256': expected}
    write(output / 'result.json', result); return result

def main():
    a = argparse.ArgumentParser(); a.add_argument('--arch', required=True, choices=('amd64', 'arm64')); a.add_argument('--component-root', required=True, type=Path); a.add_argument('--manifest', required=True, type=Path); a.add_argument('--converter', required=True, type=Path); a.add_argument('--toolchain', required=True, type=Path); a.add_argument('--output', required=True, type=Path); x = a.parse_args(); print(json.dumps(prepare(x.arch, x.component_root, x.manifest, x.converter, x.toolchain, x.output), indent=2))
if __name__ == '__main__': main()
