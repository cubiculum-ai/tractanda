#!/usr/bin/env python3
"""Immutable current-B2 Linux gate using the retained, bounded peer warm cache."""
import argparse
import contextlib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import time
import stat
import subprocess
import uuid

SPEC = importlib.util.spec_from_file_location('peer_gate', Path(__file__).with_name('verify-peer-transport.py'))
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)
REPO = Path(__file__).resolve().parents[1]
MAC_RECEIPT = 'outputs/verification/cluster-2026-10-16/peer-document-transfer-verification.json'
MAC_RECEIPT_SHA = '927c07aeba05bb51c2bbe6159ee9f56e8e793108f90aa3158da3ae979e384ccb'
MAC_SOURCE = 'work/shared-authority-20261015/logs/peer-document-b2-consumers98-source.json'
MAC_SOURCE_SHA = '3c79edd15a6fcbe20255f30bc4561bd2ddf308aa35761bdefd885bee12bab2d9'
OWNED = 'outputs/verification/cluster-2026-10-16/peer-document-transfer-final-files.json'
OWNED_SHA = '779b3d878b7ad7341e7841888b3025bac2aee7c181992c3bed1eca8413b13253'
SELF = 'scripts/verify-cluster-linux.py'
FIXTURE_CAP = 128 * 1024**2
GROWTH_ESTIMATE = 1024**3
SOURCE_LIMIT = 128 * 1024**2
DEFAULT_TIMEOUT_SECONDS = 24 * 60 * 60
MAX_TIMEOUT_SECONDS = 7 * 24 * 60 * 60
MIN_CLEANUP_HEADROOM_SECONDS = 120
MAX_CLEANUP_HEADROOM_SECONDS = 60 * 60
DEPENDENCY_CASES = [
    'TractandaPeerTransportTests.PeerTransportDependencyTests.' + name for name in (
        'testRealCoreRecordCodec', 'testCryptoExtrasForcesCCryptoBoringSSL',
        'testTwoFreshHybridPSKSessionsProtectCoreBytes', 'testWrongSecretExplicitlyRejectsWithoutHandoff')]
BASE_CAPACITY = GATE.capacity
LABEL = None
FIXTURES = None
LOGS = None
OPERATION_TIMEOUT_SECONDS = DEFAULT_TIMEOUT_SECONDS
COMMAND_TIMEOUT_SECONDS = DEFAULT_TIMEOUT_SECONDS
OPERATION_DEADLINE = None


def positive_timeout_seconds(value):
    try:
        seconds = int(value)
    except (TypeError, ValueError) as error:
        raise argparse.ArgumentTypeError('timeout must be a finite positive integer number of seconds') from error
    if seconds <= 0 or seconds > MAX_TIMEOUT_SECONDS:
        raise argparse.ArgumentTypeError(f'timeout must be between 1 and {MAX_TIMEOUT_SECONDS} seconds')
    return seconds


def cleanup_headroom(timeout_seconds):
    return max(MIN_CLEANUP_HEADROOM_SECONDS,
               min(MAX_CLEANUP_HEADROOM_SECONDS, timeout_seconds // 100))


def timeout_budgets(timeout_seconds):
    if not 1 <= timeout_seconds <= MAX_TIMEOUT_SECONDS:
        raise ValueError('operation timeout is invalid')
    cleanup = cleanup_headroom(timeout_seconds)
    return {'operationSeconds': timeout_seconds, 'cleanupHeadroomSeconds': cleanup,
            'ownerSeconds': timeout_seconds + cleanup}


def effective_command_timeout(timeout_seconds, command_timeout_seconds):
    if not 1 <= timeout_seconds <= MAX_TIMEOUT_SECONDS or not 1 <= command_timeout_seconds <= MAX_TIMEOUT_SECONDS:
        raise ValueError('operation/command timeout is invalid')
    return min(timeout_seconds, command_timeout_seconds)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def checked_json(path, expected):
    if path.is_symlink() or sha(path) != expected:
        raise RuntimeError('frozen evidence differs: ' + str(path))
    return json.loads(path.read_text())


def capacity(initial=False):
    if OPERATION_DEADLINE is not None and time.monotonic() >= OPERATION_DEADLINE:
        raise RuntimeError('whole native validation operation deadline exceeded')
    sample = BASE_CAPACITY(initial)
    if FIXTURES and FIXTURES.exists():
        used = GATE.allocated_tree(FIXTURES)
        if used > FIXTURE_CAP:
            raise RuntimeError('fixture cap exceeded: ' + str(used))
        sample['fixtureAllocated'] = used
    return sample


def configure(label, guest=False, session=None, source_sha=None, timeout_seconds=DEFAULT_TIMEOUT_SECONDS,
              command_timeout_seconds=DEFAULT_TIMEOUT_SECONDS):
    global LABEL, FIXTURES, LOGS, OPERATION_TIMEOUT_SECONDS, COMMAND_TIMEOUT_SECONDS, OPERATION_DEADLINE
    if not re.fullmatch(r'cluster-b2-20261016(?:-[a-z0-9]{1,24})?', label):
        raise RuntimeError('invalid bounded current-B2 run label')
    command_timeout_seconds = effective_command_timeout(timeout_seconds, command_timeout_seconds)
    LABEL = label
    OPERATION_TIMEOUT_SECONDS = timeout_seconds
    COMMAND_TIMEOUT_SECONDS = command_timeout_seconds
    OPERATION_DEADLINE = None
    GATE.CAP = 4 * 1024**3
    GATE.SOURCE_MANIFEST_NAME = label + '-source-manifest.json'
    GATE.GUARD_NAME = label + '-host-guard.json'
    GATE.ADAPTER_STAGE = label
    GATE.WORK = Path('/gate') if guest else REPO / 'work/peer-transport-20261015'
    GATE.SOURCE = Path('/source/Tractanda') if guest else GATE.WORK / (label + '-source/Tractanda')
    GATE.GUEST_SESSION, GATE.GUARD_SOURCE = session, source_sha
    FIXTURES = GATE.WORK / 'linux' / (label + '-fixtures')
    LOGS = Path('/current-logs') if guest else GATE.WORK / 'logs' / (label + '-run')
    GATE.capacity = capacity


def log(name):
    return LOGS / (LABEL + '-' + name)



def host_receipt(session, sample, state='running', error=None):
    GATE.save(LOGS / GATE.GUARD_NAME, dict(session=session,
        sourceSHA256=sha(GATE.WORK / GATE.SOURCE_MANIFEST_NAME), issuedAt=time.time(),
        monitorPID=os.getpid(), state=state, capacity=sample, error=error))


def guest_capacity():
    receipt = json.loads((LOGS / GATE.GUARD_NAME).read_text())
    if receipt.get('session') != GATE.GUEST_SESSION or receipt.get('sourceSHA256') != GATE.GUARD_SOURCE:
        raise RuntimeError('host guard receipt session/source mismatch')
    if receipt.get('state') != 'running' or not -5 <= time.time() - receipt['issuedAt'] <= GATE.RECEIPT_MAX_AGE:
        raise RuntimeError('host guard is stopped, stale or clock-inconsistent')
    sample = receipt['capacity']
    for key, value in [('cap', GATE.CAP), ('runtimeAllowance', GATE.ALLOWANCE), ('reserve', GATE.RESERVE)]:
        if type(sample.get(key)) is not int or sample[key] != value:
            raise RuntimeError('host guard limit mismatch')
    for key in ('available', 'allocated'):
        if type(sample.get(key)) is not int or sample[key] < 0:
            raise RuntimeError('invalid host guard accounting')
    fs = os.statvfs(GATE.WORK)
    if fs.f_frsize <= 0 or fs.f_bavail < 0:
        raise RuntimeError('guest bind filesystem capacity unavailable')
    sample['available'] = min(sample['available'], fs.f_bavail * fs.f_frsize)
    if sample['available'] < GATE.RESERVE or sample['allocated'] + GATE.ALLOWANCE > GATE.CAP:
        raise RuntimeError('host/guest capacity rejected')
    return sample


GATE.guest_capacity = guest_capacity


def run(command, label, environment, timeout=None, cleanup=None, monitor_session=None, separate_stderr=False):
    timeout = COMMAND_TIMEOUT_SECONDS if timeout is None else timeout
    initial = capacity()
    logs = LOGS
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
            diagnostics = logs / (label + '.stderr.log')
            if diagnostics.exists():
                diagnostics.replace(logs / (label + f'.failed{attempt}.stderr.log'))
    result = dict(command=list(map(str, command)), running=True, initial=initial)
    GATE.save(state, result)
    started = time.monotonic()
    process = None
    try:
        if monitor_session:
            host_receipt(monitor_session, initial)
        diagnostics = (logs / (label + '.stderr.log')).open('wb') if separate_stderr else contextlib.nullcontext(None)
        with (logs / (label + '.log')).open('wb') as output, diagnostics as errors:
            process = subprocess.Popen(command, cwd=REPO, env=environment, stdout=output,
                                       stderr=errors if separate_stderr else subprocess.STDOUT, start_new_session=True)
            result['separateStderr'] = separate_stderr
            result['pid'] = process.pid
            GATE.save(state, result)
            while process.poll() is None:
                result['latest'] = capacity()
                if monitor_session:
                    host_receipt(monitor_session, result['latest'])
                result['seconds'] = round(time.monotonic() - started, 2)
                GATE.save(state, result)
                if time.monotonic() - started > timeout:
                    raise RuntimeError('owned child exceeded validation deadline')
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    pass
            if time.monotonic() - started >= timeout:
                raise RuntimeError('owned child exceeded validation deadline')
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
            GATE.save(state, result)  # Original failure precedes cleanup.
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
        GATE.save(state, result)
    print(json.dumps({k: result.get(k) for k in ('pid', 'exit', 'seconds', 'final', 'failure')},
                     default=str), label, flush=True)
    if result['exit']:
        raise RuntimeError('validation failed: ' + label)


def verify_guest_mounts():
    expected = {'/current-logs', '/source/Tractanda/.swiftpm', str(FIXTURES)}
    expected.update('/gate/linux/' + kind for kind in ('scratch', 'cache', 'config', 'security', 'tmp', 'modules'))
    pseudo = {'proc', 'sysfs', 'devtmpfs', 'devpts', 'tmpfs', 'cgroup', 'cgroup2', 'mqueue'}
    rows, seen, readonly = [], set(), set()
    for line in Path('/proc/self/mountinfo').read_text().splitlines():
        before, after = line.split(' - ', 1)
        fields = before.split()
        target, options, kind = fields[4], fields[5].split(','), after.split()[0]
        if target in {'/', '/source', '/gate', '/etc'}:
            if 'ro' not in options:
                raise RuntimeError('required root/source/warm-root/etc mount is writable: ' + target)
            readonly.add(target)
        if 'rw' in options and kind not in pseudo and target not in expected:
            raise RuntimeError('unaccounted persistent writable mount: ' + target)
        if target in expected:
            if 'rw' not in options:
                raise RuntimeError('expected writable cache mount is read-only: ' + target)
            seen.add(target)
        rows.append(dict(target=target, filesystem=kind, options=options))
    if seen != expected or readonly != {'/', '/source', '/gate', '/etc'}:
        raise RuntimeError('required writable or read-only mount is absent')
    GATE.save(log('tested-mounts.json'), rows)



def checked_selection(receipt):
    cases = receipt['coverage']['latestCases']
    ids = sorted(x['id'] for x in cases)
    if len(ids) != 112 or len(set(ids)) != 112 or any(x['outcome'] != 'passed' for x in cases):
        raise RuntimeError('final Mac receipt does not describe 112 distinct passing IDs')
    ids += DEPENDENCY_CASES
    ids.sort()
    if len(ids) != 116 or len(set(ids)) != 116:
        raise RuntimeError('selection must contain exactly 116 distinct IDs')
    if any(not re.fullmatch(r'[A-Za-z0-9_]+\.[A-Za-z0-9_]+\.test[A-Za-z0-9_]+', v) for v in ids):
        raise RuntimeError('noncanonical selected XCTest ID')
    # SwiftPM matches Module.Class/method, while XCTest prints Module.Class.method.
    test_filter = '^(?:' + '|'.join(re.escape(v.rsplit('.', 1)[0]) + '/' + v.rsplit('.', 1)[1] for v in ids) + ')$'
    return ids, test_filter


def verify_snapshot():
    GATE.verify_snapshot()
    records = json.loads((GATE.WORK / GATE.SOURCE_MANIFEST_NAME).read_text())['files']
    actual = {str(p.relative_to(GATE.SOURCE)) for p in GATE.SOURCE.rglob('*')
              if p.is_file() and '.swiftpm' not in p.relative_to(GATE.SOURCE).parts}
    if actual != {r['path'] for r in records}:
        raise RuntimeError('immutable source inventory differs')


def verify_results(status, output, ids):
    names = {'.'.join(v.split('.')[-2:]) for v in ids}
    if len(names) != len(ids):
        raise RuntimeError('selected runtime has duplicate or module-ambiguous methods')
    if re.search(r"Test Case '[^']+' skipped|Executed \d+ tests?, with \d+ tests? skipped", output):
        raise RuntimeError('selected runtime contains skipped tests')
    # XCTest uses the singular only for one executed case; preserve its exact
    # count/events while adapting that spelling to the established verifier.
    output = re.sub(r'Executed 1 test, with 0 failures\b', 'Executed 1 tests, with 0 failures', output)
    GATE.verify_adapter_test_result(status, output, names)


def freeze():
    initial = capacity(initial=True)
    manifest = GATE.WORK / GATE.SOURCE_MANIFEST_NAME
    if manifest.exists() or GATE.SOURCE.parent.exists() or log('host.status.json').exists():
        raise RuntimeError('run label already exists; preserve it and use an explicit new label')
    receipt = checked_json(REPO / MAC_RECEIPT, MAC_RECEIPT_SHA)
    mac = checked_json(REPO / MAC_SOURCE, MAC_SOURCE_SHA)['files']
    owned = checked_json(REPO / OWNED, OWNED_SHA)['files']
    files = GATE.source_files()
    baseline = {r['path']: r['sha256'] for r in mac}
    current = {p: sha(v) for p, v in files.items()}
    if len(mac) != 1160 or current != baseline:
        raise RuntimeError('current 1160 inputs differ from final Mac compiled source')
    swift_owned = [r for r in owned if r['path'].endswith('.swift')]
    if len(swift_owned) != 40 or any(current.get(r['path']) != r['sha256'] for r in swift_owned):
        raise RuntimeError('owned 40 Swift inputs differ from final freeze')
    files[SELF] = REPO / SELF
    source_bytes = sum(p.stat().st_size for p in files.values())
    if source_bytes > SOURCE_LIMIT:
        raise RuntimeError('current snapshot exceeds 128MiB cap')
    # Includes full bounded incremental rebuild estimate, snapshot, and small evidence overhead.
    estimate = GROWTH_ESTIMATE + source_bytes + 16 * 1024**2
    if initial['available'] - estimate < GATE.RESERVE or initial['allocated'] + estimate + GATE.ALLOWANCE > GATE.CAP:
        raise RuntimeError('estimated current-source warm growth rejected')
    ids, test_filter = checked_selection(receipt)
    records = []
    for number, (relative, origin) in enumerate(sorted(files.items())):
        if number % 64 == 0:
            capacity()
        target = GATE.SOURCE / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        previous = GATE.WORK / 'adapter-source-v2/Tractanda' / relative
        if previous.is_file() and not previous.is_symlink() and sha(previous) == sha(origin):
            shutil.copy2(previous, target)  # Preserve matching warm compiler source fingerprints.
        else:
            shutil.copy2(origin, target)
        records.append(dict(path=relative, bytes=origin.stat().st_size, sha256=sha(origin)))
    GATE.save(manifest, dict(bytes=source_bytes, files=records, macCompiledSourceSHA256=MAC_SOURCE_SHA,
                             currentMacInputCount=1160, extraNoncompiledInputs=[SELF]))
    verify_snapshot()
    GATE.save(log('selection.json'), dict(ids=ids, testFilter=test_filter, macReceiptSHA256=MAC_RECEIPT_SHA))
    GATE.save(log('preflight.json'), dict(initial=initial, sourceBytes=source_bytes,
        estimatedAdditionalBytes=estimate, warmBuildGrowthEstimateBytes=GROWTH_ESTIMATE,
        sourceCap=SOURCE_LIMIT, fixtureCap=FIXTURE_CAP, ownedSwiftMatches=40,
        macInputsMatch=1160, mutableWarmCache=str(GATE.WORK / 'linux'), noColdCopy=True))


def overlay_check(root, rows):
    expected = set()
    for row in rows:
        relative = Path(row['path'])
        if relative.is_absolute() or '..' in relative.parts:
            raise RuntimeError('unsafe etc manifest path')
        p = root / relative
        info = p.lstat()
        expected.add(str(relative))
        if stat.S_IMODE(info.st_mode) != row['mode']:
            raise RuntimeError('etc mode differs: ' + str(relative))
        if row['type'] == 'file':
            if not stat.S_ISREG(info.st_mode) or sha(p) != row.get('overlaySHA256', row['sha256']):
                raise RuntimeError('etc bytes differ: ' + str(relative))
        elif row['type'] == 'symlink':
            if not stat.S_ISLNK(info.st_mode) or os.readlink(p) != row['target']:
                raise RuntimeError('etc symlink differs: ' + str(relative))
        elif row['type'] != 'directory' or not stat.S_ISDIR(info.st_mode):
            raise RuntimeError('etc type differs: ' + str(relative))
    actual = {str((Path(d) / n).relative_to(root)) for d, dirs, names in os.walk(root, followlinks=False) for n in dirs + names}
    if actual != expected:
        raise RuntimeError('etc inventory differs')


def checked_node():
    receipt_path = GATE.WORK / 'logs/host-uuid-node-for-peer-tests.json'
    node = json.loads(receipt_path.read_text())['selected']['node']
    if not re.fullmatch(r'(?:[0-9a-f]{2}:){5}[0-9a-f]{2}', node) or int(node.replace(':', ''), 16) == 0 or int(node[:2], 16) & 3:
        raise RuntimeError('real host node receipt is invalid')
    return node


def owned_child_probe(root):
    target = root / ('.tractanda-owner-probe-' + GATE.GUEST_SESSION)
    descriptor = None
    created = False
    try:
        descriptor = os.open(target, os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        created = True
        info = os.fstat(descriptor)
        result = dict(root=str(root), path=str(target), uid=info.st_uid, gid=info.st_gid,
            mode=stat.S_IMODE(info.st_mode), regular=stat.S_ISREG(info.st_mode))
        if not result['regular'] or (info.st_uid, info.st_gid, result['mode']) != (1001, 20, 0o600):
            raise RuntimeError('actual child ownership/mode mismatch: ' + json.dumps(result))
        payload = b'0123456789abcdef'
        if os.write(descriptor, payload) != len(payload):
            raise RuntimeError('short ownership probe write')
        os.fsync(descriptor)
        os.lseek(descriptor, 0, os.SEEK_SET)
        if os.read(descriptor, len(payload) + 1) != payload:
            raise RuntimeError('ownership probe readback mismatch')
        result.update(bytes=len(payload), writeReadFsync=True)
        return result
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if created:
            target.unlink()  # Cleanup failure fails the gate; never hide leaked fixture bytes.


def guest_identity():
    import grp
    import pwd
    if platform.system() != 'Linux' or os.getuid() == 0:
        raise RuntimeError('guest must be non-root Linux')
    verify_guest_mounts()
    rows = json.loads((GATE.WORK / 'logs/adapter-linux-complete-etc-overlay.json').read_text())['entries']
    overlay_check(Path('/etc'), rows)
    user, group = pwd.getpwuid(os.getuid()), grp.getgrgid(os.getgid())
    if (os.getuid(), os.getgid(), user.pw_name, user.pw_gid, user.pw_dir, user.pw_shell, group.gr_name) != (
            1001, 20, 'tractanda_test', 20, '/gate/linux/tmp', '/usr/sbin/nologin', 'dialout') or any(g != 20 for g in os.getgroups()):
        raise RuntimeError('guest fixture identity differs from approved NSS overlay')
    if os.environ.get('TRACTANDA_UUID_NODE') != checked_node():
        raise RuntimeError('guest real-node environment differs from receipt')
    fixture_fs = os.statvfs(FIXTURES)
    available = fixture_fs.f_bavail * fixture_fs.f_frsize
    if fixture_fs.f_frsize <= 0 or fixture_fs.f_bavail < 0 or available < GATE.RESERVE:
        raise RuntimeError('fixture filesystem does not preserve actual capacity reserve')
    layout = json.loads(log('write-layout.json').read_text())
    mapping = layout['hostFilesystemMappings']
    if not mapping or any(v['hostDevice'] != layout['hostWorkDevice'] or
            (v['hostUID'], v['hostGID']) != (1001, 20) for v in mapping):
        raise RuntimeError('host fixture/cache filesystem mapping mismatch')
    mounts = {v['target']: v for v in json.loads(log('tested-mounts.json').read_text())}
    fixture_mount = mounts.get(str(FIXTURES))
    if not fixture_mount or fixture_mount['filesystem'] != 'virtiofs':
        raise RuntimeError('fixture filesystem is not the approved persistent host export')
    paths, probes = {}, []
    for export in mapping:
        p = Path(export['guestPath'])
        info = p.stat()
        mounted = mounts.get(str(p))
        paths[str(p)] = dict(uid=info.st_uid, gid=info.st_gid, device=info.st_dev,
            mode=stat.S_IMODE(info.st_mode), effectiveWritable=os.access(p, os.W_OK, effective_ids=True))
        if not mounted or mounted['filesystem'] != 'virtiofs' or 'rw' not in mounted['options'] or \
                (info.st_uid, info.st_gid) not in {(1001, 20), (0, 0)} or not paths[str(p)]['effectiveWritable']:
            raise RuntimeError('unexpected scoped writable export mapping: ' + json.dumps(paths[str(p)]))
        try:
            probes.append(owned_child_probe(p))
        except BaseException as error:
            GATE.save(log('ownership-probe-failure.json'), dict(path=str(p), root=paths[str(p)], error=str(error)))
            raise
    GATE.save(log('guest-environment.json'), dict(platform=platform.platform(), architecture=platform.machine(),
        uid=os.getuid(), gid=os.getgid(), groups=os.getgroups(), user=user.pw_name,
        etcEntries=len(rows), etcMismatchCount=0, noNativeListener=True, paths=paths, ownedChildProbes=probes,
        fixtureAvailableBytes=available, fixturePath=str(FIXTURES), fixtureHostFilesystemMatchesGate=True,
        hostFilesystemMappings=mapping, guestFixtureDevice=FIXTURES.stat().st_dev,
        sessionBoundHostReceipt=str(LOGS / GATE.GUARD_NAME)))


def validate_pins():
    pins = json.loads((GATE.SOURCE / 'Package.resolved').read_text())['pins']
    for pin in pins:
        mirror = GATE.WORK / 'mirrors' / (pin['identity'] + '.git')
        if not pin['location'].startswith('https://') or not mirror.is_dir() or mirror.is_symlink():
            raise RuntimeError('exact local mirror missing: ' + pin['identity'])
        subprocess.run(['git', '-C', str(mirror), 'cat-file', '-e', pin['state']['revision'] + '^{commit}'],
                       check=True, capture_output=True, timeout=30)
    return pins


def guest():
    global OPERATION_DEADLINE
    OPERATION_DEADLINE = time.monotonic() + OPERATION_TIMEOUT_SECONDS
    capacity()
    verify_snapshot()
    base = GATE.WORK / 'linux'
    for kind in ('scratch', 'cache', 'config', 'security', 'tmp', 'modules'):
        if not (base / kind).is_dir():
            raise RuntimeError('warm Linux cache missing: ' + kind)
    if not FIXTURES.is_dir():
        raise RuntimeError('host-backed current fixture mount missing')
    guest_identity()
    environment = os.environ.copy()
    environment.pop('SWIFTCI_USE_LOCAL_DEPS', None)
    environment.update(TMPDIR=str(FIXTURES), GIT_ALLOW_PROTOCOL='file',
        CLANG_MODULE_CACHE_PATH=str(base / 'modules'), SWIFTPM_MODULECACHE_OVERRIDE=str(base / 'modules'))
    common = ['--package-path', str(GATE.SOURCE), '--disable-sandbox']
    for kind in ('scratch', 'cache', 'config', 'security'):
        common += ['--' + kind + '-path', str(base / kind)]
    pins = validate_pins()
    for pin in pins:
        run(['swift', 'package', *common, 'config', 'set-mirror', '--original', pin['location'],
                  '--mirror', (GATE.WORK / 'mirrors' / (pin['identity'] + '.git')).as_uri()],
                 LABEL + '-mirror-' + pin['identity'], environment, 60)
    run(['swift', '--version'], LABEL + '-toolchain', environment, 30)
    toolchain = log('toolchain.log').read_text()
    if not re.search(r'Swift version 6\.4(?:\.0)?(?:\s|\s*\()', toolchain):
        raise RuntimeError('unexpected Swift compiler; expected actual 6.4')
    run(['swift', 'test', '--help'], LABEL + '-swift-test-help', environment, 30)
    if '--enable-index-store' not in log('swift-test-help.log').read_text():
        raise RuntimeError('actual Linux Swift 6.4 lacks reviewed index-store flag')
    run(['dpkg-query', '-W', 'libc6', 'libsqlite3-0', 'libpam0g', 'libuuid1'], LABEL + '-system-libraries', environment, 30)
    selection = json.loads(log('selection.json').read_text())
    log('tested-source-manifest.json').write_bytes((GATE.WORK / GATE.SOURCE_MANIFEST_NAME).read_bytes())
    run(['swift', 'test', *common, '--build-system', 'native', '--enable-index-store', '--skip-update', '--jobs', '1',
              '--filter', selection['testFilter']], LABEL + '-tests', environment, COMMAND_TIMEOUT_SECONDS)
    verify_snapshot()
    verify_results(json.loads(log('tests.status.json').read_text()), log('tests.log').read_text(), selection['ids'])
    resolved = json.loads((GATE.SOURCE / 'Package.resolved').read_text())['pins']
    if resolved != pins:
        raise RuntimeError('canonical lock changed during test')
    binaries = [p for p in (base / 'scratch').rglob('TractandaPackageTests.xctest') if p.is_file() and p.open('rb').read(4) == b'\x7fELF']
    if len(binaries) != 1:
        raise RuntimeError('expected one combined root ELF')
    run(['ldd', str(binaries[0])], LABEL + '-runtime-libraries', environment, 30)
    guest_identity()
    GATE.save(log('guest-complete.json'), dict(tests=116, failures=0, skipped=0, capacity=capacity(),
        guardSession=GATE.GUEST_SESSION, sourceSHA256=sha(log('tested-source-manifest.json')), binarySHA256=sha(binaries[0])))


def collect(environment):
    verify_snapshot()
    source_manifest = GATE.WORK / GATE.SOURCE_MANIFEST_NAME
    if log('tested-source-manifest.json').read_bytes() != source_manifest.read_bytes():
        raise RuntimeError('tested source manifest differs')
    ids = json.loads(log('selection.json').read_text())['ids']
    for stage in ('host', 'tests', 'toolchain', 'swift-test-help', 'system-libraries', 'runtime-libraries'):
        status = json.loads(log(stage + '.status.json').read_text())
        if status.get('running') is not False or status.get('exit') != 0:
            raise RuntimeError('collection requires completed successful original stage: ' + stage)
    guest_complete = json.loads(log('guest-complete.json').read_text())
    guard = json.loads((LOGS / GATE.GUARD_NAME).read_text())
    if guard.get('state') != 'complete' or guard.get('session') != guest_complete.get('guardSession') or \
            guard.get('sourceSHA256') != sha(source_manifest) or guest_complete.get('sourceSHA256') != sha(source_manifest):
        raise RuntimeError('completed host/guest source-session receipts do not agree')
    if not log('guest-environment.json').is_file() or not log('tested-mounts.json').is_file():
        raise RuntimeError('guest identity/mount receipts are absent')
    absence = json.loads(log('container-absence.json').read_text())
    if absence.get('present') is not False:
        raise RuntimeError('exact container cleanup is unverified')
    verify_results(json.loads(log('tests.status.json').read_text()), log('tests.log').read_text(), ids)
    binary = GATE.WORK / 'linux/scratch/aarch64-unknown-linux-gnu/debug/TractandaPackageTests.xctest'
    if binary.is_symlink() or binary.open('rb').read(4) != b'\x7fELF':
        raise RuntimeError('expected warm combined Linux ELF')
    original_sha = sha(binary)
    nm = shutil.which('nm')
    if not nm:
        raise RuntimeError('host nm is unavailable')
    run([nm, '-g', str(binary)], LABEL + '-host-symbols', environment, 60)
    symbol_text = log('host-symbols.log').read_text()
    symbols = GATE.combined_symbol_groups(symbol_text)
    tls_symbols = sorted({parts[-1] for line in symbol_text.splitlines()
        if len(parts := line.split()) >= 3 and parts[-2].upper() != 'U' and
        'TractandaPeerTLS' in parts[-1] and ('TLSContext' in parts[-1] or 'TLSSession' in parts[-1])})
    if not tls_symbols:
        raise RuntimeError('actual defined TractandaPeerTLS context/session symbols absent')
    if sha(binary) != original_sha or json.loads(log('guest-complete.json').read_text())['binarySHA256'] != original_sha:
        raise RuntimeError('tested ELF changed before evidence collection')
    verify_snapshot()
    frozen = json.loads(source_manifest.read_text())['files']
    if any(sha(REPO / r['path']) != r['sha256'] for r in frozen):
        raise RuntimeError('workspace changed during current Linux validation')
    GATE.save(log('evidence.json'), dict(profile='tractanda.cluster-b2-linux.v1', tests=116, failures=0, skipped=0,
        exactTestIDs=ids, sourceManifestSHA256=sha(source_manifest), macInputsMatch=1160, ownedSwiftMatches=40,
        separateRunnerSHA256=sha(REPO / SELF), oldRunnerSHA256=sha(REPO / 'scripts/verify-peer-transport.py'),
        binary=str(binary), binarySHA256=original_sha, symbols=symbols, coreRecordCodec=True,
        peerExchange=True, definedPeerTLSContextOrSession=dict(count=len(tls_symbols), examples=tls_symbols[:5]),
        originalHostWrapperExit=0, guardSession=guard['session'], exactContainerAbsent=True,
        image=GATE.IMAGE, imageDigest=GATE.IMAGE_DIGEST, capacity=capacity()))


def ensure_container_absent():
    def inventory():
        return json.loads(subprocess.check_output([GATE.RUNTIME, 'list', '--all', '--format', 'json'], timeout=30))
    own = [v for v in inventory() if v.get('id') == LABEL]
    cleanup = []
    if own:
        # The label was absent before this process launched it. Never touch another label.
        for action in ('stop', 'delete'):
            result = subprocess.run([GATE.RUNTIME, action, LABEL], capture_output=True, text=True, timeout=30)
            cleanup.append(dict(action=action, exit=result.returncode, diagnostic=result.stderr[-500:]))
        own = [v for v in inventory() if v.get('id') == LABEL]
    GATE.save(log('container-absence.json'), dict(namedContainer=LABEL, present=bool(own), cleanup=cleanup))
    if own:
        raise RuntimeError('exact owned container remains after bounded cleanup')


def monitored_host_run(command, environment, session):
    def interrupted(signum, frame):
        raise InterruptedError('host received signal ' + str(signum))
    signals = (signal.SIGTERM, signal.SIGHUP)
    previous_handlers = {s: signal.signal(s, interrupted) for s in signals}
    original_failure = None
    try:
        owner_seconds = timeout_budgets(OPERATION_TIMEOUT_SECONDS)['ownerSeconds']
        run(command, LABEL + '-host', environment, owner_seconds, [GATE.RUNTIME, 'stop', LABEL], monitor_session=session)
    except BaseException as error:
        original_failure = error
    finally:
        # Bound cleanup even if a second TERM/HUP arrives; SIGKILL cannot be handled.
        for signum in signals:
            signal.signal(signum, signal.SIG_IGN)
        try:
            ensure_container_absent()
        except BaseException as error:
            GATE.save(log('cleanup-failure.json'), dict(error=str(error), originalFailure=str(original_failure)))
            if original_failure is None:
                original_failure = error
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
    if original_failure is not None:
        raise original_failure

def host():
    freeze()
    environment = os.environ.copy()
    validate_pins()
    info = json.loads(subprocess.check_output([GATE.RUNTIME, 'image', 'inspect', GATE.IMAGE], timeout=30))
    if info[0]['configuration']['descriptor']['digest'] != GATE.IMAGE_DIGEST:
        raise RuntimeError('retained image digest differs; no pull allowed')
    if not any(v.get('platform', {}).get('architecture') == 'arm64' for v in info[0].get('variants', [])):
        raise RuntimeError('retained Linux arm64 variant absent')
    if any(v.get('config', {}).get('config', {}).get('Volumes') for v in info[0].get('variants', [])):
        raise RuntimeError('image declares unaccounted volumes')
    GATE.save(log('image-inspect.json'), info)
    inventory = json.loads(subprocess.check_output([GATE.RUNTIME, 'list', '--all', '--format', 'json'], timeout=30))
    if any(v.get('id') == LABEL for v in inventory):
        raise RuntimeError('exact named test container already exists; no automatic deletion')
    GATE.save(log('container-inventory.json'), dict(namedContainer=LABEL, present=False,
        inventoryIDs=[v.get('id') for v in inventory]))
    overlay = GATE.WORK / 'linux/etc-overlay'
    rows = json.loads((GATE.WORK / 'logs/adapter-linux-complete-etc-overlay.json').read_text())['entries']
    overlay_check(overlay, rows)
    node = checked_node()
    node_binary = REPO / '.build/out/Products/Debug/tractanda'
    node_environment = environment.copy()
    node_environment.pop('TRACTANDA_UUID_NODE', None)
    refreshed_node = json.loads(subprocess.check_output([str(node_binary), 'uuid-node'],
        env=node_environment, timeout=30))
    if refreshed_node.get('node') != node or refreshed_node.get('source') != 'IOKit IOMACAddress':
        raise RuntimeError('real host UUID node changed; explicit fixture receipt review required')
    GATE.save(log('node-refresh.json'), dict(selected=refreshed_node, binarySHA256=sha(node_binary),
        profileFree=True, childEnvironmentOnly=True))
    log('node-refresh.json').chmod(0o600)
    metadata = GATE.WORK / 'linux' / (LABEL + '-metadata')
    metadata.mkdir(exist_ok=False)
    FIXTURES.mkdir(exist_ok=False)
    (GATE.SOURCE / '.swiftpm').mkdir(exist_ok=False)
    cache_paths = [GATE.WORK / 'linux' / kind for kind in ('scratch', 'cache', 'config', 'security', 'tmp', 'modules')]
    for path in (GATE.WORK, GATE.SOURCE.parent, metadata, overlay, LOGS, FIXTURES, *cache_paths):
        if path.is_symlink() or not path.resolve().is_relative_to(GATE.WORK.resolve()):
            raise RuntimeError('mount escapes owned warm tree')
    if any(not p.is_dir() or p.stat().st_uid != 1001 or p.stat().st_gid != 20 for p in cache_paths + [metadata, FIXTURES, LOGS]):
        raise RuntimeError('warm/current writable mount has unexpected ownership')
    host_work_device = GATE.WORK.stat().st_dev
    host_mapping = [dict(hostPath=str(p), guestPath=guest_path, hostDevice=p.stat().st_dev,
                        hostUID=p.stat().st_uid, hostGID=p.stat().st_gid) for p, guest_path in
        [(p, '/gate/linux/' + p.name) for p in cache_paths + [FIXTURES]] +
        [(metadata, '/source/Tractanda/.swiftpm'), (LOGS, '/current-logs')]]
    if any(v['hostDevice'] != host_work_device for v in host_mapping):
        raise RuntimeError('mutable export is on a different actual host filesystem')
    session, source_sha = uuid.uuid4().hex, sha(GATE.WORK / GATE.SOURCE_MANIFEST_NAME)
    command = [GATE.RUNTIME, 'run', '--rm', '--progress', 'none', '--name', LABEL,
        '--read-only', '--uid', str(os.getuid()), '--gid', str(os.getgid()), '--cpus', '2', '--memory', '3G',
        '--no-dns', '--env', 'TRACTANDA_UUID_NODE=' + node,
        '--mount', f'type=bind,source={overlay},target=/etc,readonly',
        '--mount', f'type=bind,source={GATE.WORK},target=/gate,readonly',
        *[part for kind in ('scratch', 'cache', 'config', 'security', 'tmp', 'modules')
          for part in ('--mount', f'type=bind,source={GATE.WORK / "linux" / kind},target=/gate/linux/{kind}')],
        '--mount', f'type=bind,source={FIXTURES},target=/gate/linux/{FIXTURES.name}',
        '--mount', f'type=bind,source={LOGS},target=/current-logs',
        '--mount', f'type=bind,source={GATE.SOURCE.parent},target=/source,readonly',
        '--mount', f'type=bind,source={metadata},target=/source/Tractanda/.swiftpm',
        '--workdir', '/source/Tractanda', '--entrypoint', '/usr/bin/python3', GATE.IMAGE,
        '/source/Tractanda/' + SELF, '--guest', '--run-label', LABEL,
        '--guard-session', session, '--guard-source', source_sha]
    command += ['--timeout-seconds', str(OPERATION_TIMEOUT_SECONDS),
                '--command-timeout-seconds', str(COMMAND_TIMEOUT_SECONDS)]
    GATE.save(log('write-layout.json'), dict(command=command, memory='3G', cpus=2, jobs=1,
        timeoutBudgets=timeout_budgets(OPERATION_TIMEOUT_SECONDS), commandTimeoutSeconds=COMMAND_TIMEOUT_SECONDS,
        indexStore='enabled for normal XCTest discovery',
        rootReadOnly=True, sourceReadOnly=True, etcReadOnly=True, warmRootReadOnly=True,
        configuredWritable=[str(GATE.WORK / 'linux' / k) for k in ('scratch', 'cache', 'config', 'security', 'tmp', 'modules')]
            + [str(metadata), str(FIXTURES), str(LOGS)],
        sourceSHA256=source_sha, fixtureCap=FIXTURE_CAP, cap=GATE.CAP, reserve=GATE.RESERVE,
        allowance=GATE.ALLOWANCE, hostWorkDevice=host_work_device, hostFilesystemMappings=host_mapping,
        offlineGitProtocols=['file'], noNewImageOrDependencyDownloads=True))
    monitored_host_run(command, environment, session)
    collect(environment)


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-label', default='cluster-b2-20261016')
    parser.add_argument('--guest', action='store_true')
    parser.add_argument('--guard-session')
    parser.add_argument('--guard-source')
    parser.add_argument('--collect-only', action='store_true')
    parser.add_argument('--timeout-seconds', type=positive_timeout_seconds, default=DEFAULT_TIMEOUT_SECONDS,
                        help='Whole native validation budget (default: 24 hours).')
    parser.add_argument('--command-timeout-seconds', type=positive_timeout_seconds, default=DEFAULT_TIMEOUT_SECONDS,
                        help='Maximum per-child test command budget, capped by the whole-run budget.')
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    if args.guest and (not args.guard_session or not args.guard_source or args.collect_only):
        raise RuntimeError('guest requires fresh host session/source receipt')
    if not args.guest and (args.guard_session or args.guard_source):
        raise RuntimeError('host cannot accept guest guard arguments')
    configure(args.run_label, args.guest, args.guard_session, args.guard_source,
              args.timeout_seconds, args.command_timeout_seconds)
    if args.guest:
        guest()
    elif args.collect_only:
        collect(os.environ.copy())
    else:
        host()


if __name__ == '__main__':
    main()
