#!/usr/bin/env python3
"""Tiny build-scratch policy checks; these do not relax immutable payload rules."""
import importlib.util
import contextlib
import io
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('component', Path(__file__).with_name('build-linux-ml-component.py'))
C = importlib.util.module_from_spec(spec)
spec.loader.exec_module(C)


class BuildStorageTests(unittest.TestCase):
    def test_contained_lock_and_allocation(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(C.B, 'capacity'):
            root = Path(folder); (root/'modules').mkdir(); data = root/'modules/file'; data.write_bytes(b'fixture')
            (root/'modules/file.lock').symlink_to(root/'modules/missing-sibling')
            used = C.build_storage(root, 1024**2)
            self.assertGreaterEqual(used, data.stat().st_blocks*512)
            with self.assertRaises(ValueError): C.build_storage(root, 1)

    def test_external_and_cross_subtree_links_rejected(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(C.B, 'capacity'):
            root = Path(folder); (root/'modules').mkdir(); (root/'scratch').mkdir()
            link = root/'modules/lock'
            for target in (Path('/etc/passwd'), root/'scratch/other'):
                link.symlink_to(target)
                with self.assertRaises(ValueError): C.build_storage(root, 1024**2)
                link.unlink()

    def test_source_links_and_special_entries_rejected(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(C.B, 'capacity'):
            root = Path(folder); (root/'source').mkdir(); link=root/'source/link';link.symlink_to(root/'source/file')
            with self.assertRaises(ValueError): C.build_storage(root, 1024**2)
            link.unlink(); os.mkfifo(root/'fifo')
            with self.assertRaises(ValueError): C.build_storage(root, 1024**2)

    def test_foreign_owner_rejected(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(C.B, 'capacity'):
            with patch.object(C.os, 'geteuid', return_value=os.getuid()+1):
                with self.assertRaises(ValueError): C.build_storage(Path(folder), 1024**2)

    def test_explicit_guard_preserves_strict_payload_on_failure(self):
        original = C.B.owned_storage
        with patch.object(C.P, 'child', side_effect=ValueError('controlled')) as child:
            with self.assertRaises(ValueError): C.compile_child([])
            self.assertIs(child.call_args.kwargs['storage_guard'], C.P.build_storage)
            self.assertIs(C.build_storage, C.P.build_storage)
        self.assertIs(C.B.owned_storage, original)


class BinaryDirectoryTests(unittest.TestCase):
    def test_actual_confined_elf(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder).resolve(); output=root/'scratch/out/Products/native';output.mkdir(parents=True)
            binary=output/'converter';binary.write_bytes(b'\x7fELF\x02\x01\x01'+bytes(9)+(3).to_bytes(2,'little')+(62).to_bytes(2,'little'));binary.chmod(0o755)
            self.assertEqual(C.compiled_artifact(str(output)+'\n',root,'converter','amd64'),binary)
            with self.assertRaises(ValueError): C.compiled_artifact(str(output),root,'converter','arm64')

    def test_escaping_or_linked_artifact_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder).resolve();(root/'scratch').mkdir();(root/'elsewhere').mkdir()
            for value in (str(root/'elsewhere'), 'relative', str(root/'scratch')+'\nextra'):
                with self.assertRaises(ValueError): C.compiled_artifact(value,root,'converter','amd64')
            (root/'scratch/converter').symlink_to(root/'elsewhere/converter')
            with self.assertRaises(ValueError): C.compiled_artifact(str(root/'scratch'),root,'converter','amd64')


class BuildArgumentTests(unittest.TestCase):
    def test_public_parser_help_enters_without_removed_producer_map(self):
        output = io.StringIO()
        with patch.object(C.sys, 'argv', ['build-linux-ml-component.py', '--help']), contextlib.redirect_stdout(output):
            with self.assertRaises(SystemExit) as stopped:
                C.main()
        self.assertEqual(stopped.exception.code, 0)
        self.assertIn('--arch {amd64,arm64}', output.getvalue())
        self.assertIn('--build-timeout-seconds', output.getvalue())

    def test_native_release_thread_and_isa_arguments(self):
        for arch in ('amd64', 'arm64'):
            with self.subTest(arch=arch):
                common = ['--scratch-path', Path('/owned/scratch')]
                command = C.build_arguments(Path('/usr/bin/swift'), common, arch, 'helper')
                self.assertEqual(command[command.index('--build-system') + 1], 'native')
                self.assertEqual(command[command.index('-c') + 1], 'release')
                self.assertEqual(command[command.index('-j') + 1], '1')
                forwarded = [command[i+1] for i, value in enumerate(command[:-1]) if value == '-Xswiftc']
                self.assertEqual(forwarded, ['-target-cpu', 'generic', '-num-threads', '4'])
                self.assertEqual(command.count('-march=' + C.B.ARCH[arch][2]), 2)
                discovery = [*command, '--show-bin-path']
                self.assertEqual(discovery[:-1], command)
                self.assertNotIn('--show-bin-path', command)

    def test_unknown_architecture_fails_closed(self):
        with self.assertRaises(KeyError):
            C.build_arguments(Path('/usr/bin/swift'), [], 'unknown', 'helper')


if __name__ == '__main__': unittest.main()
