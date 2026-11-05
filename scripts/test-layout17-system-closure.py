#!/usr/bin/env python3
"""Focused custody, ELF and configured-provider tests for the finite package inspector."""
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import os
import stat
import struct
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


def module():
    path = Path(__file__).resolve().parents[1] / 'debian/tractanda-package-hook-fallback.py.in'
    loader = importlib.machinery.SourceFileLoader('system_closure_fixture', str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    value = importlib.util.module_from_spec(spec)
    loader.exec_module(value)
    return value


def elf(needed=(), soname=None, machine=62):
    strings = bytearray(b'\0')
    tags = []
    for name in needed:
        tags.append((1, len(strings)))
        strings.extend(name.encode() + b'\0')
    if soname:
        tags.append((14, len(strings)))
        strings.extend(soname.encode() + b'\0')
    string_offset = 176 + (len(tags) + 3) * 16
    tags += [(5, 4096 + string_offset), (10, len(strings)), (0, 0)]
    dynamic = b''.join(struct.pack('<qQ', *tag) for tag in tags)
    size = string_offset + len(strings)
    header = b'\x7fELF\x02\x01\x01' + bytes(9)
    header += struct.pack('<HHIQQQIHHHHHH', 3, machine, 1, 0, 64, 0, 0, 64, 56, 2, 0, 0, 0)
    return (header + struct.pack('<IIQQQQQQ', 1, 4, 0, 4096, 0, size, size, 4096)
            + struct.pack('<IIQQQQQQ', 2, 4, 176, 4096 + 176, 0, len(dynamic), len(dynamic), 8)
            + dynamic + strings)


class ELFTests(unittest.TestCase):
    def parse(self, data, arch='amd64'):
        m = module()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture.so'
            path.write_bytes(data)
            path.chmod(0o600)
            real_fstat, real_stat = os.fstat, os.stat
            def root(row):
                names = ('st_dev', 'st_ino', 'st_mode', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
                return SimpleNamespace(st_uid=0, **{name: getattr(row, name) for name in names})
            with mock.patch.object(m.os, 'fstat', side_effect=lambda fd: root(real_fstat(fd))), \
                    mock.patch.object(m.os, 'stat', side_effect=lambda *a, **k: root(real_stat(*a, **k))):
                return m.layout17_elf_dependencies(str(path), arch)

    def test_real_elf_program_and_dynamic_tables_on_both_architectures(self):
        for arch, machine in (('amd64', 62), ('arm64', 183)):
            self.assertEqual(self.parse(elf(['libc.so.6'], 'libfixture.so.1', machine), arch),
                             (['libc.so.6'], 'libfixture.so.1'))

    def test_wrong_arch_truncation_bounds_and_unsafe_needed_name(self):
        malformed = [elf(machine=183), elf()[:100], elf(['../libbad.so'])]
        huge_headers = bytearray(elf()); struct.pack_into('<H', huge_headers, 56, 257)
        malformed.append(huge_headers)
        for data in malformed:
            with self.subTest(size=len(data)), self.assertRaises(SystemExit):
                self.parse(data)


class LoaderGraphTests(unittest.TestCase):
    def check(self, *, extended=False, defect=None, retired=False):
        m = module(); stage = '/verified/stage'
        loader = 'ld-linux-x86-64.so.2'
        private = 'libSwiftFixture.so'
        curl, crypto, transport = 'libcurl.so.4', 'libngtcp2_crypto_ossl.so.0', 'libngtcp2.so.16'
        graph = {private: ['libc.so.6'], 'libsqlite3.so.0': ['libc.so.6'],
                 curl: ['libc.so.6'], 'libc.so.6': [loader], loader: []}
        packages = {loader: 'libc6', 'libc.so.6': 'libc6', curl: 'libcurl4t64',
                    'libsqlite3.so.0': 'libsqlite3-0', crypto: 'libngtcp2-crypto-ossl0', transport: 'libngtcp2-16'}
        depends = {'libcurl4t64': 'libngtcp2-crypto-ossl0 (>= 1.24.0)',
                   'libngtcp2-crypto-ossl0': 'libngtcp2-16 (>= 1.24.0)'}
        known = set(graph) - {private}
        if extended:
            graph[curl].append(crypto); graph[crypto] = [transport, 'libc.so.6']
            graph[transport] = ['libc.so.6']
        if defect == 'unrelated':
            graph[curl].remove(crypto)
        if defect == 'undeclared':
            depends['libcurl4t64'] = ''
        inventory = {'arch': 'amd64', 'privateSONAMEs': {private: 'lib/' + private},
                     'systemLibraries': {name: {'package': packages[name], 'version': '1'} for name in known}}
        if retired:
            inventory['systemLibraries']['libretired.so.1'] = {'package': 'libretired1', 'version': '1'}
        paths = {name: '/usr/lib/x86_64-linux-gnu/' + name for name in graph}
        paths[private] = stage + '/lib/' + private
        if defect == 'private-shadow':
            paths[private] = '/usr/lib/x86_64-linux-gnu/' + private
        if defect == 'system-shadow':
            paths[crypto] = '/usr/local/lib/' + crypto
        def command(args):
            if args[1] == '--list':
                out = 'linux-vdso.so.1 (0xabc)\n' + ''.join(
                    f'{name} => {path} (0xabc)\n' for name, path in paths.items())
            elif args[1] == '--search':
                name = Path(args[2]).name
                if defect == 'unowned' and name == crypto:
                    return subprocess.CompletedProcess(args, 1, '', '')
                out = packages[name] + ':amd64: ' + args[3] + '\n'
            elif args[1] == '-W':
                package = args[-1]
                arch = 'arm64' if defect == 'wrong-arch' and package == packages[crypto] else 'amd64'
                out = 'install ok installed\t99\t' + arch + '\t' + depends.get(package, '') + '\t\t\n'
            else:
                self.assertEqual(args[1], '--compare-versions'); out = ''
            return subprocess.CompletedProcess(args, 0, out, '')
        def parsed(path, arch):
            if path == stage + '/bin/tractanda-layout17':
                return [private, 'libsqlite3.so.0', curl], None
            name = next(name for name, value in paths.items() if value == path)
            return graph[name], name
        with mock.patch.object(m, 'layout17_native_command', side_effect=command), \
                mock.patch.object(m, 'layout17_elf_dependencies', side_effect=parsed), \
                mock.patch.object(m, 'root_directory_chain'), \
                mock.patch.object(m.os, 'lstat', return_value=SimpleNamespace(st_uid=0, st_mode=stat.S_IFREG | 0o644)):
            m.layout17_check_loader(stage, inventory)

    def test_unchanged_baseline_and_disappeared_historical_transitive(self):
        self.check(); self.check(retired=True)

    def test_current_curl_transitive_extension(self):
        self.check(extended=True)

    def test_unowned_unrelated_undeclared_wrong_arch_and_shadowing_refuse(self):
        for defect in ('unowned', 'unrelated', 'undeclared', 'wrong-arch', 'private-shadow', 'system-shadow'):
            with self.subTest(defect=defect), self.assertRaises(SystemExit):
                self.check(extended=True, defect=defect)


class CapturedClosureTests(unittest.TestCase):
    def test_recorded_debian13_and_actual_stash_curl822_closures(self):
        fixture = json.loads((Path(__file__).parent / 'fixtures/layout17-system-closure.json').read_text())
        for scenario, data in fixture['scenarios'].items():
            with self.subTest(scenario=scenario):
                m = module(); stage = '/verified/stage'; inventory = fixture['inventory']
                graph = {**fixture['privateGraph'], **data['graph']}
                paths = {name: '/usr/lib/x86_64-linux-gnu/' + name for name in data['graph']}
                paths.update({name: stage + '/' + path for name, path in inventory['privateSONAMEs'].items()})
                paths['@inspector'] = stage + '/bin/tractanda-layout17'
                reverse = {value: name for name, value in paths.items()}
                def command(args):
                    if args[1] == '--list':
                        out = 'linux-vdso.so.1 (0xabc)\n' + ''.join(
                            f'{name} => {path} (0xabc)\n' for name, path in paths.items() if name != '@inspector')
                    elif args[1] == '--search':
                        name = reverse[args[2]]
                        out = data['providers'][name] + ':amd64: ' + args[3] + '\n'
                    elif args[1] == '-W':
                        if args[-1] not in data['records']:
                            return subprocess.CompletedProcess(args, 1, '', '')
                        out = '\t'.join(data['records'][args[-1]]) + '\n'
                    else:
                        self.assertEqual(args[1], '--compare-versions'); out = ''
                    return subprocess.CompletedProcess(args, 0, out, '')
                with mock.patch.object(m, 'layout17_native_command', side_effect=command), \
                        mock.patch.object(m, 'layout17_elf_dependencies',
                                          side_effect=lambda path, arch: (graph[reverse[path]],
                                                                         None if reverse[path] == '@inspector' else reverse[path])), \
                        mock.patch.object(m, 'root_directory_chain'), \
                        mock.patch.object(m.os, 'lstat', return_value=SimpleNamespace(st_uid=0, st_mode=stat.S_IFREG | 0o644)):
                    m.layout17_check_loader(stage, inventory)


class DebianRelationshipTests(unittest.TestCase):
    def test_cycle_terminates_and_invalid_relationship_refuses(self):
        m = module()
        record = lambda depends: ['install ok installed', '1', 'amd64', depends, '', '']
        records = {'fixture-a': record('fixture-b'), 'fixture-b': record('fixture-a'),
                   'fixture-target': record('')}
        with mock.patch.object(m, 'layout17_native_command') as command:
            self.assertFalse(m.layout17_declared_dependency('fixture-a', 'fixture-target', 'amd64', records))
            command.assert_not_called()
            records['fixture-a'] = record('fixture-target [unrecognized]')
            with self.assertRaises(SystemExit):
                m.layout17_declared_dependency('fixture-a', 'fixture-target', 'amd64', records)


if __name__ == '__main__':
    unittest.main()
