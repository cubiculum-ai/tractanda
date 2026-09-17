#!/usr/bin/env python3
"""Resume an audited macOS prerelease through validation, installation and publication.

prepare seals a completed changeset; run works only on that committed snapshot.
Machine paths/signing identities live in an ignored JSON configuration. No keys
are exported, no production uninstall is performed, and no privileged helper is
left behind. Administrator authentication uses the ordinary macOS dialog.
"""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
RELEASE_STEPS = tuple(json.loads(Path(__file__).with_name('release-steps.json').read_text()))
CONTROL = ROOT / 'work/release-pipeline'
DEFAULT_CONFIG = CONTROL / 'config.json'
VERSION_FILES = ['plugins/tractanda/.codex-plugin/plugin.json',
                 'plugins/tractanda/.claude-plugin/plugin.json', '.claude-plugin/marketplace.json']
SIGNIFICANT = ('Sources/', 'Packages/', 'Tests/', 'scripts/', 'templates/', 'examples/',
               'plugins/', '.github/', 'docs/', '.claude-plugin/', '.agents/plugins/')


def now():
    return datetime.now(timezone.utc).isoformat()


def read(path):
    return json.loads(Path(path).read_text())


def write(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')
        temporary = Path(stream.name)
    temporary.replace(path)


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def command(args, cwd=ROOT, env=None):
    return subprocess.check_output([str(a) for a in args], cwd=cwd, env=env, text=True).strip()


def git(*args, cwd=ROOT):
    return command(['git', *args], cwd=cwd)


def release_info(repository, tag):
    # GitHub's tag endpoint cannot find an unpublished draft without a tag ref.
    identity = json.loads(command(['gh', 'release', 'view', tag, '--repo', repository,
                                   '--json', 'databaseId']))
    identifier = identity['databaseId']
    if not isinstance(identifier, int) or identifier <= 0:
        raise ValueError('GitHub returned an invalid release ID.')
    return json.loads(command(['gh', 'api', f'repos/{repository}/releases/{identifier}']))


@contextmanager
def lock():
    CONTROL.mkdir(parents=True, exist_ok=True)
    with (CONTROL / 'pipeline.lock').open('a') as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Another release operation is running; inspect status instead of starting a duplicate.')
        yield


def config(path):
    value = read(path)
    required = ('repository', 'branch', 'instance', 'softwareRoot', 'applicationIdentity',
                'installerIdentity', 'embeddingHost', 'modelDirectory', 'modelNotices',
                'developerTeamID')
    missing = [k for k in required if not isinstance(value.get(k), str) or not value[k]]
    if missing:
        raise ValueError('Missing local release configuration: ' + ', '.join(missing))
    if not re.fullmatch(r'[\w.-]+/[\w.-]+', value['repository']):
        raise ValueError('Invalid repository.')
    if not re.fullmatch(r'[a-z0-9-]+', value['instance']):
        raise ValueError('Invalid installation name.')
    if value['applicationIdentity'] == '-' or value['installerIdentity'] == '-':
        raise ValueError('Published releases require persistent Developer ID identities.')
    if not re.fullmatch(r'[A-Z0-9]{10}', value['developerTeamID']):
        raise ValueError('developerTeamID must identify the expected Apple Developer team.')
    return value


def validate_signing_environment(settings):
    # Inspect certificate identity metadata only. Xcode owns account authentication
    # during export; no password, API key or separate notarytool profile is needed.
    command(['xcodebuild', '-version'])
    identities = command(['/usr/bin/security', 'find-identity', '-v'])
    for key, kind in (('applicationIdentity', 'Application'), ('installerIdentity', 'Installer')):
        matches = re.findall(r'([A-Fa-f0-9]{40}) "(Developer ID ' + kind + r': [^"\n]+)"', identities)
        valid = [identity for identity in matches if
                 identity[1].endswith('(' + settings['developerTeamID'] + ')') and
                 settings[key] in identity]
        if not valid:
            raise RuntimeError('The configured Developer ID ' + kind +
                               ' identity is unavailable for this team. Check certificates in Xcode. '
                               'No release has been prepared.')


def significant(paths):
    return any(p.startswith(SIGNIFICANT) or p in {
        'Package.swift', 'Package.resolved', 'VERSION', 'README.md', 'RELEASING.md',
        'CHANGELOG.md', 'LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES.md', 'install.sh',
    } for p in paths)


def next_version(version):
    match = re.fullmatch(r'(\d+\.\d+\.\d+-poc\.)(\d+)', version)
    if not match:
        raise ValueError('Expected a numbered proof-of-concept version.')
    return match[1] + str(int(match[2]) + 1)


def release_version(path):
    match = re.fullmatch(r'(\d+)\.(\d+)\.(\d+)-poc\.(\d+)', Path(path).name)
    return tuple(map(int, match.groups())) if match else None


def is_verified_published(state):
    if not isinstance(state, dict) or state.get('status') != 'complete':
        return False
    version = state.get('version', '')
    configuration = state.get('configuration', {})
    steps = state.get('steps', {})
    if not isinstance(configuration, dict) or not isinstance(steps, dict):
        return False
    published = steps.get('publish', {})
    result = published.get('result', {}) if isinstance(published, dict) else {}
    repo = configuration.get('repository', '')
    if not isinstance(result, dict) or not isinstance(repo, str) or not re.fullmatch(r'[\w.-]+/[\w.-]+', repo):
        return False
    if not isinstance(version, str) or release_version(version) is None:
        return False
    if not isinstance(state.get('commit'), str) or not re.fullmatch(r'[0-9a-f]{40}', state['commit']):
        return False
    if result.get('url') != f'https://github.com/{repo}/releases/tag/v{version}':
        return False
    hashes = result.get('sha256')
    expected = {f'tractanda-{version}-macos-arm64.tar.gz', f'Tractanda-{version}-arm64.pkg', 'SHA256SUMS'}
    return (isinstance(hashes, dict) and expected.issubset(hashes)
            and all(isinstance(name, str) and Path(name).name == name
                    and isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value)
                    for name, value in hashes.items()))


def prune_releases():
    """Caller holds pipeline.lock. Reclaim only self-bound, published build trees."""
    report = {'removed': [], 'compacted': [], 'retained': [], 'skipped': [], 'prunedWorktrees': []}
    if not CONTROL.exists():
        return report
    receipts = CONTROL / 'receipts'
    current_path = CONTROL / 'current.json'
    if CONTROL.is_symlink() or receipts.is_symlink() or current_path.is_symlink():
        raise RuntimeError('Release control/receipt paths must not be symlinks.')
    current = read(current_path) if current_path.exists() else {}
    if not isinstance(current, dict):
        raise RuntimeError('Invalid current release state; refusing cleanup.')
    active = current.get('directory') if current.get('status') != 'complete' else None
    active_path = Path(active).resolve() if isinstance(active, str) and active else None
    candidates = []
    for path in sorted(CONTROL.iterdir()):
        if release_version(path) is None or path.is_symlink() or not path.is_dir():
            continue
        state_path = path / 'state.json'
        if state_path.is_symlink() or not state_path.is_file():
            continue
        try:
            state = read(state_path)
        except (OSError, ValueError):
            report['skipped'].append({'version': path.name, 'reason': 'unreadable state'})
            continue
        if (not is_verified_published(state) or state.get('directory') != str(path)
                or state['version'] != path.name):
            continue
        candidates.append((path, state))
    newest = max((path for path, _ in candidates), key=release_version, default=None)
    # Git's NUL-delimited format preserves spaces in linked checkout paths.
    registered, entry = {}, None
    for field in git('worktree', 'list', '--porcelain', '-z').split('\0'):
        if field.startswith('worktree '):
            entry = str(Path(field[9:]).resolve()); registered[entry] = {'locked': False}
        elif field.startswith('locked') and entry:
            registered[entry]['locked'] = True
    for path, state in candidates:
        if path.resolve() == active_path:
            report['retained'].append(path.name)
            continue
        source = path / 'source'
        source_key = str(source.resolve())
        if source.is_symlink() or (source.exists() and not source.is_dir()):
            report['skipped'].append({'version': path.name, 'reason': 'unsafe source path'})
            continue
        if source.exists():
            try:
                if (source_key not in registered or registered[source_key]['locked']
                        or git('rev-parse', 'HEAD', cwd=source) != state['commit']
                        or git('status', '--porcelain', cwd=source)):
                    report['skipped'].append({'version': path.name, 'reason': 'source changed, locked or unregistered'})
                    continue
            except (OSError, subprocess.CalledProcessError):
                report['skipped'].append({'version': path.name, 'reason': 'source check failed'})
                continue
        # Persist provenance before removing any version tree. write() replaces
        # a receipt atomically and never follows a pre-existing receipt symlink.
        write(receipts / (path.name + '.json'), state)
        if source.exists() or source_key in registered:
            try:
                if registered.get(source_key, {}).get('locked'):
                    report['skipped'].append({'version': path.name, 'reason': 'locked checkout'})
                    continue
                git('worktree', 'remove', '--force', str(source))
                registered.pop(source_key, None)
            except (OSError, subprocess.CalledProcessError):
                report['skipped'].append({'version': path.name, 'reason': 'checkout removal failed'})
                continue
        if path != newest:
            shutil.rmtree(path)  # rmtree unlinks nested symlinks; it does not visit their targets.
            report['removed'].append(path.name)
            continue
        # Completed source and unpacked payloads are disposable; retain final
        # downloads plus compact state/log/notarization evidence for the newest.
        payloads = [path / name for name in ('.build', 'bundle', 'signed', 'staging', 'unpacked',
                    f'tractanda-{path.name}-macos-arm64')]
        payloads += list(path.glob('*.incomplete-*'))
        for target in payloads:
            if target.is_symlink(): target.unlink()
            elif target.is_dir(): shutil.rmtree(target)
            elif target.exists(): target.unlink()
        report['compacted'].append(path.name)
        report['retained'].append(path.name)
    # The user may already have removed a version folder. Remove only its
    # missing linked-checkout registration, never prune unrelated worktrees.
    for name, details in registered.items():
        source = Path(name)
        if (source.name != 'source' or source.parent.parent.resolve() != CONTROL.resolve()
                or release_version(source.parent) is None or source.parent.resolve() == active_path
                or details['locked'] or source.exists() or source.is_symlink()):
            continue
        try:
            git('worktree', 'remove', '--force', str(source))
            report['prunedWorktrees'].append(name)
        except (OSError, subprocess.CalledProcessError):
            report['skipped'].append({'version': source.parent.name, 'reason': 'stale checkout removal failed'})
    return report


def record_release_retention(pipeline):
    """A cleanup failure must not make a published release require rebuilding."""
    try:
        result = prune_releases()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        result = {'warning': str(error)}
    pipeline.state['retention'] = result
    pipeline.save()


def prepare(settings, notes):
    current_path = CONTROL / 'current.json'
    if current_path.exists() and read(current_path)['status'] != 'complete':
        raise RuntimeError('Finish or explicitly retire the pending release before preparing another.')
    prune_releases()
    if git('branch', '--show-current') != settings['branch']:
        raise RuntimeError('Prepare from the configured publication branch.')
    origins = {f'https://github.com/{settings["repository"]}.git', f'git@github.com:{settings["repository"]}.git'}
    if git('remote', 'get-url', 'origin') not in origins:
        raise RuntimeError('origin does not match the configured publication repository.')
    validate_signing_environment(settings)
    audit_path = CONTROL / 'candidate-audit.json'
    command([sys.executable, 'scripts/audit-release.py', '--output', audit_path])
    audited = read(audit_path)
    paths = [entry['path'] for entry in audited['manifest']]
    changed = git('diff', '--name-only', 'HEAD').splitlines()
    changed += git('ls-files', '--others', '--exclude-standard').splitlines()
    if not significant(changed):
        raise RuntimeError('No significant unpublished working-tree change was found.')
    version = next_version((ROOT / 'VERSION').read_text().strip())
    (ROOT / 'VERSION').write_text(version + '\n')
    for relative in VERSION_FILES:
        data = read(ROOT / relative)
        if relative == '.claude-plugin/marketplace.json':
            for plugin in data['plugins']:
                if plugin['name'] == 'tractanda':
                    plugin['version'] = version
        else:
            data['version'] = version
        write(ROOT / relative, data)
        os.chmod(ROOT / relative, 0o644)
    command([sys.executable, 'scripts/audit-release.py', '--output', audit_path])
    git('add', '--', *paths)
    command([sys.executable, 'scripts/audit-release.py', '--staged', '--output', CONTROL / 'staged-audit.json'])
    git('commit', '-m', f'Release {version}: {notes}')
    commit = git('rev-parse', 'HEAD')
    destination = CONTROL / version
    destination.mkdir()
    source = destination / 'source'
    git('worktree', 'add', '--detach', str(source), commit)
    state = {'version': version, 'commit': commit, 'tree': git('rev-parse', 'HEAD^{tree}'),
             'status': 'ready', 'createdAt': now(), 'steps': {}, 'directory': str(destination),
             'notes': notes, 'configuration': settings, 'plannedSteps': list(RELEASE_STEPS)}
    write(destination / 'state.json', state)
    write(current_path, state)
    return state


def revise(state, notes):
    """Repair an unpublished candidate without replacing any live/published release."""
    if any(name in state['steps'] for name in ('install', 'push', 'publish')):
        raise RuntimeError('This candidate has reached deployment/publication; prepare a separate release after resolving it.')
    current = Path(state['configuration']['softwareRoot']) / 'current/bundle-manifest.json'
    if current.exists() and read(current).get('version') == state['version']:
        raise RuntimeError('This candidate is already pinned locally; do not rewrite its source identity.')
    if (ROOT / 'VERSION').read_text().strip() != state['version']:
        raise RuntimeError('The pending candidate version must be retained during repair.')
    audit_path = CONTROL / 'repair-audit.json'
    command([sys.executable, 'scripts/audit-release.py', '--output', audit_path])
    git('add', '--', *[entry['path'] for entry in read(audit_path)['manifest']])
    command([sys.executable, 'scripts/audit-release.py', '--staged'])
    git('commit', '-m', f'Fix pending {state["version"]}: {notes}')
    source = Path(state['directory']) / 'source'
    if git('status', '--porcelain', cwd=source):
        raise RuntimeError('The sealed checkout changed; resolve it before revising the candidate.')
    commit = git('rev-parse', 'HEAD')
    git('checkout', '--detach', commit, cwd=source)
    state.setdefault('previousCandidates', []).append({
        'commit': state['commit'], 'steps': state['steps'], 'error': state.get('error')})
    state.update(commit=commit, tree=git('rev-parse', 'HEAD^{tree}'), steps={}, status='ready',
                 plannedSteps=list(RELEASE_STEPS), notes=notes)
    state.pop('error', None)
    state.pop('pauseReason', None)
    state.pop('activeStep', None)
    write(Path(state['directory']) / 'state.json', state)
    write(CONTROL / 'current.json', state)
    return state


class Pipeline:
    def __init__(self, state):
        self.state = state
        self.directory = Path(state['directory'])
        self.source = self.directory / 'source'
        self.settings = state['configuration']
        self.bundle = self.directory / f'tractanda-{state["version"]}-macos-arm64'
        self.package = self.directory / f'Tractanda-{state["version"]}-arm64.pkg'
        self.signed_package = self.directory / 'signed' / self.package.name
        self.archive = self.directory / (self.bundle.name + '.tar.gz')
        self.environment = {**os.environ, 'CLANG_MODULE_CACHE_PATH': str(self.source / '.build/module-cache')}

    def save(self):
        self.state['updatedAt'] = now()
        write(self.directory / 'state.json', self.state)
        write(CONTROL / 'current.json', self.state)

    def run_command(self, name, args, cwd=None):
        self.state['activeStep'] = name
        self.state['activeStepStartedAt'] = now()
        self.state['status'] = 'running'
        self.save()
        print(name, flush=True)
        with (self.directory / (name + '.log')).open('a') as log:
            log.write('\n' + now() + ' ' + shlex.join(map(str, args)) + '\n')
            log.flush()
            subprocess.run(list(map(str, args)), cwd=cwd or self.source, env=self.environment,
                           stdout=log, stderr=subprocess.STDOUT, check=True)

    def step(self, name, action):
        if name not in self.state['steps']:
            result = action()
            self.state['steps'][name] = {'completedAt': now(), 'result': result}
            self.save()

    def build(self):
        self.run_command('release-build', ['swift', 'build', '-c', 'release', '--disable-sandbox',
                                        '--disable-automatic-resolution'])

    def assemble(self):
        if self.bundle.exists():
            self.bundle.rename(self.bundle.with_name(self.bundle.name + '.incomplete-' + str(os.getpid())))
        products = command(['swift', 'build', '-c', 'release', '--show-bin-path'], cwd=self.source,
                           env=self.environment)
        s = self.settings
        self.run_command('bundle', [sys.executable, 'scripts/package-macos.py', '--build-products', products,
            '--output', self.bundle, '--version', self.state['version'], '--sign-identity', s['applicationIdentity'],
            '--embeddings-host', s['embeddingHost'], '--model-directory', s['modelDirectory'],
            '--model-notices', s['modelNotices']])
        return {'manifestSHA256': sha(self.bundle / 'bundle-manifest.json')}

    def build_package(self):
        self.signed_package.parent.mkdir(parents=True, exist_ok=True)
        if self.signed_package.exists():
            self.signed_package.rename(self.signed_package.with_name(
                self.signed_package.name + '.incomplete-' + str(os.getpid())))
        self.run_command('package', [sys.executable, 'scripts/build-macos-pkg.py', '--bundle', self.bundle,
                                    '--output', self.signed_package, '--sign-identity', self.settings['installerIdentity']])
        return {'sha256': sha(self.signed_package)}

    def notarize_package(self):
        if sha(self.signed_package) != self.state['steps']['package']['result']['sha256']:
            raise RuntimeError('The signed package changed before notarization.')
        evidence = self.directory / 'notarization'
        self.run_command('notarization', [sys.executable, 'scripts/notarize-macos.py',
            '--package', self.signed_package, '--output', self.package,
            '--application-identity', self.settings['applicationIdentity'],
            '--wrapper-executable', self.bundle / 'bin' / 'tractanda',
            '--expected-team-id', self.settings['developerTeamID'],
            '--evidence-directory', evidence])
        receipt = read(evidence / 'notarization.json')
        if not receipt.get('notarized') or receipt.get('outputSHA256') != sha(self.package):
            raise RuntimeError('Notarization did not produce a verified final package.')
        return {'submissionID': receipt['submissionID'], 'sha256': receipt['outputSHA256'],
                'notarized': True, 'teamID': receipt['teamID']}

    def package_artifacts(self):
        self.verify_notarization()
        if self.archive.exists():
            self.archive.rename(self.archive.with_name(self.archive.name + '.incomplete-' + str(os.getpid())))
        self.run_command('archive', ['/usr/bin/tar', '--no-xattrs', '--no-acls', '--no-fflags', '--no-mac-metadata',
                                    '-czf', self.archive, '-C', self.directory, self.bundle.name])
        checksums = {p.name: sha(p) for p in (self.archive, self.package)}
        (self.directory / 'SHA256SUMS').write_text(''.join(f'{digest}  {name}\n' for name, digest in checksums.items()))
        return checksums

    def verify_notarization(self):
        receipt = self.state['steps'].get('notarization', {}).get('result', {})
        if receipt.get('notarized') is not True or receipt.get('sha256') != sha(self.package):
            raise RuntimeError('A verified notarized package is required before installation or publication.')
        self.run_command('gatekeeper', ['xcrun', 'stapler', 'validate', self.package])
        self.run_command('gatekeeper', ['/usr/sbin/spctl', '--assess', '--type', 'install', '--verbose=4', self.package])

    def verify_artifacts(self):
        if sha(self.bundle / 'bundle-manifest.json') != self.state['steps']['bundle']['result']['manifestSHA256']:
            raise RuntimeError('The prepared bundle manifest changed.')
        for name, expected in self.state['steps']['artifacts']['result'].items():
            if sha(self.directory / name) != expected:
                raise RuntimeError('The prepared release artifact changed: ' + name)

    def install(self):
        self.verify_notarization()
        # Root authorization does not bypass macOS privacy protection for Documents.
        # Give the administrator process a private, verified temporary payload and cwd.
        with tempfile.TemporaryDirectory(prefix='tractanda-release-', dir='/private/tmp') as staging:
            staging = Path(staging)
            shutil.copyfile(self.source / 'scripts/activate-release.py', staging / 'activate.py')
            self.run_command('stage-install', ['/usr/bin/ditto', '--noextattr', '--norsrc',
                                              self.bundle, staging / 'bundle'])
            shutil.copyfile(self.package, staging / 'release.pkg')
            args = [sys.executable, str(staging / 'activate.py'), '--bundle', str(staging / 'bundle'),
                    '--software-root', self.settings['softwareRoot'], '--instance', self.settings['instance'],
                    '--manifest-sha256', self.state['steps']['bundle']['result']['manifestSHA256'],
                    '--package', str(staging / 'release.pkg'), '--package-sha256',
                    self.state['steps']['artifacts']['result'][self.package.name]]
            script = 'on run argv\n do shell script (item 1 of argv) with administrator privileges\nend run'
            self.run_command('install', ['/usr/bin/osascript', '-e', script, shlex.join(args)], cwd=staging)

    def health(self):
        base = Path(self.settings['softwareRoot'])
        client = base / 'current/bin/tractanda'
        environment = {**os.environ, 'TRACTANDA_SERVER_USER': 'daemon'}
        socket = base / 'runtime' / self.settings['instance'] / 'server.sock'
        info = json.loads(command([client, 'info', socket], env=environment))
        manifest = read(self.bundle / 'bundle-manifest.json')
        expected = next(f['sha256'] for f in manifest['files'] if f['path'] == 'bin/tractanda')
        if info.get('server', {}).get('executableSHA256') != expected:
            raise RuntimeError('The live native server does not match the prepared signed executable.')
        release = base / 'current'
        if sha(release / 'bundle-manifest.json') != sha(self.bundle / 'bundle-manifest.json'):
            raise RuntimeError('The shared client pin does not match this release.')
        return {'server': info['server'], 'features': info.get('features'), 'release': str(release.resolve())}

    def push(self):
        self.run_command('push', ['git', 'push', 'origin', self.state['commit'] + ':refs/heads/' + self.settings['branch']], ROOT)

    def ci(self):
        runs = json.loads(command(['gh', 'run', 'list', '--repo', self.settings['repository'],
            '--workflow', 'verify.yml', '--commit', self.state['commit'], '--event', 'push',
            '--json', 'databaseId,status,conclusion,headSha']))
        if not runs or runs[0]['status'] != 'completed':
            if self.state.get('activeStep') != 'ci':
                self.state['activeStepStartedAt'] = now()
            self.state['status'] = 'waitingForCI'
            self.state['activeStep'] = 'ci'
            self.save()
            return False
        if runs[0]['conclusion'] != 'success':
            raise RuntimeError('GitHub verification did not pass: ' + str(runs[0]))
        self.state['steps']['ci'] = {'completedAt': now(), 'result': runs[0]}
        self.save()
        return True

    def wait_for_ci(self, timeout):
        deadline = time.monotonic() + timeout
        while not self.ci():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError('CI wait timed out; run the same script again to resume without rebuilding.')
            time.sleep(min(30, remaining))

    def publish(self):
        self.verify_artifacts()
        self.verify_notarization()
        repo, version = self.settings['repository'], self.state['version']
        tag = 'v' + version
        notes = self.directory / 'release-notes.md'
        notes.write_text(f'Tractanda {version}\n\n{self.state["notes"]}\n\n'
            f'Source commit: `{self.state["commit"]}`. The signed macOS package and archive include the pinned Qwen3 '
            'embedding runtime/model. Linux installation remains in development. Developer ID-signed; '
            'the native package is notarized, stapled and verified by Gatekeeper. Standalone binaries in '
            'the archive rely on Apple’s online notarization lookup because tickets cannot be stapled to bare executables. '
            'The preview is experimental and uses the PolyForm Noncommercial license.\n\n'
            'The local macOS source suite, signed package checks, managed upgrade, canonical-file preservation and '
            'running-build identity checks passed. GitHub source CI passed.\n\n'
            f'Installation: https://github.com/{repo}/blob/{tag}/docs/install.md\n')
        probe = subprocess.run(['gh', 'release', 'view', tag, '--repo', repo, '--json', 'isDraft'],
                               capture_output=True, text=True)
        if probe.returncode:
            # A network failure must not be mistaken for permission to replace anything.
            self.run_command('release-create', ['gh', 'release', 'create', tag, '--repo', repo,
                '--target', self.state['commit'], '--draft', '--prerelease', '--title', 'Tractanda ' + version,
                '--notes-file', notes], ROOT)
        assets = release_info(repo, tag)
        if assets['target_commitish'] != self.state['commit']:
            raise RuntimeError('The draft/release targets a different source commit; refusing to modify it.')
        expected = {**self.state['steps']['artifacts']['result'], 'SHA256SUMS': sha(self.directory / 'SHA256SUMS')}
        existing = {asset['name']: asset for asset in assets['assets']}
        # Keep pending uploads outside synced Documents: a sync client may rename an
        # artifact while an earlier large upload runs. Verify a private local snapshot.
        with tempfile.TemporaryDirectory(prefix='tractanda-upload-', dir='/private/tmp') as staging:
            pending = []
            for name, digest in expected.items():
                if name in existing:
                    if existing[name].get('digest') != 'sha256:' + digest:
                        raise RuntimeError('Existing remote asset differs; refusing to overwrite ' + name)
                else:
                    target = Path(staging) / name
                    shutil.copyfile(self.directory / name, target)
                    if sha(target) != digest:
                        raise RuntimeError('The upload staging copy differs: ' + name)
                    pending.append(target)
            for target in pending:
                self.run_command('upload-' + target.name, ['gh', 'release', 'upload', tag, target, '--repo', repo], ROOT)
        self.run_command('release-publish', ['gh', 'release', 'edit', tag, '--repo', repo,
                                          '--draft=false', '--prerelease', '--notes-file', notes], ROOT)
        remote = release_info(repo, tag)
        observed = {a['name']: a.get('digest') for a in remote['assets']}
        if remote['draft'] or any(observed.get(name) != 'sha256:' + digest for name, digest in expected.items()):
            raise RuntimeError('Published asset verification failed.')
        return {'url': remote['html_url'], 'sha256': expected}

    def cleanup(self):
        removed = []
        stale = list(self.directory.glob('*.incomplete-*'))
        stale += list(self.signed_package.parent.glob('*.incomplete-*'))
        if self.signed_package.exists():
            stale.append(self.signed_package)
        for path in stale:
            if path.is_symlink():
                path.unlink()
            elif path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink()
            removed.append(path.relative_to(self.directory).as_posix())
        return {'removedStagingArtifacts': removed, 'installedRetention': 'active and one previous; other databases retain their pins'}

    def run(self, ci_timeout=3600):
        if self.state['status'] == 'complete':
            return
        self.state.pop('error', None)
        self.state.pop('pauseReason', None)
        if git('rev-parse', 'HEAD', cwd=self.source) != self.state['commit'] or git('status', '--porcelain', cwd=self.source):
            raise RuntimeError('The sealed source checkout changed; refusing to release an unverified tree.')
        self.state['plannedSteps'] = list(RELEASE_STEPS)
        self.save()
        self.step('verify', lambda: self.run_command('verify', ['sh', 'scripts/test.sh']))
        self.step('release-build', self.build)
        self.step('bundle', self.assemble)
        self.step('package', self.build_package)
        self.step('notarization', self.notarize_package)
        self.step('artifacts', self.package_artifacts)
        self.verify_artifacts()
        self.step('install', self.install)
        # Recheck after an interruption; a completed step alone cannot prove today's live pin.
        self.state['steps']['health'] = {'completedAt': now(), 'result': self.health()}
        self.save()
        self.step('push', self.push)
        if 'ci' not in self.state['steps']:
            self.wait_for_ci(ci_timeout)
        self.step('publish', self.publish)
        self.step('cleanup', self.cleanup)
        if set(self.state['steps']) != set(RELEASE_STEPS):
            raise RuntimeError('Completed stages do not match the declared release plan.')
        self.state['status'] = 'complete'
        self.state.pop('activeStep', None)
        self.state.pop('activeStepStartedAt', None)
        self.state.pop('error', None)
        self.save()
        # Publication is durably complete before any sealed checkout is removed.
        if getattr(self, 'directory', None) is not None:
            record_release_retention(self)



def ensure_dashboard(port=48730):
    """Best-effort developer UI; a busy or unavailable port never blocks release work."""
    url = f'http://127.0.0.1:{port}/'
    expected = hashlib.sha256(str(CONTROL.resolve()).encode()).hexdigest()
    def probe():
        try:
            with urlopen(url + 'status.json', timeout=1) as response:
                return response.headers.get('X-Tractanda-Release-Observer') == expected
        except HTTPError:
            return False
        except (URLError, OSError):
            return None
    existing = probe()
    if existing is not None:
        return url if existing else None
    with (CONTROL / 'dashboard.log').open('a') as log:
        process = subprocess.Popen(
            [sys.executable, str(ROOT / 'scripts/release-status.py'), '--control', str(CONTROL),
             'serve', '--port', str(port)], cwd=ROOT, stdin=subprocess.DEVNULL,
            stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    for _ in range(15):
        if process.poll() is not None:
            return None
        if probe() is True:
            return url
        time.sleep(0.1)
    return None


def start_runner(ci_timeout):
    CONTROL.mkdir(parents=True, exist_ok=True)
    log_path = CONTROL / 'runner.log'
    with log_path.open('a') as log:
        process = subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), 'run', '--ci-timeout', str(ci_timeout)],
            cwd=ROOT, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
            start_new_session=True)
    return {'status': 'launched', 'pid': process.pid, 'log': str(log_path),
            'dashboard': ensure_dashboard()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'revise', 'release', 'run', 'status', 'dashboard', 'prune'])
    parser.add_argument('--config', type=Path, default=DEFAULT_CONFIG)
    parser.add_argument('--notes', help='Concise description of this completed changeset')
    parser.add_argument('--background', action='store_true', help='Run in a detached local process; no agent or scheduler is used')
    parser.add_argument('--ci-timeout', type=int, default=3600, help='Maximum CI wait in seconds (default: 3600)')
    parser.add_argument('--json', action='store_true', help='Filtered live JSON status (status only)')
    parser.add_argument('--watch', action='store_true', help='Continuously observe the release (status only)')
    parser.add_argument('--port', type=int, default=48730, help='Loopback dashboard port (dashboard only)')
    args = parser.parse_args()
    if args.ci_timeout <= 0:
        parser.error('--ci-timeout must be positive')
    if args.background and args.action not in ('run', 'release'):
        parser.error('--background applies to run or release')
    if (args.json or args.watch) and args.action != 'status':
        parser.error('--json/--watch apply only to status')
    if not 1 <= args.port <= 65535:
        parser.error('--port must be between 1 and 65535')
    if args.action == 'dashboard':
        CONTROL.mkdir(parents=True, exist_ok=True)
        url = ensure_dashboard(args.port)
        print(url or 'Dashboard could not start; inspect work/release-pipeline/dashboard.log.')
        return
    if args.action == 'status':
        arguments = [sys.executable, str(ROOT / 'scripts/release-status.py'), '--control', str(CONTROL)]
        if args.json: arguments.append('--json')
        if args.watch: arguments.append('--watch')
        subprocess.run(arguments, check=True)
        return
    with lock():
        if args.action == 'prune':
            print(json.dumps(prune_releases(), indent=2))
            return
        if args.action in ('prepare', 'revise', 'release'):
            if not args.notes:
                parser.error('prepare/revise/release requires --notes')
            state = (prepare(config(args.config), args.notes) if args.action in ('prepare', 'release')
                     else revise(read(CONTROL / 'current.json'), args.notes))
        if args.action in ('run', 'release') and not args.background:
            pipeline = Pipeline(read(CONTROL / 'current.json'))
            runner = {'pid': os.getpid(), 'version': pipeline.state['version'], 'startedAt': now(), 'status': 'running'}
            write(CONTROL / 'runner.json', runner)
            try:
                pipeline.run(ci_timeout=args.ci_timeout)
            except BaseException as error:
                pipeline.state['status'] = 'failed'
                pipeline.state['error'] = str(error)
                pipeline.save()
                raise
            finally:
                runner.update(status=pipeline.state['status'], stoppedAt=now())
                write(CONTROL / 'runner.json', runner)
            state = pipeline.state
        if args.background:
            state = read(CONTROL / 'current.json')
    # Release the preparation mutex before the child takes its exclusive workflow lock.
    if args.background and state['status'] != 'complete':
        print(json.dumps(start_runner(args.ci_timeout), indent=2))
    else:
        print(json.dumps({'status': state['status'], 'version': state['version'],
                          'directory': state['directory']}, indent=2))


if __name__ == '__main__':
    main()
