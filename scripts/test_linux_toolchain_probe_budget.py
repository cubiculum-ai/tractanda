#!/usr/bin/env python3
"""Toolchain discovery budgets; no compiler, model, container or fixture corpus."""
import importlib.util
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('probe_budget_producer', Path(__file__).with_name('produce-linux-payload.py'))
P = importlib.util.module_from_spec(spec)
spec.loader.exec_module(P)


class ToolchainProbeBudgetTests(unittest.TestCase):
    def test_explicit_query_budget_keeps_loader_sanitization_and_c_locale(self):
        reply = subprocess.CompletedProcess([], 0, b'answer\n', b'')
        with mock.patch.dict(os.environ, {'LD_PRELOAD': 'untrusted.so', 'LD_LIBRARY_PATH': '/untrusted'}), \
                mock.patch.object(P.B.subprocess, 'run', return_value=reply) as run:
            self.assertEqual(P.B.run(['/fixed/tool'], timeout_seconds=1800), 'answer\n')
        self.assertEqual(run.call_args.kwargs['timeout'], 1800)
        self.assertEqual(run.call_args.kwargs['env']['LC_ALL'], 'C')
        self.assertNotIn('LD_PRELOAD', run.call_args.kwargs['env'])
        self.assertNotIn('LD_LIBRARY_PATH', run.call_args.kwargs['env'])

    def test_invalid_query_budget_stops_before_child(self):
        with mock.patch.object(P.B.subprocess, 'run') as run:
            for budget in [True, False, 0, -1, float('inf'), float('nan'), 2**31, '1800']:
                with self.subTest(budget=budget), self.assertRaises(ValueError):
                    P.B.run(['/fixed/tool'], timeout_seconds=budget)
        run.assert_not_called()

    def test_toolchain_default_and_configured_budget_keep_all_three_hashes(self):
        with tempfile.TemporaryDirectory(prefix='tractanda-tool-query-') as temporary:
            directory = Path(temporary)
            for name in ['swift', 'swift-frontend', 'clang']:
                (directory / name).write_bytes(name.encode())
            for budget in [P.DEFAULT_TOOLCHAIN_PROBE_TIMEOUT_SECONDS, 7200]:
                with self.subTest(budget=budget), mock.patch.object(P.B, 'run', return_value='Swift version 6.4.1 test\n') as run:
                    _, tools = (P.toolchain(directory / 'swift') if budget == P.DEFAULT_TOOLCHAIN_PROBE_TIMEOUT_SECONDS
                                else P.toolchain(directory / 'swift', probe_timeout_seconds=budget))
                self.assertEqual(run.call_args.kwargs['timeout_seconds'], budget)
                self.assertEqual(tools['swiftSHA256'], P.B.digest(directory / 'swift'))
                self.assertEqual(tools['swiftFrontendSHA256'], P.B.digest(directory / 'swift-frontend'))
                self.assertEqual(tools['clangSHA256'], P.B.digest(directory / 'clang'))
            self.assertEqual(P.DEFAULT_TOOLCHAIN_PROBE_TIMEOUT_SECONDS, 1800)
            with mock.patch.object(P.B, 'run') as run, self.assertRaises(argparse.ArgumentTypeError):
                P.toolchain(directory / 'swift', probe_timeout_seconds=float('inf'))
            run.assert_not_called()

    def test_plan_exposes_configured_query_budget_without_starting_build(self):
        completed = subprocess.run([sys.executable, '-I', '-B', str(Path(__file__).with_name('produce-linux-payload.py')),
                                    'plan', '--arch', 'amd64', '--toolchain-probe-timeout-seconds', '7200'],
                                   check=True, capture_output=True, text=True)
        value = json.loads(completed.stdout)
        self.assertEqual(value['toolchainProbeTimeoutSeconds'], 7200)
        self.assertFalse(value['buildStarted'])


if __name__ == '__main__':
    unittest.main()
