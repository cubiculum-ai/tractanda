#!/usr/bin/env python3
"""Finite full-package lifecycle checks inside a controller-owned disposable guest.

Default is plan-only. The controller owns native CPU/backing-host capacity proof,
guest limits/deadline and eventual guest destruction after preserving this evidence.
This script never creates an account, guest, package, model or canonical migration.
"""
import argparse
from contextlib import contextmanager
import errno
import hashlib
import grp
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
import uuid
import http.client

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


def artifact(path, payload_mode="full"):
    require(payload_mode in ("full", "slim"), "Unknown payload mode")
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
    model_prefixes = [prefix + 'models/' + name + '/' for name in
                      ('granite-embedding-311m-multilingual-r2', 'granite-docling-258m-mlx')]
    present = [any(p.startswith(base) for p in files) for base in model_prefixes]
    if payload_mode == 'full':
        require(all(present), 'Both bundled models required')
    else:
        require(not any(present) and prefix + 'models/manifest.json' in files,
                'Slim package must omit both weight trees and include the model catalog')
    require(files[prefix + 'bundle-manifest.json']['sha256'] == receipt['bundleManifestSHA256'], 'Manifest commitment differs')
    return {'path': path, 'receipt': receipt, 'serverSHA256': files[prefix + 'bin/tractanda']['sha256']}


def require_guest_baseline(build_os, release):
    os_id = release.get('ID', '').strip('\"')
    version = release.get('VERSION_ID', '').strip('\"')
    codename = release.get('VERSION_CODENAME', '').strip('\"')
    require(bool(re.fullmatch(r'[0-9]+(?:\.[0-9]+)*', version)) and
            ((build_os == 'debian13' and os_id == 'debian' and version.split('.')[0] == '13')
             or (build_os == 'kali-rolling' and os_id == 'kali' and codename == 'kali-rolling')),
            'Guest baseline differs from explicit context')


def require_package_baseline(package, build_os, manifest_path):
    require(digest(manifest_path) == package['receipt']['bundleManifestSHA256'], 'Package manifest commitment differs')
    manifest = read_json(manifest_path, 4 * 1024**2)
    require(manifest.get('linuxBuildOS', 'debian13') == build_os, 'Package baseline differs from guest context')


def model_catalog_bytes(path, manifest):
    catalog = read_json(path)
    require(digest(path) == manifest.get('modelProvisioningManifestSHA256'), 'Model catalog commitment differs')
    artifacts = catalog.get('artifacts', [])
    require(len(artifacts) == 2 and {a.get('identifier') for a in artifacts} == {
        'granite-embedding-311m-multilingual-r2', 'granite-docling-258m-mlx'}, 'Unexpected model catalog')
    sizes = [f.get('size') for a in artifacts for f in a.get('files', [])]
    require(sizes and all(type(n) is int and n > 0 for n in sizes), 'Invalid model catalog sizes')
    return sum(sizes)


def model_status_complete(status, ready):
    expected = {'granite-embedding-311m-multilingual-r2', 'granite-docling-258m-mlx'}
    return (isinstance(status, list) and len(status) == 2
            and {row.get('artifact') for row in status if isinstance(row, dict)} == expected
            and all((row.get('phase') == 'ready') == ready for row in status))


def bind_artifacts(context, roles):
    bindings = context.get('artifactBindings')
    if bindings is not None:
        require(set(bindings) == {role for role, _ in roles}, 'Artifact binding roles differ from requested inputs')
    packages = []
    for role, path in roles:
        binding = bindings[role] if bindings is not None else {
            'buildOS': 'debian13', 'payloadMode': context.get('payloadMode', 'full')}
        require(isinstance(binding, dict) and binding.get('buildOS') in ('debian13', 'kali-rolling')
                and binding.get('payloadMode') in ('full', 'slim'), 'Invalid artifact binding')
        package = artifact(path, binding['payloadMode'])
        package['buildOS'], package['payloadMode'], package['role'] = binding['buildOS'], binding['payloadMode'], role
        if bindings is not None:
            require(binding.get('packageSHA256') == package['receipt']['packageSHA256'], 'Artifact role hash differs')
            manifest = binding.get('manifest')
            require(isinstance(manifest, str) and Path(manifest).is_absolute(), 'Missing package manifest binding')
            require_package_baseline(package, binding['buildOS'], Path(manifest))
            package['manifestPath'] = manifest
        packages.append(package)
    return packages


def require_target_baseline(guest_os, packages):
    target = next((p for p in packages if p['role'] == 'upgrade'), packages[0])
    if guest_os == 'kali-rolling':
        require(target['buildOS'] == 'kali-rolling', 'Target package must have Kali build provenance')


def distinct_binary(first, second):
    require(first['receipt']['packageSHA256'] != second['receipt']['packageSHA256']
            and first['serverSHA256'] != second['serverSHA256'],
            'A renamed/revision-only package is not evidence of a different binary')


def inventory(roots, hashes=True):
    """Record absence, bytes and directory custody, excluding inode/time/directory-size churn."""
    result, total = {}, 0
    roots = tuple(Path(root) for root in roots)
    monitored_roots = set(roots)
    def record(path):
        nonlocal total
        key = str(path)
        if key in result:
            return
        try:
            info = path.lstat()
        except FileNotFoundError as error:
            if error.errno == errno.ENOENT and not hashes and path.name == '.tractanda-checkpoint-dirty' and path.parent in monitored_roots:
                return
            raise
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


HISTORICAL_171_PACKAGES = {
    'ce930c5934ddecdd7f897a5685b12274964efff714f69a59f4fb5012294eb1cb',
    '0009c7bc28673ce305b661f69ca93ee3404a64a3d19159b4cbdf01ea4e47b846',
}
HISTORICAL_FIXTURE_SUBJECT = 'Explore your shared knowledge base'
HISTORICAL_FIXTURE_BODY = 'Synthetic private upgrade qualification fixture.'


def historical_fixture_permissions(owner, group):
    text = lambda value: {'type': 'text', 'value': value}
    return {'type': 'object', 'value': {
        'profile': text('tractanda.permissions.posix.v1'), 'owner': text(owner), 'group': text(group),
        'mode': {'type': 'integer', 'value': '384'}, 'acl': {'type': 'object', 'value': {}},
    }}


def historical_fixture_command(context, name):
    owner = context['owner']
    group = grp.getgrgid(pwd.getpwnam(owner).pw_gid).gr_name
    request = {'action': 'create', 'classID': 'Item',
               'operationID': 'kali-upgrade-fixture-v1-' + context['runID'], 'unset': [],
               'changes': {'subject': {'type': 'text', 'value': HISTORICAL_FIXTURE_SUBJECT},
                           'body': {'type': 'text', 'value': HISTORICAL_FIXTURE_BODY},
                           'permissions': historical_fixture_permissions(owner, group)}}
    return [CLI, '--no-start', '--socket', '/run/tractanda/' + name + '/server.sock', 'call',
            'TractandaItem/commit', json.dumps(request, sort_keys=True, separators=(',', ':'))]


def validate_fixture_receipt(receipt, operation_id):
    require(isinstance(receipt, dict) and set(receipt) ==
            {'itemId', 'revisionId', 'operationId', 'replayed', 'indexReady', 'diagnostics'},
            'Historical fixture returned an invalid mutation receipt')
    try:
        identities = [uuid.UUID(receipt[key]) for key in ('itemId', 'revisionId')]
    except (ValueError, TypeError, AttributeError):
        raise ValueError('Historical fixture receipt identities are invalid')
    require(all(value.version == 1 and str(value) == receipt[key]
                for value, key in zip(identities, ('itemId', 'revisionId')))
            and receipt['operationId'] == operation_id and type(receipt['replayed']) is bool
            and type(receipt['indexReady']) is bool and isinstance(receipt['diagnostics'], list)
            and len(receipt['diagnostics']) == len(set(receipt['diagnostics']))
            and all(value in ('indexDelayed', 'checkpointPending', 'additionalDiagnostics')
                    for value in receipt['diagnostics']), 'Historical fixture receipt does not match the committed operation')
    return receipt['itemId']


def validate_historical_readback(fetched, item_id, revision_id, operation_id, owner, group):
    require(isinstance(fetched, dict) and isinstance(fetched.get('list'), list) and len(fetched['list']) == 1
            and isinstance(fetched['list'][0], dict) and fetched['list'][0].get('id') == item_id
            and fetched['list'][0].get('revisionId') == revision_id,
            'Historical fixture identity could not be read back exactly')
    fields = fetched['list'][0].get('fields')
    require(isinstance(fields, dict)
            and fields.get('subject') == {'type': 'text', 'value': HISTORICAL_FIXTURE_SUBJECT}
            and fields.get('body') == {'type': 'text', 'value': HISTORICAL_FIXTURE_BODY}
            and fields.get('operationID') == {'type': 'text', 'value': operation_id}
            and fields.get('permissions') == historical_fixture_permissions(owner, group),
            'Historical fixture content, operation or private permissions differ')


def setup_arguments(context, name):
    setup = [SETUP, 'install', '--name', name, '--owner', context['owner'], '--port', str(context['port'])]
    node = configured_uuid_node(context)
    if node is not None:
        setup += ['--uuid-node', node]
    if context['selection'] == 'first-source':
        setup += ['--first-source']
        if context.get('fixtureSeed', 'sample') == 'sample':
            setup += ['--sample']
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
    require(context.get('buildOS', 'debian13') in ('debian13', 'kali-rolling'), 'Unknown guest baseline')
    if context.get('buildOS', 'debian13') == 'kali-rolling':
        require(isinstance(context.get('artifactBindings'), dict), 'Kali validation requires explicit artifact bindings')
    bindings = context.get('artifactBindings', {})
    seed = context.get('fixtureSeed', 'sample')
    require(seed in ('sample', 'historical-api'), 'Unknown fixture seed mode')
    if seed == 'historical-api':
        package = bindings.get('package', {})
        upgrade = bindings.get('upgrade', {})
        require(context.get('buildOS') == 'kali-rolling' and context['selection'] == 'first-source'
                and package.get('packageSHA256') in HISTORICAL_171_PACKAGES
                and package.get('buildOS') == 'debian13' and package.get('payloadMode') == 'slim'
                and upgrade.get('buildOS') == 'kali-rolling' and upgrade.get('payloadMode') == 'slim'
                and isinstance(upgrade.get('packageSHA256'), str)
                and re.fullmatch(r'[0-9a-f]{64}', upgrade['packageSHA256'])
                and upgrade['packageSHA256'] != package['packageSHA256'],
                'Historical API fixture requires a genuine bound predecessor and distinct Kali upgrade')
    first_mode = bindings.get('package', {}).get('payloadMode', context.get('payloadMode', 'full'))
    any_slim = first_mode == 'slim' or any(isinstance(v, dict) and v.get('payloadMode') == 'slim' for v in bindings.values())
    if any_slim:
        require(configured_uuid_node(context) is not None, 'Slim loopback guest requires controller-attested UUID node')
    require(first_mode in ('full', 'slim'), 'Unknown payload mode')
    if first_mode == 'slim':
        require(context['selection'] == 'first-source', 'Slim offline FTS requires the first-source sample')
        source = context.get('offlineModelSource')
        require(isinstance(source, str) and source.startswith('/') and source != '/',
                'Slim validation requires an absolute offline model source')
        catalog = context.get('offlineModelCatalog')
        require(isinstance(catalog, str) and catalog.startswith('/') and catalog != '/',
                'Slim validation requires the exact offline model catalog')
    require(49152 <= context['port'] <= 65535 and 0 < context['expiresAt'] - time.time() <= 3600,
            'Context port or validity window rejected')


def status_fields(text):
    """Parse fixed systemd-style status output, allowing only empty separator lines."""
    fields = {}
    for line in text.splitlines():
        if not line.strip():
            continue
        key, separator, value = line.partition('=')
        require(separator and key and key not in fields, 'Malformed or duplicate status field')
        fields[key] = value
    return fields


UUIDD_POLICY_REFUSAL = 'tractanda package fallback: uuidd still runs continuous-clock mode; restart may be policy-blocked'


def classify_policy_reinstall(exit_code, output, dpkg_status, continuous):
    if exit_code == 0:
        require(dpkg_status == 'install ok installed' and not continuous,
                'Successful policy-denied install lacks installed state or has continuous-clock uuidd')
        return 'already-compliant-success'
    require(exit_code == 1 and output.splitlines().count(UUIDD_POLICY_REFUSAL) == 1
            and dpkg_status == 'install ok half-configured' and continuous,
            'Policy-denied install failed without independently confirmed uuidd safety refusal')
    return 'safe-refusal-retry-required'


def fixture_port_sockets(text, port):
    """Bounded kernel TCP rows for one owned fixture port."""
    rows = []
    for line in text.splitlines()[1:]:
        fields = line.split()
        require(len(fields) >= 10, 'Malformed kernel TCP observation')
        local = fields[1].rsplit(':', 1)
        require(len(local) == 2 and re.fullmatch(r'[0-9A-Fa-f]{4}', local[1]),
                'Malformed kernel TCP endpoint')
        if int(local[1], 16) == port:
            require(re.fullmatch(r'[0-9A-Fa-f]{2}', fields[3]) and fields[9].isdigit(),
                    'Malformed kernel TCP state or inode')
            rows.append({'state': fields[3].upper(), 'inode': fields[9]})
    return rows


def upgrade_port_blocker(port):
    """Bind an exclusive listener despite TIME_WAIT from the stopped fixture server."""
    blocker = socket.socket()
    try:
        blocker.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        blocker.bind(('127.0.0.1', port))
        blocker.listen(1)
        return blocker
    except BaseException:
        blocker.close()
        raise


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
        self.fixture_item_id = None
        self.store = Path('/opt/tractanda/var/lib/tractanda/Stores') / self.name
        self.index = Path('/opt/tractanda/var/lib/tractanda/StoreIndices') / self.name
        self.private = Path('/opt/tractanda/etc/tractanda/peer-runtime') / (self.name + '.json')
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
        model_storage = Path('/opt/tractanda/var/lib/tractanda/Models')
        require(not model_storage.is_symlink(), 'Unsafe guest model storage link')
        if model_storage.exists():
            fs = os.statvfs(model_storage)
            require(fs.f_frsize > 0 and fs.f_frsize * fs.f_bavail >= RESERVE, 'Model filesystem reserve rejected')
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
                if row['argv'][0] in ('/usr/bin/dpkg', SETUP):
                    node = configured_uuid_node(self.context)
                    if node is not None:
                        env['TRACTANDA_UUID_NODE'] = node
                if server_probe:
                    prefix = [CLI, '--no-start', '--socket', '/run/tractanda/' + self.name + '/server.sock']
                    allowed = [prefix + ['info'], prefix + ['search', 'shared knowledge base']]
                    if self.context.get('fixtureSeed', 'sample') == 'historical-api':
                        allowed.append(historical_fixture_command(self.context, self.name))
                        if self.fixture_item_id is not None:
                            allowed.append(prefix + ['get', self.fixture_item_id])
                    require(row['argv'] in allowed, 'Daemon peer binding is only permitted for the fixed native probes')
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
            fields = status_fields(value)
            require(fields['LoadState'] in ('loaded', 'not-found') and fields['ActiveState'] in ('inactive', 'failed')
                    and fields['MainPID'] == '0', 'Writer/support service not stopped')
            if disabled:
                require(fields.get('UnitFileState') == 'disabled' if fields['LoadState'] == 'loaded'
                        else fields.get('UnitFileState', '') in ('', 'not-found'),
                        'Pending/failed package could start at boot')

    def observe_uuidd(self, label):
        command = ['/usr/bin/systemctl', 'show', 'uuidd.service', '--property=MainPID', '--value']
        pid = self.command(command).strip()
        require(pid.isdecimal(), 'uuidd PID is malformed')
        if int(pid) == 0:
            observation = {'state': 'inactive', 'pid': 0, 'continuous': False, 'argv': []}
            self.result.setdefault('uuiddObservations', {})[label] = observation
            self.save()
            return observation
        proc = Path('/proc') / pid
        require(os.readlink(proc / 'exe') == '/usr/sbin/uuidd', 'uuidd process identity differs')
        with (proc / 'cmdline').open('rb') as stream:
            raw = stream.read(8193)
        require(len(raw) <= 8192 and raw.endswith(b'\0'), 'uuidd command line is malformed')
        args = [value.decode('ascii') for value in raw.split(b'\0') if value]
        require(args and args[0] == '/usr/sbin/uuidd', 'uuidd command line identity differs')
        require(self.command(command).strip() == pid, 'uuidd process changed during observation')
        require(not any((value.startswith('--cont') and not re.fullmatch(r'--cont-clock(?:=[0-9]+[hd]?)?', value))
                        or value.startswith('-C') for value in args[1:]), 'Ambiguous uuidd continuous-clock option')
        observation = {'state': 'running', 'pid': int(pid), 'argv': args,
                       'continuous': any(re.fullmatch(r'--cont-clock(?:=[0-9]+[hd]?)?', value) for value in args[1:])}
        self.result.setdefault('uuiddObservations', {})[label] = observation
        self.save()
        return observation

    def ready(self, package, previous=None):
        state = status_fields(self.command([SETUP, 'status', '--name', self.name]))
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

    def observe_embedding_port(self, label):
        port = self.context['port'] + 1
        rows = []
        for filename in ('/proc/net/tcp', '/proc/net/tcp6'):
            with open(filename, 'r', encoding='ascii') as stream:
                text = stream.read(1024 * 1024 + 1)
            require(len(text) <= 1024 * 1024, 'Kernel TCP observation exceeds bound')
            rows.extend(fixture_port_sockets(text, port))
        listener = self.command(['/usr/bin/sudo', '-n', '-u', 'daemon', '--', '/usr/bin/lsof',
                                 '-nP', '-iTCP:' + str(port), '-sTCP:LISTEN', '-Fpn'], codes=(0, 1))
        observation = {'port': port, 'kernelSockets': rows, 'daemonListenerLines': listener.splitlines()}
        self.result.setdefault('embeddingPortObservations', {})[label] = observation
        self.save()
        return observation

    def wait_embedding_ready(self):
        unit = 'tractanda-embeddings-' + self.name + '.service'
        while True:
            self.guard()
            fields = status_fields(self.command(['/usr/bin/systemctl', 'show', unit,
                                                  '--property=ActiveState,SubState,MainPID']))
            if not (fields.get('ActiveState') in ('active', 'activating')
                    and fields.get('SubState') not in ('auto-restart', 'failed', 'dead', None)
                    and fields.get('MainPID', '').isdigit()):
                reason = 'Embedding service failed or became inactive during readiness'
                self.result['embeddingReadinessFailure'] = {'reason': reason, 'serviceState': fields}
                self.save()
                try:
                    self.observe_embedding_port('readiness-failure')
                except Exception as diagnostic_error:
                    self.result['embeddingReadinessFailure']['diagnosticError'] = str(diagnostic_error)
                    self.save()
                raise ValueError(reason)
            connection = http.client.HTTPConnection('127.0.0.1', self.context['port'] + 1, timeout=2)
            try:
                connection.request('GET', '/health')
                response = connection.getresponse()
                health = json.loads(response.read(65537))
                if (response.status == 200 and health.get('ready') is True
                        and health.get('model') == 'tractanda-granite-embedding-311m-multilingual-r2-vmlx-fp32-44399559'):
                    break
            except (OSError, ValueError, http.client.HTTPException):
                pass
            finally:
                connection.close()
            time.sleep(1)
        fields = status_fields(self.command(['/usr/bin/systemctl', 'show', unit,
                                              '--property=ActiveState,SubState,MainPID']))
        require(fields.get('ActiveState') == 'active' and fields.get('MainPID', '').isdigit()
                and int(fields['MainPID']) > 0 and health.get('pid') == int(fields['MainPID']),
                'Embedding health is not bound to the active service process')
        pid = int(fields['MainPID'])
        listener = self.command(['/usr/bin/sudo', '-n', '-u', 'daemon', '--', '/usr/bin/lsof', '-nP', '-a', '-p', str(pid),
                                 '-iTCP:' + str(self.context['port'] + 1), '-sTCP:LISTEN', '-Fpn'])
        require('p' + str(pid) in listener.splitlines()
                and 'n127.0.0.1:' + str(self.context['port'] + 1) in listener.splitlines(),
                'Embedding service does not own the health listener')
        return pid

    def installed(self, package, configured=True):
        fields = self.command(['/usr/bin/dpkg-query', '-W', '-f=${Status}\t${Version}\t${Architecture}', 'tractanda']).strip().split('\t')
        require(len(fields) == 3 and fields[1:] == [package['receipt']['version'], package['receipt']['arch']]
                and (fields[0] == 'install ok installed' if configured else fields[0] in
                     ('install ok unpacked', 'install ok half-configured')), 'Actual dpkg state/version/architecture differs')
        manifest = read_json(PAYLOAD / 'bundle-manifest.json', 4 * 1024**2)
        require(digest(PAYLOAD / 'bundle-manifest.json') == package['receipt']['bundleManifestSHA256']
                and manifest.get('embedding') and manifest.get('documentExtraction'), 'Actual active full payload differs')
        expected_os = package.get('buildOS', self.context.get('buildOS', 'debian13'))
        require(manifest.get('linuxBuildOS', 'debian13') == expected_os, 'Package baseline differs from guest context')
        require(manifest['version'] != '', 'Missing source version')
        self.command([SETUP, 'plan', '--bundle', PAYLOAD], timeout=self.command_timeout_seconds)
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
    build_os = context.get('buildOS', 'debian13')
    require_guest_baseline(build_os, release)
    roles = [('package', args.package), ('upgrade', args.upgrade), ('olderRefusal', args.older_refusal)]
    roles = [(role, path) for role, path in roles if path is not None]
    packages = bind_artifacts(context, roles)
    require((args.older_refusal is None) == (args.older_manifest is None), 'Older refusal needs its actual hash-bound bundle manifest')
    arch = ARCH[platform.machine()]
    require(all(p['receipt']['arch'] == arch for p in packages), 'Package/native architecture mismatch')
    require_target_baseline(build_os, packages)
    payload_mode = packages[0]['payloadMode']
    if any(p['payloadMode'] == 'slim' for p in packages):
        require(all(name == 'lo' for _, name in socket.if_nameindex()), 'Slim offline guest must have loopback only')
    if payload_mode == 'slim':
        model_source = Path(context['offlineModelSource'])
        require(model_source.is_absolute() and not model_source.is_symlink() and model_source.is_dir()
                and os.statvfs(model_source).f_flag & os.ST_RDONLY, 'Model source must be a read-only mount')
    require(all(not path.exists() and not path.is_symlink() for path in
                (PAYLOAD, Path('/opt/tractanda/var/lib/tractanda/Installation/receipts'), Path('/usr/sbin/policy-rc.d'))),
            'Use a fresh isolated image without another installation/policy fixture or dangling link')
    if payload_mode == 'slim':
        require('manifestPath' in packages[0], 'Slim package needs its bound manifest')
        manifest_path = Path(packages[0]['manifestPath'])
        manifest = read_json(manifest_path, 4 * 1024**2)
        catalog_path = Path(context['offlineModelCatalog'])
        model_bytes = model_catalog_bytes(catalog_path, manifest)
        require(context['softwareAllowanceBytes'] >= 2 * model_bytes + sum(p['receipt']['installedKiB'] * 1024 for p in packages),
                'Software allowance does not cover package and model import staging')
        model_storage = Path('/opt/tractanda/var/lib/tractanda/Models')
        require(not model_storage.exists() and not model_storage.is_symlink(), 'Slim test requires fresh model storage')
    pwd.getpwnam('daemon'); pwd.getpwnam(context['owner'])  # Never provision an account.
    work = Path('/var/tmp/tractanda-package-validation-' + context['runID']); work.mkdir(mode=0o700)
    check = Validation(context, work, args.timeout_seconds, args.command_timeout_seconds); current = packages[0]
    check.result['artifacts'] = [{'role': p['role'], 'packageSHA256': p['receipt']['packageSHA256'],
                                  'buildOS': p['buildOS'], 'payloadMode': p['payloadMode']} for p in packages]
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
        require(not check.observe_uuidd('initial-install')['continuous'], 'Initial install left continuous-clock uuidd running')
        require(inventory([check.store, check.private]) == before, 'Package implicitly bootstrapped/joined a store')
        require(not check.store.parent.exists() or {p.name for p in check.store.parent.iterdir()} <=
                ({check.name} if context['selection'] == 'prepared' else set()), 'Package created an unrelated store')
        require(not check.command(['/usr/bin/systemctl', 'list-units', '--type=service', '--all',
                    '--no-legend', '--no-pager', 'tractanda-*.service']).strip(), 'Fresh package started/registered an unrelated service')
        check.command(setup_arguments(context, check.name), timeout=check.command_timeout_seconds)
        identity = check.ready(current)
        if payload_mode == 'slim':
            socket_path = '/run/tractanda/' + check.name + '/server.sock'
            info = json.loads(check.command([CLI, '--no-start', '--socket', socket_path, 'info'], server_probe=True))
            require(info.get('documentExtraction', {}).get('state') == 'awaitingModel', 'Document model was not initially absent')
            initial_status = json.loads(check.command(['/usr/bin/sudo', '-n', '-u', 'daemon', '--', CLI,
                'models', 'status', '--manifest', str(PAYLOAD / 'models/manifest.json'), '--storage',
                '/opt/tractanda/var/lib/tractanda/Models']))
            require(model_status_complete(initial_status, ready=False),
                    'Model artifact unexpectedly ready before offline import')
            health_connection = http.client.HTTPConnection('127.0.0.1', context['port'] + 1, timeout=2)
            try:
                health_connection.request('GET', '/health')
                response = health_connection.getresponse()
                require(response.status != 200, 'Embedding worker unexpectedly ready before offline import')
            except (OSError, http.client.HTTPException):
                pass
            finally:
                health_connection.close()
            if context.get('fixtureSeed', 'sample') == 'historical-api':
                operation_id = 'kali-upgrade-fixture-v1-' + context['runID']
                receipt = json.loads(check.command(historical_fixture_command(context, check.name), server_probe=True))
                check.fixture_item_id = validate_fixture_receipt(receipt, operation_id)
                fetched = json.loads(check.command([CLI, '--no-start', '--socket', socket_path,
                                                    'get', check.fixture_item_id], server_probe=True))
                owner = context['owner']
                group = grp.getgrgid(pwd.getpwnam(owner).pw_gid).gr_name
                validate_historical_readback(fetched, check.fixture_item_id, receipt['revisionId'],
                                             operation_id, owner, group)
                check.result['cases']['historical-api-fixture'] = {
                    'status': 'PASS', 'itemID': check.fixture_item_id,
                    'revisionID': receipt['revisionId'], 'operationID': operation_id}
            result = json.loads(check.command([CLI, '--no-start', '--socket', socket_path, 'search',
                                               'shared knowledge base'], server_probe=True))
            require(context['selection'] == 'first-source' and isinstance(result.get('ids'), list)
                    and len(result['ids']) > 0
                    and (check.fixture_item_id is None or check.fixture_item_id in result['ids']),
                    'Offline fixture full-text search did not return the expected item')
            check.result['cases']['slim-offline-core-fts'] = {'status': 'PASS', 'packageSHA256': current['receipt']['packageSHA256']}
            embedding_unit = 'tractanda-embeddings-' + check.name + '.service'
            check.command([SETUP, 'stop', '--name', check.name], timeout=check.command_timeout_seconds)
            check.stopped()
            require(not model_storage.is_symlink() and model_storage.is_dir(), 'Unsafe guest model storage')
            fs = os.statvfs(model_storage)
            require(fs.f_frsize * fs.f_bavail >= RESERVE + 2 * model_bytes, 'Model backing filesystem reserve rejected')
            check.command(['/usr/bin/sudo', '-n', '-u', 'daemon', '--', CLI, 'models', 'import',
                           '--manifest', str(PAYLOAD / 'models/manifest.json'), '--storage',
                           '/opt/tractanda/var/lib/tractanda/Models', '--from', str(model_source)],
                          timeout=check.command_timeout_seconds)
            model_status = json.loads(check.command(['/usr/bin/sudo', '-n', '-u', 'daemon', '--', CLI,
                'models', 'status', '--manifest', str(PAYLOAD / 'models/manifest.json'), '--storage',
                '/opt/tractanda/var/lib/tractanda/Models']))
            require(model_status_complete(model_status, ready=True),
                    'Imported model artifacts are not ready')
            check.command([SETUP, 'start', '--name', check.name], timeout=check.command_timeout_seconds)
            identity = check.ready(current)
            pid = check.wait_embedding_ready()
            info = json.loads(check.command([CLI, '--no-start', '--socket', socket_path, 'info'], server_probe=True))
            require(info.get('documentExtraction', {}).get('state') == 'configured', 'Imported document model not configured')
            check.result['modelArtifactBytes'] = model_bytes
            check.result['embeddingWorkerPID'] = pid
            converter = check.command(['/usr/bin/sudo', '-n', '-u', 'daemon', '--', str(PAYLOAD / 'bin/tractanda-document-converter')], codes=(1,))
            require('usage: converter prepare|convert' in converter, 'Document worker did not load')
            check.result['cases']['slim-offline-model-import-and-worker'] = {'status': 'PASS', 'packageSHA256': current['receipt']['packageSHA256']}
        check.command([SETUP, 'stop', '--name', check.name], timeout=check.command_timeout_seconds)
        check.stopped()
        baseline = check.snapshot()
        check.result['retainedFixture'] = baseline
        if payload_mode == 'slim':
            observation = check.observe_embedding_port('before-baseline-restart')
            require(not any(row['state'] == '0A' for row in observation['kernelSockets']),
                    'Embedding port has an active listener after owned services stopped')
        check.command([SETUP, 'start', '--name', check.name], timeout=check.command_timeout_seconds)
        identity = check.ready(current)
        if payload_mode == 'slim':
            check.result['embeddingWorkerPIDAfterRestart'] = check.wait_embedding_ready()
        check.result['cases']['explicit-selection'] = 'PASS'
        if args.upgrade:
            incoming = next(p for p in packages if p['path'] == args.upgrade.resolve()); distinct_binary(current, incoming)
            check.command(['/usr/bin/dpkg', '--compare-versions', current['receipt']['version'], 'lt', incoming['receipt']['version']])
            check.command(['/usr/bin/dpkg', '--unpack', incoming['path']], timeout=check.command_timeout_seconds)
            check.stopped(disabled=True)
            with upgrade_port_blocker(context['port']):
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
        require(not check.observe_uuidd('before-remove')['continuous'], 'Installed uuidd entered continuous-clock mode')
        check.command(['/usr/bin/dpkg', '--remove', 'tractanda'], timeout=check.command_timeout_seconds)
        check.stopped(); retained(baseline, check.snapshot())
        check.observe_uuidd('after-remove')
        require(not Path(CLI).exists(), 'Removed payload still present')
        with denied_policy(context['runID']):
            output = check.command(['/usr/bin/dpkg', '--install', current['path']], codes=(0, 1),
                                   timeout=check.command_timeout_seconds)
            install_exit = check.result['commands'][-1]['exit']
            dpkg_status = check.command(['/usr/bin/dpkg-query', '-W', '-f=${Status}', 'tractanda']).strip()
            denied_uuidd = check.observe_uuidd('during-policy-denial')
            branch = classify_policy_reinstall(install_exit, output, dpkg_status, denied_uuidd['continuous'])
            check.stopped(disabled=True)
            retained(baseline, check.snapshot())
            if branch == 'already-compliant-success':
                check.installed(current)
        if branch == 'safe-refusal-retry-required':
            check.command(['/usr/bin/dpkg', '--configure', 'tractanda'], timeout=check.command_timeout_seconds)
            check.installed(current)
            require(not check.observe_uuidd('after-normal-retry')['continuous'],
                    'Normal retry left continuous-clock uuidd running')
        check.result['cases']['policy-denied-reinstall'] = branch
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
