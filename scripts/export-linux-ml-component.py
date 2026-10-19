#!/usr/bin/env python3
"""Project verified native component artifacts into the existing D4 contract.

This is an offline export recipe, not the compiler recipe that built its inputs.
It never admits a manifest, rewrites a library, executes a helper or copies models.
The fixed D4 registry must already approve the exact normalized wrapper bytes.
"""
import argparse
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTER_DOCLING = {
    'licenses/Docling/Granite-Docling-LICENSE': 'Packages/TractandaDocuments/ThirdPartyNotices/Granite-Docling-LICENSE',
    'licenses/Docling/Granite-Docling-MODEL-NOTICE.md': 'Packages/TractandaDocuments/ThirdPartyNotices/Granite-Docling-MODEL-NOTICE.md',
    'licenses/Docling/Pillow-LICENSE': 'Packages/TractandaDocuments/ThirdPartyNotices/Pillow-LICENSE',
    'licenses/Docling/ModelAssets.json': 'Packages/TractandaDocuments/Sources/TractandaDocumentConverter/Resources/ModelAssets.json',
    'licenses/Docling/runtime-patches.json': 'Packages/TractandaDocuments/RuntimePatches/manifest.json',
    'licenses/Docling/vmlx-61a4b20-idefics3-gelu-f32.patch': 'Packages/TractandaDocuments/RuntimePatches/vmlx-61a4b20-idefics3-gelu-f32.patch',
}


def producer(root):
    spec = importlib.util.spec_from_file_location('supplier_producer', root / 'scripts/produce-linux-payload.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def projection(P, value, source, role, arch, expected):
    """Validate the entire immutable source tree and exact six-file projection."""
    B = P.B
    if P.sha(B.canonical(value)) != expected or value.get('component') != role or value.get('arch') != arch:
        raise ValueError('Supplier wrapper differs from its fixed reviewed registry commitment.')
    declared = [P.file_entry(row) for row in value['files']]
    if declared != sorted(declared, key=lambda row: row['path']) or len({r['path'] for r in declared}) != len(declared):
        raise ValueError('Supplier inventory must be sorted and unique.')
    actual = P.rows(source, maximum=8 * 1024**3)
    outer = OUTER_DOCLING if role == 'documents' else {}
    names = {row['path']: row for row in declared}
    if not set(outer) <= names.keys():
        raise ValueError('Supplier wrapper omits an outer Docling notice/model/patch commitment.')
    # Artifact bytes and modes remain unchanged. Only absent outer text files
    # are projected; if already present they must match the exact declaration.
    sources = {row['path']: source / row['path'] for row in actual}
    for relative, tracked in outer.items():
        if relative not in sources:
            sources[relative] = P.ROOT / tracked
    if set(sources) != names.keys():
        raise ValueError('Supplier tree contains missing or undeclared artifacts.')
    by_actual = {row['path']: row for row in actual}
    for relative, path in sources.items():
        row = names[relative]
        if relative in by_actual:
            if by_actual[relative] != row:
                raise ValueError('Supplier artifact changed: ' + relative)
        else:
            captured = P.rows(P.ROOT, roots=[outer[relative]], maximum=8 * 1024**2)
            if len(captured) != 1 or {**captured[0], 'path': relative} != row:
                raise ValueError('Tracked outer projection differs from its reviewed bytes/mode: ' + relative)
    return actual, [(sources[row['path']], row) for row in declared]


def export(P, manifest, source, output, role, arch, expected, maximum):
    value = P.B.read_json(manifest, 16 * 1024**2)
    before, selected = projection(P, value, source, role, arch, expected)
    if output.exists() or output.is_symlink() or not output.parent.is_dir() or output.parent.is_symlink():
        raise ValueError('Exporter requires a fresh output under a real existing parent.')
    if source.resolve() == output.resolve() or output.resolve().is_relative_to(source.resolve()):
        raise ValueError('Supplier output must be separate from immutable input.')
    estimate = sum(row['size'] for _, row in selected) + len(selected) * 8192 + 1024**2
    P.B.capacity(output.parent, estimate, maximum)
    output.mkdir(mode=0o755)
    # An interrupted export remains a partial tree, never a success manifest.
    for path, row in selected:
        P.B.owned_storage(output, maximum, row['size'] + 8192)
        P.B.copy_verified(path, output / row['path'], row, maximum)
    if P.rows(source, maximum=8 * 1024**3) != before:
        raise ValueError('Supplier source changed during export.')
    # Reuse D4's complete wrapper/recipe/toolchain/runtime/notices validation;
    # successful export grants no production admission on its own.
    result = P.component(manifest, output, role, arch, expected)
    P.B.owned_storage(output, maximum)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--arch', required=True, choices=('amd64', 'arm64'))
    parser.add_argument('--component', required=True, choices=('documents', 'embeddings'))
    parser.add_argument('--manifest', required=True, type=Path)
    parser.add_argument('--component-root', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    P = producer(ROOT)
    approved = P.require_admitted(args.arch)[args.component]
    export(P, args.manifest, args.component_root, args.output, args.component, args.arch, approved, 8 * 1024**3)


if __name__ == '__main__':
    main()
