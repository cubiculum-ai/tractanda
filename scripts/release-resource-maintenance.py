#!/usr/bin/env python3
"""Bounded maintenance of explicitly registered Apple build containers.

The caller of maintain holds the release pipeline lock. The builder must hold the
resource lock while it runs jobs and register an idle container explicitly.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

CONTAINER = '/usr/local/bin/container'
NAME = re.compile(r'tractanda-[a-zA-Z0-9][a-zA-Z0-9_.-]*\Z')
IMAGE = re.compile(r'tractanda-[a-zA-Z0-9_.-]+:[a-zA-Z0-9_.-]+\Z')


def invoke(*args):
    return subprocess.run([CONTAINER, *args], text=True, capture_output=True, check=True)


def listing():
    rows = json.loads(invoke('list', '--all', '--format', 'json').stdout)
    if not isinstance(rows, list) or any(not isinstance(row, dict) or not isinstance(row.get('configuration'), dict) or not isinstance(row['configuration'].get('id'), str) for row in rows):
        raise ValueError('invalid container list')
    return rows


def identity(config):
    # Bind all runtime configuration, including image, entrypoint, creation date,
    # privileges and host mounts. Runtime state and startedDate are excluded.
    return hashlib.sha256(json.dumps(config, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def registry_path(control):
    path = control / 'resource-maintenance.json'
    if control.is_symlink() or path.is_symlink():
        raise ValueError('unsafe resource registry')
    return path


def read_registry(control):
    path = registry_path(control)
    if not path.exists():
        return []
    data = json.loads(path.read_text())
    if not isinstance(data, dict) or data.get('schema') != 1 or not isinstance(data.get('resources'), list):
        raise ValueError('invalid resource registry')
    return data['resources']


def write_registry(control, rows):
    fd, tmp = tempfile.mkstemp(prefix='.resources-', dir=control)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump({'schema': 1, 'resources': rows}, stream, indent=2)
            stream.flush(); os.fsync(stream.fileno())
        os.replace(tmp, registry_path(control))
    finally:
        if os.path.exists(tmp): os.unlink(tmp)


def register(control, version, name, policy):
    """Register a stopped build guest; caller holds pipeline and resource locks."""
    if not NAME.fullmatch(name) or not version or policy not in ('retire', 'retain'):
        raise ValueError('invalid registration')
    matches = [r for r in listing() if r.get('configuration', {}).get('id') == name]
    if len(matches) != 1 or matches[0].get('status', {}).get('state') != 'stopped':
        raise ValueError('registration requires exactly one stopped container')
    config = matches[0]['configuration']
    if not config.get('creationDate') or not config.get('image', {}).get('descriptor', {}).get('digest', '').startswith('sha256:'):
        raise ValueError('missing immutable identity')
    # Host paths must not be affected by guest maintenance. Only read-only
    # mounts are eligible, and trim explicitly addresses the root filesystem.
    if any('ro' not in m.get('options', []) for m in config.get('mounts', [])):
        raise ValueError('writable host mounts are not eligible')
    rows = read_registry(control)
    if any(r.get('name') == name for r in rows):
        raise ValueError('already registered')
    rows.append({'kind': 'container', 'name': name, 'version': version, 'policy': policy, 'identity': identity(config)})
    control.mkdir(parents=True, exist_ok=True)
    write_registry(control, rows)


def register_image(control, version, name):
    """Explicitly register a project-built image tag and its inspected identity."""
    if not IMAGE.fullmatch(name) or not version:
        raise ValueError('invalid image registration')
    result = json.loads(invoke('image', 'inspect', name).stdout)
    if len(result) != 1 or not re.fullmatch(r'[0-9a-f]{64}', result[0].get('id', '')):
        raise ValueError('invalid image identity')
    rows = read_registry(control)
    if any(row.get('name') == name for row in rows):
        raise ValueError('already registered')
    rows.append({'kind': 'image', 'name': name, 'version': version, 'policy': 'retire', 'identity': result[0]['id']})
    control.mkdir(parents=True, exist_ok=True)
    write_registry(control, rows)


# The idle check runs while the cooperative host lock is held. Only an idle sleep PID 1 is eligible. Any extra user process,
# including unexpected helpers, causes a conservative skip.
IDLE_CHECK = r'''set -eu
[ "$(tr '\0' ' ' </proc/1/cmdline)" = 'sleep infinity ' ] || [ "$(tr '\0' ' ' </proc/1/cmdline)" = '/bin/sleep infinity ' ] || exit 20
for p in /proc/[0-9]*; do
 n=${p#/proc/}; [ "$n" = 1 ] && continue; [ "$n" = "$$" ] && continue
 [ -r "$p/cmdline" ] || exit 21
 cmd=$(tr "\0" " " <"$p/cmdline") || exit 21
 [ -z "$cmd" ] || exit 21
done
'''


def maintain(control: Path, published: dict, protected_versions: set[str], retired_versions: set[str]) -> dict:
    report = {'removed': [], 'trimmed': [], 'skipped': [], 'warnings': [], 'unregistered': [], 'unregisteredImages': []}
    rows = read_registry(control)
    try:
        current = listing()
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        report['warnings'].append(f'container inventory unavailable: {error}')
        return report
    registered = {row.get('name') for row in rows if isinstance(row, dict)}
    report['unregistered'] = sorted(r.get('configuration', {}).get('id') for r in current
        if isinstance(r.get('configuration', {}).get('id'), str)
        and NAME.fullmatch(r['configuration']['id']) and r['configuration']['id'] not in registered)
    images = None
    try:
        images = json.loads(invoke('image', 'list', '--format', 'json').stdout)
        if not isinstance(images, list) or any(not isinstance(i, dict) or not isinstance(i.get('configuration'), dict) or not isinstance(i['configuration'].get('name'), str) for i in images):
            raise ValueError('invalid image list')
        report['unregisteredImages'] = sorted(i['configuration']['name'] for i in images
            if IMAGE.fullmatch(i['configuration']['name']) and i['configuration']['name'] not in registered)
    except (OSError, subprocess.SubprocessError, ValueError, TypeError) as error:
        images = None
        report['warnings'].append(f'image inventory unavailable: {error}')
    for row in rows:
        try:
            name, version, policy, fingerprint = (row[k] for k in ('name', 'version', 'policy', 'identity'))
            if row.get('retired') is True:
                if row.get('kind') == 'image':
                    if images is None: raise ValueError('retired image inventory unavailable')
                    if any(i.get('configuration', {}).get('name') == name for i in images):
                        raise ValueError('retired image name reappeared; identity requires review')
                elif any(r.get('configuration', {}).get('id') == name for r in current):
                    raise ValueError('retired container name reappeared; identity requires review')
                continue
            if row.get('kind') == 'image':
                if not isinstance(name, str) or not IMAGE.fullmatch(name) or policy != 'retire':
                    raise ValueError('invalid image registration')
                if version in protected_versions or version not in retired_versions:
                    raise ValueError('release version protected or not verified published')
                image_lock = control / ('resource-' + name + '.lock')
                if image_lock.is_symlink(): raise ValueError('unsafe lock')
                with image_lock.open('a') as lock:
                    try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError: raise ValueError('build resource busy')
                    image = json.loads(invoke('image', 'inspect', name).stdout)
                    if len(image) != 1 or image[0].get('id') != fingerprint:
                        raise ValueError('image identity changed')
                    digests = {image[0].get('configuration', {}).get('descriptor', {}).get('digest')}
                    digests.update(v.get('digest') for v in image[0].get('variants', []))
                    if 'sha256:' + fingerprint not in digests or None in digests:
                        raise ValueError('image digest metadata incomplete')
                    # Check index and platform variants, plus the registered tag.
                    for candidate in listing():
                        source = candidate['configuration'].get('image')
                        if not isinstance(source, dict) or not isinstance(source.get('descriptor'), dict):
                            raise ValueError('container image metadata incomplete')
                        if not source.get('reference') or not source.get('descriptor', {}).get('digest'):
                            raise ValueError('container image metadata incomplete')
                        if source['reference'].endswith('/' + name) or source['reference'] == name or source['descriptor']['digest'] in digests:
                            raise ValueError('image referenced by container')
                    invoke('image', 'delete', name)
                    row['retired'] = True
                    write_registry(control, rows)
                    report['removed'].append(name)
                continue
            if row.get('kind', 'container') != 'container' or not isinstance(name, str) or not NAME.fullmatch(name) or policy not in ('retire', 'retain'):
                raise ValueError('invalid registration')
            matches = [r for r in current if r.get('configuration', {}).get('id') == name]
            if len(matches) != 1 or identity(matches[0]['configuration']) != fingerprint:
                raise ValueError('missing or changed identity')
            config, state = matches[0]['configuration'], matches[0].get('status', {}).get('state')
            if any('ro' not in m.get('options', []) for m in config.get('mounts', [])):
                raise ValueError('writable host mount')
            lockpath = control / ('resource-' + name + '.lock')
            if lockpath.is_symlink(): raise ValueError('unsafe lock')
            with lockpath.open('a') as lock:
                try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError: raise ValueError('build resource busy')
                # Reinspect after taking the cooperative lock, not a stale list.
                fresh = json.loads(invoke('inspect', name).stdout)
                if len(fresh) != 1 or identity(fresh[0]['configuration']) != fingerprint:
                    raise ValueError('identity changed')
                state = fresh[0].get('status', {}).get('state')
                if policy == 'retire':
                    if version in protected_versions or version not in retired_versions:
                        raise ValueError('release version protected or not verified published')
                    if state != 'stopped': raise ValueError('container not stopped')
                    invoke('delete', name)
                    row['retired'] = True
                    write_registry(control, rows)
                    report['removed'].append(name)
                else:
                    if state != 'running': raise ValueError('retained container not running; not started for trim')
                    try:
                        # clean also targets named volumes: never admit them here.
                        if any(set(m.get('type', {})) != {'virtiofs'} for m in config.get('mounts', [])):
                            raise ValueError('not trimmed: non-bind volume mount')
                        invoke('exec', name, 'sh', '-c', IDLE_CHECK)
                        result = invoke('clean', name)
                        report['trimmed'].append({'name': name, 'output': result.stdout.strip()})
                    except subprocess.CalledProcessError as error:
                        report['skipped'].append({'name': name, 'reason': 'not trimmed: idle check or discard failed', 'detail': (error.stderr or '').strip()})
        except (KeyError, TypeError, ValueError, OSError, subprocess.SubprocessError) as error:
            report['skipped'].append({'name': row.get('name') if isinstance(row, dict) else None, 'reason': str(error)})
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--control', required=True, type=Path)
    parser.add_argument('--version', required=True)
    parser.add_argument('--policy', required=True, choices=('retire', 'retain'))
    parser.add_argument('--image', action='store_true', help='register a project-built image tag for retirement')
    parser.add_argument('name')
    args = parser.parse_args()
    if not (IMAGE.fullmatch(args.name) if args.image else NAME.fullmatch(args.name)): parser.error("invalid resource name")
    if args.image and args.policy != "retire": parser.error("image policy must be retire")
    if args.control.is_symlink(): parser.error('unsafe control directory')
    args.control.mkdir(parents=True, exist_ok=True)
    pipeline_path = args.control / 'pipeline.lock'
    resource_path = args.control / ('resource-' + args.name + '.lock')
    if pipeline_path.is_symlink() or resource_path.is_symlink(): parser.error('unsafe lock path')
    with pipeline_path.open('a') as pipeline, resource_path.open('a') as resource:
        fcntl.flock(pipeline, fcntl.LOCK_EX); fcntl.flock(resource, fcntl.LOCK_EX)
        if args.image: register_image(args.control, args.version, args.name)
        else: register(args.control, args.version, args.name, args.policy)


if __name__ == '__main__': main()
