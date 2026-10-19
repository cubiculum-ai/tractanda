#!/usr/bin/env python3
"""Current-source guarded combined Core/TLS gate; no listener or production access."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import uuid
import subprocess
import time

REPO = Path(__file__).resolve().parents[1]
HARNESS = REPO / 'Packages/TractandaPeerTLSLinkGate'
WORK = REPO / 'work/peer-transport-20261015'
CAP = 5 * 1024**3 // 2
ALLOWANCE = 256 * 1024**2
RESERVE = 10 * 1024**3
PREFLIGHT = RESERVE + 2 * 1024**3
IMAGE = 'tractanda-test:swift6.4.0-trixie-validation-20261002'
IMAGE_DIGEST = 'sha256:12de0505417a967a9a2fe3036e501c1eb6ee92960fd7461a2a0e6a5783951d65'
CONTAINER = 'tractanda-peer-transport-20261015'
RUNTIME = '/usr/local/bin/container'
SOURCE = WORK / 'source/Tractanda'
GUEST_SESSION = None
GUARD_SOURCE = None
RECEIPT_MAX_AGE = 15
SOURCE_MANIFEST_NAME = 'source-manifest.json'
GUARD_NAME = 'linux-host-guard.json'
ADAPTER_STAGE = 'adapter-linux'
PORTABILITY_FILTER = 'Version1UUIDTests|testSearchInvokesFromViewsAndCategoriesAndRetainsTypingBindings|testTextSearchIsGlobalWithoutSavingViewAndEscapeRestoresSelection|testClearRemovesSearchAndOptionalExpressionWorks|testSemanticRankingDeduplicationAndCurrentRevisionAuthorization|testActualInspectorAliasNewlinesAndOverlaySmallScreenFocusStayVisible'


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
    receipt = json.loads((WORK / 'logs' / GUARD_NAME).read_text())
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
    save(WORK / 'logs' / GUARD_NAME, dict(
        session=session, sourceSHA256=hashlib.sha256((WORK / SOURCE_MANIFEST_NAME).read_bytes()).hexdigest(),
        issuedAt=time.time(), monitorPID=os.getpid(), state=state, capacity=sample, error=error))


def transient_walk_error(error, root=None):
    # SwiftPM removes its own temporary directories during this read-only accounting walk.
    # A vanished entry contributes no retained bytes; every other inspection failure is fatal.
    if isinstance(error, FileNotFoundError):
        if root is not None and Path(error.filename or root) == Path(root):
            raise error
        return
    raise error


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
    for path in (WORK,):
        if not path.exists():
            continue
        for directory, dirs, names in os.walk(path, followlinks=False, onerror=lambda error: transient_walk_error(error, path)):
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
        if not path.is_dir():
            raise RuntimeError('required accounting root disappeared: ' + str(path))
    if NATIVE_BASELINE is not None:
        growth = max(0, allocated_tree(REPO / '.build') - NATIVE_BASELINE)
        if growth > 512 * 1024**2:
            raise RuntimeError('warm native growth exceeds estimated 512MiB')
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
                'Packages/TractandaPeerTLSLinkGate', 'scripts/verify-peer-transport.py']
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
    old = WORK / SOURCE_MANIFEST_NAME
    if old.exists():
        previous = json.loads(old.read_text())
        for record in previous['files']:
            if record['path'].startswith('Packages/TractandaPeerTLSLinkGate/') or record['path'] == 'scripts/verify-peer-transport.py':
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
            original = REPO / 'work/peer-dependency-link-20261014/mirrors' / (pin['identity'] + '.git')
            if not original.is_dir():
                raise RuntimeError('exact cached dependency absent; no download: ' + pin['identity'])
            run(['git', 'init', '--bare', str(mirror)], 'prepare-init-' + pin['identity'], environment, 30)
            run(['git', '-C', str(mirror), 'fetch', '--depth=1', '--no-tags', str(original), pin['state']['revision']],
                'prepare-fetch-' + pin['identity'], environment, 60)
            run(['git', '-C', str(mirror), 'update-ref', 'refs/tags/' + pin['state']['version'],
                 pin['state']['revision']], 'prepare-tag-' + pin['identity'], environment, 30)
    return pins


def verify_snapshot():
    manifest = json.loads((WORK / SOURCE_MANIFEST_NAME).read_text())
    for record in manifest['files']:
        actual = SOURCE / record['path']
        if actual.is_symlink() or hashlib.sha256(actual.read_bytes()).hexdigest() != record['sha256']:
            raise RuntimeError('source snapshot changed: ' + record['path'])


def validate(name, environment, evidence_only=False):
    verify_snapshot()
    harness = SOURCE / 'Packages/TractandaPeerTLSLinkGate'
    if name == 'macos':
        return validate_native(environment, evidence_only)
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
        tested.write_bytes((WORK / SOURCE_MANIFEST_NAME).read_bytes())
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
    manifest_path = WORK / SOURCE_MANIFEST_NAME
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


def verify_guest_mounts(adapter=False):
    expected = {'/gate', '/source/Tractanda/Packages/TractandaPeerTLSLinkGate/.swiftpm'}
    if adapter:
        expected = {'/gate', '/source/Tractanda/.swiftpm'}
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
    save(WORK / 'logs' / (ADAPTER_STAGE + '-tested-mounts.json' if adapter else 'linux-tested-mounts.json'), rows)



def validate_native(environment, evidence_only=False):
    if evidence_only:
        status = json.loads((WORK / 'logs/macos-tests.status.json').read_text())
        if status.get('running') or status.get('exit') != 0:
            raise RuntimeError('evidence collection requires completed passing current tests')
    # Root .build is intentionally reused. Bound new growth plus genuine free space.
    environment = environment.copy()
    (WORK / 'native-tmp').mkdir(exist_ok=True)
    environment.update(TMPDIR=str(WORK / 'native-tmp'), CLANG_MODULE_CACHE_PATH=str(REPO / '.build/clang-module-cache'),
                       SWIFTPM_MODULECACHE_OVERRIDE=str(REPO / '.build/clang-module-cache'))
    before = allocated_tree(REPO / '.build')
    global NATIVE_BASELINE
    NATIVE_BASELINE = before
    tested = WORK / 'logs/macos-tested-source-manifest.json'
    if not evidence_only:
        tested.write_bytes((WORK / SOURCE_MANIFEST_NAME).read_bytes())
        run(['swift', '--version'], 'macos-toolchain', environment, 30)
        run(['swift', 'test', '--disable-sandbox', '--skip-update', '--jobs', '2', '--filter',
             'PeerTransportDependencyTests'], 'macos-tests', environment)
    verify_snapshot()
    for row in json.loads(tested.read_text())['files']:
        if row['path'] == 'scripts/verify-peer-transport.py':
            continue  # Evidence-only runner changed; compiled inputs must match exactly.
        if hashlib.sha256((REPO / row['path']).read_bytes()).hexdigest() != row['sha256']:
            raise RuntimeError('working source changed during native gate: ' + row['path'])
    candidates = list((REPO / '.build').glob('out/Products/Debug/TractandaPeerTransportTests.xctest/Contents/MacOS/TractandaPeerTransportTests'))
    if len(candidates) != 1:
        raise RuntimeError('expected one actual native test executable')
    run(['nm', '-g', str(candidates[0])], 'macos-symbols', environment, 60)
    symbols = (WORK / 'logs/macos-symbols.log').read_text()
    groups = {}
    for prefix in ('CCryptoBoringSSL_', 'CNIOBoringSSL_'):
        matched = sorted({parts[-1].lstrip('_') for line in symbols.splitlines()
                          if len(parts := line.split()) >= 3 and parts[-2].upper() != 'U'
                          and parts[-1].lstrip('_').startswith(prefix)})
        if not matched:
            raise RuntimeError('missing defined symbols: ' + prefix)
        groups[prefix] = dict(count=len(matched), examples=matched[:5])
    if 'RecordCodec' not in symbols:
        raise RuntimeError('actual Core symbol absent')
    save(WORK / 'logs/macos-evidence.json', dict(
        platform=platform.platform(), architecture=platform.machine(),
        binary=str(candidates[0]), binarySHA256=hashlib.sha256(candidates[0].read_bytes()).hexdigest(),
        symbols=groups, coreRecordCodec=True, capacity=capacity(),
        warmBuildInitialAllocated=before, warmBuildFinalAllocated=allocated_tree(REPO / '.build')))


def allocated_tree(root):
    total = 0
    before = root.stat()
    if not root.is_dir():
        raise RuntimeError('required accounting root is not a directory: ' + str(root))
    for directory, dirs, names in os.walk(root, followlinks=False, onerror=lambda error: transient_walk_error(error, root)):
        dirs[:] = [d for d in dirs if not (Path(directory) / d).is_symlink()]
        for name in names:
            try:
                info = (Path(directory) / name).lstat()
            except FileNotFoundError:
                continue
            total += info.st_blocks * 512
    after = root.stat()
    if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
        raise RuntimeError('required accounting root changed: ' + str(root))
    return total

NATIVE_BASELINE = None


def adapter_native(environment, compile_only, test_filter='PeerExchange|PeerPairing'):
    global NATIVE_BASELINE
    sample = capacity()
    if sample['available'] < RESERVE + 512 * 1024**2:
        raise RuntimeError('warm adapter build preestimate rejected')
    NATIVE_BASELINE = allocated_tree(REPO / '.build')
    files = source_files()
    manifest = dict(files=[dict(path=key, sha256=hashlib.sha256(path.read_bytes()).hexdigest())
                          for key, path in sorted(files.items())])
    if not test_filter or len(test_filter) > 512 or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_|' for c in test_filter):
        raise RuntimeError('invalid bounded native test filter')
    label = 'adapter-native-build' if compile_only else ('adapter-native-tests' if test_filter == 'PeerExchange|PeerPairing' else ('adapter-native-portability-tests' if test_filter == PORTABILITY_FILTER else ('adapter-native-uuid-tests' if test_filter == 'Version1UUIDTests' else 'adapter-native-regressions')))
    save(WORK / 'logs' / (label + '-source.json'), manifest)
    environment = environment.copy()
    environment.update(TMPDIR=str(WORK / 'native-tmp'),
                       CLANG_MODULE_CACHE_PATH=str(REPO / '.build/clang-module-cache'),
                       SWIFTPM_MODULECACHE_OVERRIDE=str(REPO / '.build/clang-module-cache'))
    command = ['swift', 'build' if compile_only else 'test', '--disable-sandbox', '--skip-update', '--jobs', '2']
    command += ['--target', 'TractandaPeerTransport'] if compile_only else ['--filter', test_filter]
    run(command, label, environment)
    for row in manifest['files']:
        if row['path'] != 'scripts/verify-peer-transport.py' and hashlib.sha256((REPO / row['path']).read_bytes()).hexdigest() != row['sha256']:
            raise RuntimeError('adapter compiled source changed during validation: ' + row['path'])



def adapter_linux_snapshot():
    global SOURCE
    capacity(initial=True)
    files = source_files()
    if sum(p.stat().st_size for p in files.values()) > 128 * 1024**2:
        raise RuntimeError('adapter source exceeds 128MiB estimate')
    # Actual compiled source must still equal the last native tested source. Runner is not compiled.
    native_name = 'adapter-native-portability-tests-source.json' if ADAPTER_STAGE.endswith('-v2') else 'adapter-native-tests-source.json'
    native = json.loads((WORK / 'logs' / native_name).read_text())
    for row in native['files']:
        if row['path'] != 'scripts/verify-peer-transport.py' and (row['path'] not in files or hashlib.sha256(files[row['path']].read_bytes()).hexdigest() != row['sha256']):
            raise RuntimeError('native tested source drift: ' + row['path'])
    SOURCE = WORK / ('adapter-source-v2/Tractanda' if ADAPTER_STAGE.endswith('-v2') else 'adapter-source/Tractanda')
    records = []
    for number, (relative, origin) in enumerate(sorted(files.items())):
        if number % 64 == 0:
            capacity()
        data = origin.read_bytes()
        target = SOURCE / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() and target.read_bytes() != data:
            raise RuntimeError('immutable adapter snapshot differs: ' + relative)
        if not target.exists():
            previous = WORK / 'adapter-source/Tractanda' / relative
            if ADAPTER_STAGE.endswith('-v2') and previous.is_file() and not previous.is_symlink() and previous.read_bytes() == data:
                shutil.copy2(previous, target)  # Same bytes/mtime retain warm compiler fingerprints.
            else:
                target.write_bytes(data)
        records.append(dict(path=relative, bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
    actual = {str(p.relative_to(SOURCE)) for p in SOURCE.rglob('*') if p.is_file() and '.swiftpm' not in p.relative_to(SOURCE).parts}
    if actual != set(files):
        raise RuntimeError('adapter snapshot file inventory differs')
    save(WORK / SOURCE_MANIFEST_NAME, dict(bytes=sum(r['bytes'] for r in records), files=records))
    verify_snapshot()


def adapter_linux_validate(environment):
    verify_snapshot()
    base = WORK / 'linux'
    for kind in ('scratch', 'cache', 'config', 'security', 'tmp', 'modules'):
        if not (base / kind).is_dir():
            raise RuntimeError('existing warm Linux cache missing: ' + kind)
    environment = environment.copy()
    environment.pop('SWIFTCI_USE_LOCAL_DEPS', None)
    environment.update(TMPDIR=str(base / 'tmp'), CLANG_MODULE_CACHE_PATH=str(base / 'modules'),
                       SWIFTPM_MODULECACHE_OVERRIDE=str(base / 'modules'))
    common = ['--package-path', str(SOURCE), '--disable-sandbox']
    for kind in ('scratch', 'cache', 'config', 'security'):
        common += ['--' + kind + '-path', str(base / kind)]
    pins = json.loads((SOURCE / 'Package.resolved').read_text())['pins']
    for pin in pins:
        run(['swift', 'package', *common, 'config', 'set-mirror', '--original', pin['location'],
             '--mirror', (WORK / 'mirrors' / (pin['identity'] + '.git')).as_uri()],
            ADAPTER_STAGE + '-mirror-' + pin['identity'], environment, 60)
    tested = WORK / 'logs' / (ADAPTER_STAGE + '-tested-source-manifest.json')
    tested.write_bytes((WORK / SOURCE_MANIFEST_NAME).read_bytes())
    run(['swift', '--version'], ADAPTER_STAGE + '-toolchain', environment, 30)
    run(['swift', 'test', *common, '--build-system', 'native', '--skip-update', '--jobs', '2',
         '--filter', ('PeerExchange|PeerPairing|' + PORTABILITY_FILTER if ADAPTER_STAGE.endswith('-v2') else 'PeerExchange|PeerPairing')], ADAPTER_STAGE + '-tests', environment, 1800)
    verify_snapshot()
    # Stop guest work after its validated test status. ELF inspection is host-only: no
    # further guest guard-receipt read can turn completed tests into an nm collection race.
    save(WORK / 'logs' / (ADAPTER_STAGE + '-guest-test-completed.json'), dict(
        platform=platform.platform(), architecture=platform.machine(), uid=os.getuid(),
        sourceManifestSHA256=hashlib.sha256(tested.read_bytes()).hexdigest()))


def adapter_expected_cases():
    files = {
        'PeerExchangeTests': 'Tests/TractandaPeerTransportTests/PeerExchangeTests.swift',
        'PeerExchangeBoundaryTests': 'Tests/TractandaCoreTests/PeerExchangeBoundaryTests.swift',
        'PeerExchangeCommitTests': 'Tests/TractandaCoreTests/PeerExchangeCommitTests.swift',
    }
    if ADAPTER_STAGE.endswith('-v2'):
        files['Version1UUIDTests'] = 'Tests/TractandaCoreTests/Version1UUIDTests.swift'
    expected = set()
    for name, relative in files.items():
        methods = re.findall(r'^\s+func (test[A-Za-z0-9_]+)\(', (SOURCE / relative).read_text(), re.M)
        if not methods or len(methods) != len(set(methods)):
            raise RuntimeError('invalid selected test declarations: ' + name)
        expected.update(name + '.' + method for method in methods)
    if ADAPTER_STAGE.endswith('-v2'):
        for method in PORTABILITY_FILTER.split('|')[1:]:
            name = 'CaptureApplicationTests' if method.startswith('testActualInspector') else 'ItemSearchTests'
            expected.add(name + '.' + method)
    return expected


def verify_adapter_test_result(status, output, expected):
    if status.get('running') is not False or type(status.get('exit')) is not int or status['exit'] != 0:
        raise RuntimeError('ELF collection requires completed passing test command')
    passed = ['.'.join(name.split('.')[-2:]) for name in re.findall(r"Test Case '([^']+)' passed", output)]
    summaries = re.findall(r'Executed ([0-9]+) tests, with ([0-9]+) failures', output)
    if not summaries or tuple(map(int, summaries[-1])) != (len(expected), 0):
        raise RuntimeError('test summary does not match selected suite')
    if set(passed) != expected or len(passed) != len(expected) or re.search(r"Test Case '[^']+' failed", output):
        raise RuntimeError('selected test methods are incomplete, repeated or failed')


def combined_symbol_groups(symbols):
    groups = {}
    for prefix in ('CCryptoBoringSSL_', 'CNIOBoringSSL_'):
        found = {v[-1].lstrip('_') for line in symbols.splitlines() if len(v := line.split()) >= 3 and
                 v[-2].upper() != 'U' and v[-1].lstrip('_').startswith(prefix)}
        if not found:
            raise RuntimeError('missing defined combined root adapter prefix: ' + prefix)
        groups[prefix] = len(found)
    if 'RecordCodec' not in symbols or 'PeerExchange' not in symbols:
        raise RuntimeError('actual Core/PeerExchange symbols missing')
    return groups


def collect_adapter_host_evidence(environment):
    if GUEST_SESSION is not None:
        raise RuntimeError('adapter ELF collection must run on host')
    capacity()
    verify_snapshot()
    tested = WORK / 'logs' / (ADAPTER_STAGE + '-tested-source-manifest.json')
    if tested.read_bytes() != (WORK / SOURCE_MANIFEST_NAME).read_bytes():
        raise RuntimeError('tested source manifest differs from frozen snapshot')
    status = json.loads((WORK / 'logs' / (ADAPTER_STAGE + '-tests.status.json')).read_text())
    output = (WORK / 'logs' / (ADAPTER_STAGE + '-tests.log')).read_text()
    expected = adapter_expected_cases()
    verify_adapter_test_result(status, output, expected)
    candidates = [p for p in (WORK / 'linux/scratch').rglob('TractandaPackageTests.xctest')
                  if p.is_file() and not p.is_symlink() and p.open('rb').read(4) == b'\x7fELF']
    if len(candidates) != 1 or not candidates[0].resolve().is_relative_to(WORK.resolve()):
        raise RuntimeError('expected one owned actual Linux adapter test ELF')
    binary = candidates[0]
    original_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
    nm = shutil.which('nm')
    if not nm:
        raise RuntimeError('host LLVM nm unavailable; no guest collector fallback')
    run([nm, '-g', str(binary)], ADAPTER_STAGE + '-host-symbols', environment, 60)
    groups = combined_symbol_groups((WORK / 'logs' / (ADAPTER_STAGE + '-host-symbols.log')).read_text())
    verify_snapshot()
    if hashlib.sha256(binary.read_bytes()).hexdigest() != original_hash:
        raise RuntimeError('tested ELF changed during readonly collection')
    manifest = json.loads(tested.read_text())
    guest_driver = next(v['sha256'] for v in manifest['files'] if v['path'] == 'scripts/verify-peer-transport.py')
    host_status = json.loads((WORK / 'logs' / (ADAPTER_STAGE + '-host.status.json')).read_text())
    current_driver = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    original_driver_file = WORK / 'logs' / (ADAPTER_STAGE + '-host-driver.json')
    if not original_driver_file.exists():
        original_driver_file = WORK / 'logs' / (ADAPTER_STAGE + '-node-retry-driver.json')
    original_driver = json.loads(original_driver_file.read_text())['hostRunnerSHA256'] if original_driver_file.exists() else None
    result = dict(
        scope='readonly host collection of already-tested frozen Linux adapter; no test rerun',
        tests=len(expected), failures=0, selectedMethods=sorted(expected), testCommandExit=status['exit'],
        testRunnerSeconds=status['seconds'], originalHostWrapperExit=host_status['exit'],
        binary=str(binary), binarySHA256=original_hash, symbols=groups,
        sourceManifestSHA256=hashlib.sha256(tested.read_bytes()).hexdigest(),
        testedFrozenGuestDriverSHA256=guest_driver,
        testedOriginalHostDriverSHA256=original_driver,
        currentReadonlyHostCollectorSHA256=current_driver,
        currentCollectorMatchesFrozenGuestDriver=current_driver == guest_driver,
        currentCollectorMatchesOriginalHostDriver=current_driver == original_driver, productOrTestMutation=False,
        testRerunForCollection=False, capacity=capacity())
    save(WORK / 'logs' / (ADAPTER_STAGE + '-host-evidence.json'), result)
    return result


def adapter_linux_host(environment, frozen_node_retry=False):
    global SOURCE
    node = None
    if frozen_node_retry:
        SOURCE = WORK / 'adapter-source-v2/Tractanda'
        verify_snapshot()
        archived = WORK / 'logs/adapter-linux-v2-node-unavailable'
        archived.mkdir(exist_ok=False)
        for prior in (WORK / 'logs').glob('adapter-linux-v2-*'):
            if prior.is_file():
                shutil.copy2(prior, archived / prior.name)
        proof = json.loads((WORK / 'logs/adapter-linux-complete-etc-preflight.json').read_text())
        if proof.get('exit') != 0 or not json.loads(proof['stdout']).get('passed'):
            raise RuntimeError('complete readonly etc/NSS preflight has not passed')
        overlay = WORK / 'linux/etc-overlay'
        if overlay.is_symlink() or not overlay.resolve().is_relative_to(WORK.resolve()):
            raise RuntimeError('etc overlay escapes owned work')
        overlay_manifest = json.loads((WORK / 'logs/adapter-linux-complete-etc-overlay.json').read_text())
        for row in overlay_manifest['entries']:
            path = overlay / row['path']
            if row['type'] == 'file' and (path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != row.get('overlaySHA256', row['sha256'])):
                raise RuntimeError('etc overlay file differs: ' + row['path'])
            if row['type'] == 'symlink' and (not path.is_symlink() or os.readlink(path) != row['target']):
                raise RuntimeError('etc overlay link differs: ' + row['path'])
        node_receipt = json.loads((WORK / 'logs/host-uuid-node-for-peer-tests.json').read_text())
        node = node_receipt['selected']['node']
        compact = node.replace(':', '')
        if len(compact) != 12 or int(compact, 16) == 0 or int(compact[:2], 16) & 3:
            raise RuntimeError('invalid real host hardware node receipt')
        save(WORK / 'logs/adapter-linux-v2-node-retry-driver.json', dict(
            hostRunnerSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            frozenGuestRunnerSHA256=hashlib.sha256((SOURCE / 'scripts/verify-peer-transport.py').read_bytes()).hexdigest(),
            nodeReceiptSHA256=hashlib.sha256((WORK / 'logs/host-uuid-node-for-peer-tests.json').read_bytes()).hexdigest(),
            childEnvironmentOnly=True, globallyConfigured=False, sourceMutation=False,
            completeEtcOverlaySHA256=hashlib.sha256((WORK / 'logs/adapter-linux-complete-etc-overlay.json').read_bytes()).hexdigest(),
            completeEtcPreflightSHA256=hashlib.sha256((WORK / 'logs/adapter-linux-complete-etc-preflight.json').read_bytes()).hexdigest()))
    else:
        adapter_linux_snapshot()
    info = json.loads(subprocess.check_output([RUNTIME, 'image', 'inspect', IMAGE], timeout=30))
    if info[0]['configuration']['descriptor']['digest'] != IMAGE_DIGEST:
        raise RuntimeError('cached image differs; no pull allowed')
    for variant in info[0].get('variants', []):
        if variant.get('config', {}).get('config', {}).get('Volumes'):
            raise RuntimeError('unaccounted image volumes')
    (SOURCE / '.swiftpm').mkdir(exist_ok=True)
    metadata = WORK / 'linux/root-package-metadata'
    metadata.mkdir(exist_ok=True)
    for path in (WORK, SOURCE.parent, metadata):
        if path.is_symlink() or not path.resolve().is_relative_to(WORK.resolve()):
            raise RuntimeError('adapter mount escapes owned work')
    session = uuid.uuid4().hex
    source_sha = hashlib.sha256((WORK / SOURCE_MANIFEST_NAME).read_bytes()).hexdigest()
    save(WORK / 'logs' / (ADAPTER_STAGE + '-write-layout.json'), dict(
        rootReadOnly=True, sourceReadOnly=True, configuredWritable=[str(WORK), str(metadata)],
        existingWarmScratch=str(WORK / 'linux/scratch'), newImageDownloads=False,
        cpus=2, memory='3G', cap=CAP, runtimeAllowance=ALLOWANCE, reserve=RESERVE,
        sourceSHA256=source_sha, source=str(SOURCE)))
    command = [RUNTIME, 'run', '--rm', '--progress', 'none', '--name', CONTAINER,
               '--read-only', '--uid', str(os.getuid()), '--gid', str(os.getgid()),
               '--cpus', '2', '--memory', '3G', '--no-dns',
               *(['--env', 'TRACTANDA_UUID_NODE=' + node] if node else []),
               *(['--mount', f'type=bind,source={WORK / "linux/etc-overlay"},target=/etc,readonly'] if frozen_node_retry else []),
               '--mount', f'type=bind,source={WORK},target=/gate',
               '--mount', f'type=bind,source={SOURCE.parent},target=/source,readonly',
               '--mount', f'type=bind,source={metadata},target=/source/Tractanda/.swiftpm',
               '--workdir', '/source/Tractanda', '--entrypoint', '/usr/bin/python3', IMAGE,
               '/source/Tractanda/scripts/verify-peer-transport.py', '--platform', 'linux', '--guest',
               '--adapter-linux', *(['--adapter-linux-retry'] if ADAPTER_STAGE.endswith('-v2') else []), '--guard-session', session, '--guard-source', source_sha]
    save(WORK / 'logs' / (ADAPTER_STAGE + '-host-driver.json'), dict(
        hostRunnerSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        frozenGuestRunnerSHA256=hashlib.sha256((SOURCE / 'scripts/verify-peer-transport.py').read_bytes()).hexdigest(),
        sourceManifestSHA256=source_sha))
    run(command, ADAPTER_STAGE + '-host', environment, 1800,
        [RUNTIME, 'stop', CONTAINER], monitor_session=session)
    collect_adapter_host_evidence(environment)


def main():
    global WORK, SOURCE, GUEST_SESSION, GUARD_SOURCE, CAP, SOURCE_MANIFEST_NAME, GUARD_NAME, ADAPTER_STAGE
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=('macos', 'linux'), required=True)
    parser.add_argument('--guest', action='store_true')
    parser.add_argument('--adapter-native', action='store_true')
    parser.add_argument('--adapter-linux', action='store_true')
    parser.add_argument('--adapter-linux-retry', action='store_true')
    parser.add_argument('--adapter-linux-node-retry', action='store_true')
    parser.add_argument('--adapter-linux-collect-only', action='store_true')
    parser.add_argument('--compile-only', action='store_true')
    parser.add_argument('--test-filter', default='PeerExchange|PeerPairing')
    parser.add_argument('--frozen-snapshot', action='store_true')
    parser.add_argument('--guard-session')
    parser.add_argument('--guard-source')
    parser.add_argument('--evidence-only', action='store_true', help='Inspect an unchanged already-passing binary, without another test run')
    args = parser.parse_args()
    environment = os.environ.copy()
    if args.adapter_linux:
        if args.platform != 'linux' or args.adapter_native or args.frozen_snapshot or args.evidence_only:
            raise RuntimeError('invalid adapter Linux stage options')
        CAP = 4 * 1024**3  # Explicit root-approved full-root adapter build cap; reserve unchanged.
        ADAPTER_STAGE = 'adapter-linux-v2' if args.adapter_linux_retry else 'adapter-linux'
        SOURCE_MANIFEST_NAME = ADAPTER_STAGE + '-source-manifest.json'
        GUARD_NAME = ADAPTER_STAGE + '-host-guard.json'
        if args.guest:
            if platform.system() != 'Linux' or os.getuid() == 0 or not args.guard_session or not args.guard_source:
                raise RuntimeError('adapter guest requires non-root Linux and host receipt')
            WORK = Path('/gate')
            SOURCE = Path('/source/Tractanda')
            GUEST_SESSION, GUARD_SOURCE = args.guard_session, args.guard_source
            capacity()
            verify_guest_mounts(adapter=True)
            adapter_linux_validate(environment)
        else:
            if args.adapter_linux_collect_only:
                SOURCE = WORK / ('adapter-source-v2/Tractanda' if args.adapter_linux_retry else 'adapter-source/Tractanda')
                collect_adapter_host_evidence(environment)
                return
            if args.adapter_linux_node_retry and not args.adapter_linux_retry:
                raise RuntimeError('host node retry requires frozen v2 stage')
            adapter_linux_host(environment, args.adapter_linux_node_retry)
        return
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
    if args.adapter_native:
        if args.platform != 'macos' or args.guest:
            raise RuntimeError('adapter native is host macOS only')
        adapter_native(environment, args.compile_only, args.test_filter)
        return
    capacity(initial=True)
    WORK.mkdir(parents=True, exist_ok=True)
    if args.frozen_snapshot:
        if args.platform != 'linux' or args.evidence_only:
            raise RuntimeError('frozen continuation is the bounded Linux gate only')
        raise RuntimeError('historical continuation is not valid for current source gate')
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
        (SOURCE / 'Packages/TractandaPeerTLSLinkGate/.swiftpm').mkdir(exist_ok=True)
        metadata = WORK / 'linux/package-metadata'
        metadata.mkdir(parents=True, exist_ok=True)
        for path in (WORK, WORK / 'source', metadata):
            if path.is_symlink() or not path.resolve().is_relative_to(WORK.resolve()):
                raise RuntimeError('mount escapes the owned work root')
        session = uuid.uuid4().hex  # Transient guard-run identity, never a pairing credential.
        prior = WORK / 'logs' / GUARD_NAME
        if prior.exists():
            old = json.loads(prior.read_text())
            save(WORK / 'logs' / ('linux-host-guard-' + old['session'] + '.json'), old)
        source_sha = hashlib.sha256((WORK / SOURCE_MANIFEST_NAME).read_bytes()).hexdigest()
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
                   '/source/Tractanda/scripts/verify-peer-transport.py', '--platform', 'linux', '--guest', '--guard-session', session, '--guard-source', source_sha]
        run(command, 'linux-host', environment, 2400, [RUNTIME, 'stop', CONTAINER], monitor_session=session)
    print(json.dumps(dict(phase='complete', platform=args.platform, capacity=capacity())), flush=True)


if __name__ == '__main__':
    main()
