"""Linux artifact admission and explicit candidate-bound cluster acceptance.

Receipts bind existing build evidence; operator acceptance is not remote proof.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import uuid
from datetime import datetime, timezone

PROFILE = 'tractanda.release-delivery.v2'
PUBLIC_PROFILE = 'tractanda.release-delivery.v3-publish-before-update'
ARCHES = {'amd64': 'x86_64', 'arm64': 'arm64'}
INSTALL_CHECKS = ('candidate-compatibility-and-maintenance', 'current-installation-identity')
CHECKS = ('raven-candidate-runtime', 'stash-candidate-runtime',
          'current-membership-and-peer-runtime', 'bidirectional-verification')
RESERVE = 10 * 1024**3


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def fingerprint(path, limit=None):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode) and (limit is None or before.st_size <= limit), 'Unbounded/nonregular release input')
        h = hashlib.sha256()
        for block in iter(lambda: stream.read(1024**2), b''):
            h.update(block)
        after = os.fstat(stream.fileno())
    stamp = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
    require(stamp(before) == stamp(after), 'Release input changed while reading')
    return {'sha256': h.hexdigest(), 'bytes': before.st_size}


def json_input(path):
    proof = fingerprint(path, 16 * 1024**2)
    raw = Path(path).read_bytes()
    require(digest(raw) == proof['sha256'], 'JSON changed after capture')
    def unique(pairs):
        out = {}
        for k, v in pairs:
            require(k not in out, 'Duplicate release JSON field')
            out[k] = v
        return out
    return json.loads(raw, object_pairs_hook=unique), raw, proof


def release_plan(steps):
    result = list(steps)
    result.insert(result.index('install'), 'install-authorization')
    result.insert(result.index('push'), 'cluster-acceptance')
    return result


def fresh():
    return {'profile': PROFILE, 'linuxAssets': []}


def public_fresh():
    return {'profile': PUBLIC_PROFILE, 'linuxAssets': []}


def public(state):
    return isinstance(state.get('delivery'), dict) and state['delivery'].get('profile') == PUBLIC_PROFILE


def active(state):
    return isinstance(state.get('delivery'), dict) and state['delivery'].get('profile') in (PROFILE, PUBLIC_PROFILE)


# This is deliberately narrower than the producer's capture. Tests are captured
# for reproducibility but default SwiftPM test sources do not enter release
# products. Changing a recipe, resource, dependency, or target mapping requires a
# normal producer run. The original producer receipts always remain untouched.
EQUIVALENCE_PROFILE = 'tractanda.release-linux-source-equivalence.v1'
# Reviewed G manifest: release targets use Sources/Tools, Tests contains only
# default test targets. A different manifest requires a normal producer run or
# separate review of this admission policy; arbitrary Swift is never evaluated.
REVIEWED_PACKAGE_SHA256 = {'58971af17f8c0b6871f7d42da6bb6c4dbc109cc589eb5aac67bcff96e1908176'}
DEVELOPMENT_ONLY = {'scripts/release-delivery.py', 'scripts/release-macos.py',
                    'scripts/test-release-delivery.py'}
EVIDENCE_INPUTS = {'inventory': None, 'bundle-manifest': 'bundleManifest',
                   'bundle-build': 'bundleBuildReceipt',
                   'producer-source-inputs': 'producerSourceInputs',
                   'producer-result': 'producerResult'}


def git_bytes(root, *args, input=None):
    result = subprocess.run(['git', '-C', str(root), *args], input=input,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    require(result.returncode == 0, 'Source equivalence Git verification failed')
    return result.stdout


def git_inventory(root, commit):
    result = {}
    for raw in git_bytes(root, 'ls-tree', '-rlz', commit).split(b'\0'):
        if not raw: continue
        metadata, name = raw.split(b'\t', 1)
        mode, kind, oid, size = metadata.split()
        path = name.decode('utf-8')
        require(not Path(path).is_absolute() and '..' not in Path(path).parts,
                'Unsafe source equivalence Git path')
        result[path] = {'mode': mode.decode(), 'kind': kind.decode(),
                        'oid': oid.decode(), 'size': int(size) if size != b'-' else None}
    return result


def git_rows(root, inventory, paths):
    paths = sorted(paths)
    require(len(paths) <= 20000 and all(inventory[p]['kind'] == 'blob'
            and inventory[p]['mode'] in ('100644', '100755') for p in paths),
            'Source equivalence requires bounded regular Git files')
    require(sum(inventory[p]['size'] for p in paths) <= 128 * 1024**2,
            'Source equivalence Git byte bound exceeded')
    raw = git_bytes(root, 'cat-file', '--batch',
                    input=''.join(inventory[p]['oid'] + '\n' for p in paths).encode()) if paths else b''
    result, offset = [], 0
    for path in paths:
        end = raw.index(b'\n', offset)
        oid, kind, size = raw[offset:end].split()
        size = int(size); offset = end + 1
        require(oid.decode() == inventory[path]['oid'] and kind == b'blob'
                and size == inventory[path]['size'] and raw[offset+size:offset+size+1] == b'\n',
                'Source equivalence Git blob framing differs')
        result.append({'path': path, 'mode': int(inventory[path]['mode'], 8) & 0o777,
                       'size': size, 'sha256': digest(raw[offset:offset+size])})
        offset += size + 1
    require(offset == len(raw), 'Extra source equivalence Git blob data')
    return result


def selected_source_paths(inventory, context):
    selectors = (*context['sourceRoots'], *context['sourceFiles'], *context['publicRoots'])
    return {p for p in inventory if not set(Path(p).parts) & set(context['sourceSkip'])
            and any(p == selector or p.startswith(selector + '/') for selector in selectors)}


def asset_binding(entry):
    require(isinstance(entry, dict) and set(entry) == {'arch', 'package', 'bundleManifest',
            'bundleBuildReceipt', 'producerSourceInputs', 'producerResult'} and entry['arch'] in ARCHES,
            'Complete original Linux artifact evidence required for source equivalence')
    return {'arch': entry['arch'], 'package': fingerprint(entry['package']),
            'evidence': {key: fingerprint(str(entry['package']) + '.inventory.json' if field is None
                                         else entry[field]) for key, field in EVIDENCE_INPUTS.items()}}


def source_equivalence(state, context, origin_commit, assets):
    """Generate the exact reviewable opt-in proof from Git and existing bytes.

    Callers supply artifact fingerprints, never source rows or changed paths.
    Attachment and every later verification independently recompute this proof.
    """
    root = context['sourceRoot']
    require(isinstance(origin_commit, str) and re.fullmatch(r'[0-9a-f]{40}', origin_commit) is not None,
            'Full original producer source commit required')
    final = {'commit': state['commit'], 'tree': state['tree']}
    require(git_bytes(root, 'rev-parse', 'HEAD').decode().strip() == final['commit']
            and git_bytes(root, 'rev-parse', 'HEAD^{tree}').decode().strip() == final['tree']
            and not git_bytes(root, 'status', '--porcelain', '--untracked-files=all'),
            'Source equivalence requires the clean sealed candidate checkout')
    git_bytes(root, 'merge-base', '--is-ancestor', origin_commit, final['commit'])
    origin = {'commit': origin_commit,
              'tree': git_bytes(root, 'rev-parse', origin_commit + '^{tree}').decode().strip()}
    old = git_inventory(root, origin_commit); new = git_inventory(root, final['commit'])
    changed = sorted(p for p in old.keys() | new.keys() if old.get(p) != new.get(p))
    require(changed, 'Source equivalence requires an explicit nonempty correction')
    # A reviewed immutable manifest, not a general Swift/regex interpretation,
    # establishes that these default test paths are outside release products.
    require('Package.swift' in new, 'Reviewed root package manifest required')
    package_raw = git_bytes(root, 'cat-file', 'blob', new['Package.swift']['oid'])
    require(digest(package_raw) in REVIEWED_PACKAGE_SHA256,
            'Root package manifest is not reviewed for source equivalence')
    package = package_raw.decode()
    require(not re.search(r'"(?:\./)?Tests(?:/|")', package),
            'Explicit Tests target/resource mapping is not eligible for source equivalence')
    targets = set(re.findall(r'\.testTarget\s*\(\s*name:\s*"([^"\n]+)"', package))
    for path in changed:
        test = re.fullmatch(r'Tests/([^/]+Tests)/[^/]+\.swift', path)
        allowed = path in DEVELOPMENT_ONLY or path.startswith('.github/workflows/') and path.endswith(('.yml', '.yaml'))
        allowed = allowed or bool(test and test.group(1) in targets)
        require(allowed and path in old and path in new
                and old[path]['mode'] == new[path]['mode'] and new[path]['mode'] in ('100644', '100755')
                and old[path]['kind'] == new[path]['kind'] == 'blob',
                'Only existing unshipped test/workflow/development source edits with unchanged modes are eligible')
        require(not any(path == p or path.startswith(p + '/') for p in context['publicRoots']),
                'Public shipping input cannot use source equivalence')
    original_rows = git_rows(root, old, selected_source_paths(old, context))
    final_rows = git_rows(root, new, selected_source_paths(new, context))
    require(final_rows == context['files'], 'Current producer capture differs from sealed Git source')
    before = {r['path']: r for r in git_rows(root, old, changed)}
    after = {r['path']: r for r in git_rows(root, new, changed)}
    proof = {'profile': EQUIVALENCE_PROFILE, 'origin': origin, 'candidate': final,
             'changes': [{'path': p, 'origin': before[p], 'candidate': after[p]} for p in changed],
             'assets': sorted(assets, key=lambda a: a['arch'])}
    return proof, dict(context, files=original_rows)


def equivalent_context(state, context, proof, assets):
    require(isinstance(proof, dict) and set(proof) == {'profile', 'origin', 'candidate', 'changes', 'assets'}
            and isinstance(proof.get('origin'), dict) and set(proof['origin']) == {'commit', 'tree'}
            and isinstance(proof.get('candidate'), dict) and proof.get('profile') == EQUIVALENCE_PROFILE,
            'Invalid explicit Linux source equivalence proof')
    expected, original_context = source_equivalence(state, context, proof.get('origin', {}).get('commit'), assets)
    require(proof == expected, 'Linux source equivalence proof differs from Git/artifact evidence')
    return original_context


def inspect_asset(entry, version, context):
    fields = {'arch', 'package', 'bundleManifest', 'bundleBuildReceipt', 'producerSourceInputs', 'producerResult'}
    require(set(entry) == fields and entry['arch'] in ARCHES, 'Explicit Linux architecture and all existing producer receipts required')
    arch = entry['arch']; package = Path(entry['package'])
    require(package.is_absolute() and package.suffix == '.deb', 'Use an absolute real Debian package path')
    require(all(Path(entry[k]).is_absolute() for k in fields - {'arch'}), 'Use absolute producer evidence paths')
    receipt, receipt_raw, rp = json_input(str(package) + '.inventory.json')
    manifest, manifest_raw, mp = json_input(entry['bundleManifest'])
    build, build_raw, bp = json_input(entry['bundleBuildReceipt'])
    source, source_raw, sp = json_input(entry['producerSourceInputs'])
    result, result_raw, xp = json_input(entry['producerResult'])
    require(source.get('profile') == 'tractanda.linux-producer-source.v1'
            and result.get('profile') == 'tractanda.linux-payload-result.v1', 'Actual final producer receipts required')
    package_proof = fingerprint(package)
    require(receipt.get('arch') == arch and receipt.get('packageSHA256') == package_proof['sha256']
            and receipt.get('packageBytes') == package_proof['bytes'] and package_proof['bytes'] > 0, 'Linux package bytes/hash/architecture differ from D3 receipt')
    base = version.replace('-poc.', '~poc.')
    require(isinstance(receipt.get('version'), str) and re.fullmatch(re.escape(base) + r'-[1-9][0-9A-Za-z.+]*', receipt['version']), 'Linux Debian/source release versions differ')
    require(manifest.get('profile') == 'tractanda.bundle.v1' and manifest.get('platform') == 'linux'
            and manifest.get('arch') == ARCHES[arch] and manifest.get('version') == version
            and manifest.get('embedding') and manifest.get('documentExtraction')
            and receipt.get('bundleManifestSHA256') == mp['sha256'], 'Linux bundle identity/manifest commitment differs')
    inventory = {r['path']: r for r in receipt['inventory']}
    files = {r['path']: r for r in manifest['files']}
    require(len(inventory) == len(receipt['inventory']) and len(files) == len(manifest['files']), 'Duplicate Linux inventory path')
    prefix = 'opt/tractanda/current/'
    require(inventory[prefix + 'bundle-manifest.json']['sha256'] == mp['sha256'], 'D3 manifest inventory differs')
    for name, row in files.items():
        require(not Path(name).is_absolute() and '..' not in Path(name).parts, 'Unsafe bundle path')
        actual = inventory.get(prefix + name, {})
        require(all(actual.get(k) == row.get(k) for k in ('sha256', 'size', 'mode')), 'D3 file commitment differs from actual bundle manifest')
    core = ('tractanda', 'tractanda-tui', 'tractanda-mcp', 'tractanda-setup', 'tractanda-auth-helper', 'tractanda-embeddings', 'tractanda-document-converter')
    require(all('bin/' + n in files for n in core), 'Complete Linux executable inventory required')
    if manifest.get('version') in ('0.1.0-poc.17', '0.1.0-poc.17.1'):
        require('bin/tractanda-layout17' in files, 'The .17 one-time migration bridge is required')
    if manifest.get('modelProvisioningManifestPath') == 'models/manifest.json':
        require(files.get('models/manifest.json', {}).get('sha256') == manifest.get('modelProvisioningManifestSHA256')
                and not any(p.endswith(('.safetensors', '.gguf')) for p in files),
                'Slim Linux artifact catalogue or weight exclusion differs')
    else:
        require(all(any(p.startswith('models/' + model + '/') for p in files) for model in
                    ('granite-embedding-311m-multilingual-r2', 'granite-docling-258m-mlx')), 'Complete legacy Linux model inventory required')
    require(files['lib/tractanda/linux-bundle-build.json']['sha256'] == bp['sha256'], 'Bundle-build receipt is not in the committed manifest')
    spec = build['input']
    baseline = build['baseline']
    require(build.get('profile') == 'tractanda.linux-bundle-build.v1'
            and spec['profile'] == 'tractanda.linux-bundle-input.v2'
            and baseline['arch'] == arch and baseline['os'] == spec['buildOS'] == context['buildOS']
            and baseline == source['baseline'] == result['baseline']
            and spec['version'] == version and spec['arch'] == arch,
            'Linux producer/bundle build identity differs')
    require(source['files'] == context['files'] and source['componentManifests'] == context['components'][arch]
            and spec['buildFlags'] == context['flags'][arch], 'Linux core source/recipe/approved components differ from the sealed candidate')
    normalized = {'files': source['files'], 'components': source['componentManifests'], 'toolchain': source['toolchain'],
                  'buildFlags': spec['buildFlags'], 'buildEnvironment': source['buildEnvironment'], 'baseline': baseline}
    commitment = digest(canonical(normalized))
    require(spec['sourceInputsSHA256'] == commitment == result['sourceInputsSHA256']
            and result['bundle']['manifestSHA256'] == mp['sha256'] and result['components'] == normalized['components']
            and result['toolchain'] == normalized['toolchain'] and result['buildEnvironment'] == normalized['buildEnvironment'],
            'Existing normalized Linux producer commitments differ')
    metadata = {'inventory': receipt_raw, 'bundle-manifest': manifest_raw, 'bundle-build': build_raw,
                'producer-source-inputs': source_raw, 'producer-result': result_raw}
    record = {'arch': arch, 'name': f'tractanda_{receipt["version"]}_{arch}.deb', 'debianVersion': receipt['version'],
              'sha256': package_proof['sha256'], 'bytes': package_proof['bytes'], 'bundleManifestSHA256': mp['sha256'],
              'sourceInputsSHA256': commitment,
              'evidence': {key: {'name': arch + '-' + key + '.json', 'sha256': digest(raw)} for key, raw in metadata.items()}}
    return record, package, metadata


def copy_bound(source, target, expected):
    if target.exists() or target.is_symlink():
        require(fingerprint(target)['sha256'] == expected, 'Existing candidate Linux asset differs; revise/archive it explicitly')
        return
    with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            with Path(source).open('rb') as original:
                shutil.copyfileobj(original, stream, 1024**2)
            stream.flush(); os.fsync(stream.fileno())
            require(fingerprint(temporary)['sha256'] == expected, 'Linux staging input changed')
            os.link(temporary, target)
        finally:
            temporary.unlink(missing_ok=True)


def attach(state, input_path, context):
    require(active(state) and state['status'] != 'complete' and not any(k in state['steps'] for k in ('artifacts', 'install', 'push', 'publish')),
            'Attach both Linux packages before artifact sealing; revised candidates require fresh attachment')
    value, _, _ = json_input(input_path)
    strict = set(value) == {'profile', 'assets'} and value['profile'] == 'tractanda.release-linux-input.v1'
    reuse = set(value) == {'profile', 'assets', 'sourceEquivalence'} and value['profile'] == 'tractanda.release-linux-input.v2'
    require((strict or reuse) and isinstance(value['assets'], list) and len(value['assets']) == 2,
            'Exactly two Linux package inputs and a supported explicit admission contract required')
    effective = equivalent_context(state, context, value['sourceEquivalence'],
                                   [asset_binding(e) for e in value['assets']]) if reuse else context
    rows = [inspect_asset(entry, state['version'], effective) for entry in value['assets']]
    if reuse:
        # Bind the exact bytes inspected below, not merely an earlier fingerprint
        # of input paths which could have changed before admission completed.
        inspected = [{'arch': r['arch'], 'package': {'sha256': r['sha256'], 'bytes': r['bytes']},
                      'evidence': {key: {'sha256': digest(raw), 'bytes': len(raw)} for key, raw in metadata.items()}}
                     for r, _, metadata in rows]
        require(sorted(inspected, key=lambda a: a['arch']) == value['sourceEquivalence']['assets'],
                'Original Linux artifact inputs changed during source equivalence admission')
        for record, _, _ in rows:
            record['artifactOrigin'] = value['sourceEquivalence']['origin']
            record['sourceEquivalenceSHA256'] = digest(canonical(value['sourceEquivalence']))
    require({r[0]['arch'] for r in rows} == set(ARCHES)
            and len({r[0]['sha256'] for r in rows}) == 2, 'Missing/duplicate Linux architecture or package')
    directory = Path(state['directory']); evidence = directory / 'linux-evidence'
    require(not evidence.is_symlink(), 'Linux evidence directory is a link')
    evidence.mkdir(mode=0o700, exist_ok=True)
    fs = os.statvfs(directory)
    require(fs.f_frsize > 0 and fs.f_bavail * fs.f_frsize >= RESERVE + sum(r[0]['bytes'] for r in rows), 'Linux staging capacity/reserve rejected')
    for record, package, metadata in rows:
        copy_bound(package, directory / record['name'], record['sha256'])
        for key, raw in metadata.items():
            target = evidence / record['evidence'][key]['name']
            if target.exists() or target.is_symlink():require(fingerprint(target)['sha256'] == digest(raw), 'Existing candidate Linux evidence differs')
            else:
                with target.open('xb') as f:f.write(raw)
    if reuse: state['delivery']['sourceEquivalence'] = value['sourceEquivalence']
    else: state['delivery'].pop('sourceEquivalence', None)
    state['delivery']['linuxAssets'] = sorted((r[0] for r in rows), key=lambda r: r['arch'])
    state['delivery'].pop('acceptance', None)
    state['delivery'].pop('installAuthorization', None)
    return state['delivery']['linuxAssets']


def verify_linux(state, context):
    rows = state['delivery'].get('linuxAssets', [])
    require(len(rows) == 2 and {r['arch'] for r in rows} == set(ARCHES), 'Both admitted Linux release packages are required')
    directory = Path(state['directory']); evidence = directory / 'linux-evidence'
    proof = state['delivery'].get('sourceEquivalence')
    if proof is not None:
        assets = [{'arch': r['arch'], 'package': fingerprint(directory / r['name']),
                   'evidence': {key: fingerprint(evidence / r['evidence'][key]['name']) for key in EVIDENCE_INPUTS}}
                  for r in rows]
        context = equivalent_context(state, context, proof, assets)
        require(all(r.get('artifactOrigin') == proof['origin']
                    and r.get('sourceEquivalenceSHA256') == digest(canonical(proof)) for r in rows),
                'Original Linux artifact provenance binding changed')
    else:
        require(all('artifactOrigin' not in r and 'sourceEquivalenceSHA256' not in r for r in rows),
                'Linux source equivalence proof is missing')
    for record in rows:
        package = directory / record['name']
        require(fingerprint(package) == {'sha256': record['sha256'], 'bytes': record['bytes']}, 'Candidate Linux package changed')
        for item in record['evidence'].values():
            require(fingerprint(evidence / item['name'])['sha256'] == item['sha256'], 'Candidate Linux evidence changed')
        entry = {'arch': record['arch'], 'package': str(package), 'bundleManifest': str(evidence / record['evidence']['bundle-manifest']['name']),
                 'bundleBuildReceipt': str(evidence / record['evidence']['bundle-build']['name']),
                 'producerSourceInputs': str(evidence / record['evidence']['producer-source-inputs']['name']),
                 'producerResult': str(evidence / record['evidence']['producer-result']['name'])}
        # The D3 inventory stays adjacent to the original package at admission;
        # staged verification uses the preserved candidate-owned inventory.
        inventory, _, _ = json_input(evidence / record['evidence']['inventory']['name'])
        require(inventory['packageSHA256'] == record['sha256'] and inventory['bundleManifestSHA256'] == record['bundleManifestSHA256'], 'Staged D3 inventory differs')
        source, _, _ = json_input(entry['producerSourceInputs'])
        build, _, _ = json_input(entry['bundleBuildReceipt'])
        baseline = build['baseline']
        normalized = {'files': source['files'], 'components': source['componentManifests'], 'toolchain': source['toolchain'],
                      'buildFlags': build['input']['buildFlags'], 'buildEnvironment': source['buildEnvironment'],
                      'baseline': baseline}
        require(source['files'] == context['files'] and source['componentManifests'] == context['components'][record['arch']]
                and baseline == source['baseline'] and baseline['arch'] == record['arch']
                and baseline['os'] == build['input']['buildOS'] == context['buildOS']
                and normalized['buildFlags'] == context['flags'][record['arch']]
                and digest(canonical(normalized)) == record['sourceInputsSHA256'], 'Staged Linux sealed-source commitment changed')
    return {r['name']: r['sha256'] for r in rows}


def binding(state):
    require(active(state), 'Candidate lacks the current delivery contract')
    value = {'version': state['version'], 'commit': state['commit'], 'tree': state['tree'],
             'installation': {k: state['configuration'][k] for k in ('instance', 'softwareRoot')},
             'macBundleManifestSHA256': state['steps']['bundle']['result']['manifestSHA256'],
             'artifacts': state['steps']['artifacts']['result'], 'linuxAssets': state['delivery']['linuxAssets']}
    require(len(value['linuxAssets']) == 2, 'Candidate lacks both Linux artifacts')
    return value


def challenge(state):
    value = binding(state)
    return {'profile': 'tractanda.release-cluster-acceptance.v2', 'candidateID': digest(canonical(value)), 'candidate': value,
            'cluster': {'storeID': '', 'ravenReplicaID': '', 'stashReplicaID': ''},
            'checks': [{'name': name, 'status': 'PENDING', 'completedAt': '', 'evidence': []} for name in CHECKS]}


def install_challenge(state):
    value = binding(state)
    return {'profile': 'tractanda.release-install-authorization.v2', 'candidateID': digest(canonical(value)), 'candidate': value,
            'raven': {'storeID': '', 'replicaID': ''},
            'checks': [{'name': name, 'status': 'PENDING', 'completedAt': '', 'evidence': []} for name in INSTALL_CHECKS]}


def validate_binding(value, expected):
    require(set(value) == set(expected) and value['profile'] == expected['profile']
            and value['candidateID'] == expected['candidateID'] and value['candidate'] == expected['candidate'], 'Cluster acceptance is stale or belongs to another candidate')


def validate_pins(pins, keys):
    require(set(pins) == set(keys) and len(set(pins.values())) == len(keys), 'Actual distinct canonical identity pins required')
    for identity in pins.values():
        parsed = uuid.UUID(identity)
        require(parsed.version == 1 and str(parsed) == identity, 'Canonical cluster pins must be lowercase UUIDv1')


def validate_checks(checks, names):
    require([c['name'] for c in checks] == list(names), 'Evidence must retain the current compatibility/runtime verification order')
    previous = None
    for check in checks:
        require(set(check) == {'name', 'status', 'completedAt', 'evidence'} and check['status'] == 'PASS', 'Every actual cluster check must explicitly pass')
        ended = datetime.fromisoformat(check['completedAt'].replace('Z', '+00:00'))
        require(ended.tzinfo is not None and (previous is None or ended >= previous)
                and ended <= datetime.now(timezone.utc), 'Cluster evidence order/time is invalid')
        previous = ended
        require(isinstance(check['evidence'], list) and 0 < len(check['evidence']) <= 8, 'Retained nonsecret evidence is required for each cluster check')
        for item in check['evidence']:
            require(set(item) == {'path', 'sha256'} and Path(item['path']).is_absolute()
                    and fingerprint(item['path'], 16 * 1024**2)['sha256'] == item['sha256'], 'Cluster evidence changed or is unavailable')


def validate_install(state, value):
    expected = install_challenge(state); validate_binding(value, expected)
    validate_pins(value['raven'], expected['raven']); validate_checks(value['checks'], INSTALL_CHECKS)
    return expected['candidateID']


def validate_acceptance(state, value):
    expected = challenge(state); validate_binding(value, expected)
    validate_pins(value['cluster'], expected['cluster']); validate_checks(value['checks'], CHECKS)
    allowed = verify_install(state)
    require(allowed is not None and value['cluster']['storeID'] == allowed['raven']['storeID']
            and value['cluster']['ravenReplicaID'] == allowed['raven']['replicaID'], 'Cluster acceptance differs from the explicitly authorized Raven identity')
    return expected['candidateID']


def record_operator_action(state, path, candidate_id, key, validate, folder):
    value, raw, proof = json_input(path)
    require(candidate_id == validate(state, value), 'Explicit candidate ID does not match acceptance evidence')
    directory = Path(state['directory']) / folder
    require(not directory.is_symlink(), 'Cluster evidence directory is a link')
    directory.mkdir(mode=0o700, exist_ok=True)
    target = directory / (proof['sha256'] + '.json')
    if target.exists():require(target.read_bytes() == raw, 'Stored cluster acceptance differs')
    else:
        with target.open('xb') as f:f.write(raw)
    state['delivery'][key] = {'candidateID': candidate_id, 'evidenceFile': str(target), 'sha256': proof['sha256'],
                                     'operatorUID': os.getuid(), 'acceptedAt': datetime.now(timezone.utc).isoformat()}
    if 'raven' in value: state['delivery'][key]['raven'] = value['raven']
    return state['delivery'][key]


def allow_install(state, path, candidate_id):
    require('artifacts' in state['steps'] and 'install' not in state['steps'] and 'push' not in state['steps']
            and state['status'] != 'complete', 'Explicit allow-install applies only after artifact sealing and before installation')
    return record_operator_action(state, path, candidate_id, 'installAuthorization', validate_install, 'install-evidence')


def accept(state, path, candidate_id):
    require('health' in state['steps'] and 'push' not in state['steps'] and state['status'] != 'complete', 'Accept cluster checks only after candidate health and before source publication')
    return record_operator_action(state, path, candidate_id, 'acceptance', validate_acceptance, 'cluster-evidence')


def verify_operator_action(state, key, validate):
    accepted = state['delivery'].get(key)
    if not accepted:return None
    value, _, proof = json_input(accepted['evidenceFile'])
    require(proof['sha256'] == accepted['sha256'] and validate(state, value) == accepted['candidateID'], 'Recorded operator acceptance changed')
    if 'raven' in value:require(value['raven'] == accepted['raven'], 'Authorized Raven pins changed')
    return accepted


def verify_install(state):
    return verify_operator_action(state, 'installAuthorization', validate_install)


def verify_acceptance(state):
    return verify_operator_action(state, 'acceptance', validate_acceptance)


def archive_for_revision(state):
    if not active(state):return
    directory = Path(state['directory']); rows = state['delivery'].get('linuxAssets', [])
    for row in rows:
        require(Path(row['name']).name == row['name'] and row['name'].endswith('_' + row['arch'] + '.deb'),
                'Previous Linux artifact escaped its candidate directory')
        path = directory / row['name']
        if path.exists() or path.is_symlink():
            require(fingerprint(path)['sha256'] == row['sha256'], 'Previous Linux asset changed; retain it for inspection')
    targets = [directory / r['name'] for r in rows] + [directory / n for n in ('linux-evidence', 'install-evidence', 'cluster-evidence')]
    targets = [p for p in targets if p.exists() or p.is_symlink()]
    if not targets:return
    history = directory / 'delivery-history'; history.mkdir(mode=0o700, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=state['commit'][:12] + '-', dir=history) as staging:
        target = Path(staging)
        for p in targets:
            require(not p.is_symlink(), 'Refuse linked previous delivery evidence')
            p.rename(target / p.name)
        retained = target.with_name(target.name + '-retained')
        target.rename(retained)
        return str(retained)
