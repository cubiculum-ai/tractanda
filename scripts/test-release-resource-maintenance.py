import fcntl
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('resources', Path(__file__).with_name('release-resource-maintenance.py'))
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


def guest(state='stopped'):
    return {'configuration': {'id': 'tractanda-build', 'creationDate': 'today',
            'image': {'reference': 'docker.io/library/other:latest', 'descriptor': {'digest': 'sha256:abc'}},
            'mounts': [{'source': '/host', 'destination': '/src', 'options': ['ro'], 'type': {'virtiofs': {}}}]},
            'status': {'state': state}}


class Maintenance(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.control = Path(self.tmp.name)
        self.row = guest()
        self.calls = []
        self.fail_trim = False
        self.present = True
        self.image_present = True
        def invoke(*args):
            self.calls.append(args)
            if args[0] == 'list': return subprocess.CompletedProcess(args, 0, json.dumps([self.row] if self.present else []), '')
            if args[0] == 'inspect': return subprocess.CompletedProcess(args, 0, json.dumps([self.row]), '')
            if args[:2] == ('image', 'inspect'): return subprocess.CompletedProcess(args, 0, json.dumps([{'id': 'a' * 64, 'configuration': {'descriptor': {'digest': 'sha256:' + 'a' * 64}}, 'variants': [{'digest': 'sha256:' + 'b' * 64}]}]), '')
            if args[:2] == ('image', 'list'): return subprocess.CompletedProcess(args, 0, json.dumps([{'configuration': {'name': 'tractanda-test:bookworm'}}] if self.image_present else []), '')
            if args[0] == 'delete': self.present = False
            if args[:2] == ('image', 'delete'): self.image_present = False
            if args[0] == 'clean' and self.fail_trim:
                raise subprocess.CalledProcessError(1, args, stderr='Operation not permitted')
            return subprocess.CompletedProcess(args, 0, 'trimmed', '')
        self.patch = patch.object(r, 'invoke', side_effect=invoke)
        self.patch.start()
    def tearDown(self):
        self.patch.stop(); self.tmp.cleanup()
    def test_retire_exact_stopped_and_preserve_protected(self):
        r.register(self.control, 'old', 'tractanda-build', 'retire')
        self.assertFalse(r.maintain(self.control, {'version': 'new'}, {'old'}, {'old'})['removed'])
        self.assertEqual(r.maintain(self.control, {'version': 'new'}, set(), {'old', 'new'})['removed'], ['tractanda-build'])
        self.assertEqual(self.calls[-1], ('delete', 'tractanda-build'))
        report = r.maintain(self.control, {'version': 'new'}, set(), {'old'})
        self.assertFalse(report['skipped'])
        self.assertEqual(sum(c[0] == 'delete' for c in self.calls), 1)
        self.present = True
        self.assertIn('reappeared', r.maintain(self.control, {'version': 'new'}, set(), {'old'})['skipped'][0]['reason'])
    def test_changed_identity_or_running_guest_never_deleted(self):
        r.register(self.control, 'old', 'tractanda-build', 'retire')
        self.row['configuration']['mounts'][0]['source'] = '/changed'
        self.assertFalse(r.maintain(self.control, {'version': 'new'}, set(), {'old', 'new'})['removed'])
        self.assertFalse(any(c[0] == 'delete' for c in self.calls))
    def test_retained_trim_failure_is_not_success(self):
        r.register(self.control, 'new', 'tractanda-build', 'retain')
        self.row['status']['state'] = 'running'; self.fail_trim = True
        report = r.maintain(self.control, {'version': 'new'}, set(), {'old', 'new'})
        self.assertFalse(report['trimmed'])
        self.assertIn('not trimmed', report['skipped'][0]['reason'])
        self.assertIn('Operation not permitted', report['skipped'][0]['detail'])
    def test_image_identity_reference_and_retirement_allowlist(self):
        r.register_image(self.control, 'old', 'tractanda-test:bookworm')
        self.assertFalse(r.maintain(self.control, {'version': 'new'}, set(), set())['removed'])
        self.row['configuration']['image']['descriptor']['digest'] = 'sha256:' + 'a' * 64
        self.assertFalse(r.maintain(self.control, {'version': 'new'}, set(), {'old'})['removed'])
        self.row['configuration']['image']['descriptor']['digest'] = 'sha256:' + 'b' * 64
        self.assertFalse(r.maintain(self.control, {'version': 'new'}, set(), {'old'})['removed'])
        self.row['configuration']['image']['descriptor']['digest'] = 'sha256:other'
        self.assertEqual(r.maintain(self.control, {'version': 'new'}, set(), {'old'})['removed'], ['tractanda-test:bookworm'])
        self.assertEqual(self.calls[-1], ('image', 'delete', 'tractanda-test:bookworm'))
        self.assertFalse(r.maintain(self.control, {'version': 'new'}, set(), {'old'})['skipped'])
    def test_busy_lock_and_running_retire_skip(self):
        r.register(self.control, 'old', 'tractanda-build', 'retire')
        with (self.control / 'resource-tractanda-build.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            report = r.maintain(self.control, {'version': 'new'}, set(), {'old'})
            self.assertIn('busy', report['skipped'][0]['reason'])
        self.row['status']['state'] = 'running'
        report = r.maintain(self.control, {'version': 'new'}, set(), {'old'})
        self.assertIn('not stopped', report['skipped'][0]['reason'])
        self.assertFalse(any(c[0] in ('delete', 'start', 'stop') for c in self.calls))
    def test_guest_busy_is_not_trimmed(self):
        r.register(self.control, 'new', 'tractanda-build', 'retain')
        self.row['status']['state'] = 'running'
        with patch.object(r, 'invoke', side_effect=lambda *args: (_ for _ in ()).throw(subprocess.CalledProcessError(21, args)) if args[0] == 'exec' else subprocess.CompletedProcess(args, 0, json.dumps([self.row]), '')):
            report = r.maintain(self.control, {'version': 'new'}, set(), {'new'})
        self.assertFalse(report['trimmed'])
        self.assertIn('not trimmed', report['skipped'][0]['reason'])
    def test_native_clean_only_after_idle_and_reject_named_volume(self):
        r.register(self.control, 'new', 'tractanda-build', 'retain')
        self.row['status']['state'] = 'running'
        report = r.maintain(self.control, {'version': 'new'}, set(), {'new'})
        self.assertEqual(report['trimmed'][0]['name'], 'tractanda-build')
        self.assertEqual(self.calls[-1], ('clean', 'tractanda-build'))
        self.row['configuration']['mounts'][0]['type'] = {'volume': {}}
        # Re-register the modified configuration to isolate the volume guard.
        rows = r.read_registry(self.control); rows[0]['identity'] = r.identity(self.row['configuration']); r.write_registry(self.control, rows)
        report = r.maintain(self.control, {'version': 'new'}, set(), {'new'})
        self.assertIn('non-bind volume', report['skipped'][0]['reason'])
        self.assertEqual(sum(c[0] == 'clean' for c in self.calls), 1)
    def test_unregistered_reported_only(self):
        report = r.maintain(self.control, {'version': 'new'}, set(), set())
        self.assertEqual(report['unregistered'], ['tractanda-build'])
        self.assertEqual(report['unregisteredImages'], ['tractanda-test:bookworm'])
        self.assertFalse(any(c[0] in ('delete', 'exec') for c in self.calls))
    def test_malformed_inventories_are_reported(self):
        with patch.object(r, 'invoke', return_value=subprocess.CompletedProcess([], 0, '[null]', '')):
            report = r.maintain(self.control, {'version': 'new'}, set(), set())
        self.assertIn('invalid container list', report['warnings'][0])
    def test_registration_rejects_symlink_locks(self):
        (self.control / 'pipeline.lock').symlink_to(self.control / 'other')
        with patch('sys.argv', ['tool', '--control', str(self.control), '--version', 'new', '--policy', 'retain', 'tractanda-build']):
            with self.assertRaises(SystemExit): r.main()
        self.assertFalse((self.control / 'other').exists())
    def test_stopped_retained_not_started_and_writable_mount_rejected(self):
        r.register(self.control, 'new', 'tractanda-build', 'retain')
        self.assertFalse(r.maintain(self.control, {'version': 'new'}, set(), {'old', 'new'})['trimmed'])
        self.assertFalse(any(c[0] in ('start', 'exec') for c in self.calls))
        self.row['configuration']['mounts'][0]['options'] = []
        with self.assertRaises(ValueError): r.register(self.control, 'new', 'tractanda-other', 'retain')

if __name__ == '__main__': unittest.main()
