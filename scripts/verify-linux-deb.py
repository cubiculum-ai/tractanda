#!/usr/bin/env python3
"""Finite full-package lifecycle checks inside a controller-owned disposable guest.

Default is plan-only. The controller owns native CPU/backing-host capacity proof,
guest limits/deadline and eventual guest destruction after preserving this evidence.
This script never creates an account, guest, package, model or canonical migration.
"""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import platform
import pwd
import re
import signal
import socket
import stat
import subprocess
import sys
import time

RESERVE = 10 * 1024**3
FIXTURE_CAP = 128 * 1024**2
DEFAULT_TIMEOUT_SECONDS = 24 * 60 * 60
MAX_TIMEOUT_SECONDS = 7 * 24 * 60 * 60
PAYLOAD = Path('/opt/tractanda/current')
SETUP = str(PAYLOAD / 'bin/tractanda-setup')
CLI = str(PAYLOAD / 'bin/tractanda')
CONTEXT = Path('/run/tractanda-package-validation.json')
ARCH = {'x86_64': 'amd64', 'aarch64': 'arm64'}
COMMANDS = ['fresh-unconfigured', 'explicit-setup', 'configured-readiness',
            'optional-real-upgrade-failure-retry', 'optional-real-older-refusal',
            'remove-retains', 'policy-denied-reinstall', 'explicit-restart', 'purge-retains']


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def positive_timeout_seconds(value):
    try:
        seconds = int(value)
    except (TypeError, ValueError) as error:
        raise argparse.ArgumentTypeError('timeout must be a finite positive integer number of seconds') from error
    if seconds <= 0 or seconds > MAX_TIMEOUT_SECONDS:
        raise argparse.ArgumentTypeError(f'timeout must be between 1 and {MAX_TIMEOUT_SECONDS} seconds')
    return seconds


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate JSON field: ' + key)
        result[key] = value
    return result


def read_json(path, maximum=16 * 1024**2):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode) and 0 < before.st_size <= maximum, 'Unbounded/nonregular JSON')
        raw = stream.read(maximum + 1)
        after = os.fstat(stream.fileno())
    stamp = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
    require(len(raw) == before.st_size and stamp(before) == stamp(after), 'JSON changed while reading')
    return json.loads(raw, object_pairs_hook=unique)


def artifact(path):
    """Use D3's adjacent receipt, hash the .deb without unpacking/duplicating models."""
    path = path.resolve(strict=True)
    require(path.is_file() and path.suffix == '.deb', 'Supply a regular complete .deb')
    receipt = read_json(Path(str(path) + '.inventory.json'))
    require(receipt['packageSHA256'] == digest(path) and receipt['packageBytes'] == path.stat().st_size,
            'Package differs from its D3 receipt')
    files = {r['path']: r for r in receipt['inventory']}
    prefix = 'opt/tractanda/current/'
    require(all(prefix + 'bin/' + name in files for name in ('tractanda', 'tractanda-tui', 'tractanda-mcp',
                'tractanda-setup', 'tractanda-auth-helper', 'tractanda-embeddings', 'tractanda-document-converter')),
            'Complete seven-binary D3 payload required')
    require(all(any(p.startswith(prefix + 'models/' + name + '/') for p in files) for name in
                ('granite-embedding-311m-multilingual-r2', 'granite-docling-258m-mlx')), 'Both bundled models required')
    require(files[prefix + 'bundle-manifest.json']['sha256'] == receipt['bundleManifestSHA256'], 'Manifest commitment differs')
    return {'path': path, 'receipt': receipt, 'serverSHA256': files[prefix + 'bin/tractanda']['sha256']}


def distinct_binary(first, second):
    require(first['receipt']['packageSHA256'] != second['receipt']['packageSHA256']
            and first['serverSHA256'] != second['serverSHA256'],
            'A renamed/revision-only package is not evidence of a different binary')


def inventory(roots, hashes=True):
    """Record absence, bytes and directory custody, excluding inode/time/directory-size churn."""
    result, total = {}, 0
    def record(path):
        nonlocal total
        key = str(path)
        if key in result:
            return
        info = path.lstat()
        custody = {'mode': stat.S_IMODE(info.st_mode), 'uid': info.st_uid, 'gid': info.st_gid}
        require(len(result) < 20_000, 'Canonical/credential fixture cap exceeded')
        if stat.S_ISDIR(info.st_mode):
            result[key] = dict(kind='directory', **custody)
        else:
            require(stat.S_ISREG(info.st_mode), 'Fixture link/special file')
            total += info.st_size
            require(total <= FIXTURE_CAP, 'Canonical/credential fixture cap exceeded')
            result[key] = dict(kind='file', sha256=digest(path) if hashes else None,
                               size=info.st_size, **custody)
    for root in roots:
        root = Path(root)
        require(not root.is_symlink(), 'Fixture root is a link')
        if not root.exists():
            result[str(root)] = {'kind': 'absent'}
            continue
        record(root)
        if root.is_file():
            continue
        def failed(error): raise error
        for directory, dirs, names in os.walk(root, followlinks=False, onerror=failed):
            record(Path(directory))
            require(all(not (Path(directory) / n).is_symlink() for n in dirs), 'Fixture directory link')
            for name in names:
                record(Path(directory) / name)
    return result


def retained(before, after):
    require(before == after, 'Canonical identity/history/credential record set, bytes or custody changed')


def can_read(support, requirement):
    require(support['profile'] == 'tractanda.canonical-formats.v1'
            and requirement['profile'] == 'tractanda.canonical-reader.v1', 'Unknown actual canonical declarations')
    return (support['readerLevel'] >= requirement['minimumReaderLevel']
            and set(requirement['recordFormats']) <= set(support['read'])
            and set(requirement['capabilities']) <= set(support['capabilities']))


def configured_uuid_node(context):
    """Controller-attested issuer hardware only; no inherited/random substitute."""
    if 'uuidNode' not in context:
        return None
    value = context['uuidNode']
    require(isinstance(value, str) and re.fullmatch(
        r'(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}|[0-9a-fA-F]{12}', value),
        'Context UUID node must be a globally administered unicast hardware MAC')
    node = int(value.replace(':', ''), 16)
    require(0 < node < (1 << 48) and node & (3 << 40) == 0,
            'Context UUID node must be a globally administered unicast hardware MAC')
    return value


def setup_arguments(context, name):
    setup = [SETUP, 'install', '--name', name, '--owner', context['owner'], '--port', str(context['port'])]
    node = configured_uuid_node(context)
    if node is not None:
        setup += ['--uuid-node', node]
    if context['selection'] == 'first-source':
        setup += ['--first-source', '--sample']
    else:
        setup += ['--adopt-prepared', '--store-id', context['storeID'], '--replica-id', context['replicaID'], '--empty']
    return setup


def validate_context(context):
    require(context['schema'] == 'tractanda.package-validation.v1'
            and re.fullmatch('[a-f0-9]{12}', context['runID']), 'Unknown disposable-guest context')
    require(context['fixtureCapBytes'] == FIXTURE_CAP and context['reserveBytes'] == RESERVE
            and type(context['softwareAllowanceBytes']) is int and context['softwareAllowanceBytes'] > 0,
            'Keep software allowance separate; fixture/reserve limits are fixed')
    require(context['selection'] in ('first-source', 'prepared'), 'Explicit store selection required')
    configured_uuid_node(context)
    require(49152 <= context['port'] <= 65535 and 0 < context['expiresAt'] - time.time() <= 3600,
            'Context port or validity window rejected')


class Validation:
    def __init__(self, context, work, timeout_seconds=DEFAULT_TIMEOUT_SECONDS,
                 command_timeout_seconds=DEFAULT_TIMEOUT_SECONDS):
        self.context, self.work = context, work
        require(1 <= timeout_seconds <= MAX_TIMEOUT_SECONDS, 'Whole validation timeout is invalid')
        require(1 <= command_timeout_seconds <= MAX_TIMEOUT_SECONDS, 'Per-command timeout is invalid')
        self.timeout_seconds = timeout_seconds
        self.command_timeout_seconds = min(command_timeout_seconds, timeout_seconds)
        self.deadline = time.monotonic() + timeout_seconds
        self.name = 'd5-' + context['runID']
        self.store = Path('/var/lib/tractanda/stores') / self.name
        self.index = Path('/var/cache/tractanda/indexes') / self.name
        self.private = Path('/etc/tractanda/peer-runtime') / (self.name + '.json')
        self.units = ['tractanda-' + role + '-' + self.name + '.service'
                      for role in ('server', 'embeddings', 'authentication')]
        self.result = {'schema': 'tractanda.package-validation-result.v1', 'status': 'RUNNING', 'commands': [], 'cases': {},
                       'timeoutBudgets': {'operationSeconds': timeout_seconds,
                                          'longCommandMaxSeconds': self.command_timeout_seconds}}

    def save(self):
        temporary = self.work / 'RESULT.new'
        temporary.write_text(json.dumps(self.result, indent=2) + '\n')
        temporary.replace(self.work / 'RESULT.json')

    def guard(self):
        require(time.monotonic() < self.deadline, 'Whole validation deadline exceeded')
        for path in (Path('/opt'), Path('/etc'), Path('/var/lib'), Path('/var/cache'), self.work):
            fs = os.statvfs(path)
            require(fs.f_frsize > 0 and fs.f_bavail * fs.f_frsize >= RESERVE, 'Actual guest filesystem reserve rejected')
        inventory([self.store, self.index, self.private, self.work], hashes=False)

    def command(self, argv, failure=False, timeout=300, codes=None, server_probe=False):
        self.guard()
        remaining = self.deadline - time.monotonic()
        effective_timeout = min(timeout, remaining)
        require(effective_timeout > 0, 'Whole validation deadline leaves no command budget')
        row = {'argv': list(map(str, argv)), 'log': str(self.work / ('command-%03d.log' % len(self.result['commands']))),
               'timeoutSeconds': effective_timeout}
        self.result['commands'].append(row); self.save()
        process = None; started = time.monotonic()
        try:
            with open(row['log'], 'xb') as out:
                env = {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LC_ALL': 'C', 'DEBIAN_FRONTEND': 'noninteractive'}
                if server_probe:
                    require(row['argv'] == [CLI, '--no-start', '--socket', '/run/tractanda/' + self.name + '/server.sock', 'info'],
                            'Daemon peer binding is only permitted for the fixed native info probe')
                    env['TRACTANDA_SERVER_USER'] = 'daemon'
                    row['serverUser'] = 'daemon'
                process = subprocess.Popen(row['argv'], stdout=out, stderr=subprocess.STDOUT,
                                           stdin=subprocess.DEVNULL, env=env, start_new_session=True)
                row['pid'] = process.pid; self.save()
                while process.poll() is None:
                    self.guard()
                    require(time.monotonic() - started < effective_timeout and Path(row['log']).stat().st_size <= 4 * 1024**2,
                            'Command deadline/log cap exceeded')
                    time.sleep(.1)
                row['exit'] = process.wait(); self.guard()
                require(time.monotonic() - started <= effective_timeout, 'Command deadline exceeded')
                require(Path(row['log']).stat().st_size <= 4 * 1024**2, 'Final log cap exceeded')
                text = Path(row['log']).read_text(errors='replace')
                expected = row['exit'] in codes if codes is not None else (row['exit'] != 0 if failure else row['exit'] == 0)
                require(expected, 'Unexpected command status; retain guest/logs')
                return text
        finally:
            if process is not None:
                try: os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                process.wait()
            self.save()

    def stopped(self, disabled=False):
        for unit in self.units:
            value = self.command(['/usr/bin/systemctl', 'show', unit, '--property=LoadState,ActiveState,MainPID,UnitFileState'], codes=(0, 1, 4))
            fields = dict(line.split('=', 1) for line in value.splitlines())
            require(fields['LoadState'] in ('loaded', 'not-found') and fields['ActiveState'] in ('inactive', 'failed')
                    and fields['MainPID'] == '0', 'Writer/support service not stopped')
            if disabled:
                require(fields.get('UnitFileState') == 'disabled' if fields['LoadState'] == 'loaded'
                        else fields.get('UnitFileState', '') in ('', 'not-found'),
                        'Pending/failed package could start at boot')

    def ready(self, package, previous=None):
        state = dict(line.split('=', 1) for line in self.command([SETUP, 'status', '--name', self.name]).splitlines())
        info = json.loads(self.command([CLI, '--no-start', '--socket', '/run/tractanda/' + self.name + '/server.sock', 'info'], server_probe=True))
        server = info['server']
        require(server['executableSHA256'] == package['serverSHA256']
                and server['version'] == read_json(PAYLOAD / 'bundle-manifest.json')['version']
                and state['ActiveState'] == 'active' and int(state['MainPID']) == server['processID'], 'Running old/unbound software')
        require(info['accessMode'] == 'multi-user' and info['callerIsAdministrator'], 'Native readiness authority differs')
        if previous:
            require(server['instanceID'] != previous['instanceID'] and server['processID'] != previous['processID'], 'Old daemon survived replacement')
        for unit in self.units:
            self.command(['/usr/bin/systemctl', 'is-active', unit])
        self.result['nativeIdentity'] = server
        return server

    def installed(self, package, configured=True):
        fields = self.command(['/usr/bin/dpkg-query', '-W', '-f=${Status}\t${Version}\t${Architecture}', 'tractanda']).strip().split('\t')
        require(len(fields) == 3 and fields[1:] == [package['receipt']['version'], package['receipt']['arch']]
                and (fields[0] == 'install ok installed' if configured else fields[0] in
                     ('install ok unpacked', 'install ok half-configured')), 'Actual dpkg state/version/architecture differs')
        manifest = read_json(PAYLOAD / 'bundle-manifest.json', 4 * 1024**2)
        require(digest(PAYLOAD / 'bundle-manifest.json') == package['receipt']['bundleManifestSHA256']
                and manifest.get('embedding') and manifest.get('documentExtraction'), 'Actual active full payload differs')
        require(manifest['version'] != '', 'Missing source version')
        self.command([SETUP, 'plan', '--bundle', PAYLOAD])
        for name in ('tractanda', 'tractanda-setup'):
            owned = self.command(['/usr/bin/dpkg-query', '-S', str(PAYLOAD / 'bin' / name)])
            require(owned.startswith('tractanda: '), 'dpkg does not own active software')
        require(not (PAYLOAD.parent / 'releases').exists() and not PAYLOAD.is_symlink(), 'Parallel Setup software ownership')
        return manifest

    def snapshot(self):
        value = inventory([self.store, self.private.parent, self.private])
        require(str(self.store / '.tractanda-store-identity.json') in value
                and str(self.store / '.tractanda-replica-identity.json') in value
                and any(p.endswith('.tractanda') and row['kind'] == 'file' for p, row in value.items()), 'Missing real canonical fixture/history')
        self.result['privateCoverage'] = {
            'managedPeerConfiguration': value[str(self.private)]['kind'],
            'canonicalCredentialFiles': sum(row['kind'] == 'file' and '.peer-credentials' in Path(p).parts
                                            for p, row in value.items()),
            'directoryCustodyRecorded': True,
            'qualification': 'Absent configuration/credential files were not exercised; no secret bytes are published.'}
        return value

    def attempt_older_refusal(self, older):
        # Dpkg echoes paths and arbitrary hook text. A nonzero result is not a
        # structured compatibility diagnostic; the parent must review this log.
        self.command(['/usr/bin/dpkg', '--install', older['path']], failure=True,
                     timeout=self.command_timeout_seconds)
        refusal_log = self.result['commands'][-1]['log']
        self.stopped(disabled=True)
        return {'status': 'REVIEW_REQUIRED', 'log': refusal_log,
                'packageManifestSHA256': older['receipt']['bundleManifestSHA256'],
                'reason': 'Actual incompatible reader declaration was established, but the failed installation reason is not automatically proved.'}


@contextmanager
def denied_policy(run_id):
    path = Path('/usr/sbin/policy-rc.d')
    data = ('#!/bin/sh\n# tractanda-d5-' + run_id + '\nexit 101\n').encode()
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o755)
    with os.fdopen(fd, 'wb') as stream: stream.write(data)
    try:
        yield
    finally:
        require(not path.is_symlink() and path.read_bytes() == data, 'Policy fixture drifted; retain it for inspection')
        path.unlink()


def execute(args):
    st = CONTEXT.lstat()
    require(os.geteuid() == 0 and stat.S_ISREG(st.st_mode) and st.st_uid == 0
            and st.st_nlink == 1 and stat.S_IMODE(st.st_mode) == 0o600, 'Private controller context required')
    context = read_json(CONTEXT, 16 * 1024); validate_context(context)
    require(platform.system() == 'Linux' and Path('/proc/1/comm').read_text().strip() == 'systemd'
            and Path('/run/systemd/container').read_text().strip() in ('podman', 'other'), 'Only explicit disposable systemd guests')
    require(Path('/etc/machine-id').read_text().strip() == context['guestMachineID'], 'Controller guest binding differs')
    release = dict(line.split('=', 1) for line in Path('/etc/os-release').read_text().splitlines() if '=' in line)
    require(release['ID'].strip('"') == 'debian' and release['VERSION_ID'].strip('"') == '13', 'Native Debian13 required')
    arch = ARCH[platform.machine()]; packages = [artifact(p) for p in (args.package, args.upgrade, args.older_refusal) if p]
    require((args.older_refusal is None) == (args.older_manifest is None), 'Older refusal needs its actual hash-bound bundle manifest')
    require(all(p['receipt']['arch'] == arch for p in packages), 'Package/native architecture mismatch')
    require(all(not path.exists() and not path.is_symlink() for path in
                (PAYLOAD, Path('/etc/tractanda/receipts'), Path('/usr/sbin/policy-rc.d'))),
            'Use a fresh isolated image without another installation/policy fixture or dangling link')
    pwd.getpwnam('daemon'); pwd.getpwnam(context['owner'])  # Never provision an account.
    work = Path('/var/tmp/tractanda-package-validation-' + context['runID']); work.mkdir(mode=0o700)
    check = Validation(context, work, args.timeout_seconds, args.command_timeout_seconds); current = packages[0]
    try:
        data_root = check.store.parent
        require(not data_root.exists() or {p.name for p in data_root.iterdir()} <=
                ({check.name} if context['selection'] == 'prepared' else set()), 'Unrelated canonical stores in the guest')
        require(sum(p['receipt']['installedKiB'] * 1024 for p in packages) <= context['softwareAllowanceBytes'], 'Separate software allowance insufficient')
        for path in (Path('/opt'), work):
            fs = os.statvfs(path); require(fs.f_frsize * fs.f_bavail >= RESERVE + context['softwareAllowanceBytes'] + FIXTURE_CAP, 'Initial software/fixture estimate rejected')
        require(not check.store.exists() if context['selection'] == 'first-source' else check.store.is_dir(), 'Fresh/prepared fixture selection mismatch')
        before = inventory([check.store, check.private])
        require(not check.command(['/usr/bin/systemctl', 'list-units', '--type=service', '--all',
                    '--no-legend', '--no-pager', 'tractanda-*.service']).strip(), 'Existing Tractanda service in fresh guest')
        check.command(['/usr/bin/dpkg', '--install', current['path']], timeout=check.command_timeout_seconds)
        check.installed(current); check.stopped()
        require(inventory([check.store, check.private]) == before, 'Package implicitly bootstrapped/joined a store')
        require(not check.store.parent.exists() or {p.name for p in check.store.parent.iterdir()} <=
                ({check.name} if context['selection'] == 'prepared' else set()), 'Package created an unrelated store')
        require(not check.command(['/usr/bin/systemctl', 'list-units', '--type=service', '--all',
                    '--no-legend', '--no-pager', 'tractanda-*.service']).strip(), 'Fresh package started/registered an unrelated service')
        check.command(setup_arguments(context, check.name), timeout=check.command_timeout_seconds)
        identity = check.ready(current)
        check.command([SETUP, 'stop', '--name', check.name], timeout=check.command_timeout_seconds)
        baseline = check.snapshot()
        check.result['retainedFixture'] = baseline
        check.command([SETUP, 'start', '--name', check.name], timeout=check.command_timeout_seconds)
        identity = check.ready(current)
        check.result['cases']['explicit-selection'] = 'PASS'
        if args.upgrade:
            incoming = next(p for p in packages if p['path'] == args.upgrade.resolve()); distinct_binary(current, incoming)
            check.command(['/usr/bin/dpkg', '--compare-versions', current['receipt']['version'], 'lt', incoming['receipt']['version']])
            check.command(['/usr/bin/dpkg', '--unpack', incoming['path']], timeout=check.command_timeout_seconds)
            check.stopped(disabled=True)
            with socket.socket() as blocker:
                blocker.bind(('127.0.0.1', context['port'])); blocker.listen(1)
                check.command(['/usr/bin/dpkg', '--configure', 'tractanda'], failure=True,
                              timeout=check.command_timeout_seconds)
            check.stopped(disabled=True); check.installed(incoming, configured=False); retained(baseline, check.snapshot())
            check.command(['/usr/bin/dpkg', '--configure', 'tractanda'], timeout=check.command_timeout_seconds)
            current = incoming
            identity = check.ready(current, identity); check.result['cases']['real-upgrade-failure-retry'] = 'PASS'
        else: check.result['cases']['real-upgrade-failure-retry'] = 'NOT EXERCISED: distinct complete upgrade package not supplied'
        if args.older_refusal:
            # The controller must supply a genuinely incompatible old artifact; no format marker is fabricated.
            older = next(p for p in packages if p['path'] == args.older_refusal.resolve()); distinct_binary(current, older)
            check.command(['/usr/bin/dpkg', '--compare-versions', older['receipt']['version'], 'lt', current['receipt']['version']])
            older_manifest = read_json(args.older_manifest, 4 * 1024**2)
            require(digest(args.older_manifest) == older['receipt']['bundleManifestSHA256'], 'Older manifest is not the actual package commitment')
            check.command([SETUP, 'stop', '--name', check.name], timeout=check.command_timeout_seconds)
            requirement = json.loads(check.command(['/usr/bin/sudo', '-n', '-u', 'daemon', '--', SETUP,
                                                    '--canonical-reader-admit', check.store],
                                                    timeout=check.command_timeout_seconds))
            check.result['actualCanonicalRequirement'] = requirement
            check.command([SETUP, 'start', '--name', check.name], timeout=check.command_timeout_seconds)
            identity = check.ready(current)
            if can_read(older_manifest['canonicalFormats'], requirement):
                check.result['cases']['older-package-attempt'] = 'NOT EXERCISED: supplied older reader supports actual retained data'
            else:
                check.result['cases']['older-package-attempt'] = check.attempt_older_refusal(older)
                retained(baseline, check.snapshot())
                check.command(['/usr/bin/dpkg', '--install', current['path']], timeout=check.command_timeout_seconds)
                identity = check.ready(current, identity)
        else: check.result['cases']['older-package-attempt'] = 'NOT EXERCISED: distinct incompatible older package not supplied'
        check.command(['/usr/bin/dpkg', '--remove', 'tractanda'], timeout=check.command_timeout_seconds)
        check.stopped(); retained(baseline, check.snapshot())
        require(not Path(CLI).exists(), 'Removed payload still present')
        with denied_policy(context['runID']):
            check.command(['/usr/bin/dpkg', '--install', current['path']], timeout=check.command_timeout_seconds)
            check.installed(current); check.stopped()
        retained(baseline, check.snapshot())
        check.command([SETUP, 'start', '--name', check.name], timeout=check.command_timeout_seconds)
        check.ready(current)
        check.command(['/usr/bin/dpkg', '--purge', 'tractanda'], timeout=check.command_timeout_seconds)
        check.stopped(); retained(baseline, check.snapshot())
        check.command(['/usr/bin/dpkg', '--install', current['path']], timeout=check.command_timeout_seconds)
        check.installed(current); check.ready(current)
        retained(baseline, check.snapshot())
        check.command(['/usr/bin/dpkg', '--purge', 'tractanda'], timeout=check.command_timeout_seconds)
        check.stopped(); retained(baseline, check.snapshot())
        review = any(isinstance(value, dict) and value.get('status') == 'REVIEW_REQUIRED'
                     for value in check.result['cases'].values())
        check.result.update(status='REVIEW_REQUIRED' if review else 'PASS',
                            cases={**check.result['cases'], 'remove-policy-reinstall-purge-retains': 'PASS'})
    except BaseException as error:
        check.result.update(status='FAIL', failure=str(error)); raise
    finally:
        failures = []
        for unit in check.units:
            try:
                subprocess.run(['/usr/bin/systemctl', 'stop', unit], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
            except Exception as error:
                failures.append(unit + ': ' + str(error))
        try: check.stopped()
        except Exception as error: failures.append(str(error))
        check.result['cleanup'] = {'stoppedVerified': not failures, 'failures': failures,
                                   'retained': 'Canonical/private data, dpkg state and logs for controller inspection'}
        if failures: check.result['status'] = 'FAIL'
        check.save()
        if failures and sys.exc_info()[0] is None:
            raise ValueError('Owned service cleanup needs controller inspection')
    print(json.dumps({'status': check.result['status'], 'resultPath': str(work / 'RESULT.json'),
                      'resultSHA256': digest(work / 'RESULT.json')}))
    return check.result['status'] == 'PASS'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--upgrade', type=Path)
    parser.add_argument('--older-refusal', type=Path)
    parser.add_argument('--older-manifest', type=Path)
    parser.add_argument('--execute', action='store_true')
    parser.add_argument('--timeout-seconds', type=positive_timeout_seconds,
                        default=DEFAULT_TIMEOUT_SECONDS, help='Whole package validation budget (default: 24 hours).')
    parser.add_argument('--command-timeout-seconds', type=positive_timeout_seconds,
                        default=DEFAULT_TIMEOUT_SECONDS, help='Per-command budget, capped by remaining whole-run time.')
    args = parser.parse_args()
    if not args.execute:
        print(json.dumps({'status': 'PLAN_ONLY_NO_MUTATION', 'phases': COMMANDS,
                          'context': str(CONTEXT), 'fixtureCapBytes': FIXTURE_CAP, 'reserveBytes': RESERVE,
                          'timeoutSeconds': args.timeout_seconds,
                          'commandTimeoutSeconds': min(args.command_timeout_seconds, args.timeout_seconds)}, indent=2)); return
    def interrupted(signum, frame):
        for item in (signal.SIGTERM, signal.SIGHUP): signal.signal(item, signal.SIG_IGN)
        raise InterruptedError('Validation interrupted; owned child/service cleanup follows')
    for item in (signal.SIGTERM, signal.SIGHUP): signal.signal(item, interrupted)
    if not execute(args): raise SystemExit(2)


if __name__ == '__main__':
    main()
