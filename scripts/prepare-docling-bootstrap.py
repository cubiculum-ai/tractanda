#!/usr/bin/env python3
"""Prepare a receipt-bound, isolated Docling bootstrap source; never admit its helper."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path

if not __debug__:
    raise RuntimeError('Bootstrap verification requires Python assertions enabled.')
ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


C = load('bootstrap_compiler', ROOT / 'scripts/build-linux-ml-component.py')
P, B = C.P, C.B
G = load('bootstrap_binding', ROOT / 'scripts/generate-linux-docling-binding.py')
N = G.N
SENTINEL = '0' * 64
SOURCE_ROOTS = tuple(dict.fromkeys((*C.SOURCE_ROOTS, *N.SOURCE_ROOTS)))


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validated_registry(path):
    value = B.read_json(path)
    require(isinstance(value, dict) and set(value) == {'profile', 'runtimeRevision', 'baselines'}
            and value['profile'] == 'tractanda.linux-runtime-inputs.v2' and value['runtimeRevision'] == P.RUNTIME
            and isinstance(value['baselines'], dict) and set(value['baselines']) == set(B.GLIBC_LIMITS),
            'Invalid runtime registry schema.')
    for architectures in value['baselines'].values():
        require(isinstance(architectures, dict) and set(architectures) == set(B.ARCH), 'Invalid registry architecture set.')
        for entries in architectures.values():
            require(isinstance(entries, dict) and set(entries) == set(P.COMPONENTS)
                    and all(v is None or P.hash_string(v) for v in entries.values()), 'Invalid registry cells.')
    return value


def normalized_execution(source):
    result = P.execution_source(source, 'documents')
    for row in result['files']:
        if row['path'] in (N.CLIENT, N.CONVERTER):
            data, _ = N.normalize(row['path'], (source / row['path']).read_bytes())
            row['sha256'] = hashlib.sha256(data).hexdigest()
            row['size'] = len(data)
    return result['files']


def prepare(source, output, report, arch, expected_source, expected_registry, expected_cell, expected_slot):
    require(not source.is_symlink(), 'Source root must be a real directory.')
    source = source.resolve(strict=True)
    output = output.parent.resolve(strict=True) / output.name
    report = report.parent.resolve(strict=True) / report.name
    require(arch in B.ARCH and P.hash_string(expected_source) and P.hash_string(expected_registry), 'Invalid expected inputs.')
    require(expected_cell is None or P.hash_string(expected_cell), 'Invalid expected registry cell.')
    require(expected_slot is None or (P.hash_string(expected_slot) and expected_slot != SENTINEL), 'Invalid expected slot.')
    require((expected_cell is None) == (expected_slot is None), 'Registry and slot must both be empty or both populated.')
    for path in (output, report):
        require(not path.exists() and not path.is_symlink() and not path.is_relative_to(source), 'Output and report must be fresh and outside source.')
    require(not output.is_relative_to(report) and not report.is_relative_to(output), 'Output and report overlap.')
    original = P.rows(source, roots=SOURCE_ROOTS, skip=P.SKIP)
    require(P.sha(B.canonical(original)) == expected_source, 'Source manifest differs from reviewed input.')
    for relative in ('scripts/prepare-docling-bootstrap.py', 'scripts/build-linux-ml-component.py',
                     'scripts/produce-linux-payload.py', 'scripts/package-linux.py', 'scripts/package-macos.py',
                     'scripts/generate-linux-docling-binding.py', 'scripts/linux-docling-provenance.py'):
        require(B.digest(source / relative) == B.digest(ROOT / relative),
                'Executing verifier differs from reviewed source: ' + relative)
    registry_path = source / N.REGISTRY
    require(B.digest(registry_path) == expected_registry, 'Registry differs from reviewed input.')
    registry = validated_registry(registry_path)
    require(registry['baselines']['kali-rolling'][arch]['documents'] == expected_cell, 'Selected registry cell differs.')
    normalized, actual = N.normalized_rows(P, C, source, G.TEMPLATES)
    label = 'kali-' + arch
    require(actual[N.CLIENT]['digests'][label] == expected_slot, 'Selected source slot differs.')
    execution = normalized_execution(source)
    output.mkdir(mode=0o700)
    P.merge_files(source, output, original, P.SOURCE_LIMIT)
    name = 'kaliAMD64' if arch == 'amd64' else 'kaliARM64'
    before = 'nil' if expected_slot is None else '"' + expected_slot + '"'
    old = ('static let ' + name + ': String? = ' + before).encode()
    new = ('static let ' + name + ': String? = "' + SENTINEL + '"').encode()
    for relative in (N.CLIENT, N.CONVERTER):
        path = output / relative
        data = path.read_bytes()
        require(data.count(old) == 1, 'Expected generated slot was not unique.')
        path.write_bytes(data.replace(old, new, 1))
    after = P.rows(output, roots=SOURCE_ROOTS, skip=P.SKIP)
    first = {r['path']: r for r in original}
    second = {r['path']: r for r in after}
    changed = sorted(k for k in set(first) | set(second) if first.get(k) != second.get(k))
    require(changed == sorted([N.CLIENT, N.CONVERTER]), 'Unexpected staged source mutation.')
    new_normalized, staged = N.normalized_rows(P, C, output, G.TEMPLATES)
    require(normalized == new_normalized and execution == normalized_execution(output), 'Normalized source or execution closure changed.')
    require(staged[N.CLIENT]['digests'] == {**actual[N.CLIENT]['digests'], label: SENTINEL}, 'Other generated slot changed.')
    require(P.rows(source, roots=SOURCE_ROOTS, skip=P.SKIP) == original and B.digest(registry_path) == expected_registry,
            'Original source changed during staging.')
    report.mkdir(mode=0o700)
    result = {'status': 'PRIVATE_BOOTSTRAP_SOURCE_NOT_ADMITTED', 'architecture': arch,
              'sourceManifestSHA256': expected_source, 'registrySHA256': expected_registry,
              'selectedRegistryCell': expected_cell, 'previousSlot': expected_slot, 'bootstrapSlot': SENTINEL,
              'otherSlots': {k: v for k, v in actual[N.CLIENT]['digests'].items() if k != label},
              'changedPaths': changed, 'sourceRows': original, 'stagedRows': after,
              'normalizedSourceSHA256': P.sha(B.canonical(normalized)),
              'normalizedExecutionSourceSHA256': P.sha(B.canonical(execution)),
              'registryModified': False, 'runtimeAdmission': False, 'modelExecution': False}
    P.write_json(report / 'RESULT.json', result)
    return result


def main():
    a = argparse.ArgumentParser(description=__doc__)
    for flag in ('source', 'output', 'report'):
        a.add_argument('--' + flag, type=Path, required=True)
    a.add_argument('--arch', choices=tuple(B.ARCH), required=True)
    for flag in ('expected-source', 'expected-registry', 'expected-cell', 'expected-slot'):
        a.add_argument('--' + flag, required=True)
    args = a.parse_args()
    optional = lambda value: None if value == 'none' else value
    print(json.dumps(prepare(args.source, args.output, args.report, args.arch, args.expected_source,
                             args.expected_registry, optional(args.expected_cell), optional(args.expected_slot)), indent=2))


if __name__ == '__main__':
    os.umask(0o077)
    main()
