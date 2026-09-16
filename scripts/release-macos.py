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

ROOT = Path(__file__).resolve().parents[1]
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
                'installerIdentity', 'embeddingHost', 'modelDirectory', 'modelNotices')
    if any(not isinstance(value.get(k), str) or not value[k] for k in required):
        raise ValueError('Incomplete local release configuration.')
    if not re.fullmatch(r'[\w.-]+/[\w.-]+', value['repository']):
        raise ValueError('Invalid repository.')
    if not re.fullmatch(r'[a-z0-9-]+', value['instance']):
        raise ValueError('Invalid installation name.')
    if value['applicationIdentity'] == '-' or value['installerIdentity'] == '-':
        raise ValueError('Published releases require persistent Developer ID identities.')
    return value


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


def prepare(settings, notes):
    current_path = CONTROL / 'current.json'
    if current_path.exists() and read(current_path)['status'] != 'complete':
        raise RuntimeError('Finish or explicitly retire the pending release before preparing another.')
    if git('branch', '--show-current') != settings['branch']:
        raise RuntimeError('Prepare from the configured publication branch.')
    origins = {f'https://github.com/{settings["repository"]}.git', f'git@github.com:{settings["repository"]}.git'}
    if git('remote', 'get-url', 'origin') not in origins:
        raise RuntimeError('origin does not match the configured publication repository.')
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
             'notes': notes, 'configuration': settings}
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
    state.update(commit=commit, tree=git('rev-parse', 'HEAD^{tree}'), steps={}, status='ready')
    state.pop('error', None)
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
        self.archive = self.directory / (self.bundle.name + '.tar.gz')
        self.environment = {**os.environ, 'CLANG_MODULE_CACHE_PATH': str(self.source / '.build/module-cache')}

    def save(self):
        self.state['updatedAt'] = now()
        write(self.directory / 'state.json', self.state)
        write(CONTROL / 'current.json', self.state)

    def run_command(self, name, args, cwd=None):
        self.state['activeStep'] = name
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

    def package_artifacts(self):
        for path in (self.package, self.archive):
            if path.exists():
                path.rename(path.with_name(path.name + '.incomplete-' + str(os.getpid())))
        self.run_command('package', [sys.executable, 'scripts/build-macos-pkg.py', '--bundle', self.bundle,
                                    '--output', self.package, '--sign-identity', self.settings['installerIdentity']])
        self.run_command('archive', ['/usr/bin/tar', '--no-xattrs', '--no-acls', '--no-fflags', '--no-mac-metadata',
                                    '-czf', self.archive, '-C', self.directory, self.bundle.name])
        checksums = {p.name: sha(p) for p in (self.archive, self.package)}
        (self.directory / 'SHA256SUMS').write_text(''.join(f'{digest}  {name}\n' for name, digest in checksums.items()))
        return checksums

    def verify_artifacts(self):
        if sha(self.bundle / 'bundle-manifest.json') != self.state['steps']['bundle']['result']['manifestSHA256']:
            raise RuntimeError('The prepared bundle manifest changed.')
        for name, expected in self.state['steps']['artifacts']['result'].items():
            if sha(self.directory / name) != expected:
                raise RuntimeError('The prepared release artifact changed: ' + name)

    def install(self):
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
            self.state['status'] = 'waitingForCI'
            self.save()
            return False
        if runs[0]['conclusion'] != 'success':
            raise RuntimeError('GitHub verification did not pass: ' + str(runs[0]))
        self.state['steps']['ci'] = {'completedAt': now(), 'result': runs[0]}
        self.save()
        return True

    def publish(self):
        self.verify_artifacts()
        repo, version = self.settings['repository'], self.state['version']
        tag = 'v' + version
        notes = self.directory / 'release-notes.md'
        notes.write_text(f'Tractanda {version}\n\n{self.state["notes"]}\n\n'
            f'Source commit: `{self.state["commit"]}`. The signed macOS package and archive include the pinned Qwen3 '
            'embedding runtime/model. Linux installation remains in development. Developer ID-signed, not notarized. '
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
        for name, digest in expected.items():
            if name in existing:
                if existing[name].get('digest') != 'sha256:' + digest:
                    raise RuntimeError('Existing remote asset differs; refusing to overwrite ' + name)
            else:
                self.run_command('upload-' + name, ['gh', 'release', 'upload', tag, self.directory / name, '--repo', repo], ROOT)
        self.run_command('release-publish', ['gh', 'release', 'edit', tag, '--repo', repo,
                                          '--draft=false', '--prerelease', '--notes-file', notes], ROOT)
        remote = release_info(repo, tag)
        observed = {a['name']: a.get('digest') for a in remote['assets']}
        if remote['draft'] or any(observed.get(name) != 'sha256:' + digest for name, digest in expected.items()):
            raise RuntimeError('Published asset verification failed.')
        return {'url': remote['html_url'], 'sha256': expected}

    def cleanup(self):
        removed = []
        for path in self.directory.glob('*.incomplete-*'):
            if path.is_symlink():
                path.unlink()
            elif path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink()
            removed.append(path.name)
        return {'removedStagingArtifacts': removed, 'installedRetention': 'active and one previous; other databases retain their pins'}

    def run(self):
        if self.state['status'] == 'complete':
            return
        if git('rev-parse', 'HEAD', cwd=self.source) != self.state['commit'] or git('status', '--porcelain', cwd=self.source):
            raise RuntimeError('The sealed source checkout changed; refusing to release an unverified tree.')
        self.step('verify', lambda: self.run_command('verify', ['sh', 'scripts/test.sh']))
        self.step('release-build', self.build)
        self.step('bundle', self.assemble)
        self.step('artifacts', self.package_artifacts)
        self.verify_artifacts()
        self.step('install', self.install)
        # Recheck after an interruption; a completed step alone cannot prove today's live pin.
        self.state['steps']['health'] = {'completedAt': now(), 'result': self.health()}
        self.save()
        self.step('push', self.push)
        if 'ci' not in self.state['steps'] and not self.ci():
            return
        self.step('publish', self.publish)
        self.step('cleanup', self.cleanup)
        self.state['status'] = 'complete'
        self.state.pop('activeStep', None)
        self.state.pop('error', None)
        self.save()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'revise', 'run', 'status'])
    parser.add_argument('--config', type=Path, default=DEFAULT_CONFIG)
    parser.add_argument('--notes', help='Concise description of this completed changeset')
    args = parser.parse_args()
    if args.action == 'status':
        path = CONTROL / 'current.json'
        print(json.dumps(read(path) if path.exists() else {'status': 'notPrepared'}, indent=2))
        return
    with lock():
        if args.action in ('prepare', 'revise'):
            if not args.notes:
                parser.error('prepare/revise requires --notes')
            state = (prepare(config(args.config), args.notes) if args.action == 'prepare'
                     else revise(read(CONTROL / 'current.json'), args.notes))
        else:
            pipeline = Pipeline(read(CONTROL / 'current.json'))
            try:
                pipeline.run()
            except BaseException as error:
                pipeline.state['status'] = 'failed'
                pipeline.state['error'] = str(error)
                pipeline.save()
                raise
            state = pipeline.state
        print(json.dumps({'status': state['status'], 'version': state['version'],
                          'directory': state['directory']}, indent=2))


if __name__ == '__main__':
    main()
