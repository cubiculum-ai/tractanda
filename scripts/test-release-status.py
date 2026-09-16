#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest
from urllib.request import urlopen
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('status', Path(__file__).with_name('release-status.py'))
status = importlib.util.module_from_spec(spec); spec.loader.exec_module(status)

class StatusTests(unittest.TestCase):
    def test_relative_cli_launch_uses_its_observed_working_directory(self):
        controller = Path('/tmp/project/scripts/release-macos.py')
        command = '/usr/bin/python3 scripts/release-macos.py run'
        self.assertFalse(status.is_controller_command(command, controller))
        self.assertTrue(status.is_controller_command(command, controller, '/tmp/project'))
        self.assertFalse(status.is_controller_command(command, controller, '/tmp/different-project'))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root, {'version': 'v', 'status': 'running', 'steps': {}})
            def run(args, **kwargs):
                class Result: returncode = 0; stderr = ''
                result = Result()
                result.stdout = (f'fcwd\nn{status.ROOT}\n' if args[0] == 'lsof'
                                 else '44 1 00:01 ' + command + '\n')
                return result
            data = status.snapshot(root, runner=run)
            self.assertEqual(data['status'], 'running')
            self.assertEqual(data['runner']['identity'], 'matched')

    def test_completed_count_uses_the_release_plan_not_upload_substeps(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root, {'version': 'v', 'status': 'running',
                                'plannedSteps': ['verify', 'publish'],
                                'steps': {'verify': {}, 'upload-a.pkg': {}}})
            data = status.snapshot(root, runner=lambda *a, **k: None)
            self.assertEqual(data['completedStepCount'], 1)
            self.assertEqual(data['totalStepCount'], 2)
            self.assertIn('completed steps: 1 of 2', status.readable(data))

    def test_complete_plan_and_unknown_total(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root, {'version': 'v', 'status': 'complete',
                                'steps': {name: {} for name in status.RELEASE_STEPS}})
            data = status.snapshot(root, runner=lambda *a, **k: None)
            self.assertEqual(data['completedStepCount'], len(status.RELEASE_STEPS))
            self.assertEqual(data['totalStepCount'], len(status.RELEASE_STEPS))
            self.fixture(root, {'version': 'v', 'status': 'running', 'steps': {},
                                'plannedSteps': ['verify', 'verify']})
            data = status.snapshot(root, runner=lambda *a, **k: None)
            self.assertIsNone(data['totalStepCount'])
            self.assertIn('completed steps: 0 of unknown', status.readable(data))

    def test_failed_duration_stops_when_runner_stopped(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root, {'version': 'v', 'status': 'failed', 'steps': {},
                                'createdAt': '2026-01-01T00:00:00Z', 'activeStep': 'upload-a.pkg',
                                'activeStepStartedAt': '2026-01-01T00:00:02Z'},
                         {'pid': 44, 'version': 'v', 'status': 'failed', 'stoppedAt': '2026-01-01T00:00:10Z'})
            data = status.snapshot(root, runner=lambda *a, **k: None,
                                   now=status.parse_time('2026-01-02T00:00:00Z'))
            self.assertEqual(data['overallElapsedSeconds'], 10)
            self.assertEqual(data['stepElapsedSeconds'], 8)

    def test_elapsed_silence_is_not_advancement(self):
        observer = status.Observer()
        observation = {'status': 'running', 'stage': 'upload-a.pkg', 'latestObservedProgress': 'ci',
                       'lastLogActivityAt': '2026-01-01T00:00:00Z', 'lastLogActivityAgeSeconds': 5}
        observer.observe(dict(observation))
        self.assertEqual(observer.observe({**observation, 'lastLogActivityAgeSeconds': 9})['advancement'],
                         'quiet; advancement unknown')
        self.assertEqual(observer.observe({**observation, 'uploadReadProgress': {'readBytes': 25}})['advancement'],
                         'observed advancement')

    def test_controller_identity_with_unquoted_spaces_and_naive_time(self):
        controller = Path('/tmp/a project/scripts/release-macos.py')
        self.assertTrue(status.is_controller_command('/usr/bin/python3 ' + str(controller) + ' run', controller))
        self.assertFalse(status.is_controller_command('/bin/echo ' + str(controller) + ' run', controller))
        self.assertFalse(status.is_controller_command('/usr/bin/python3 ' + str(controller) + ' status --notes run', controller))
        self.assertIsNone(status.parse_time('2026-01-01T00:00:00'))

    def fixture(self, root, state, runner=None):
        runner = runner or {'pid': 44, 'status': 'running', 'version': state.get('version')}
        (root / 'current.json').write_text(json.dumps(state)); (root / 'runner.json').write_text(json.dumps(runner))
    def test_complete_precedes_dead_pid(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); self.fixture(root, {'version':'v','status':'complete','steps':{},'createdAt':'2026-01-01T00:00:00+00:00'})
            data = status.snapshot(root, runner=lambda *a, **k: None)
            self.assertEqual(data['status'], 'complete'); self.assertEqual(data['observation'], 'completed')
    def test_pid_mismatch_is_interrupted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); self.fixture(root, {'version':'v','status':'running','steps':{},'createdAt':'2026-01-01T00:00:00+00:00'})
            class Result: returncode=0; stdout='44 1 00:01 /bin/sleep 99\n'
            data = status.snapshot(root, runner=lambda *a, **k: Result())
            self.assertEqual(data['status'], 'interrupted'); self.assertFalse(data['runner']['alive'])
    def test_dead_ci_and_runner_version_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); state={'version':'v','status':'waitingForCI','steps':{},'createdAt':'2026-01-01T00:00:00+00:00'}
            self.fixture(root, state)
            class Absent: returncode=1; stdout=''; stderr=''
            self.assertEqual(status.snapshot(root, runner=lambda *a, **k: Absent())['status'], 'interrupted')
            self.fixture(root, state, {'pid':44,'status':'running','version':'other'})
            data=status.snapshot(root, runner=lambda *a, **k: Absent())
            self.assertEqual(data['status'], 'unknown'); self.assertEqual(data['runner']['identity'], 'versionMismatch')
    def test_missing_and_corrupt_state_are_safe(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); self.assertEqual(status.snapshot(root)['status'], 'unknown')
            (root/'current.json').write_text('{bad'); self.assertEqual(status.snapshot(root)['status'], 'unknown')
    def test_lsof_parser_and_progress_without_offset(self):
        parsed=status.parse_lsof_records('f3\no0t50\ns100\nn/tmp/a.pkg\n')
        self.assertEqual(parsed[0]['offset'], '0t50')
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); payload=root/'a.pkg'; payload.write_bytes(b'x'*100)
            class Result: returncode=0; stdout='f3\no0t50\ns100\nn'+str(payload)+'\n'
            private=Path('/private/tmp/tractanda-upload-test/a.pkg')
            Result.stdout='f3\no0t50\ns100\nn'+str(private)+'\n'
            self.assertEqual(status.upload_read_progress(1, root, 'a.pkg', lambda *a, **k: Result())['percent'], 50.0)
            Result.stdout='f3\no0t50\ns200\nn'+str(private)+'\n'
            self.assertIsNone(status.upload_read_progress(1, root, 'a.pkg', lambda *a, **k: Result()))
            Result.stdout='f3\ns100\nn'+str(payload)+'\n'
            self.assertIsNone(status.upload_read_progress(1, root, 'a.pkg', lambda *a, **k: Result()))
    def test_lsof_numbers_and_process_observability(self):
        self.assertEqual(status.numeric_lsof('0x10'), 16); self.assertEqual(status.numeric_lsof('0t10'), 10)
        self.assertEqual(status.numeric_lsof('10'), 10); self.assertIsNone(status.numeric_lsof('-1'))
        class Absent: returncode=1; stdout=''; stderr=''
        class Denied: returncode=1; stdout=''; stderr='operation not permitted'
        self.assertEqual(status.command_for_pid(4, lambda *a, **k: Absent())['presence'], 'absent')
        self.assertEqual(status.command_for_pid(4, lambda *a, **k: Denied())['presence'], 'unobservable')
    def test_routes_are_filtered(self):
        self.assertIn("textContent", status.PAGE); self.assertNotIn('configuration', status.PAGE)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); self.fixture(root, {'version':'v','status':'running','steps':{},'createdAt':'2026-01-01T00:00:00+00:00','configuration':{'secret':'no'}})
            data=status.snapshot(root, runner=lambda *a, **k: None)
            self.assertNotIn('configuration', data); self.assertNotIn('secret', json.dumps(data)); self.assertNotIn('command', json.dumps(data))
    def test_loopback_http_only_serves_dashboard_and_filtered_status(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); self.fixture(root, {'version':'v','status':'running','steps':{},'createdAt':'2026-01-01T00:00:00+00:00','notes':'private'})
            try:
                server=status.make_server(root, 0)
            except PermissionError:
                self.skipTest('sandbox blocks local listener creation')
            thread=threading.Thread(target=server.serve_forever); thread.start()
            try:
                address=f'http://127.0.0.1:{server.server_port}'
                with urlopen(address + '/') as reply: page=reply.read().decode()
                with urlopen(address + '/status.json') as reply: payload=reply.read().decode()
                self.assertIn('textContent', page); self.assertNotIn('private', payload)
            finally:
                server.shutdown(); thread.join(); server.server_close()

if __name__ == '__main__': unittest.main()
