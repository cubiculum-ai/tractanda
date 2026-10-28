#!/usr/bin/env python3
"""Private filesystem/systemd doubles; never operates a host service."""
import importlib.machinery
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def load():
    loader = importlib.machinery.SourceFileLoader('uuidd_policy', str(ROOT / 'debian/tractanda-package-hook-fallback.py.in'))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    result = importlib.util.module_from_spec(spec)
    loader.exec_module(result)
    return result


class UUIDDPolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='tractanda-uuidd-policy-')
        self.addCleanup(self.temp.cleanup)
        self.m = load()
        self.dropin = Path(self.temp.name) / 'system/uuidd.service.d/90-tractanda-normal-clock.conf'
        self.receipt = Path(self.temp.name) / 'tractanda/uuidd-normal-clock.json'
        self.m.UUIDD_DROPIN = str(self.dropin)
        self.m.UUIDD_RECEIPT = str(self.receipt)
        self.calls = []
        self.base = ['/usr/sbin/uuidd', '--socket-activation', '--cont-clock']
        self.effective_override = None
        self.fail_on = None
        # Existing custody helpers are separately exercised by package-hook tests.
        self.m.root_directory_chain = lambda path: None
        self.m.read_private_regular = lambda path, *a, **k: Path(path).read_bytes()
        self.m.uuidd_run = self.run_command
        self.running = mock.Mock()
        self.m.uuidd_verify_running = self.running

    def run_command(self, args):
        self.calls.append(args)
        if self.fail_on and self.fail_on in args:
            raise SystemExit('injected operation failure')
        if '--property=ExecStart' in args:
            command = self.effective_override or self.base
            if self.dropin.exists() and self.effective_override is None:
                command = self.dropin.read_text().split('ExecStart=')[-1].strip().split()
            return '{ path=/usr/sbin/uuidd ; argv[]=' + ' '.join(command) + ' ; ignore_errors=no ; start_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }'
        return ''

    def test_install_upgrade_retry_and_remove_preserve_shared_files(self):
        unrelated = Path(self.temp.name) / 'system/uuidd.service.d/99-admin.conf'
        unrelated.parent.mkdir(parents=True)
        unrelated.write_text('[Service]\nRestart=on-failure\n')
        self.base += ['--timeout', '300']
        self.assertEqual(self.m.uuidd_configure(), 0)
        original = self.dropin.read_bytes()
        self.assertIn(b'ExecStart=/usr/sbin/uuidd --socket-activation --timeout 300\n', original)
        self.assertEqual(self.m.uuidd_configure(), 0)
        self.assertEqual(self.dropin.read_bytes(), original)
        self.assertEqual(self.m.uuidd_remove(), 0)
        self.assertFalse(self.dropin.exists())
        self.assertFalse(self.receipt.exists())
        self.assertEqual(unrelated.read_text(), '[Service]\nRestart=on-failure\n')
        self.assertTrue(unrelated.parent.exists())
        self.assertEqual(self.m.uuidd_remove(), 0)
        self.assertIn(['/usr/bin/deb-systemd-invoke', 'try-restart', 'uuidd.service'], self.calls)
        self.assertFalse(any('uuidd.socket' in arg for call in self.calls for arg in call))

    def test_normal_admin_config_is_not_claimed(self):
        self.base.remove('--cont-clock')
        self.assertEqual(self.m.uuidd_configure(), 0)
        self.assertFalse(self.receipt.exists())
        self.assertFalse(self.dropin.exists())
        self.running.assert_called_once()

    def test_foreign_leaf_and_modified_owned_leaf_are_preserved(self):
        self.dropin.parent.mkdir(parents=True)
        self.dropin.write_text('administrator content')
        with self.assertRaises(SystemExit):
            self.m.uuidd_configure()
        self.dropin.unlink()
        self.m.uuidd_configure()
        self.dropin.write_text('changed by administrator')
        for action in (self.m.uuidd_configure, self.m.uuidd_remove):
            with self.assertRaises(SystemExit):
                action()
            self.assertEqual(self.dropin.read_text(), 'changed by administrator')

    def test_reload_and_restart_failures_leave_retryable_owned_state(self):
        for operation in ('daemon-reload', 'try-restart'):
            self.fail_on = operation
            with self.assertRaises(SystemExit):
                self.m.uuidd_configure()
            self.assertTrue(self.receipt.exists())
            self.assertTrue(self.dropin.exists())
            self.fail_on = None
            self.m.uuidd_configure()
            self.fail_on = operation
            with self.assertRaises(SystemExit):
                self.m.uuidd_remove()
            self.assertTrue(self.receipt.exists())
            self.assertFalse(self.dropin.exists())
            self.fail_on = None
            self.m.uuidd_remove()
            self.assertFalse(self.receipt.exists())

    def test_higher_priority_continuous_override_fails(self):
        self.effective_override = self.base[:]
        with self.assertRaises(SystemExit):
            self.m.uuidd_configure()
        self.assertTrue(self.receipt.exists())
        self.assertTrue(self.dropin.exists())

    def test_changed_effective_options_require_review(self):
        self.m.uuidd_configure()
        self.effective_override = ['/usr/sbin/uuidd', '--socket-activation', '--timeout', '42']
        with self.assertRaises(SystemExit):
            self.m.uuidd_configure()

    def test_unsafe_and_ambiguous_execstart_are_refused(self):
        for command in (
            ['/custom/uuidd', '--socket-activation', '--cont-clock'],
            ['/usr/sbin/uuidd', '--cont-clock'],
            ['/usr/sbin/uuidd', '--socket-activation', '--timeout', '"3 4"'],
            ['/usr/sbin/uuidd', '--socket-activation', '-C123'],
            ['/usr/sbin/uuidd', '--socket-activation', '--continuous'],
        ):
            self.effective_override = command
            with self.subTest(command=command), self.assertRaises(SystemExit):
                self.m.uuidd_configure()
            self.assertFalse(self.dropin.exists())

    def test_explicit_continuous_limit_is_removed(self):
        self.base[-1] = '--cont-clock=2h'
        self.m.uuidd_configure()
        self.assertNotIn('--cont-clock', self.dropin.read_text())

    def test_missing_dropin_retained_receipt_and_stale_temporary_retry(self):
        self.m.uuidd_configure()
        self.dropin.unlink()  # Crash after ownership intent, before leaf publication.
        stale = Path(str(self.dropin) + '.tractanda-new-dead-owner')
        stale.write_text('unpublished bytes')
        self.m.uuidd_configure()
        self.assertTrue(self.dropin.exists())
        self.assertEqual(stale.read_text(), 'unpublished bytes')

    def test_policy_blocked_running_daemon_fails_then_same_configure_recovers(self):
        self.running.side_effect = SystemExit('continuous-clock daemon still running')
        with self.assertRaises(SystemExit):
            self.m.uuidd_configure()
        original = self.dropin.read_bytes()
        self.assertTrue(self.receipt.exists())
        self.running.side_effect = None
        self.assertEqual(self.m.uuidd_configure(), 0)
        self.assertEqual(self.dropin.read_bytes(), original)

    def test_hook_dispatch_configures_before_setup_and_removes_after_validation(self):
        self.m.verify_helper = mock.Mock(return_value=0)
        self.m.ensure_layout_aliases = mock.Mock(return_value=None)
        self.m.uuidd_configure = mock.Mock(return_value=0)
        with mock.patch.object(self.m.os, 'geteuid', return_value=0):
            self.assertEqual(self.m.fallback(['configure-helper', '/fixed/helper']), 0)
        self.m.verify_helper.assert_called_once_with(['verify-helper', '/fixed/helper'])
        self.m.ensure_layout_aliases.assert_called_once()
        self.m.uuidd_configure.assert_called_once()

    def test_live_process_continuous_clock_is_detected(self):
        actual = load()
        actual.uuidd_run = lambda args: '123'
        with mock.patch('builtins.open', mock.mock_open(read_data=b'/usr/sbin/uuidd\0--socket-activation\0--cont-clock\0')):
            with self.assertRaises(SystemExit):
                actual.uuidd_verify_running()
        with mock.patch('builtins.open', mock.mock_open(read_data=b'/usr/sbin/uuidd\0--socket-activation\0')):
            actual.uuidd_verify_running()
        actual.uuidd_run = lambda args: '0'
        with mock.patch('builtins.open', side_effect=AssertionError('inactive daemon must remain inactive')):
            actual.uuidd_verify_running()


if __name__ == '__main__':
    unittest.main()
