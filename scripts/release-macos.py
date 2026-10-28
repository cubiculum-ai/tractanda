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
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import tarfile
import time
from urllib.error import HTTPError, URLError
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
_delivery_spec = importlib.util.spec_from_file_location('release_delivery', Path(__file__).with_name('release-delivery.py'))
delivery = importlib.util.module_from_spec(_delivery_spec)
_delivery_spec.loader.exec_module(delivery)
RELEASE_STEPS = tuple(json.loads(Path(__file__).with_name('release-steps-legacy-v2.json').read_text()))
PUBLIC_STEPS = tuple(json.loads(Path(__file__).with_name('release-steps.json').read_text()))
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


def render_release_notes(template, version, commit, notes, repository):
    """Render self-contained user guidance from the sealed release's template."""
    if (not re.fullmatch(r'\d+\.\d+\.\d+-poc\.\d+', version)
            or not re.fullmatch(r'[0-9a-f]{40}', commit)
            or not re.fullmatch(r'[\w.-]+/[\w.-]+', repository)):
        raise ValueError('Invalid release-note identity.')
    values = {'VERSION': version, 'SOURCE_COMMIT': commit, 'CHANGES': notes,
              'TAG_URL': f'https://github.com/{repository}/blob/v{version}'}
    pattern = r'\{\{([A-Z_]+)\}\}'
    if set(re.findall(pattern, template)) != set(values):
        raise ValueError('Release-note template has missing or unknown placeholders.')
    return re.sub(pattern, lambda match: values[match.group(1)], template)


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
                'installerIdentity', 'modelDirectory', 'documentModelDirectory',
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
    if not isinstance(hashes, dict):
        return False
    if delivery.active(state):
        try:
            rows = state['delivery']['linuxAssets']
            if (len(rows) != 2 or {r['arch'] for r in rows} != set(delivery.ARCHES)
                    or any(hashes.get(r['name']) != r['sha256'] for r in rows)
                    or not delivery.public(state) and (state['delivery']['acceptance']['candidateID'] != delivery.digest(delivery.canonical(delivery.binding(state)))
                    or state['delivery']['installAuthorization']['candidateID'] != state['delivery']['acceptance']['candidateID']
                    or steps.get('install-authorization', {}).get('result') != state['delivery']['installAuthorization']
                    or steps.get('cluster-acceptance', {}).get('result') != state['delivery']['acceptance'])):
                return False
        except (KeyError, TypeError, RuntimeError):
            return False
    if delivery.public(state) and (hashes.get('apt-site.tar.gz') is None
            or steps.get('published-source', {}).get('result', {}).get('commit') != state['commit']
            or steps.get('published-source', {}).get('result', {}).get('tree') != state.get('tree')
            or not steps.get('pages', {}).get('result', {}).get('runID')):
        return False
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
             'notes': notes, 'configuration': settings, 'delivery': delivery.public_fresh(),
             'plannedSteps': list(PUBLIC_STEPS)}
    write(destination / 'state.json', state)
    write(current_path, state)
    return state


def archive_notarization_evidence(state, new_commit):
    """Retain an old attempt before a revised payload creates a new receipt."""
    directory = Path(state['directory'])
    names = ('notarization', 'notarization.log', 'ticket-probe')
    present = [name for name in names if (directory / name).exists() or (directory / name).is_symlink()]
    if not present:
        (directory / 'notarization').mkdir(exist_ok=False)
        return None
    for name in present:
        if (directory / name).is_symlink():
            raise RuntimeError('Notarization evidence path is a symlink; refusing revision.')
    history = directory / 'notarization-history'
    if history.is_symlink() or (history.exists() and not history.is_dir()):
        raise RuntimeError('Notarization history path is unsafe; refusing revision.')
    history.mkdir(exist_ok=True)
    number = len(state.get('previousCandidates', [])) + 1
    destination = history / f'{number:04d}-{state["commit"][:12]}-to-{new_commit[:12]}'
    receipt = directory / 'notarization/notarization.json'
    if receipt.is_symlink():
        raise RuntimeError('Notarization receipt is a symlink; refusing revision.')
    details = read(receipt) if receipt.is_file() else {}
    package_sha = details.get('inputSHA256')
    candidates = [*state.get('previousCandidates', []), state]
    matching = [entry.get('commit') for entry in candidates
                if isinstance(package_sha, str) and re.fullmatch(r'[0-9a-f]{64}', package_sha)
                and entry.get('steps', {}).get('package', {}).get('result', {}).get('sha256') == package_sha]
    provenance = {
        'archivedAt': now(), 'controllerCommit': state['commit'], 'nextCommit': new_commit,
        'receiptOwnerCommit': matching[-1] if matching else None,
        'inputSHA256': package_sha, 'submissionID': details.get('submissionID'),
        'submissionState': details.get('submissionState'), 'archive': details.get('archive'),
        'receiptSHA256': sha(receipt) if receipt.is_file() else None, 'preserved': present,
    }
    destination.mkdir(exist_ok=False)
    write(destination / 'provenance.json', provenance)
    for name in present:
        (directory / name).rename(destination / name)
    (directory / 'notarization').mkdir(exist_ok=False)
    return str(destination)


def require_unpublished_version(state):
    """Require authenticated release visibility and conclusive tag/release absence."""
    repository = state['configuration']['repository']
    metadata = json.loads(command(['gh', 'api', 'repos/' + repository]))
    if not isinstance(metadata, dict) or metadata.get('permissions', {}).get('push') is not True:
        raise RuntimeError('Remote release visibility is uncertain; refusing revision.')
    tag = 'v' + state['version']
    releases = command(['gh', 'api', '--paginate', 'repos/' + repository + '/releases?per_page=100',
                        '--jq', '.[].tag_name']).splitlines()
    if any(not name or re.search(r'\s', name) for name in releases):
        raise RuntimeError('Remote release response is malformed; refusing revision.')
    if tag in releases:
        raise RuntimeError('A remote release already exists for this version; refusing revision.')
    remote = subprocess.run(['git', 'ls-remote', '--exit-code', '--tags',
        'https://github.com/' + repository + '.git', 'refs/tags/' + tag],
        capture_output=True, text=True, check=False, timeout=30)
    if remote.returncode == 0:
        raise RuntimeError('A public tag already exists for this version; refusing revision.')
    if remote.returncode != 2 or remote.stdout.strip() or remote.stderr.strip():
        raise RuntimeError('Remote tag absence is uncertain; refusing revision.')
    return {'verifiedAt': now(), 'remoteTag': tag, 'remoteReleaseAbsent': True}


def require_unpublished_ci_repair(state):
    """Permit a same-version repair only after an installed, unpublished CI failure."""
    required = {'verify', 'release-build', 'bundle', 'package', 'notarization',
                'artifacts', 'install', 'health', 'push'}
    if delivery.active(state): required.update(('install-authorization', 'cluster-acceptance'))
    if (state.get('status') != 'failed' or state.get('activeStep') != 'ci'
            or set(state.get('steps', {})) != required):
        raise RuntimeError('Only a terminal unpublished CI failure can revise an installed candidate.')
    runner_path = CONTROL / 'runner.json'
    if runner_path.is_symlink() or not runner_path.is_file():
        raise RuntimeError('Runner state is unavailable; refusing installed-candidate revision.')
    runner = read(runner_path)
    pid = runner.get('pid')
    if (runner.get('version') != state['version'] or runner.get('status') != 'failed'
            or not isinstance(runner.get('stoppedAt'), str) or type(pid) is not int or pid <= 0):
        raise RuntimeError('Runner termination is unproven; refusing installed-candidate revision.')
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        pass
    except OSError as error:
        raise RuntimeError('Runner presence is uncertain; refusing installed-candidate revision.') from error
    else:
        raise RuntimeError('A recorded runner process is still present; refusing revision.')
    current = Path(state['configuration']['softwareRoot']) / 'current/bundle-manifest.json'
    expected = state['steps']['bundle'].get('result', {}).get('manifestSHA256')
    if (not isinstance(expected, str) or not re.fullmatch(r'[0-9a-f]{64}', expected)
            or not current.is_file() or read(current).get('version') != state['version']
            or sha(current) != expected):
        raise RuntimeError('The live bundle does not match the failed installed candidate; refusing revision.')
    repository = state['configuration']['repository']
    runs = json.loads(command(['gh', 'run', 'list', '--repo', repository,
        '--workflow', 'verify.yml', '--commit', state['commit'], '--event', 'push',
        '--json', 'databaseId,status,conclusion,headSha']))
    if (not isinstance(runs, list) or not runs or not isinstance(runs[0], dict)
            or runs[0].get('headSha') != state['commit'] or runs[0].get('status') != 'completed'
            or runs[0].get('conclusion') != 'failure'):
        raise RuntimeError('A completed verification failure for this exact source is unproven.')
    return {**require_unpublished_version(state), 'failedCI': runs[0],
            'liveManifestSHA256': expected}


def require_public_ci_repair(state):
    """Repair a pushed v3 candidate only after terminal CI failure, before any publication/update."""
    required = set(PUBLIC_STEPS[:PUBLIC_STEPS.index('ci')])
    if (not delivery.public(state) or state.get('status') != 'failed' or state.get('activeStep') != 'ci'
            or set(state.get('steps', {})) != required):
        raise RuntimeError('Only terminal pre-publication CI failure permits public candidate revision.')
    runner = read(CONTROL / 'runner.json')
    pid = runner.get('pid')
    if (runner.get('version') != state['version'] or runner.get('status') != 'failed'
            or not isinstance(runner.get('stoppedAt'), str) or type(pid) is not int or pid <= 0):
        raise RuntimeError('Public candidate runner termination is unproven.')
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        pass
    except OSError as error:
        raise RuntimeError('Public candidate runner presence is uncertain.') from error
    else:
        raise RuntimeError('Public candidate runner remains present.')
    runs = json.loads(command(['gh', 'run', 'list', '--repo', state['configuration']['repository'],
        '--workflow', 'verify.yml', '--commit', state['commit'], '--event', 'push',
        '--json', 'databaseId,status,conclusion,headSha']))
    if (not runs or runs[0].get('headSha') != state['commit'] or runs[0].get('status') != 'completed'
            or runs[0].get('conclusion') != 'failure'):
        raise RuntimeError('A terminal CI failure for this public source commit is unproven.')
    return {**require_unpublished_version(state), 'failedCI': runs[0], 'gate': 'public-pre-update-ci'}


def require_unpublished_cluster_repair(state):
    """Permit explicit repair at the unaccepted cluster gate, without changing live state."""
    required = {'verify', 'release-build', 'bundle', 'package', 'notarization',
                'artifacts', 'install-authorization', 'install', 'health'}
    if (not delivery.active(state) or state.get('status') != 'paused'
            or state.get('activeStep') != 'cluster-acceptance'
            or set(state.get('steps', {})) != required
            or state['delivery'].get('acceptance')):
        raise RuntimeError('Only an installed candidate paused before cluster acceptance may use cluster repair.')
    authorization = delivery.verify_install(state)
    if authorization is None:
        raise RuntimeError('The installed candidate authorization is unproven; refusing cluster repair.')
    runner_path = CONTROL / 'runner.json'
    if runner_path.is_symlink() or not runner_path.is_file():
        raise RuntimeError('Runner termination is unproven; refusing cluster repair.')
    runner = read(runner_path)
    pid = runner.get('pid')
    if (runner.get('version') != state['version'] or runner.get('status') != 'paused'
            or not isinstance(runner.get('stoppedAt'), str) or type(pid) is not int or pid <= 0):
        raise RuntimeError('Runner termination is unproven; refusing cluster repair.')
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        pass
    except OSError as error:
        raise RuntimeError('Runner presence is uncertain; refusing cluster repair.') from error
    else:
        raise RuntimeError('A recorded runner is still present; refusing cluster repair.')
    current = Path(state['configuration']['softwareRoot']) / 'current/bundle-manifest.json'
    expected = state['steps']['bundle'].get('result', {}).get('manifestSHA256')
    health = state['steps']['health'].get('result', {})
    executable = health.get('server', {}).get('executableSHA256')
    if (not isinstance(expected, str) or not re.fullmatch(r'[0-9a-f]{64}', expected)
            or current.is_symlink() or not current.is_file() or sha(current) != expected
            or read(current).get('version') != state['version']
            or health.get('release') != str(current.parent.resolve())
            or not isinstance(executable, str) or not re.fullmatch(r'[0-9a-f]{64}', executable)
            or sha(current.parent / 'bin/tractanda') != executable):
        raise RuntimeError('The live bundle/health identity differs; refusing cluster repair.')
    return {**require_unpublished_version(state), 'liveManifestSHA256': expected,
            'liveExecutableSHA256': executable, 'installCandidateID': authorization['candidateID'],
            'gate': 'cluster-acceptance'}


def require_unpublished_cluster_descendant_repair(state):
    """Revise an uninstalled descendant while its archived cluster ancestor stays live."""
    allowed = {'verify', 'release-build', 'bundle', 'package', 'notarization', 'artifacts'}
    failed_before_replacement = (state.get('status') == 'failed' and state.get('activeStep') == 'install'
                                 and set(state.get('steps', {})) == allowed | {'install-authorization'}
                                 and delivery.verify_install(state) is not None)
    if (not delivery.active(state) or state.get('status') not in ('failed', 'paused')
            or not failed_before_replacement and (not set(state.get('steps', {})) <= allowed
                or state.get('activeStep') not in allowed | {'archive', 'install-authorization'}
                or state['delivery'].get('installAuthorization'))
            or state['delivery'].get('acceptance')):
        raise RuntimeError('Only a stopped, uninstalled cluster-repair descendant may be revised.')
    runner_path = CONTROL / 'runner.json'
    if runner_path.is_symlink() or not runner_path.is_file():
        raise RuntimeError('Descendant runner termination is unproven.')
    runner = read(runner_path)
    pid = runner.get('pid')
    if (runner.get('version') != state['version'] or runner.get('status') != state['status']
            or not isinstance(runner.get('stoppedAt'), str) or type(pid) is not int or pid <= 0):
        raise RuntimeError('Descendant runner termination does not match the candidate.')
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        pass
    except OSError as error:
        raise RuntimeError('Descendant runner presence is uncertain.') from error
    else:
        raise RuntimeError('Descendant runner is still present.')
    current = Path(state['configuration']['softwareRoot']) / 'current/bundle-manifest.json'
    if current.is_symlink() or not current.is_file():
        raise RuntimeError('Installed cluster ancestor manifest is unavailable.')
    manifest, digest = read(current), sha(current)
    ancestors = [a for a in state.get('previousCandidates', [])
                 if isinstance(a.get('unpublishedClusterRepair'), dict)
                 and a['unpublishedClusterRepair'].get('liveManifestSHA256') == digest]
    if len(ancestors) != 1:
        raise RuntimeError('Installed cluster-repair ancestor is missing or ambiguous.')
    ancestor = ancestors[0]
    saved = ancestor['unpublishedClusterRepair']
    required = allowed | {'install-authorization', 'install', 'health'}
    if (set(ancestor.get('steps', {})) != required or saved.get('gate') != 'cluster-acceptance'
            or saved.get('remoteReleaseAbsent') is not True or saved.get('remoteTag') != 'v' + state['version']
            or manifest.get('version') != state['version']
            or manifest.get('sourceCommit') != ancestor.get('commit')
            or ancestor.get('delivery', {}).get('acceptance')):
        raise RuntimeError('Archived cluster ancestor proof is inconsistent.')
    authorization = ancestor['delivery']['installAuthorization']
    history = Path(ancestor['deliveryEvidence'])
    expected_history = Path(state['directory']) / 'delivery-history'
    if history.parent != expected_history or any(p.is_symlink() for p in (expected_history, history, history / 'install-evidence')):
        raise RuntimeError('Archived cluster authorization escaped its retained history.')
    proof_path = history / 'install-evidence' / (authorization['sha256'] + '.json')
    value, _raw, fingerprint = delivery.json_input(proof_path)
    candidate = value.get('candidate', {})
    if (fingerprint['sha256'] != authorization['sha256']
            or value.get('profile') != 'tractanda.release-install-authorization.v1'
            or value.get('candidateID') != saved.get('installCandidateID')
            or value['candidateID'] != authorization.get('candidateID')
            or value['candidateID'] != delivery.digest(delivery.canonical(candidate))
            or candidate.get('commit') != ancestor['commit'] or candidate.get('version') != state['version']
            or candidate.get('macBundleManifestSHA256') != digest
            or candidate.get('installation') != {k: state['configuration'][k] for k in ('instance', 'softwareRoot')}
            or value.get('raven') != authorization.get('raven')
            or ancestor['steps']['install-authorization'].get('result') != authorization):
        raise RuntimeError('Archived cluster authorization bytes or candidate binding changed.')
    executable = current.parent / 'bin/tractanda'
    health = ancestor['steps']['health'].get('result', {})
    if (executable.is_symlink() or not executable.is_file()
            or sha(executable) != saved.get('liveExecutableSHA256')
            or health.get('server', {}).get('executableSHA256') != saved['liveExecutableSHA256']
            or health.get('release') != str(current.parent.resolve())):
        raise RuntimeError('Installed cluster ancestor executable/health identity changed.')
    git('merge-base', '--is-ancestor', ancestor['commit'], state['commit'])
    command(['/usr/bin/codesign', '--verify', '--strict', str(executable)])
    return {**require_unpublished_version(state), 'gate': 'cluster-acceptance-descendant',
            'installedAncestorCommit': ancestor['commit'], 'liveManifestSHA256': digest,
            'liveExecutableSHA256': saved['liveExecutableSHA256'],
            'archivedAuthorizationSHA256': fingerprint['sha256'],
            'failedBeforeReplacement': failed_before_replacement}


def require_ready_ci_descendant_repair(state):
    """Continue source-first repair while its proven installed ancestor stays pinned."""
    if state.get('status') != 'ready' or state.get('steps') != {}:
        raise RuntimeError('Only a zero-gate READY source-first descendant may continue repair.')
    if not isinstance(state.get('commit'), str) or not re.fullmatch(r'[0-9a-f]{40}', state['commit']):
        raise RuntimeError('The source-first descendant commit is invalid.')
    current = Path(state['configuration']['softwareRoot']) / 'current/bundle-manifest.json'
    if current.is_symlink() or not current.is_file():
        raise RuntimeError('The installed ancestor manifest is unavailable.')
    manifest, digest = read(current), sha(current)
    ancestors = [entry for entry in state.get('previousCandidates', [])
                 if entry.get('steps', {}).get('bundle', {}).get('result', {}).get('manifestSHA256') == digest
                 and isinstance(entry.get('unpublishedCIRepair'), dict)]
    if len(ancestors) != 1:
        raise RuntimeError('The installed unpublished-CI ancestor is missing or ambiguous.')
    ancestor = ancestors[0]
    saved = ancestor['unpublishedCIRepair']
    if (saved.get('liveManifestSHA256') != digest
            or saved.get('failedCI', {}).get('headSha') != ancestor.get('commit')
            or saved.get('remoteReleaseAbsent') is not True
            or saved.get('remoteTag') != 'v' + state['version']
            or manifest.get('sourceCommit') != ancestor.get('commit')):
        raise RuntimeError('The installed ancestor source identity/proof does not match.')
    # Reuse the existing terminal-runner, exact live pin and fresh remote absence gates.
    installed = {**state, 'commit': ancestor['commit'], 'steps': ancestor['steps'],
                 'status': 'failed', 'activeStep': 'ci', 'delivery': ancestor.get('delivery')}
    proof = require_unpublished_ci_repair(installed)
    git('merge-base', '--is-ancestor', ancestor['commit'], state['commit'])
    executable = current.parent / 'bin/tractanda'
    expected = [entry.get('sha256') for entry in manifest.get('files', [])
                if entry.get('path') == 'bin/tractanda']
    if (len(expected) != 1 or not isinstance(expected[0], str)
            or not re.fullmatch(r'[0-9a-f]{64}', expected[0])
            or executable.is_symlink() or not executable.is_file() or sha(executable) != expected[0]):
        raise RuntimeError('The installed ancestor executable differs from its signed inventory.')
    command(['/usr/bin/codesign', '--verify', '--strict', str(executable)])
    runs = json.loads(command(['gh', 'run', 'list', '--repo', state['configuration']['repository'],
        '--workflow', 'verify.yml', '--commit', state['commit'], '--event', 'push',
        '--json', 'databaseId,status,conclusion,headSha']))
    if (not isinstance(runs, list) or not runs or not isinstance(runs[0], dict)
            or runs[0].get('headSha') != state['commit'] or runs[0].get('status') != 'completed'
            or runs[0].get('conclusion') != 'failure'):
        raise RuntimeError('A terminal source-first CI failure for this exact descendant is unproven.')
    return {**proof, 'installedAncestorCommit': ancestor['commit'],
            'sourceFirstFailedCI': runs[0], 'liveExecutableSHA256': expected[0]}


def revise(state, notes):
    """Repair an unpublished candidate without replacing any live/published release."""
    if 'publish' in state['steps'] or state.get('status') == 'complete':
        raise RuntimeError('This candidate has been published; prepare a separate release after resolving it.')
    cluster_repair = (require_unpublished_cluster_repair(state)
                      if state.get('status') == 'paused' and state.get('activeStep') == 'cluster-acceptance' else None)
    repair_proof = (require_public_ci_repair(state) if delivery.public(state) and 'push' in state['steps']
                    else cluster_repair or (require_unpublished_ci_repair(state)
                    if any(name in state['steps'] for name in ('install', 'push')) else None))
    current = Path(state['configuration']['softwareRoot']) / 'current/bundle-manifest.json'
    if not repair_proof and current.exists() and read(current).get('version') == state['version']:
        repair_proof = (require_unpublished_cluster_descendant_repair(state)
                        if any(a.get('unpublishedClusterRepair') for a in state.get('previousCandidates', []))
                        else require_ready_ci_descendant_repair(state))
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
    notarization_history = archive_notarization_evidence(state, commit)
    state.setdefault('previousCandidates', []).append({
        'commit': state['commit'], 'steps': state['steps'], 'error': state.get('error'),
        'notarizationEvidence': notarization_history,
        'unpublishedCIRepair': repair_proof if cluster_repair is None and (repair_proof or {}).get('gate') != 'cluster-acceptance-descendant' else None,
        'unpublishedClusterRepair': cluster_repair,
        'unpublishedClusterDescendantRepair': repair_proof if (repair_proof or {}).get('gate') == 'cluster-acceptance-descendant' else None,
        'delivery': state.get('delivery')})
    state['previousCandidates'][-1]['deliveryEvidence'] = delivery.archive_for_revision(state)
    was_public = delivery.public(state)
    state.update(commit=commit, tree=git('rev-parse', 'HEAD^{tree}'), steps={}, status='ready',
                 plannedSteps=list(PUBLIC_STEPS) if was_public else delivery.release_plan(RELEASE_STEPS),
                 notes=notes, delivery=delivery.public_fresh() if was_public else delivery.fresh())
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

    def linux_context(self):
        # Use the candidate's existing source capture/configuration algorithm.
        if (git('rev-parse', 'HEAD', cwd=self.source) != self.state['commit']
                or git('rev-parse', 'HEAD^{tree}', cwd=self.source) != self.state['tree']
                or git('status', '--porcelain', cwd=self.source)):
            raise RuntimeError('Linux receipts require the unchanged sealed candidate checkout.')
        spec = importlib.util.spec_from_file_location('candidate_linux_producer', self.source / 'scripts/produce-linux-payload.py')
        producer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(producer)
        return {'files': producer.source_rows(),
                'components': {arch: producer.require_admitted(arch) for arch in delivery.ARCHES},
                'flags': {arch: producer.core_build_flags(arch) for arch in delivery.ARCHES}}

    def install_gate(self):
        self.state['activeStep'] = 'install-authorization'
        accepted = delivery.verify_install(self.state)
        if accepted is None:
            self.state.update(status='paused', pauseReason='Verify candidate compatibility/maintenance and current installation identity, then use explicit allow-install and run.',
                              installCandidateID=delivery.install_challenge(self.state)['candidateID'])
            self.save()
            return False
        self.state['steps']['install-authorization'] = {'completedAt': now(), 'result': accepted}
        self.save()
        return True

    def cluster_gate(self):
        self.state['activeStep'] = 'cluster-acceptance'
        accepted = delivery.verify_acceptance(self.state)
        if accepted is None:
            self.state.update(status='paused', pauseReason='Complete the ordered Raven/Stash checks, then use explicit accept-cluster and run.',
                              clusterCandidateID=delivery.challenge(self.state)['candidateID'])
            self.save()
            return False
        self.state['steps']['cluster-acceptance'] = {'completedAt': now(), 'result': accepted}
        self.save()
        return True

    def document_build_arguments(self):
        # Separate paths keep the patched native runtime out of the embedding/root graphs.
        base = self.directory / 'docling-build'
        return [argument for name in ('scratch', 'cache', 'config', 'security')
                for argument in ('--' + name, str(base / name))]

    def verify_document_model(self, directory, evidence):
        proof = json.loads(command([sys.executable, 'scripts/validate-docling-model.py', str(directory)],
                                   cwd=self.source, env=self.environment))
        if proof.get('status') != 'verified' or proof.get('fileCount') != 14:
            raise RuntimeError('Pinned document model validation did not complete.')
        write(self.directory / evidence, proof)

    def build(self):
        self.run_command('release-build', ['swift', 'build', '-c', 'release', '--disable-sandbox',
                                        '--disable-automatic-resolution'])
        # The provider is part of this source snapshot too. Reusing an installed
        # helper can silently pair an old runtime/model profile with new weights.
        self.run_command('release-build', ['swift', 'build', '-c', 'release',
            '--package-path', 'Packages/TractandaEmbeddings', '--disable-sandbox',
            '--disable-automatic-resolution'])
        products = command(['swift', 'build', '-c', 'release', '--show-bin-path',
            '--package-path', 'Packages/TractandaEmbeddings'], cwd=self.source, env=self.environment)
        self.run_command('release-build', ['sh', 'scripts/validate-granite-runtime.sh',
            str(Path(products) / 'TractandaEmbeddingsHost'), self.settings['modelDirectory']])

        self.verify_document_model(self.settings['documentModelDirectory'], 'document-model-input.json')
        self.run_command('release-build', [sys.executable, 'scripts/build-docling-native.py',
                         *self.document_build_arguments()])

    def assemble(self):
        if self.bundle.exists():
            self.bundle.rename(self.bundle.with_name(self.bundle.name + '.incomplete-' + str(os.getpid())))
        products = command(['swift', 'build', '-c', 'release', '--show-bin-path'], cwd=self.source,
                           env=self.environment)
        embedding_products = command(['swift', 'build', '-c', 'release', '--show-bin-path',
            '--package-path', 'Packages/TractandaEmbeddings'], cwd=self.source, env=self.environment)
        document_products = command(['swift', 'build', '-c', 'release', '--show-bin-path',
            '--package-path', 'Packages/TractandaDocuments',
            *[argument for name in ('scratch', 'cache', 'config', 'security')
              for argument in ('--' + name + '-path', str(self.directory / 'docling-build' / name))]],
            cwd=self.source, env=self.environment)
        s = self.settings
        self.run_command('bundle', [sys.executable, 'scripts/package-macos.py', '--build-products', products,
            '--output', self.bundle, '--version', self.state['version'], '--sign-identity', s['applicationIdentity'],
            '--embeddings-host', str(Path(embedding_products) / 'TractandaEmbeddingsHost'),
            '--document-converter', str(Path(document_products) / 'tractanda-document-converter')])
        bundle_manifest = json.loads((self.bundle / 'bundle-manifest.json').read_text(encoding='utf-8'))
        catalog = self.bundle / 'models/manifest.json'
        if (bundle_manifest.get('modelProvisioningManifestPath') != 'models/manifest.json'
                or bundle_manifest.get('modelProvisioningManifestSHA256') != sha(catalog)):
            raise RuntimeError('Slim release bundle does not bind the pinned model artifact catalog.')
        self.run_command('bundle-skills', [sys.executable, 'scripts/verify-release-skills.py', '--bundle', self.bundle])
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
        if delivery.active(self.state):
            checksums.update(delivery.verify_linux(self.state, self.linux_context()))
        if delivery.public(self.state):
            checksums['apt-site.tar.gz'] = sha(self.directory / 'apt-site.tar.gz')
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
            if Path(name).name != name:
                raise RuntimeError('Unsafe release artifact name.')
            if sha(self.directory / name) != expected:
                raise RuntimeError('The prepared release artifact changed: ' + name)
        if delivery.active(self.state):
            linux = delivery.verify_linux(self.state, self.linux_context())
            expected = self.state['steps']['artifacts']['result']
            if any(expected.get(name) != value for name, value in linux.items()):
                raise RuntimeError('Both bound Linux assets must be in the release inventory.')
            sums = ''.join(f'{value}  {name}\n' for name, value in expected.items())
            if (self.directory / 'SHA256SUMS').read_text() != sums:
                raise RuntimeError('Release checksums changed.')

    def install(self):
        if not delivery.active(self.state):
            raise RuntimeError('Revise the pending legacy candidate explicitly to the current delivery contract.')
        self.verify_notarization()
        if delivery.public(self.state):
            self.verify_published_package()
        elif delivery.verify_install(self.state) is None:
            raise RuntimeError('Explicit candidate-bound allow-install is required before managed installation.')
        # Root authorization does not bypass macOS privacy protection for Documents.
        # Give the administrator process a private, verified temporary payload and cwd.
        with tempfile.TemporaryDirectory(prefix='tractanda-release-', dir='/private/tmp') as staging:
            staging = Path(staging)
            shutil.copyfile(self.source / 'scripts/activate-release.py', staging / 'activate.py')
            shutil.copyfile(self.source / 'scripts/canonical-format-guard.py', staging / 'canonical-format-guard.py')
            self.run_command('stage-install', ['/usr/bin/ditto', '--noextattr', '--norsrc',
                                              self.bundle, staging / 'bundle'])
            shutil.copyfile(self.package, staging / 'release.pkg')
            args = [sys.executable, '-B', str(staging / 'activate.py'), '--bundle', str(staging / 'bundle'),
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
        socket = Path('/private/var/run/tractanda') / self.settings['instance'] / 'server.sock'
        info = json.loads(command([client, 'info', socket], env=environment))
        manifest = read(self.bundle / 'bundle-manifest.json')
        expected = next(f['sha256'] for f in manifest['files'] if f['path'] == 'bin/tractanda')
        expected_formats = manifest.get('canonicalFormats')
        if expected_formats is None or info.get('canonicalFormats') != expected_formats:
            raise RuntimeError('Runtime canonical reader/writer formats differ from the signed bundle.')
        if info.get('server', {}).get('executableSHA256') != expected:
            raise RuntimeError('The live native server does not match the prepared signed executable.')
        release = base / 'current'
        if sha(release / 'bundle-manifest.json') != sha(self.bundle / 'bundle-manifest.json'):
            raise RuntimeError('The shared client pin does not match this release.')
        semantic = None
        if manifest.get('embedding'):
            semantic = json.loads(command([client, 'call', socket, 'TractandaSemantic/status', '{}'],
                                          env=environment))
            if not semantic.get('enabled') or semantic.get('model') != manifest['embedding']['model']:
                raise RuntimeError('The live semantic configuration does not match the bundled model.')
        document = manifest.get('documentExtraction')
        if document:
            observed = info.get('documentExtraction', {})
            expected_converter = next(f['sha256'] for f in manifest['files']
                                      if f['path'] == document['converterPath'])
            if (observed.get('state') != 'configured' or observed.get('identity') != document['identity']
                    or observed.get('executableSHA256') != expected_converter
                    or observed.get('requiresPreparedInput') is not False
                    or info.get('documentJobs', {}).get('protocol') != document['workerProtocol']):
                raise RuntimeError('Running document configuration differs from the signed payload.')
        return {'documentExtraction': info.get('documentExtraction'), 'server': info['server'], 'features': info.get('features'),
                'release': str(release.resolve()), 'semantic': semantic}

    def push(self):
        self.run_command('push', ['git', 'push', 'origin', self.state['commit'] + ':refs/heads/' + self.settings['branch']], self.source)

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
        if not delivery.active(self.state):
            raise RuntimeError('Revise the pending legacy candidate explicitly to the current delivery contract.')
        self.verify_artifacts()
        self.verify_notarization()
        if not delivery.public(self.state) and delivery.verify_acceptance(self.state) is None:
            raise RuntimeError('Explicit candidate-bound cluster acceptance is required before publication.')
        repo, version = self.settings['repository'], self.state['version']
        tag = 'v' + version
        notes = self.directory / 'release-notes.md'
        notes.write_text(render_release_notes(
            (self.source / 'docs/github-release-template.md').read_text(), version,
            self.state['commit'], self.state['notes'], repo))
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
        if len(existing) != len(assets['assets']):
            raise RuntimeError('Duplicate remote release asset names.')
        if delivery.active(self.state) and set(existing) - set(expected):
            raise RuntimeError('Unexpected remote asset outside the sealed release inventory.')
        # Keep pending uploads outside synced Documents: a sync client may rename an
        # artifact while an earlier large upload runs. Verify a private local snapshot.
        with tempfile.TemporaryDirectory(prefix='tractanda-upload-', dir='/private/tmp') as staging:
            fs = os.statvfs(staging)
            needed = sum((self.directory / name).stat().st_size for name in expected if name not in existing)
            if fs.f_frsize <= 0 or fs.f_bavail * fs.f_frsize < needed + delivery.RESERVE:
                raise RuntimeError('Private upload staging capacity/reserve rejected.')
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
        if (len(observed) != len(remote['assets']) or remote['draft']
                or delivery.active(self.state) and set(observed) != set(expected)
                or any(observed.get(name) != 'sha256:' + digest for name, digest in expected.items())):
            raise RuntimeError('Published asset verification failed.')
        return {'url': remote['html_url'], 'sha256': expected}

    def build_apt(self):
        fingerprint = (self.source / 'docs/apt/fingerprint.txt').read_text().strip()
        output = self.directory / 'apt-site/apt'
        args = [sys.executable, 'scripts/apt-repository.py', 'build', '--root', output,
                '--fingerprint', fingerprint, '--gpg', self.settings.get('aptGPG', 'gpg')]
        for row in self.state['delivery']['linuxAssets']:
            args += ['--package', self.directory / row['name']]
        previous = self.directory / 'previous-pages'
        previous_key = self.settings.get('aptPreviousPublicKey')
        previous_fingerprint = self.settings.get('aptPreviousFingerprint')
        if bool(previous_key) != bool(previous_fingerprint):
            raise RuntimeError('APT rotation requires both reviewed previous public key and full fingerprint.')
        if not previous.exists():
            prior_args = [sys.executable, 'scripts/assemble-pages.py', '--output', previous,
                          '--repository', self.settings['repository']]
            if previous_key: prior_args += ['--public-key', previous_key, '--fingerprint', previous_fingerprint]
            self.run_command('apt-previous', prior_args)
        if (previous / 'apt/repository.json').is_file():
            record = json.loads(command([sys.executable, 'scripts/apt-repository.py', 'verify',
                '--root', previous / 'apt', '--public-key', previous_key or self.source / 'docs/apt/tractanda-archive-keyring.asc',
                '--fingerprint', previous_fingerprint or fingerprint, '--gpg', self.settings.get('aptGPG', 'gpg')],
                cwd=self.source, env=self.environment))
            version = record['packages'][0]['Version']
            prior = [r for r in record['packages'] if r['Version'] == version]
            if len(prior) != 2 or {r['Architecture'] for r in prior} != set(delivery.ARCHES):
                raise RuntimeError('Previous signed APT snapshot has an ambiguous current architecture pair.')
            for row in prior:
                args += ['--previous-package', previous / 'apt' / row['Filename']]
        # The key lives outside the checkout. GNUPGHOME is inherited or explicitly
        # configured locally; no private key or passphrase enters release state.
        if self.settings.get('aptGNUPGHome'):
            self.environment['GNUPGHOME'] = self.settings['aptGNUPGHome']
        if output.exists():
            # Retain interrupted output as evidence; never publish a partial tree.
            output.rename(output.with_name('apt.incomplete-' + str(time.time_ns())))
        self.run_command('apt', args)
        if (output / 'tractanda-archive-keyring.asc').read_bytes() != (self.source / 'docs/apt/tractanda-archive-keyring.asc').read_bytes():
            raise RuntimeError('APT signing public key differs from the reviewed source key.')
        with tarfile.open(self.directory / 'apt-site.tar.gz', 'w:gz') as archive:
            archive.add(output, arcname='apt', recursive=True)
        return read(output / 'repository.json')

    def verify_published_source(self):
        # Fetch the actual public tag into a new ref, independently of local HEAD.
        tag = 'v' + self.state['version']
        ref = 'refs/tractanda-published/' + tag
        self.run_command('published-source', ['git', 'fetch', '--no-tags', 'origin',
                         'refs/tags/' + tag + ':' + ref], self.source)
        if (git('rev-parse', ref + '^{commit}', cwd=self.source) != self.state['commit']
                or git('rev-parse', ref + '^{tree}', cwd=self.source) != self.state['tree']):
            raise RuntimeError('Published GitHub source differs from the sealed source/skill snapshot.')
        self.run_command('published-source', [sys.executable, 'scripts/verify-release-skills.py'], self.source)
        return {'commit': self.state['commit'], 'tree': self.state['tree'], 'tag': tag,
                'skills': 'actual public tag equals sealed source tree'}

    def published_pages(self):
        # A release-published workflow run deploys one combined site, preserving
        # the manual and the authenticated APT metadata in the same Pages artifact.
        runs = json.loads(command(['gh', 'run', 'list', '--repo', self.settings['repository'],
            '--workflow', 'manual.yml', '--event', 'release', '--json', 'databaseId,status,conclusion,headSha']))
        runs = [r for r in runs if r['headSha'] == self.state['commit']]
        if not runs:
            raise RuntimeError('Published Pages run is not visible yet; resume without rebuilding.')
        self.run_command('pages', ['gh', 'run', 'watch', str(runs[0]['databaseId']), '--repo',
                                  self.settings['repository'], '--exit-status'], ROOT)
        return {'runID': runs[0]['databaseId'], 'url': 'https://cubiculum-ai.github.io/tractanda/apt/'}

    def verify_published_package(self):
        published = self.state['steps'].get('publish', {}).get('result', {})
        if ('published-source' not in self.state['steps'] or 'pages' not in self.state['steps']
                or published.get('sha256', {}).get(self.package.name) != sha(self.package)):
            raise RuntimeError('Published source, Pages and exact package must be verified before update.')
        target = self.directory / 'published-download'
        target.mkdir(exist_ok=True)
        downloaded = target / self.package.name
        if not downloaded.exists():
            self.run_command('download-published-package', ['gh', 'release', 'download', 'v' + self.state['version'],
                '--repo', self.settings['repository'], '--pattern', self.package.name, '--dir', target], ROOT)
        if sha(downloaded) != published['sha256'][self.package.name]:
            raise RuntimeError('Downloaded published package differs from sealed release.')
        # install() stages this downloaded artifact, rather than a private package.
        self.package = downloaded

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
        if not delivery.active(self.state):
            raise RuntimeError('Revise the pending legacy candidate explicitly to the current Linux/cluster delivery contract.')
        if delivery.public(self.state):
            return self.run_public(ci_timeout)
        self.state.pop('error', None)
        self.state.pop('pauseReason', None)
        if git('rev-parse', 'HEAD', cwd=self.source) != self.state['commit'] or git('status', '--porcelain', cwd=self.source):
            raise RuntimeError('The sealed source checkout changed; refusing to release an unverified tree.')
        self.state['plannedSteps'] = delivery.release_plan(RELEASE_STEPS)
        self.save()
        self.step('verify', lambda: self.run_command('verify', ['sh', 'scripts/test.sh']))
        self.step('release-build', self.build)
        self.step('bundle', self.assemble)
        self.step('package', self.build_package)
        self.step('notarization', self.notarize_package)
        self.step('artifacts', self.package_artifacts)
        self.verify_artifacts()
        if not self.install_gate():
            return
        self.step('install', self.install)
        # Recheck after an interruption; a completed step alone cannot prove today's live pin.
        self.state['steps']['health'] = {'completedAt': now(), 'result': self.health()}
        self.save()
        if not self.cluster_gate():
            return
        self.step('push', self.push)
        if 'ci' not in self.state['steps']:
            self.wait_for_ci(ci_timeout)
        self.step('publish', self.publish)
        self.step('cleanup', self.cleanup)
        if set(self.state['steps']) != set(self.state['plannedSteps']):
            raise RuntimeError('Completed stages do not match the declared release plan.')
        self.state['status'] = 'complete'
        self.state.pop('activeStep', None)
        self.state.pop('activeStepStartedAt', None)
        self.state.pop('error', None)
        self.save()
        # Publication is durably complete before any sealed checkout is removed.
        if getattr(self, 'directory', None) is not None:
            record_release_retention(self)

    def run_public(self, ci_timeout):
        self.state.pop('error', None)
        if git('rev-parse', 'HEAD', cwd=self.source) != self.state['commit'] or git('status', '--porcelain', cwd=self.source):
            raise RuntimeError('Public release source changed after sealing.')
        self.state['plannedSteps'] = list(PUBLIC_STEPS)
        self.save()
        self.step('verify', lambda: self.run_command('verify', ['sh', 'scripts/test.sh']))
        self.step('release-build', self.build)
        self.step('bundle', self.assemble)
        self.step('package', self.build_package)
        self.step('notarization', self.notarize_package)
        self.step('apt', self.build_apt)
        self.step('artifacts', self.package_artifacts)
        self.verify_artifacts()
        self.step('push', self.push)
        if 'ci' not in self.state['steps']: self.wait_for_ci(ci_timeout)
        self.step('publish', self.publish)
        self.step('published-source', self.verify_published_source)
        self.step('pages', self.published_pages)
        self.step('install', self.install)
        self.state['steps']['health'] = {'completedAt': now(), 'result': self.health()}
        self.save()
        self.step('cleanup', self.cleanup)
        if set(self.state['steps']) != set(PUBLIC_STEPS):
            raise RuntimeError('Public release stages differ from the declared publication-before-update plan.')
        self.state.update(status='complete')
        for key in ('activeStep', 'activeStepStartedAt', 'error'): self.state.pop(key, None)
        self.save()
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
    parser.add_argument('action', choices=['prepare', 'revise', 'release', 'run', 'status', 'dashboard', 'prune',
                                         'attach-linux', 'install-template', 'allow-install', 'cluster-template', 'accept-cluster'])
    parser.add_argument('--config', type=Path, default=DEFAULT_CONFIG)
    parser.add_argument('--notes', help='Concise description of this completed changeset')
    parser.add_argument('--linux-assets', type=Path, help='Both real Linux packages and existing build receipts (attach-linux only)')
    parser.add_argument('--evidence', type=Path, help='Completed nonsecret operator evidence (allow-install/accept-cluster)')
    parser.add_argument('--candidate', help='Explicit exact candidate ID from the corresponding operator template')
    parser.add_argument('--background', action='store_true', help='Run in a detached local process; no agent or scheduler is used')
    parser.add_argument('--ci-timeout', type=int, default=3600, help='Maximum CI wait in seconds (default: 3600)')
    parser.add_argument('--json', action='store_true', help='Filtered live JSON status (status only)')
    parser.add_argument('--watch', action='store_true', help='Continuously observe the release (status only)')
    parser.add_argument('--port', type=int, default=48730, help='Loopback dashboard port (dashboard only)')
    args = parser.parse_args()
    if args.ci_timeout <= 0:
        parser.error('--ci-timeout must be positive')
    if args.linux_assets is not None and args.action != 'attach-linux':
        parser.error('--linux-assets applies only to attach-linux')
    if (args.evidence is not None or args.candidate is not None) and args.action not in ('allow-install', 'accept-cluster'):
        parser.error('--evidence/--candidate apply only to allow-install or accept-cluster')
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
        if args.action in ('attach-linux', 'install-template', 'allow-install', 'cluster-template', 'accept-cluster'):
            pipeline = Pipeline(read(CONTROL / 'current.json'))
            if args.action == 'attach-linux':
                if args.linux_assets is None: parser.error('attach-linux requires --linux-assets')
                delivery.attach(pipeline.state, args.linux_assets, pipeline.linux_context())
                pipeline.save()
            else:
                pipeline.verify_artifacts()
                if args.action in ('install-template', 'cluster-template'):
                    template = delivery.install_challenge if args.action == 'install-template' else delivery.challenge
                    print(json.dumps(template(pipeline.state), indent=2)); return
                if args.evidence is None or args.candidate is None: parser.error(args.action + ' requires --evidence and --candidate')
                action = delivery.allow_install if args.action == 'allow-install' else delivery.accept
                action(pipeline.state, args.evidence, args.candidate)
                pipeline.save()
            state = pipeline.state
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
