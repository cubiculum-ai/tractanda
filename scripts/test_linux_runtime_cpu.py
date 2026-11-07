#!/usr/bin/env python3
"""CPU admission and actual rendered preinst refusal/recovery regressions."""
import importlib.util
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
CPU_PATH = ROOT / 'debian/tractanda-runtime-cpu.py'
SPEC = importlib.util.spec_from_file_location('runtime_cpu', CPU_PATH)
CPU = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CPU)


def cpuinfo(*flags):
    return '\n\n'.join('processor : ' + str(number) + '\nflags : ' + value for number, value in enumerate(flags)) + '\n'


class RuntimeCPUTests(unittest.TestCase):
    def verify(self, information, before='0-1', after=None):
        values = [before, information, before if after is None else after]
        with patch.object(CPU.platform, 'system', return_value='Linux'), \
                patch.object(CPU.platform, 'machine', return_value='x86_64'), \
                patch.object(CPU, 'read_bounded', side_effect=values):
            CPU.verify_host_cpu('amd64')

    def test_every_online_cpu_can_satisfy_the_separate_runtime_feature(self):
        self.verify(cpuinfo('fpu sse2 cx16', 'cx16 sse2'))
        self.assertEqual(CPU.required_features('amd64'), ('cx16',))
        self.assertEqual(CPU.required_features('arm64'), ())

    def test_missing_feature_on_one_online_cpu_refuses(self):
        with self.assertRaisesRegex(ValueError, 'CPU 1.*cx16'):
            self.verify(cpuinfo('cx16', 'sse2'))

    def test_incomplete_or_extra_processor_evidence_refuses(self):
        for value in (cpuinfo('cx16'), cpuinfo('cx16', 'cx16', 'cx16')):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'inconsistent'):
                self.verify(value)

    def test_cpu_hotplug_during_capture_refuses(self):
        with self.assertRaisesRegex(ValueError, 'changed'):
            self.verify(cpuinfo('cx16', 'cx16'), after='0')

    def test_duplicate_or_malformed_processor_evidence_refuses(self):
        for value in ('processor : 0\nflags : cx16\nflags : cx16',
                      'processor : 0\nflags : cx16\n\nprocessor : 0\nflags : cx16',
                      'processor : 0', 'flags : cx16', 'processor : unknown\nflags : cx16'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                CPU.processor_features(value)

    def test_online_ranges_are_bounded_and_unambiguous(self):
        self.assertEqual(CPU.online_cpus('0-2,4\n'), {0, 1, 2, 4})
        for value in ('', '0,0', '3-1', '0-65536', 'all', '-1'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                CPU.online_cpus(value)

    def test_unreadable_or_oversized_evidence_refuses(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'flags'
            with self.assertRaises(FileNotFoundError):
                CPU.read_bounded(path, 4)
            path.write_text('cx16-extra')
            with self.assertRaisesRegex(ValueError, 'bound'):
                CPU.read_bounded(path, 4)

    def test_foreign_architecture_refuses_before_feature_read(self):
        with patch.object(CPU.platform, 'system', return_value='Linux'), \
                patch.object(CPU.platform, 'machine', return_value='aarch64'), \
                patch.object(CPU, 'read_bounded') as read:
            with self.assertRaisesRegex(ValueError, 'architecture'):
                CPU.verify_host_cpu('amd64')
            read.assert_not_called()

    def test_arm64_has_no_invented_additional_feature_requirement(self):
        with patch.object(CPU.platform, 'system', return_value='Linux'), \
                patch.object(CPU.platform, 'machine', return_value='aarch64'), \
                patch.object(CPU, 'read_bounded') as read:
            CPU.verify_host_cpu('arm64')
            read.assert_not_called()

    def run_preinst(self, root, flags, *arguments):
        information = root / 'cpuinfo'
        information.write_text(cpuinfo(flags))
        online = root / 'online'
        online.write_text('0\n')
        helper = root / 'helper'
        called = root / 'helper-called'
        helper.write_text('#!/bin/sh\nprintf \'%s\\n\' "$@" > ' + shlex.quote(str(called)) + '\n')
        helper.chmod(0o755)
        source = CPU_PATH.read_text().replace("Path('/proc/cpuinfo')", 'Path(' + repr(str(information)) + ')')
        source = source.replace("Path('/sys/devices/system/cpu/online')", 'Path(' + repr(str(online)) + ')')
        source = source.replace('platform.system()', "'Linux'").replace('platform.machine()', "'x86_64'")
        hook = (ROOT / 'debian/tractanda.preinst.in').read_text()
        replacements = {
            '@TRACTANDA_RUNTIME_CPU_CHECK_PY@': source,
            '@TRACTANDA_DEBIAN_ARCH@': 'amd64',
            '@TRACTANDA_PACKAGE_DESCRIPTOR_JSON@': '{}',
            '@TRACTANDA_PACKAGE_HOOK_FALLBACK_PY@': "print('fallback reached')",
            '@TRACTANDA_LAYOUT17_INSPECTOR_SHA256@': '-',
            '/opt/tractanda/current/bin/tractanda-setup': str(helper),
            '/run/tractanda-package-descriptor.': str(root / 'descriptor-'),
            '/usr/bin/python3': shlex.quote(sys.executable),
        }
        for old, value in replacements.items():
            hook = hook.replace(old, value)
        path = root / 'preinst'
        path.write_text(hook)
        return subprocess.run(['/bin/sh', str(path), *arguments], text=True, capture_output=True), called

    def test_rendered_preinst_missing_feature_refuses_before_descriptor_or_helper(self):
        for arguments in (('install',), ('upgrade', '0.1.0~poc.17.1-2', '0.1.0~poc.17.2-1')):
            with self.subTest(arguments=arguments), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                result, called = self.run_preinst(root, 'sse2', *arguments)
                self.assertEqual(result.returncode, 1)
                self.assertIn('cx16', result.stderr)
                self.assertNotIn('fallback reached', result.stdout)
                self.assertFalse(called.exists())
                self.assertEqual(list(root.glob('descriptor-*')), [])

    def test_rendered_preinst_satisfied_requirement_reaches_existing_helper(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result, called = self.run_preinst(root, 'sse2 cx16', 'install')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('fallback reached', result.stdout)
            self.assertIn('preinst', called.read_text())

    def test_abort_upgrade_recovery_skips_new_cpu_admission(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result, called = self.run_preinst(root, 'sse2', 'abort-upgrade', 'old-version')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('abort-upgrade', called.read_text())
            self.assertEqual(list(root.glob('descriptor-*')), [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
