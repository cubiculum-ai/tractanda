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
import tempfile
import uuid
from datetime import datetime, timezone

PROFILE = 'tractanda.release-delivery.v1'
ARCHES = {'amd64': 'x86_64', 'arm64': 'arm64'}
CHECKS = ('raven-backup-and-restore', 'canonical-cluster-initialization',
          'raven-candidate-runtime', 'stash-amd64-install-and-empty-preparation',
          'ssh-activation-closed-and-reaped', 'prepared-target-adoption',
          'loaded-peer-runtime-both-hosts', 'bidirectional-canary')
INSTALL_CHECKS = CHECKS[:2]
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


def active(state):
    return isinstance(state.get('delivery'), dict) and state['delivery'].get('profile') == PROFILE


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
    require(all('bin/' + n in files for n in core)
            and all(any(p.startswith('models/' + model + '/') for p in files) for model in
                    ('granite-embedding-311m-multilingual-r2', 'granite-docling-258m-mlx')), 'Complete Linux feature inventory required')
    require(files['lib/tractanda/linux-bundle-build.json']['sha256'] == bp['sha256'], 'Bundle-build receipt is not in the committed manifest')
    spec = build['input']
    require(build.get('profile') == 'tractanda.linux-bundle-build.v1' and build['baseline']['arch'] == arch
            and build['baseline']['os'] == 'debian13' and spec['version'] == version and spec['arch'] == arch,
            'Linux producer/bundle build identity differs')
    require(source['files'] == context['files'] and source['componentManifests'] == context['components'][arch]
            and spec['buildFlags'] == context['flags'][arch], 'Linux core source/recipe/approved components differ from the sealed candidate')
    normalized = {'files': source['files'], 'components': source['componentManifests'], 'toolchain': source['toolchain'],
                  'buildFlags': spec['buildFlags'], 'buildEnvironment': source['buildEnvironment']}
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
    require(set(value) == {'profile', 'assets'} and value['profile'] == 'tractanda.release-linux-input.v1'
            and isinstance(value['assets'], list) and len(value['assets']) == 2, 'Exactly two Linux package inputs required')
    rows = [inspect_asset(entry, state['version'], context) for entry in value['assets']]
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
    state['delivery']['linuxAssets'] = sorted((r[0] for r in rows), key=lambda r: r['arch'])
    state['delivery'].pop('acceptance', None)
    state['delivery'].pop('installAuthorization', None)
    return state['delivery']['linuxAssets']


def verify_linux(state, context):
    rows = state['delivery'].get('linuxAssets', [])
    require(len(rows) == 2 and {r['arch'] for r in rows} == set(ARCHES), 'Both admitted Linux release packages are required')
    directory = Path(state['directory']); evidence = directory / 'linux-evidence'
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
        normalized = {'files': source['files'], 'components': source['componentManifests'], 'toolchain': source['toolchain'],
                      'buildFlags': build['input']['buildFlags'], 'buildEnvironment': source['buildEnvironment']}
        require(source['files'] == context['files'] and source['componentManifests'] == context['components'][record['arch']]
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
    return {'profile': 'tractanda.release-cluster-acceptance.v1', 'candidateID': digest(canonical(value)), 'candidate': value,
            'cluster': {'storeID': '', 'ravenReplicaID': '', 'stashReplicaID': ''},
            'checks': [{'name': name, 'status': 'PENDING', 'completedAt': '', 'evidence': []} for name in CHECKS]}


def install_challenge(state):
    value = binding(state)
    return {'profile': 'tractanda.release-install-authorization.v1', 'candidateID': digest(canonical(value)), 'candidate': value,
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
    require([c['name'] for c in checks] == list(names), 'Evidence must retain backup/initialization/activation-before-adoption order')
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
