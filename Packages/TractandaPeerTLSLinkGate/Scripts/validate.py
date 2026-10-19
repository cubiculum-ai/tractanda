#!/usr/bin/env python3
"""Guarded, offline-mirrored Core/TLS combined link gate; no product integration."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import uuid
import subprocess
import time

HARNESS = Path(__file__).resolve().parents[1]
REPO = HARNESS.parents[1]
WORK = REPO / 'work/peer-dependency-link-20261014'
CAP = 6 * 1024**3
ALLOWANCE = 256 * 1024**2
RESERVE = 10 * 1024**3
PREFLIGHT = 16 * 1024**3
IMAGE = 'tractanda-test:swift6.4.0-trixie-validation-20261002'
IMAGE_DIGEST = 'sha256:12de0505417a967a9a2fe3036e501c1eb6ee92960fd7461a2a0e6a5783951d65'
CONTAINER = 'tractanda-peer-link-gate-20261014'
RUNTIME = '/usr/local/bin/container'
SOURCE = WORK / 'source/Tractanda'
GUEST_SESSION = None
GUARD_SOURCE = None
RECEIPT_MAX_AGE = 15


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.tmp')
    with temporary.open('w') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def guest_capacity():
    receipt = json.loads((WORK / 'logs/linux-host-guard.json').read_text())
    if receipt.get('session') != GUEST_SESSION or receipt.get('sourceSHA256') != GUARD_SOURCE:
        raise RuntimeError('host guard receipt session/source mismatch')
    if receipt.get('state') != 'running':
        raise RuntimeError('host guard is not running')
    age = time.time() - receipt['issuedAt']
    if not -5 <= age <= RECEIPT_MAX_AGE:
        raise RuntimeError('host guard receipt is stale or clock is inconsistent')
    sample = receipt['capacity']
    for key, value in [('cap', CAP), ('runtimeAllowance', ALLOWANCE), ('reserve', RESERVE)]:
        if type(sample.get(key)) is not int or sample[key] != value:
            raise RuntimeError('host guard limit mismatch')
    for key in ('available', 'allocated'):
        if type(sample.get(key)) is not int or sample[key] < 0:
            raise RuntimeError('invalid host guard accounting')
    fs = os.statvfs(WORK)  # One syscall, never a recursive guest metadata sweep.
    if fs.f_frsize <= 0 or fs.f_bavail < 0:
        raise RuntimeError('guest bind filesystem capacity unavailable')
    sample['available'] = min(sample['available'], fs.f_bavail * fs.f_frsize)
    if sample['available'] < RESERVE or sample['allocated'] + ALLOWANCE > CAP:
        raise RuntimeError('host/guest capacity rejected')
    return sample


def host_receipt(session, sample, state='running', error=None):
    save(WORK / 'logs/linux-host-guard.json', dict(
        session=session, sourceSHA256=hashlib.sha256((WORK / 'source-manifest.json').read_bytes()).hexdigest(),
        issuedAt=time.time(), monitorPID=os.getpid(), state=state, capacity=sample, error=error))


def capacity(initial=False):
    if GUEST_SESSION is not None:
        return guest_capacity()
    volume = WORK if WORK.exists() else REPO
    fs = os.statvfs(volume)
    if fs.f_frsize <= 0 or fs.f_bavail < 0:
        raise RuntimeError('genuine filesystem capacity unavailable')
    available = fs.f_bavail * fs.f_frsize
    allocated = 0
    seen = set()
    for path in (WORK, HARNESS):
        if not path.exists():
            continue
        for directory, dirs, names in os.walk(path, followlinks=False, onerror=lambda error: (_ for _ in ()).throw(error)):
            dirs[:] = [d for d in dirs if not (Path(directory) / d).is_symlink()]
            for name in names:
                try:
                    info = (Path(directory) / name).lstat()
                except FileNotFoundError:
                    continue
                identity = (info.st_dev, info.st_ino)
                if identity not in seen:
                    seen.add(identity)
                    allocated += info.st_blocks * 512
    result = dict(available=available, allocated=allocated, cap=CAP,
                  runtimeAllowance=ALLOWANCE, reserve=RESERVE)
    if available < (PREFLIGHT if initial else RESERVE) or allocated + ALLOWANCE > CAP:
        raise RuntimeError('capacity rejected: ' + json.dumps(result))
    return result


def run(command, label, environment, timeout=1800, cleanup=None, monitor_session=None):
    initial = capacity()
    logs = WORK / 'logs'
    state = logs / (label + '.status.json')
    if state.exists():
        previous = json.loads(state.read_text())
        if previous.get('running'):
            raise RuntimeError('owned prior child is still marked running: ' + label)
        if previous.get('exit'):
            attempt = 1
            while (logs / (label + f'.failed{attempt}.status.json')).exists():
                attempt += 1
            state.replace(logs / (label + f'.failed{attempt}.status.json'))
            output = logs / (label + '.log')
            if output.exists():
                output.replace(logs / (label + f'.failed{attempt}.log'))
    result = dict(command=list(map(str, command)), running=True, initial=initial)
    save(state, result)
    started = time.monotonic()
    process = None
    try:
        if monitor_session:
            host_receipt(monitor_session, initial)
        with (logs / (label + '.log')).open('wb') as output:
            process = subprocess.Popen(command, cwd=REPO, env=environment, stdout=output,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            result['pid'] = process.pid
            save(state, result)
            while process.poll() is None:
                result['latest'] = capacity()
                if monitor_session:
                    host_receipt(monitor_session, result['latest'])
                result['seconds'] = round(time.monotonic() - started, 2)
                save(state, result)
                if time.monotonic() - started > timeout:
                    raise RuntimeError('owned child exceeded validation deadline')
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    pass
            result['exit'] = process.returncode
            result['final'] = capacity()
    except BaseException as error:
        result['failure'] = str(error)
        result['exit'] = 125
        if monitor_session:
            try:
                host_receipt(monitor_session, None, 'failed', str(error))
            except Exception as receipt_error:
                result['receiptFailure'] = str(receipt_error)
        try:
            save(state, result)  # Original failure precedes cleanup.
        except Exception as status_error:
            result['statusFailure'] = str(status_error)
        if cleanup is not None:
            try:
                stopped = subprocess.run(cleanup, capture_output=True, text=True, timeout=30)
                result['cleanupExit'] = stopped.returncode
                result['cleanupDiagnostic'] = stopped.stderr[-500:]
            except Exception as cleanup_error:
                result['cleanupFailure'] = str(cleanup_error)
        if process is not None and process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
    finally:
        result['running'] = False
        result['seconds'] = round(time.monotonic() - started, 2)
        if monitor_session:
            try:
                host_receipt(monitor_session, result.get('final'),
                             'complete' if result.get('exit') == 0 else 'failed', result.get('failure'))
            except Exception as receipt_error:
                result['receiptFailure'] = str(receipt_error)
        save(state, result)
    print(json.dumps({k: result.get(k) for k in ('pid', 'exit', 'seconds', 'final', 'failure')},
                     default=str), label, flush=True)
    if result['exit']:
        raise RuntimeError('validation failed: ' + label)


def source_files():
    selected = ['Package.swift', 'Package.resolved', 'LICENSE', 'Sources', 'Tests',
                'Packages/TractandaClient', 'Packages/TractandaPeerTLS',
                'Packages/TractandaPeerTLSLinkGate']
    files = {}
    for relative in selected:
        path = REPO / relative
        if not path.exists():
            raise RuntimeError('required source is missing: ' + relative)
        candidates = [path] if path.is_file() else path.rglob('*')
        for item in candidates:
            rel = item.relative_to(REPO)
            if any(part in {'.build', '.swiftpm', '__pycache__', '.git'} for part in rel.parts) or rel.parts[:2] == ('Tests', 'work'):
                continue
            if item.is_symlink():
                raise RuntimeError('source symlink needs explicit review: ' + str(rel))
            if item.is_file():
                files[str(rel)] = item
    size = sum(path.stat().st_size for path in files.values())
    if size > 128 * 1024**2:
        raise RuntimeError('source snapshot exceeds pre-estimated 128 MiB')
    return files


def prepare(environment):
    capacity(initial=True)
    files = source_files()
    records = []
    old = WORK / 'source-manifest.json'
    if old.exists():
        previous = json.loads(old.read_text())
        for record in previous['files']:
            if record['path'].startswith('Packages/TractandaPeerTLSLinkGate/'):
                continue  # Only owned harness source may be repaired between runs.
            actual = files.get(record['path'])
            if actual is None or hashlib.sha256(actual.read_bytes()).hexdigest() != record['sha256']:
                raise RuntimeError('frozen root/TLS source changed: ' + record['path'])
    for position, (relative, origin) in enumerate(sorted(files.items())):
        if position % 64 == 0:
            capacity()
        data = origin.read_bytes()
        target = SOURCE / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists() or target.read_bytes() != data:
            target.write_bytes(data)
        records.append(dict(path=relative, bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
    actual = {str(p.relative_to(SOURCE)) for p in SOURCE.rglob('*') if p.is_file()
              and '.swiftpm' not in p.relative_to(SOURCE).parts}
    if actual != set(files):
        raise RuntimeError('snapshot inventory differs; no source stubbing/removal is permitted')
    save(old, dict(bytes=sum(r['bytes'] for r in records), files=records))
    pins = json.loads((REPO / 'Package.resolved').read_text())['pins']
    for pin in pins:
        if not pin['location'].startswith('https://'):
            raise RuntimeError('noncanonical root pin')
        mirror = WORK / 'mirrors' / (pin['identity'] + '.git')
        if not (mirror / 'HEAD').exists():
            original = REPO / '.build/checkouts' / pin['identity']
            if not original.is_dir():
                raise RuntimeError('exact cached dependency absent; no download: ' + pin['identity'])
            run(['git', 'init', '--bare', str(mirror)], 'prepare-init-' + pin['identity'], environment, 30)
            run(['git', '-C', str(mirror), 'fetch', '--depth=1', '--no-tags', str(original), pin['state']['revision']],
                'prepare-fetch-' + pin['identity'], environment, 60)
            run(['git', '-C', str(mirror), 'update-ref', 'refs/tags/' + pin['state']['version'],
                 pin['state']['revision']], 'prepare-tag-' + pin['identity'], environment, 30)
    return pins


def verify_snapshot():
    manifest = json.loads((WORK / 'source-manifest.json').read_text())
    for record in manifest['files']:
        actual = SOURCE / record['path']
        if actual.is_symlink() or hashlib.sha256(actual.read_bytes()).hexdigest() != record['sha256']:
            raise RuntimeError('source snapshot changed: ' + record['path'])


def validate(name, environment, evidence_only=False):
    verify_snapshot()
    harness = SOURCE / 'Packages/TractandaPeerTLSLinkGate'
    base = WORK / name
    for kind in ('scratch', 'cache', 'config', 'security', 'tmp', 'modules'):
        (base / kind).mkdir(parents=True, exist_ok=True)
    environment = environment.copy()
    environment.pop('SWIFTCI_USE_LOCAL_DEPS', None)
    environment.update(TMPDIR=str(base / 'tmp'), CLANG_MODULE_CACHE_PATH=str(base / 'modules'),
                       SWIFTPM_MODULECACHE_OVERRIDE=str(base / 'modules'))
    common = ['--package-path', str(harness), '--disable-sandbox']
    for kind in ('scratch', 'cache', 'config', 'security'):
        common += ['--' + kind + '-path', str(base / kind)]
    pins = json.loads((SOURCE / 'Package.resolved').read_text())['pins']
    for pin in pins:
        run(['swift', 'package', *common, 'config', 'set-mirror', '--original', pin['location'],
             '--mirror', (WORK / 'mirrors' / (pin['identity'] + '.git')).as_uri()],
            name + '-mirror-' + pin['identity'], environment, 60)
    run(['swift', '--version'], name + '-toolchain', environment, 30)
    backend = ['--build-system', 'native'] if name == 'linux' else ['--disable-index-store']
    tested = WORK / 'logs' / (name + '-tested-source-manifest.json')
    if not evidence_only:
        tested.write_bytes((WORK / 'source-manifest.json').read_bytes())
        run(['swift', 'test', *common, *backend, '--jobs', '2', '--filter', 'PeerTLSLinkGateTests'],
            name + '-tests', environment)
    else:
        state = json.loads((WORK / 'logs' / (name + '-tests.status.json')).read_text())
        if state.get('exit') != 0 or state.get('running'):
            raise RuntimeError('evidence-only requires an already successful completed test process')
    for record in json.loads(tested.read_text())['files']:
        if record['path'] == 'Packages/TractandaPeerTLSLinkGate/Scripts/validate.py':
            continue  # Evidence-runner repairs do not change any compiled input.
        if hashlib.sha256((SOURCE / record['path']).read_bytes()).hexdigest() != record['sha256']:
            raise RuntimeError('tested compiled source changed: ' + record['path'])
    resolved = json.loads((harness / 'Package.resolved').read_text())['pins']
    expected = {p['identity']: (p['location'], p['state']) for p in pins}
    for pin in resolved:
        if (pin['location'], pin['state']) != expected.get(pin['identity']):
            raise RuntimeError('noncanonical or changed resolved pin: ' + pin['identity'])
    save(WORK / 'logs' / (name + '-resolved.json'), resolved)
    verify_snapshot()
    candidates = [p for p in (base / 'scratch').rglob('*') if p.is_file() and
                  (p.name.endswith('.xctest') or p.name in {'TractandaPeerTLSLinkGatePackageTests', 'PeerTLSLinkGateTests'})]
    candidates = [p for p in candidates if p.open('rb').read(4) in
                  (b'\x7fELF', b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf')]
    if len(candidates) != 1:
        raise RuntimeError('expected exactly one combined test executable: ' + str(candidates))
    nm = shutil.which('nm')
    if not nm:
        raise RuntimeError('nm unavailable; cannot establish both prefixed families')
    run([nm, '-g', str(candidates[0])], name + '-symbols', environment, 60)
    symbols = (WORK / 'logs' / (name + '-symbols.log')).read_text()
    groups = {}
    for prefix in ('CCryptoBoringSSL_', 'CNIOBoringSSL_'):
        matched = sorted({parts[-1].lstrip('_') for line in symbols.splitlines()
                          if len(parts := line.split()) >= 3 and parts[-2].upper() != 'U'
                          and parts[-1].lstrip('_').startswith(prefix)})
        if not matched:
            raise RuntimeError('missing defined symbols: ' + prefix)
        groups[prefix] = dict(count=len(matched), examples=matched[:5])
    if 'RecordCodec' not in symbols:
        raise RuntimeError('real Core RecordCodec symbol is absent')
    save(WORK / 'logs' / (name + '-evidence.json'), dict(
        platform=platform.platform(), architecture=platform.machine(), binary=str(candidates[0]),
        binarySHA256=hashlib.sha256(candidates[0].read_bytes()).hexdigest(),
        symbols=groups, coreRecordCodec=True, capacity=capacity(), resolution='offline exact local Git mirrors; canonical lock URLs'))


def resume_frozen():
    # Current product sources may have evolved. Never hydrate them into this historical proof.
    verify_snapshot()
    manifest_path = WORK / 'source-manifest.json'
    previous = manifest_path.read_bytes()
    archive = WORK / 'logs/original-frozen-source-manifest.json'
    if not archive.exists():
        archive.write_bytes(previous)
    relative = 'Packages/TractandaPeerTLSLinkGate/Scripts/validate.py'
    script = (HARNESS / 'Scripts/validate.py').read_bytes()
    manifest = json.loads(previous)
    record = next(r for r in manifest['files'] if r['path'] == relative)
    record.update(bytes=len(script), sha256=hashlib.sha256(script).hexdigest())
    (SOURCE / relative).write_bytes(script)
    manifest['bytes'] = sum(r['bytes'] for r in manifest['files'])
    save(manifest_path, manifest)
    save(WORK / 'logs/host-guard-runner-transition.json', dict(
        previousManifestSHA256=hashlib.sha256(previous).hexdigest(),
        currentManifestSHA256=hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
        changedPaths=[relative], compiledInputs='unchanged original snapshot; no current-C1 source refresh'))


def verify_guest_mounts():
    expected = {'/gate', '/source/Tractanda/Packages/TractandaPeerTLSLinkGate/.swiftpm'}
    pseudo = {'proc', 'sysfs', 'devtmpfs', 'devpts', 'tmpfs', 'cgroup', 'cgroup2', 'mqueue'}
    rows = []
    seen = set()
    for line in Path('/proc/self/mountinfo').read_text().splitlines():
        before, after = line.split(' - ', 1)
        fields = before.split()
        target, options = fields[4], fields[5].split(',')
        kind = after.split()[0]
        if target in {'/', '/source'} and 'ro' not in options:
            raise RuntimeError('required root/source mount is not read-only: ' + target)
        if 'rw' in options and kind not in pseudo and target not in expected:
            raise RuntimeError('unaccounted persistent writable mount: ' + target)
        if target in expected:
            seen.add(target)
        rows.append(dict(target=target, filesystem=kind, options=options))
    if seen != expected:
        raise RuntimeError('expected host-backed writable mount is absent')
    save(WORK / 'logs/linux-tested-mounts.json', rows)


def main():
    global WORK, SOURCE, GUEST_SESSION, GUARD_SOURCE
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=('macos', 'linux'), required=True)
    parser.add_argument('--guest', action='store_true')
    parser.add_argument('--frozen-snapshot', action='store_true')
    parser.add_argument('--guard-session')
    parser.add_argument('--guard-source')
    parser.add_argument('--evidence-only', action='store_true', help='Inspect an unchanged already-passing binary, without another test run')
    args = parser.parse_args()
    environment = os.environ.copy()
    if args.guest:
        if args.platform != 'linux' or platform.system() != 'Linux' or os.getuid() == 0:
            raise RuntimeError('guest must be non-root Linux')
        WORK = Path('/gate')
        SOURCE = Path('/source/Tractanda')
        if not args.guard_session or not args.guard_source:
            raise RuntimeError('guest requires a fresh session-bound host monitor')
        GUEST_SESSION, GUARD_SOURCE = args.guard_session, args.guard_source
        capacity()
        verify_guest_mounts()
        validate('linux', environment, args.evidence_only)
        return
    capacity(initial=True)
    WORK.mkdir(parents=True, exist_ok=True)
    if args.frozen_snapshot:
        if args.platform != 'linux' or args.evidence_only:
            raise RuntimeError('frozen continuation is the bounded Linux gate only')
        resume_frozen()
    else:
        prepare(environment)
    if args.platform == 'macos':
        if platform.system() != 'Darwin':
            raise RuntimeError('macOS gate requires native macOS')
        validate('macos', environment, args.evidence_only)
    else:
        info = json.loads(subprocess.check_output([RUNTIME, 'image', 'inspect', IMAGE], timeout=30))
        if info[0]['configuration']['descriptor']['digest'] != IMAGE_DIGEST:
            raise RuntimeError('cached image digest mismatch; no pull permitted')
        for variant in info[0].get('variants', []):
            if variant.get('config', {}).get('config', {}).get('Volumes'):
                raise RuntimeError('image declares unaccounted persistent volumes')
        metadata = WORK / 'linux/package-metadata'
        metadata.mkdir(parents=True, exist_ok=True)
        for path in (WORK, WORK / 'source', metadata):
            if path.is_symlink() or not path.resolve().is_relative_to(WORK.resolve()):
                raise RuntimeError('mount escapes the owned work root')
        session = uuid.uuid4().hex  # Transient guard-run identity, never a pairing credential.
        prior = WORK / 'logs/linux-host-guard.json'
        if prior.exists():
            old = json.loads(prior.read_text())
            save(WORK / 'logs' / ('linux-host-guard-' + old['session'] + '.json'), old)
        source_sha = hashlib.sha256((WORK / 'source-manifest.json').read_bytes()).hexdigest()
        save(WORK / 'logs/linux-write-layout.json', dict(
            rootReadOnly=True, sourceReadOnly=True, configuredWritable=[str(WORK), str(metadata)],
            guestLocalPersistentVolumes=[], memory='3G', cpus=2,
            hostCap=CAP, runtimeAllowance=ALLOWANCE, reserve=RESERVE, sourceSHA256=source_sha))
        command = [RUNTIME, 'run', '--rm', '--progress', 'none', '--name', CONTAINER,
                   '--read-only', '--uid', str(os.getuid()), '--gid', str(os.getgid()),
                   '--cpus', '2', '--memory', '3G', '--no-dns',
                   '--mount', f'type=bind,source={WORK},target=/gate',
                   '--mount', f'type=bind,source={WORK / "source"},target=/source,readonly',
                   '--mount', f'type=bind,source={metadata},target=/source/Tractanda/Packages/TractandaPeerTLSLinkGate/.swiftpm',
                   '--workdir', '/source/Tractanda', '--entrypoint', '/usr/bin/python3', IMAGE,
                   '/source/Tractanda/Packages/TractandaPeerTLSLinkGate/Scripts/validate.py', '--platform', 'linux', '--guest', '--guard-session', session, '--guard-source', source_sha]
        run(command, 'linux-host', environment, 2400, [RUNTIME, 'stop', CONTAINER], monitor_session=session)
    print(json.dumps(dict(phase='complete', platform=args.platform, capacity=capacity())), flush=True)


if __name__ == '__main__':
    main()
