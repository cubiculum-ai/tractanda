#!/usr/bin/env python3
"""Read-only local observer for the detached macOS release controller."""
import argparse
from datetime import datetime, timezone
import json
import hashlib
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import shlex
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]
RELEASE_STEPS = tuple(json.loads(Path(__file__).with_name('release-steps.json').read_text()))
DEFAULT_CONTROL = ROOT / 'work' / 'release-pipeline'
CONTROLLER = (ROOT / 'scripts' / 'release-macos.py').resolve()
TERMINAL = {'complete', 'failed'}


def utc_now():
    return datetime.now(timezone.utc)


def parse_time(value):
    if not isinstance(value, str):
        return None
    try:
        point = datetime.fromisoformat(value.replace('Z', '+00:00'))
        return point if point.tzinfo is not None else None
    except ValueError:
        return None


def age_seconds(value, now=None):
    point = parse_time(value) if isinstance(value, str) else value
    if point is None:
        return None
    return max(0, int(((now or utc_now()) - point).total_seconds()))


def read_object(path):
    try:
        value = json.loads(Path(path).read_text())
        if not isinstance(value, dict):
            raise ValueError('expected an object')
        return value, None
    except FileNotFoundError:
        return None, 'missing'
    except (OSError, ValueError, json.JSONDecodeError) as error:
        return None, 'unreadable: ' + str(error)


def command_for_pid(pid, runner=subprocess.run):
    """Distinguish an absent process from a process the observer cannot inspect."""
    try:
        result = runner(['ps', '-p', str(pid), '-o', 'pid=,ppid=,etime=,command='],
                        capture_output=True, text=True, timeout=1, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return {'presence': 'unobservable'}
    if result is None:
        return {'presence': 'unobservable'}
    line = (result.stdout or '').strip()
    if result.returncode == 1 and not line and not (getattr(result, 'stderr', '') or '').strip():
        return {'presence': 'absent'}
    if result.returncode or not line:
        return {'presence': 'unobservable'}
    fields = line.split(None, 3)
    if len(fields) != 4 or not fields[0].isdigit() or not fields[1].isdigit():
        return {'presence': 'unobservable'}
    return {'presence': 'present', 'pid': int(fields[0]), 'ppid': int(fields[1]),
            'elapsed': fields[2], 'command': fields[3]}


def is_controller_command(command, controller=CONTROLLER, working_directory=None):
    # ps does not reliably quote argv paths containing spaces. The launcher uses
    # an absolute Python executable followed directly by this controller; a
    # relative controller path additionally requires the observed process cwd.
    paths = {str(Path(controller)), str(Path(controller).resolve())}
    if working_directory:
        relative = os.path.relpath(Path(controller).resolve(), Path(working_directory).resolve())
        paths.update((relative, './' + relative))
    choices = [printed for path in paths for printed in (path, shlex.quote(path), '"' + path + '"')]
    for printed in choices:
        match = re.search(r'\s' + re.escape(printed) + r'\s+run(?:\s|$)', command)
        if match:
            executable = command[:match.start()].strip().strip('"\'')
            return Path(executable).name.lower().startswith('python')
    return False


def working_directory_for_pid(pid, runner=subprocess.run):
    """Resolve a relative launch path against that process's cwd, not ours."""
    try:
        result = runner(['lsof', '-a', '-p', str(pid), '-d', 'cwd', '-F', 'fn'],
                        capture_output=True, text=True, timeout=1, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result is None or result.returncode:
        return None
    for entry in parse_lsof_records(result.stdout):
        if entry.get('fd') == 'cwd' and entry.get('name', '').startswith('/'):
            return entry['name']
    return None


def child_for_pid(pid, runner=subprocess.run):
    try:
        result = runner(['ps', '-axo', 'pid=,ppid=,etime=,command='], capture_output=True,
                        text=True, timeout=1, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result is None or result.returncode:
        return None
    for line in result.stdout.splitlines():
        fields = line.split(None, 3)
        if len(fields) == 4 and fields[0].isdigit() and fields[1].isdigit() and int(fields[1]) == pid:
            command = fields[3]
            try:
                label = Path(shlex.split(command)[0]).name
            except (ValueError, IndexError):
                label = 'process'
            return {'pid': int(fields[0]), 'elapsed': fields[2], 'label': label}
    return None


def parse_lsof_records(text):
    """Parse only lsof machine fields needed for regular-file read offsets."""
    records, current = [], {}
    for line in text.splitlines():
        if not line:
            continue
        key, value = line[0], line[1:]
        if key == 'f':
            if current:
                records.append(current)
            current = {'fd': value}
        elif key in {'n', 'o', 's'} and current:
            current[{'n': 'name', 'o': 'offset', 's': 'size'}[key]] = value
    if current:
        records.append(current)
    return records


def numeric_lsof(value):
    if not isinstance(value, str):
        return None
    if value.startswith('0t'):
        base, value = 10, value[2:]
    elif value.startswith('0x'):
        base, value = 16, value[2:]
    else:
        base = 10
    try:
        number = int(value, base)
        return number if number >= 0 else None
    except ValueError:
        return None


def upload_read_progress(pid, directory, expected_name, runner=subprocess.run):
    """Best-effort local stream-read position; it says nothing about remote acceptance."""
    if Path(expected_name).name != expected_name or not expected_name.endswith(('.pkg', '.tar.gz')):
        return None
    expected = Path(directory) / expected_name
    try:
        expected_size = expected.stat().st_size
    except OSError:
        return None
    try:
        result = runner(['lsof', '-o', '-F', 'fnos', '-p', str(pid)], capture_output=True,
                        text=True, timeout=1, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result is None or result.returncode:
        return None
    for record in parse_lsof_records(result.stdout):
        offset = numeric_lsof(record.get('offset'))
        # The controller uploads a verified private copy. Match only the active
        # expected asset's basename and byte size, never arbitrary open files.
        handle = Path(record.get('name', ''))
        permitted = (handle == expected or
                     handle.parent.name.startswith('tractanda-upload-') and
                     handle.parent.parent in (Path('/private/tmp'), Path('/tmp')))
        if handle.name == expected_name and offset is not None and permitted:
            size = numeric_lsof(record.get('size'))
            if size is None:
                try:
                    size = handle.stat().st_size
                except OSError:
                    continue
            if size != expected_size:
                continue
            return {'file': expected_name, 'readBytes': min(offset, expected_size), 'sizeBytes': expected_size,
                    'percent': round(min(offset, expected_size) * 100 / expected_size, 1) if expected_size else 100.0,
                    'meaning': 'local payload read position; remote acceptance is not implied'}
    return None


class Observer:
    """Keeps only prior public measurements, allowing quiet to stay inconclusive."""
    def __init__(self):
        self.previous = None
    def observe(self, data):
        marker = (data.get('stage'), data.get('latestObservedProgress'),
                  data.get('lastLogActivityAt'),
                  (data.get('uploadReadProgress') or {}).get('readBytes'))
        if data['status'] in TERMINAL:
            data['advancement'] = 'finished'
        elif self.previous is None:
            data['advancement'] = 'single observation; advancement unknown'
        elif marker != self.previous:
            data['advancement'] = 'observed advancement'
        else:
            data['advancement'] = 'quiet; advancement unknown'
        self.previous = marker
        return data


def failure_summary(state, control):
    """Expose only an explicit, non-sensitive category from the matching release."""
    if state.get('status') != 'failed' or state.get('activeStep') != 'notarization':
        return None
    directory = Path(state.get('directory', ''))
    if directory.resolve().parent != Path(control).resolve() or directory.name != state.get('version'):
        return None
    receipt, _ = read_object(directory / 'notarization/notarization.json')
    if receipt and not receipt.get('notarized') and receipt.get('failureCategory') == 'accountDiscovery':
        return 'Xcode CLI could not discover the configured developer account before upload. The bounded recovery stopped.'
    return None


def snapshot(control=DEFAULT_CONTROL, runner=subprocess.run, now=None, observer=None):
    """Return filtered observer state without reading configuration, notes, or log bodies."""
    control, now = Path(control), now or utc_now()
    state, state_error = read_object(control / 'current.json')
    runner_state, _runner_error = read_object(control / 'runner.json')
    if state is None:
        data = {'status': 'unknown', 'observedAt': now.isoformat(), 'observation': 'release state unavailable',
                'runner': {'state': 'unknown', 'identity': 'unavailable'}, 'completedSteps': [],
                'completedStepCount': 0, 'totalStepCount': None, 'progress': 'unavailable'}
        return observer.observe(data) if observer else data
    status = state.get('status') if isinstance(state.get('status'), str) else 'unknown'
    active = state.get('activeStep') if isinstance(state.get('activeStep'), str) else None
    steps = state.get('steps') if isinstance(state.get('steps'), dict) else {}
    planned = state.get('plannedSteps', list(RELEASE_STEPS))
    valid_plan = (isinstance(planned, list) and bool(planned)
                  and all(isinstance(name, str) and name for name in planned)
                  and len(set(planned)) == len(planned))
    completed = [{'name': name, 'completedAt': item.get('completedAt') if isinstance(item, dict) else None}
                 for name, item in steps.items()]
    valid_pid = isinstance(runner_state, dict) and type(runner_state.get('pid')) is int and runner_state['pid'] > 0
    version_matches = isinstance(runner_state, dict) and runner_state.get('version') == state.get('version')
    pid = runner_state['pid'] if valid_pid and version_matches else None
    process = command_for_pid(pid, runner) if pid else {'presence': 'unobservable'}
    matches = process.get('presence') == 'present' and is_controller_command(process['command'])
    if process.get('presence') == 'present' and not matches:
        matches = is_controller_command(process['command'],
                                        working_directory=working_directory_for_pid(pid, runner))
    runner_view = {'state': 'missing' if runner_state is None else 'recorded', 'pid': pid,
                   'alive': matches, 'identity': 'matched' if matches else
                   ('versionMismatch' if valid_pid and not version_matches else
                    ('mismatch' if process.get('presence') == 'present' else process['presence']))}
    if process.get('presence') == 'present':
        runner_view['elapsed'] = process['elapsed']
    child = child_for_pid(pid, runner) if matches else None
    log_age = log_at = None
    try:
        if active and Path(active).name == active:
            changed_at = (Path(state.get('directory', '')) / (active + '.log')).stat().st_mtime
            log_at = datetime.fromtimestamp(changed_at, timezone.utc).isoformat()
            log_age = max(0, int(now.timestamp() - changed_at))
    except OSError:
        pass
    terminal = status in TERMINAL
    if terminal:
        observation = 'completed' if status == 'complete' else 'failed'
    elif status == 'waitingForCI' and matches:
        observation = 'waiting for CI; quiet logs do not prove a stall'
    elif matches:
        observation = 'controller is present; progress is unknown until state or stream position changes'
    elif pid and process['presence'] == 'present':
        observation = 'runner PID belongs to a different command; treating it as not running'
        status = 'interrupted'
    elif pid and process['presence'] == 'absent':
        observation = 'recorded runner is absent; release was interrupted'
        status = 'interrupted'
    else:
        observation = 'runner cannot be observed; release status is unknown'
        status = 'unknown'
    latest = completed[-1]['name'] if completed else None
    progress = None
    if child and active and active.startswith('upload-'):
        progress = upload_read_progress(child['pid'], state.get('directory', ''), active.removeprefix('upload-'), runner)
    end = parse_time(runner_state.get('stoppedAt')) if terminal and version_matches else None
    end = end or (parse_time(state.get('updatedAt')) if terminal else now) or now
    data = {'status': status, 'version': state.get('version'), 'stage': active, 'observedAt': now.isoformat(),
            'completedSteps': completed,
            'completedStepCount': sum(name in steps for name in planned) if valid_plan else len(completed),
            'totalStepCount': len(planned) if valid_plan else None,
            'latestObservedProgress': latest or active or 'none',
            'overallElapsedSeconds': max(0, int((end - parse_time(state['createdAt'])).total_seconds())) if parse_time(state.get('createdAt')) else None,
            'stepElapsedSeconds': age_seconds(state.get('activeStepStartedAt'), end) if active else None,
            'lastLogActivityAgeSeconds': log_age, 'lastLogActivityAt': log_at, 'runner': runner_view, 'child': child,
            'uploadReadProgress': progress, 'progress': progress or 'unavailable', 'observation': observation,
            'failureSummary': failure_summary(state, control)}
    return observer.observe(data) if observer else data


def readable(data):
    lines = [f"Release {data.get('version') or 'unknown'}: {data['status']}",
             f"Stage: {data.get('stage') or 'none'}; completed steps: {data.get('completedStepCount', 0)} of {data.get('totalStepCount') or 'unknown'}",
             'Observer: ' + data.get('observation', 'unknown')]
    runner = data.get('runner', {})
    if data.get('failureSummary'):
        lines.insert(2, 'Failure: ' + data['failureSummary'])
    lines.append('Runner: ' + runner.get('identity', 'unknown') +
                 (f" (PID {runner['pid']})" if runner.get('pid') else ''))
    if data.get('child'):
        lines.append(f"Child: {data['child']['label']} (PID {data['child']['pid']})")
    if data.get('lastLogActivityAgeSeconds') is not None:
        lines.append(f"Last log activity: {data['lastLogActivityAgeSeconds']}s ago")
    if data.get('overallElapsedSeconds') is not None:
        lines.append(f"Overall elapsed: {data['overallElapsedSeconds']}s")
    if data.get('stepElapsedSeconds') is not None:
        lines.append(f"Step elapsed: {data['stepElapsedSeconds']}s")
    if isinstance(data.get('uploadReadProgress'), dict):
        progress = data['uploadReadProgress']
        lines.append(f"Local stream read: {progress['file']} {progress['percent']}% (remote acceptance unknown)")
    elif data['status'] in TERMINAL:
        lines.append('Progress: finished.')
    else:
        lines.append('Progress: unavailable; a quiet controller is not proof of a stall.')
    lines.append('Advancement: ' + data.get('advancement', 'unknown'))
    return '\n'.join(lines)


PAGE = '''<!doctype html><meta charset="utf-8"><title>Tractanda release status</title>
<style>body{margin:0;background:#07182d;color:#dce9fa;font:16px -apple-system,sans-serif}main{max-width:760px;margin:48px auto;padding:24px;background:#0d2745;border-radius:12px}pre{white-space:pre-wrap;color:#b8d4f1}</style>
<main><h1>Release observer</h1><pre id="status">Loading…</pre></main><script>let busy=false;async function load(){if(busy)return;busy=true;let out=document.querySelector('#status');try{let r=await fetch('/status.json',{cache:'no-store'});if(!r.ok)throw Error('status unavailable');let x=await r.json();out.textContent=[`Release ${x.version||'unknown'}: ${x.status}`,`Stage: ${x.stage||'none'}; completed steps: ${x.completedStepCount||0} of ${x.totalStepCount??'unknown'}`,...(x.failureSummary?[`Failure: ${x.failureSummary}`]:[]),`Observer: ${x.observation}`,`Advancement: ${x.advancement||'unknown'}`,`Overall elapsed: ${x.overallElapsedSeconds??'unavailable'}s`,x.stepElapsedSeconds!=null?`Step elapsed: ${x.stepElapsedSeconds}s`:'Step elapsed: unavailable',x.lastLogActivityAgeSeconds!=null?`Last activity: ${x.lastLogActivityAgeSeconds}s ago`:'Last activity: unavailable',x.uploadReadProgress?`Local stream read: ${x.uploadReadProgress.file} ${x.uploadReadProgress.percent}% (remote acceptance unknown)`:x.status==='complete'?'Progress: finished.':'Progress: unavailable; quiet is not proof of a stall.'].join('\\n')}catch(e){out.textContent='Status refresh failed; displayed state is unavailable.'}finally{busy=false}}load();setInterval(load,2000)</script>'''


def make_server(control, port):
    observer = Observer()
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == '/':
                body, content_type = PAGE.encode(), 'text/html; charset=utf-8'
            elif self.path == '/status.json':
                body, content_type = json.dumps(snapshot(control, observer=observer), separators=(',', ':')).encode(), 'application/json'
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Tractanda-Release-Observer', hashlib.sha256(str(Path(control).resolve()).encode()).hexdigest())
            self.send_header('Content-Security-Policy', "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'")
            self.send_header('Content-Length', str(len(body)))
            self.end_headers(); self.wfile.write(body)
        def log_message(self, *_):
            pass
    return ThreadingHTTPServer(('127.0.0.1', port), Handler)


def serve(control, port):
    make_server(control, port).serve_forever()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--control', type=Path, default=DEFAULT_CONTROL)
    parser.add_argument('--json', action='store_true', help='Print filtered machine-readable state')
    parser.add_argument('--watch', action='store_true', help='Refresh the readable status every two seconds')
    parser.add_argument('--interval', type=float, default=2)
    sub = parser.add_subparsers(dest='command')
    web = sub.add_parser('serve', help='Serve a loopback-only status dashboard')
    web.add_argument('--port', type=int, default=48730)
    args = parser.parse_args()
    if args.command == 'serve':
        serve(args.control, args.port); return
    if args.interval <= 0: parser.error('--interval must be positive')
    observer = Observer()
    while True:
        data = snapshot(args.control, observer=observer)
        print(json.dumps(data, indent=2) if args.json else readable(data), flush=True)
        if not args.watch: return
        time.sleep(args.interval)


if __name__ == '__main__':
    main()
