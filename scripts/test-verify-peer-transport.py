#!/usr/bin/env python3
"""Pure, tiny evidence-collector guards; never launch a build, container or product test."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("peer_guard", Path(__file__).with_name("verify-peer-transport.py"))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class CollectorGuards(unittest.TestCase):
    expected = {"Suite.testOne"}
    output = "Test Case 'Module.Suite.testOne' passed (0.001 seconds)\nExecuted 1 tests, with 0 failures\n"
    symbols = "0001 T CCryptoBoringSSL_one\n0002 W CNIOBoringSSL_two\n0003 T CoreRecordCodec\n0004 T PeerExchange\n"

    def test_completed_exact_run_is_accepted(self):
        guard.verify_adapter_test_result({"running": False, "exit": 0}, self.output, self.expected)

    def test_running_failed_missing_and_boolean_exit_are_rejected(self):
        for status in ({"running": True, "exit": 0}, {"running": False, "exit": 1},
                       {"running": False}, {"running": False, "exit": False}, {"exit": 0}):
            with self.subTest(status=status), self.assertRaises(RuntimeError):
                guard.verify_adapter_test_result(status, self.output, self.expected)

    def test_incomplete_duplicate_wrong_method_and_failed_run_are_rejected(self):
        for output in ("", self.output.replace("testOne", "testOther"),
                       self.output + "Test Case 'Module.Suite.testOne' passed\n",
                       self.output + "Test Case 'Module.Suite.testOne' failed\n",
                       self.output.replace("Executed 1", "Executed 0")):
            with self.subTest(output=output), self.assertRaises(RuntimeError):
                guard.verify_adapter_test_result({"running": False, "exit": 0}, output, self.expected)

    def test_both_defined_prefixes_and_actual_core_adapter_are_required(self):
        self.assertEqual(guard.combined_symbol_groups(self.symbols),
                         {"CCryptoBoringSSL_": 1, "CNIOBoringSSL_": 1})

    def test_undefined_prefix_missing_core_and_missing_adapter_are_rejected(self):
        for symbols in (self.symbols.replace("0002 W", "0002 U"),
                        self.symbols.replace("CoreRecordCodec", "Other"),
                        self.symbols.replace("PeerExchange", "Other")):
            with self.subTest(symbols=symbols), self.assertRaises(RuntimeError):
                guard.combined_symbol_groups(symbols)

    def test_collection_refuses_guest_before_any_io(self):
        old = guard.GUEST_SESSION
        try:
            guard.GUEST_SESSION = "unit-only"
            with self.assertRaises(RuntimeError):
                guard.collect_adapter_host_evidence({})
        finally:
            guard.GUEST_SESSION = old


if __name__ == "__main__":
    unittest.main()
