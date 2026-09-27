#!/usr/bin/env python3
"""Small mocked-capacity checks for the query-scale harness disk guards."""
import importlib.util
from pathlib import Path
import tempfile
import time
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location(
    "verify_query_scale", Path(__file__).with_name("verify-query-scale.py"))
scale = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(scale)


class FakeProcess:
    def __init__(self, graceful_exit=False):
        self.terminated = False
        self.graceful_exit = graceful_exit
        self.returncode = None

    def poll(self):
        return 0 if self.terminated else None

    def terminate(self):
        self.terminated = True
        self.returncode = 0 if self.graceful_exit else -15

    def wait(self, timeout=None):
        return self.returncode


class CapacityGuardTests(unittest.TestCase):
    def test_insufficient_initial_capacity_fails_closed(self):
        with mock.patch.object(scale, "available_bytes", return_value=99):
            with self.assertRaisesRegex(RuntimeError, "Insufficient available disk space"):
                scale.require_capacity(Path("/tmp"), 0, 1000, 100, 1, "startup")

    def test_fixture_budget_and_oversized_batch_are_rejected(self):
        with mock.patch.object(scale, "available_bytes", return_value=10000):
            with self.assertRaisesRegex(RuntimeError, "fixture budget"):
                scale.require_capacity(Path("/tmp"), 90, 100, 0, 11, "batch")

    def test_admissible_estimate_and_cleanup(self):
        with mock.patch.object(scale, "available_bytes", return_value=10000):
            self.assertEqual(scale.require_capacity(Path("/tmp"), 20, 1000, 100, 500, "small"), 10000)
        with tempfile.TemporaryDirectory(prefix="scale-guard-test-") as temp:
            owned = Path(temp)
            (owned / "tiny").write_bytes(b"x")
        self.assertFalse(owned.exists())

    def test_watchdog_stops_owned_process_on_midrun_pressure(self):
        process = FakeProcess()
        with tempfile.TemporaryDirectory(prefix="scale-guard-test-") as temp:
            root = Path(temp)
            store = root / "store"
            store.mkdir()
            with mock.patch.object(scale, "available_bytes", side_effect=[10000, 50]):
                watchdog = scale.CapacityWatchdog(root, store, process, 1000, 100)
                watchdog.start()
                deadline = time.monotonic() + 2.5
                while not process.terminated and time.monotonic() < deadline:
                    time.sleep(.05)
                watchdog.stop()
            self.assertTrue(process.terminated)
            self.assertIn("Insufficient available disk space", watchdog.error)

    def test_low_space_before_readiness_stops_child_with_capacity_error(self):
        for graceful_exit in (False, True):
            with self.subTest(graceful_exit=graceful_exit):
                process = FakeProcess(graceful_exit=graceful_exit)
                with tempfile.TemporaryDirectory(prefix="scale-guard-test-") as temp:
                    root = Path(temp)
                    store = root / "store"
                    store.mkdir()
                    endpoint = root / "never-ready.sock"
                    with mock.patch.object(scale.subprocess, "Popen", return_value=process), \
                         mock.patch.object(scale, "available_bytes", return_value=50):
                        with self.assertRaisesRegex(RuntimeError, "Insufficient available disk space"):
                            with scale.measured_server("fake-native", store, endpoint, root,
                                                       1000, 100, ready_timeout_seconds=1):
                                self.fail("server should fail before readiness")
                    self.assertTrue(process.terminated)
                    self.assertFalse(process._scale_watchdog.thread.is_alive())


if __name__ == "__main__":
    unittest.main()
