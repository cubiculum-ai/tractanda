#!/usr/bin/env python3
"""Build a reviewable component from actual native Kali compiler and loader facts.

The isolated compiler, independently sourced runtime tree and behavior validation
are separate inputs. This recipe never updates the finite runtime slots or registry.
The v2 outer descriptor preserves the actual compiler execution-source binding;
old unbound compiler results require a new build, never receipt relabelling.
"""
import argparse
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


C = load('kali_component_compile', 'build-linux-ml-component.py')
G = load('kali_component_provenance', 'generate-linux-docling-binding.py')
P, B, N = C.P, C.B, G.N
BASELINE = B.PRIMARY_BUILD_OS
CAP = 8 * 1024**3
NATIVE = 'lib/tractanda/document-native/'
SUPPLIERS = {NATIVE + f'libtractanda_docling_{role}.so.1' for role in ('images', 'pdf')}
DESCRIPTOR = 'lib/tractanda/document-native-closure.json'
PROVENANCE = 'licenses/Docling/linux-build-provenance.json'
PATCH_ROOT = 'Packages/TractandaDocuments/RuntimePatches/'
PATCHES = [PATCH_ROOT + name for name in ('vmlx-61a4b20-linux-docling.patch', 'vmlx-61a4b20-idefics3-gelu-f32.patch')]
HELPERS = {'embeddings': 'tractanda-embeddings', 'documents': 'tractanda-document-converter'}
PROFILE = 'tractanda.kali-component-review.v1'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def contains_digest(path, digest):
    needle = digest.encode()
    tail = b''
    with path.open('rb') as stream:
        while block := stream.read(1024 * 1024):
            data = tail + block
            if needle in data:
                return True
            tail = data[-(len(needle) - 1):]
    return False


def compiler_input(work, role, arch, baseline):
    source = B.read_json(work / 'source-inputs.json', 16 * 1024**2)
    result = B.read_json(work / 'result.json', 16 * 1024**2)
    flags = C.build_arguments('swift', [], arch, C.ROLES[role][1], BASELINE)
    expected_status = 'NATIVE_HELPER_COMPILED_NOT_RUNTIME_ADMITTED_NOT_MODEL_EXECUTED'
    require(result['status'] == expected_status and source['status'] == 'COMPILE_ONLY_UNADMITTED'
            and result['sourceInputsSHA256'] == B.digest(work / 'source-inputs.json')
            and all(result[key] == source[key] for key in ('component', 'arch', 'baseline', 'toolchain', 'buildFlags'))
            and (result['component'], result['arch'], result['baseline'], result['buildFlags'])
            == (role, arch, baseline, flags), 'Native Kali compiler receipt differs.')
    require(source['files'] == P.rows(ROOT, roots=C.SOURCE_ROOTS, skip=P.SKIP),
            'The compiler source differs from the current frozen input.')
    execution_source = P.execution_source(work / 'source', role, compiled_files=source['files'])
    require(source.get('executionSource') == execution_source
            and result.get('executionSource') == execution_source
            and execution_source == P.execution_source(ROOT, role),
            'Actual compiler execution source binding is missing or differs; rebuild before admission.')
    artifact = Path(result['artifact']['path'])
    require(artifact == C.compiled_artifact(str(artifact.parent), work, C.ROLES[role][1], arch)
            and artifact.stat().st_size == result['artifact']['size']
            and B.digest(artifact) == result['artifact']['sha256'], 'Native compiler bytes differ.')
    return artifact, source, result


def vendor_facts(arch, manifest_path, descriptor_path, provenance_path, rows):
    approved = P.require_admitted(arch, B.DEBIAN_BUILD_OS)['documents']
    manifest = B.read_json(manifest_path, 16 * 1024**2)
    require(P.sha(B.canonical(manifest)) == approved, 'Original vendor supplier component commitment differs.')
    source_entries = {entry['path']: P.file_entry(entry) for entry in manifest['files']}
    current = {row['path']: row for row in rows}
    require(all(current.get(name) == source_entries.get(name) and name in current for name in SUPPLIERS),
            'Raster supplier bytes differ from the original admitted C ABI.')
    descriptor_sha = B.digest(descriptor_path)
    provenance_sha = B.digest(provenance_path)
    require(descriptor_sha == source_entries[DESCRIPTOR]['sha256']
            and provenance_sha == source_entries[PROVENANCE]['sha256'], 'Vendor descriptor or provenance differs.')
    descriptor = B.read_json(descriptor_path)
    provenance = B.read_json(provenance_path, 16 * 1024**2)
    require(descriptor['architecture'] == arch and descriptor['buildProvenanceSHA256'] == provenance_sha,
            'Original descriptor does not bind this supplier provenance.')
    require(P.hash_string(provenance.get('nativeSourceCommitmentsSHA256'))
            and P.hash_string(provenance.get('nativeRecipeSHA256')),
            'Original provenance does not bind the native C supplier recipe and inputs.')
    return manifest['documentExtraction'], descriptor, {
        'originalBaseline': manifest['baseline'],
        'originalComponentManifestSHA256': approved,
        'originalDescriptorSHA256': descriptor_sha,
        'originalBuildProvenanceSHA256': provenance_sha,
        'nativeSourceCommitmentsSHA256': provenance['nativeSourceCommitmentsSHA256'],
        'nativeRecipeSHA256': provenance['nativeRecipeSHA256'],
        'supplierFiles': [current[path] for path in sorted(SUPPLIERS)],
    }


def native_closure(root, rows, role, arch):
    dynamic = []
    for row in rows:
        if row['path'].startswith('lib/'):
            with (root / row['path']).open('rb') as stream:
                if stream.read(4) == b'\x7fELF':
                    dynamic.append(row['path'])
    closure = B.runtime_closure(root, rows, arch, dynamic, BASELINE, required_products=(HELPERS[role],))
    required = {}
    paths = [root / name for name in closure['privateELF']]
    paths += [Path(provider['path']) for provider in closure['osLibraries']]
    for path in paths:
        for soname, versions in G.required_versions(path).items():
            required.setdefault(soname, set()).update(versions)
    providers = {item['soname']: Path(item['path']) for item in closure['osLibraries']}
    system = [{'soname': item['soname'], 'provider': item['package'], 'version': item['version'],
               'requiredSymbolVersions': sorted(required.get(item['soname'], ()))}
              for item in closure['osLibraries']]
    private = []
    for name in closure['privateELF']:
        elf = B.elf(root / name, arch, BASELINE)
        private.append({'path': name, 'soname': elf['soname'], 'needed': elf['needed'],
                        'runpath': elf['searchPaths'], 'machine': B.ARCH[arch][1]})
        if elf['soname']:
            providers[elf['soname']] = root / name
    for soname, versions in required.items():
        require(soname in providers and versions <= provided_versions(providers[soname]),
                'Native provider lacks a required symbol version: ' + soname)
    return closure, dynamic, private, system


def provided_versions(path):
    names = set()
    definitions = False
    text = B.run(['/usr/bin/readelf', '--wide', '--version-info', path])
    for line in text.splitlines():
        if line.startswith('Version '):
            definitions = line.startswith('Version definition section')
        if definitions and 'Name:' in line:
            names.add(line.split('Name:', 1)[1].strip().split()[0])
    return names


def prepare(args):
    role, arch = args.component, args.arch
    baseline = B.native_baseline(arch, BASELINE)
    work, support = args.compile_work.resolve(strict=True), args.runtime_root.resolve(strict=True)
    artifact, source, compiler = compiler_input(work, role, arch, baseline)
    _, toolchain = P.toolchain(args.swift)
    require(toolchain == source['toolchain'], 'The concrete compiler toolchain differs.')
    output, report = args.output.absolute(), args.report.absolute()
    for path in (output, report):
        require(not path.exists() and not path.is_symlink() and not path.is_relative_to(ROOT)
                and not path.is_relative_to(work) and not path.is_relative_to(support),
                'Use new isolated output and report directories.')
    require(not output.is_relative_to(report) and not report.is_relative_to(output),
            'Output and report directories overlap.')
    rows = P.rows(support, maximum=CAP)
    helper = 'bin/' + HELPERS[role]
    require(all(row['path'].startswith(('bin/', 'lib/', 'licenses/'))
                and row['path'] not in {helper, DESCRIPTOR, PROVENANCE} for row in rows),
            'Prepared runtime inputs contain an unsupported path.')
    require(0 < sum(row['size'] for row in rows) + artifact.stat().st_size <= CAP,
            'Component input exceeds its fixed bound.')
    if role == 'documents':
        require(all((args.supplier_manifest, args.supplier_descriptor, args.supplier_provenance)),
                'Docling requires all original supplier commitments.')
        document, historical, vendor = vendor_facts(
            arch, args.supplier_manifest, args.supplier_descriptor, args.supplier_provenance, rows)
    else:
        require(not any((args.supplier_manifest, args.supplier_descriptor, args.supplier_provenance,
                         args.expected_descriptor)), 'Embedding has no document supplier or descriptor.')
        document, historical, vendor = None, None, None
    B.capacity(output.parent, sum(row['size'] for row in rows) + artifact.stat().st_size, CAP)
    output.mkdir(mode=0o700)
    report.mkdir(mode=0o700)
    P.merge_files(support, output, rows, CAP)
    entry = P.rows(artifact.parent, [artifact.name])[0]
    B.copy_verified(artifact, output / helper, entry, CAP)
    runpath = '$ORIGIN/../lib'
    if role == 'documents':
        runpath += ':$ORIGIN/../lib/tractanda/document-native'
    patcher = Path('/usr/bin/patchelf')
    B.run([patcher, '--set-rpath', runpath, output / helper])
    rows = P.rows(output, maximum=CAP)
    closure, dynamic, private, system = native_closure(output, rows, role, arch)
    flags = compiler['buildFlags']
    descriptor_digest = None
    if role == 'documents':
        normalized, generated = N.normalized_rows(P, C, ROOT, G.TEMPLATES)
        provenance = {'profile': 'tractanda.kali-docling-normalized-build.v1', 'baseline': baseline,
                      'sourceSelectionProfile': N.SELECTION_PROFILE, 'sourceSelectionRoots': N.SOURCE_ROOTS,
                      'sourceFiles': normalized, 'toolchain': toolchain, 'buildFlags': flags,
                      'vendor': vendor, 'nativeClosure': closure, 'patcherSHA256': B.digest(patcher)}
        P.write_json(output / PROVENANCE, provenance)
        (output / PROVENANCE).chmod(0o644)
        descriptor = {key: historical[key] for key in (
            'schema', 'operatingSystem', 'architecture', 'backend', 'runtimeBaseRevision', 'modelAssetsSHA256',
            'preprocessing', 'parser', 'sourceRevisions', 'patchSHA256s')}
        descriptor.update(buildProvenanceSHA256=B.digest(output / PROVENANCE),
                          files=[row for row in P.rows(output, maximum=CAP) if row['path'] != helper],
                          privateDependencies=private, osDependencies=system)
        P.write_json(output / DESCRIPTOR, descriptor)
        (output / DESCRIPTOR).chmod(0o644)
        descriptor_digest = B.digest(output / DESCRIPTOR)
        document['identity']['converter'] = document['identity']['converter'].rsplit('.', 1)[0] + '.' + descriptor_digest
        if args.expected_descriptor:
            require(descriptor_digest == args.expected_descriptor
                    and generated[N.CLIENT]['digests']['kali-' + arch] == descriptor_digest
                    and contains_digest(output / helper, descriptor_digest),
                    'Second-pass executable or stable descriptor differs from the reviewed commitment.')
        source_sha = P.sha(B.canonical(provenance))
    else:
        source_sha = P.sha(B.canonical({'files': source['files'], 'baseline': baseline,
                                        'toolchain': toolchain, 'flags': flags, 'closure': closure}))
    rows = P.rows(output, maximum=CAP)
    manifest = {'profile': 'tractanda.linux-component-artifacts.v2', 'component': role, 'arch': arch,
                'baseline': {'buildOS': BASELINE, 'minimumCPU': B.ARCH[arch][2], 'swiftABI': '6.4'},
                'modelRevision': P.MODELS[role], 'runtimeRevision': P.RUNTIME, 'sourceInputsSHA256': source_sha,
                'executionSource': compiler['executionSource'],
                'recipe': {'path': 'scripts/prepare-kali-linux-component.py', 'sha256': B.digest(Path(__file__))},
                'patches': [{'path': rel, 'sha256': B.digest(ROOT / rel)} for rel in PATCHES],
                'toolchain': toolchain, 'files': rows, 'dynamicLoads': dynamic,
                'runtimeNotices': [row['path'] for row in rows if row['path'].startswith('licenses/')],
                'documentExtraction': document}
    digest = P.sha(B.canonical(manifest))
    path = report / 'component.json'
    P.write_json(path, manifest)
    P.component(path, output, role, arch, digest, BASELINE)
    result = {'profile': PROFILE, 'status': 'PREPARED_NOT_ADMITTED_NOT_MODEL_EXECUTED',
              'component': role, 'architecture': arch, 'baseline': baseline, 'manifestSHA256': digest,
              'descriptorSHA256': descriptor_digest, 'secondPassBound': bool(args.expected_descriptor),
              'artifactSHA256': B.digest(output / helper), 'originalCompilerSHA256': compiler['artifact']['sha256'],
              'nativeClosure': closure, 'registryUpdated': False}
    P.write_json(report / 'result.json', result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--component', choices=HELPERS, required=True)
    parser.add_argument('--arch', choices=B.ARCH, required=True)
    for name in ('compile-work', 'runtime-root', 'swift', 'output', 'report'):
        parser.add_argument('--' + name, type=Path, required=True)
    for name in ('supplier-manifest', 'supplier-descriptor', 'supplier-provenance'):
        parser.add_argument('--' + name, type=Path)
    parser.add_argument('--expected-descriptor')
    print(json.dumps(prepare(parser.parse_args()), indent=2))


if __name__ == '__main__':
    main()
