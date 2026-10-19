#!/usr/bin/env python3
"""Small fault tests for Linux evidence admission; never launches a container."""
import importlib.util
import json
from pathlib import Path
import signal
import stat
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('cluster_gate', Path(__file__).with_name('verify-cluster-linux.py'))
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


class CurrentLinuxGateTests(unittest.TestCase):
    def test_timeout_cli_defaults_overrides_rejects_invalid_and_derives_owner_headroom(self):
        defaults = GATE.parse_args([])
        self.assertEqual(defaults.timeout_seconds, 24 * 60 * 60)
        self.assertEqual(defaults.command_timeout_seconds, 24 * 60 * 60)
        configured = GATE.parse_args(['--timeout-seconds', '7200', '--command-timeout-seconds', '14400'])
        self.assertEqual(configured.timeout_seconds, 7200)
        self.assertEqual(configured.command_timeout_seconds, 14400)
        self.assertEqual(GATE.timeout_budgets(3600),
                         {'operationSeconds': 3600, 'cleanupHeadroomSeconds': 120, 'ownerSeconds': 3720})
        self.assertEqual(GATE.effective_command_timeout(configured.timeout_seconds,
                                                        configured.command_timeout_seconds), 7200)
        for flag, invalid in (('--timeout-seconds', '0'), ('--timeout-seconds', '-1'),
                              ('--timeout-seconds', 'nan'), ('--command-timeout-seconds', 'inf')):
            with self.subTest(flag=flag, invalid=invalid), self.assertRaises(SystemExit):
                GATE.parse_args([flag, invalid])

    def test_host_owner_budget_exceeds_selected_guest_operation_for_cleanup(self):
        with patch.object(GATE, 'LABEL', 'cluster-b2-20261016-test'), \
                patch.object(GATE, 'OPERATION_TIMEOUT_SECONDS', 7200), \
                patch.object(GATE, 'run') as run, patch.object(GATE, 'ensure_container_absent'):
            GATE.monitored_host_run(['owned-container'], {}, 'test-session')
        self.assertEqual(run.call_args.args[3], 7320)

    def test_final_selection_is_exact_and_does_not_expand_other_methods(self):
        receipt = GATE.checked_json(GATE.REPO / GATE.MAC_RECEIPT, GATE.MAC_RECEIPT_SHA)
        ids, expression = GATE.checked_selection(receipt)
        import re
        self.assertEqual(len(ids), 116)
        for case in ids:
            name, method = case.rsplit('.', 1)
            self.assertIsNotNone(re.fullmatch(expression, name + '/' + method))
        self.assertIsNone(re.fullmatch(expression,
            'TractandaPeerTransportTests.PeerExchangeTests/testRetainedPairingCannotOpenAfterActualRemoteRetirement'))

    def test_duplicate_or_nonpassing_mac_coverage_is_rejected(self):
        receipt = GATE.checked_json(GATE.REPO / GATE.MAC_RECEIPT, GATE.MAC_RECEIPT_SHA)
        receipt['coverage']['latestCases'][1] = receipt['coverage']['latestCases'][0]
        with self.assertRaises(RuntimeError):
            GATE.checked_selection(receipt)
        receipt = GATE.checked_json(GATE.REPO / GATE.MAC_RECEIPT, GATE.MAC_RECEIPT_SHA)
        receipt['coverage']['latestCases'][0]['outcome'] = 'skipped'
        with self.assertRaises(RuntimeError):
            GATE.checked_selection(receipt)

    def test_exit_zero_with_missing_repeated_failed_or_skipped_case_is_rejected(self):
        ids = ['Module.Fixture.testOne', 'Module.Fixture.testTwo']
        status = {'running': False, 'exit': 0}
        output = "Test Case 'Fixture.testOne' passed\nTest Case 'Fixture.testTwo' passed\nExecuted 2 tests, with 0 failures\n"
        GATE.verify_results(status, output, ids)
        for damaged in (
                output.replace("Test Case 'Fixture.testTwo' passed\n", ''),
                output.replace('Fixture.testTwo', 'Fixture.testOne'),
                output.replace("'Fixture.testTwo' passed", "'Fixture.testTwo' failed"),
                output.replace("'Fixture.testTwo' passed", "'Fixture.testTwo' skipped")):
            with self.assertRaises(RuntimeError):
                GATE.verify_results(status, damaged, ids)
        with self.assertRaises(RuntimeError):
            GATE.verify_results({'running': True, 'exit': 0}, output, ids)
        with self.assertRaisesRegex(RuntimeError,'module-ambiguous'):
            GATE.verify_results(status, output, ['One.Fixture.testOne','Two.Fixture.testOne'])

    def test_one_case_singular_summary_preserves_count_and_failure_rejection(self):
        text="Test Case 'Fixture.testOne' passed\nExecuted 1 test, with 0 failures\n"
        GATE.verify_results(dict(running=False,exit=0),text,['Module.Fixture.testOne'])
        for changed in (text.replace('1 test','2 tests'),text.replace(' passed',' failed'),text+"Test Case 'Fixture.testOne' passed\n",text.replace(' passed',' skipped')):
            with self.assertRaises(RuntimeError):GATE.verify_results(dict(running=False,exit=0),changed,['Module.Fixture.testOne'])

    def test_changed_or_symlink_evidence_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / 'receipt.json'
            target.write_text('{}')
            expected = GATE.sha(target)
            self.assertEqual(GATE.checked_json(target, expected), {})
            target.write_text('{"changed":true}')
            with self.assertRaises(RuntimeError):
                GATE.checked_json(target, expected)
            link = root / 'alias.json'
            link.symlink_to(target)
            with self.assertRaises(RuntimeError):
                GATE.checked_json(link, GATE.sha(target))

    def test_fixture_capacity_fails_without_lowering_reserve(self):
        sample = {'available': 12 * 1024**3, 'allocated': 1000}
        with tempfile.TemporaryDirectory() as temporary, patch.object(GATE, 'FIXTURES', Path(temporary)), \
                patch.object(GATE, 'BASE_CAPACITY', return_value=sample), \
                patch.object(GATE.GATE, 'allocated_tree', return_value=GATE.FIXTURE_CAP + 1):
            with self.assertRaisesRegex(RuntimeError, 'fixture cap exceeded'):
                GATE.capacity()
        with patch.object(GATE, 'BASE_CAPACITY', side_effect=RuntimeError('capacity unknown')):
            with self.assertRaisesRegex(RuntimeError, 'capacity unknown'):
                GATE.capacity()

    def test_overlay_inventory_or_bytes_change_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / 'passwd'
            target.write_text('tractanda_test:x:1001:20::/gate/linux/tmp:/usr/sbin/nologin\n')
            target.chmod(0o644)
            rows = [{'path': 'passwd', 'type': 'file', 'mode': 0o644, 'sha256': GATE.sha(target)}]
            GATE.overlay_check(root, rows)
            (root / 'unexpected').write_text('extra')
            with self.assertRaisesRegex(RuntimeError, 'inventory differs'):
                GATE.overlay_check(root, rows)
            (root / 'unexpected').unlink()
            target.write_text('different')
            with self.assertRaisesRegex(RuntimeError, 'bytes differ'):
                GATE.overlay_check(root, rows)

    def test_term_and_hup_enter_exact_cleanup_and_restore_handlers(self):
        for signum in (signal.SIGTERM, signal.SIGHUP):
            previous = signal.getsignal(signum)
            with patch.object(GATE, 'LABEL', 'cluster-b2-20261016-test'), \
                    patch.object(GATE, 'run', side_effect=lambda *a, **k: signal.raise_signal(signum)), \
                    patch.object(GATE, 'ensure_container_absent') as cleanup:
                with self.assertRaisesRegex(InterruptedError, 'host received signal'):
                    GATE.monitored_host_run(['unused'], {}, 'test-session')
                cleanup.assert_called_once_with()
            self.assertEqual(signal.getsignal(signum), previous)

    def test_cleanup_error_preserves_original_run_failure(self):
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(GATE, 'LABEL', 'cluster-b2-20261016-test'), \
                patch.object(GATE, 'run', side_effect=RuntimeError('original failed run')), \
                patch.object(GATE, 'ensure_container_absent', side_effect=RuntimeError('cleanup failed')), \
                patch.object(GATE, 'log', return_value=Path(temporary) / 'cleanup.json'):
            with self.assertRaisesRegex(RuntimeError, 'original failed run'):
                GATE.monitored_host_run(['unused'], {}, 'test-session')
            receipt = json.loads((Path(temporary) / 'cleanup.json').read_text())
            self.assertEqual(receipt['originalFailure'], 'original failed run')
            self.assertEqual(receipt['error'], 'cleanup failed')

    def test_owned_child_probe_validates_real_child_and_removes_it(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(GATE.GATE, 'GUEST_SESSION', 'test-session'):
            root = Path(temporary)
            result = GATE.owned_child_probe(root)
            self.assertEqual((result['uid'], result['gid'], result['mode'], result['bytes']), (1001, 20, 0o600, 16))
            self.assertTrue(result['writeReadFsync'])
            self.assertEqual(list(root.iterdir()), [])

    def test_child_probe_refuses_existing_path_without_removing_it(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(GATE.GATE, 'GUEST_SESSION', 'test-session'):
            root = Path(temporary)
            target = root / '.tractanda-owner-probe-test-session'
            target.write_bytes(b'keep')
            with self.assertRaises(FileExistsError):
                GATE.owned_child_probe(root)
            self.assertEqual(target.read_bytes(), b'keep')

    def test_wrong_child_owner_fails_and_disposes_only_probe(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(GATE.GATE, 'GUEST_SESSION', 'test-session'), \
                patch.object(GATE.os, 'fstat', return_value=SimpleNamespace(st_uid=0, st_gid=0, st_mode=stat.S_IFREG | 0o600)):
            root = Path(temporary)
            with self.assertRaisesRegex(RuntimeError, 'actual child ownership/mode mismatch'):
                GATE.owned_child_probe(root)
            self.assertEqual(list(root.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
