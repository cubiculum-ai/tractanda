#!/usr/bin/env python3
"""Tiny synthetic ELF/data fixtures; no model copy, native build, real helper or installation."""
import importlib.util
import json
import os
from pathlib import Path
import struct
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('linux_bundle_tested', Path(__file__).with_name('package-linux.py'))
B = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(B)


def elf_bytes(machine=62):
    header = bytearray(64)
    header[:7] = b'\x7fELF\x02\x01\x01'
    struct.pack_into('<HH', header, 16, 3, machine)
    return bytes(header)


def input_spec():
    return dict(profile='tractanda.linux-bundle-input.v1', version='0.1.0-poc.14', arch='amd64',
                minimumCPU='x86-64', sourceInputsSHA256='a' * 64, buildFlags=['-march=x86-64'],
                semanticProfile=B.SEMANTIC_PROFILE, documentExtraction={}, dynamicLoads=[],
                runtimeNotices=['licenses/runtime/NOTICE'])


def payload(root):
    for name in B.CORE:
        path = root / 'bin' / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(elf_bytes())
        path.chmod(0o755)
    for name in ['lib/runtime.txt', 'docs/index.html', 'templates/example.json', 'licenses/runtime/NOTICE',
                 'bin/Tractanda_TractandaWeb.resources/Kanban.html']:
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'tiny fixture')
        path.chmod(0o644)


class LinuxBundleTests(unittest.TestCase):
    def query_system_library(self, search_output):
        target = '/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1'

        class FakePath:
            def __init__(self, value): self.value = str(value)
            def __truediv__(self, name): return FakePath(self.value.rstrip('/') + '/' + str(name))
            def __str__(self): return self.value
            def __hash__(self): return hash(self.value)
            def __eq__(self, other): return isinstance(other, FakePath) and self.value == other.value
            def exists(self): return self.value == target
            def resolve(self): return self
            def is_file(self): return self.value == target

        def dpkg_search(_argv, **_kwargs):
            return SimpleNamespace(returncode=0, stdout=search_output, stderr='')

        with patch.object(B, 'Path', FakePath), patch.object(B.subprocess, 'run', side_effect=dpkg_search), \
                patch.object(B, 'run', return_value='libc6:arm64\t2.41-12\tarm64'), \
                patch.object(B, 'digest', return_value='a' * 64):
            return B.system_library('ld-linux-aarch64.so.1', 'arm64')

    def test_system_library_ignores_diversion_annotations_and_accepts_multiarch_owner(self):
        path = '/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1'
        output = (f'diversion by libc6 from: {path}\n'
                  f'diversion by libc6 to: {path}.usr-is-merged\n'
                  f'libc6:arm64: {path}\n')
        resolved, provider = self.query_system_library(output)
        self.assertEqual(str(resolved), path)
        self.assertEqual(provider['package'], 'libc6')
        self.assertEqual(provider['version'], '2.41-12')

    def test_system_library_rejects_diversion_only_missing_and_multiple_real_owners(self):
        path = '/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1'
        cases = ('', f'diversion by libc6 from: {path}\n',
                 f'libc6:arm64: {path}\nlibgcc-s1:arm64: {path}\n')
        for output in cases:
            with self.subTest(output=output), self.assertRaisesRegex(ValueError, 'unique owning'):
                self.query_system_library(output)

    def test_real_elf_header_rejects_wrong_machine_macho_and_newer_glibc(self):
        with tempfile.TemporaryDirectory() as temporary:
            file = Path(temporary) / 'binary'
            file.write_bytes(elf_bytes())
            with patch.object(B, 'run', return_value='') as tool:
                self.assertEqual(B.elf(file, 'amd64')['needed'], [])
                self.assertEqual(tool.call_count, 4)
                with self.assertRaisesRegex(ValueError, 'ELF'):
                    B.elf(file, 'arm64')
            file.write_bytes(elf_bytes(183))
            with patch.object(B, 'run', return_value=''):
                self.assertEqual(B.elf(file, 'arm64')['needed'], [])
            file.write_bytes(b'\xcf\xfa\xed\xfe' + b'\0' * 60)
            with self.assertRaisesRegex(ValueError, 'ELF'):
                B.elf(file, 'amd64')
            file.write_bytes(elf_bytes())
            with patch.object(B, 'run', side_effect=['', '', '', 'Name: GLIBC_2.43']):
                with self.assertRaisesRegex(ValueError, 'glibc'):
                    B.elf(file, 'amd64')
            with patch.object(B, 'run', side_effect=['', '', 'x86-64-v3', '']):
                with self.assertRaisesRegex(ValueError, 'ISA'):
                    B.elf(file, 'amd64')

    def test_closed_inventory_rejects_links_mutable_entries_and_unsafe_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            p = root / 'file'; p.write_bytes(b'a'); p.chmod(0o644)
            self.assertEqual(B.inventory(root)[0]['sha256'], B.digest(p))
            (root / 'link').symlink_to(p)
            with self.assertRaisesRegex(ValueError, 'links'):
                B.inventory(root)
            (root / 'link').unlink(); p.chmod(0o666)
            with self.assertRaisesRegex(ValueError, 'writable'):
                B.inventory(root)
        for name in ['.', '../escape', '/absolute', 'x//y', 'a\\b', 'line\nfeed']:
            with self.assertRaises(ValueError): B.safe_path(name)

    def test_spec_has_no_core_only_or_host_cpu_escape(self):
        spec = input_spec()
        self.assertEqual(B.validate_spec(spec, 'amd64'), spec)
        for flags in [['-march=native'], ['-mcpu=apple-m1'], ['-march', 'native']]:
            with self.assertRaisesRegex(ValueError, 'flags|baseline'):
                B.validate_spec(dict(spec, buildFlags=flags), 'amd64')
        with self.assertRaises(ValueError): B.validate_spec(dict(spec, minimumCPU='x86-64-v3'), 'amd64')
        with self.assertRaises(ValueError): B.validate_spec(dict(spec, coreOnly=True), 'amd64')

    def test_capacity_and_copy_are_bounded_without_filling_a_disk(self):
        low = SimpleNamespace(f_frsize=1, f_bavail=B.RESERVE + 1)
        with patch.object(B.os, 'statvfs', return_value=low):
            with self.assertRaisesRegex(ValueError, 'reserve'):
                B.capacity(Path('/tmp'), 2, 16)
        with patch.object(B.os, 'statvfs', side_effect=OSError('unknown')):
            with self.assertRaises(OSError): B.capacity(Path('/tmp'), 1, 16)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); source = root / 'source'; source.write_bytes(b'tiny'); source.chmod(0o644)
            row = B.inventory(root)[0]
            with patch.object(B, 'capacity') as guard:
                B.copy_verified(source, root / 'target', row, 128)
                self.assertTrue(guard.called)
                self.assertEqual((root / 'target').read_bytes(), b'tiny')
                with self.assertRaisesRegex(ValueError, 'content'):
                    B.copy_verified(source, root / 'bad', dict(row, sha256='0' * 64), 128)

    def test_global_isa_policy_covers_c_swift_and_forwarded_backend_forms(self):
        bad=[['-mavx2'],['-mfma'],['-msse3'],['-Xcc','-mavx2'],['-Xcc=-mavx2'],
             ['-target-cpu','haswell'],['-Xfrontend','-target-feature','+avx2'],
             ['-Xclang','-target-feature','-Xclang','+avx2'],['-Xllvm','-mattr=+avx2'],
             ['-Wa,-march=skylake'],['--target=x86_64-apple-macosx'],
             ['--target-cpu=haswell'],['-Wl,--lto-cpu=haswell'],['-Xcc=@uninspected.rsp'],
             ['-flto','-Xlinker','--lto-cpu=haswell'],['-Xlinker=--lto-cpu=haswell'],
             ['-flto','-Xlinker','--plugin-opt=mcpu=haswell'],['-Xlinker','-mllvm','-Xlinker','-mattr=+avx2'],
             ['-Xlinker','@uninspected.rsp'],['-Xlinker']]
        for flags in bad:
            with self.subTest(flags=flags),self.assertRaises(ValueError):B.global_isa_flags(flags,'amd64')
        B.global_isa_flags(['-Xcc','-march=x86-64','-mno-avx','-target-feature','-avx','-module-name','Fixture'],'amd64')
        B.global_isa_flags(['-Xlinker','-rpath','-Xlinker','$ORIGIN/../lib','-Xlinker=-z','-Xlinker','now'],'amd64')
        B.global_isa_flags(['-mcpu=generic','-target-feature=+neon','--target=aarch64-unknown-linux-gnu'],'arm64')
        for flags in [['-march=armv8.2-a'],['-target-feature','+sve']]:
            with self.assertRaises(ValueError):B.global_isa_flags(flags,'arm64')

    def test_native_backend_and_bounded_thread_metadata_keep_isa_checks(self):
        for arch in ('amd64', 'arm64'):
            B.global_isa_flags(['--build-system', 'native', '-num-threads', '4',
                                '-march=' + B.ARCH[arch][2], '-target-cpu', 'generic'], arch)
        with self.assertRaisesRegex(ValueError, 'baseline'):
            B.global_isa_flags(['--build-system', 'native', '-num-threads', '4', '-march=native'], 'amd64')

    def test_directory_allocation_and_directory_count_are_bounded(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            for name in ('a','b','c'):(root/name).mkdir()
            with patch.object(B,'MAX_DIRECTORIES',2):
                with self.assertRaisesRegex(ValueError,'directory'):
                    B.inventory(root)
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            metadata=SimpleNamespace(st_mode=0o40700,st_uid=os.geteuid(),st_blocks=4)
            with patch.object(B,'capacity'),patch.object(Path,'lstat',return_value=metadata):
                with self.assertRaisesRegex(ValueError,'budget'):
                    B.owned_storage(root,1024)

    def test_manifest_snapshot_is_immutable_and_capture_has_a_small_bound(self):
        snapshot=B.ManifestSnapshot(b'{"version":1}')
        view=snapshot.manifest();view['version']=2
        self.assertEqual(snapshot.manifest()['version'],1)
        with self.assertRaises(AttributeError):snapshot.raw=b'{}'
        with tempfile.TemporaryDirectory() as temporary:
            file=Path(temporary)/'manifest';file.write_bytes(b'{}')
            with self.assertRaises(ValueError):B.captured_bytes(file,1)
            alias=Path(temporary)/'alias';alias.symlink_to(file)
            with self.assertRaises(OSError):B.captured_bytes(alias,1024)

    def test_recursive_closure_resolves_private_library_and_explicit_os_provider(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); payload(root)
            library = root / 'lib/libprivate.so'; library.write_bytes(elf_bytes()); library.chmod(0o644)
            rows = B.inventory(root)
            def inspect(path, arch):
                name = path.name
                if name == 'libprivate.so': return dict(soname=name, needed=['libc.so.6'], searchPaths=[], interpreter=None)
                if name == 'libc.so.6': return dict(soname=name, needed=[], searchPaths=[], interpreter=None)
                return dict(soname=None, needed=['libprivate.so'], searchPaths=['$ORIGIN/../lib'], interpreter=None)
            system = dict(soname='libc.so.6', path='/usr/lib/x86_64-linux-gnu/libc.so.6', sha256='b'*64,
                          package='libc6', version='2.41-12')
            with patch.object(B, 'elf', side_effect=inspect), patch.object(B, 'system_library', return_value=(Path(system['path']), system)):
                closure = B.runtime_closure(root, rows, 'amd64', ['lib/libprivate.so'])
            self.assertEqual(closure['depends'], ['libc6 (>= 2.41-12)'])
            self.assertIn('lib/libprivate.so', closure['privateELF'])
            self.assertEqual(closure['edges']['lib/libprivate.so'][0]['system'], system['path'])
            with patch.object(B, 'elf', return_value=dict(soname=None, needed=[], searchPaths=['/home/build/lib'], interpreter=None)):
                with self.assertRaisesRegex(ValueError, 'search'):
                    B.runtime_closure(root, rows, 'amd64', [])

    def test_complete_assembly_always_calls_actual_setup_admission_and_inventory_is_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); source = root / 'input'; source.mkdir(); payload(source)
            spec = root / 'input.json'; spec.write_text(json.dumps(input_spec()))
            formats = dict(profile='fixture-only', readerLevel=1, writerLevel=1, read=[1], write=[1], capabilities=[], writeCapabilities=[])
            calls = []
            def helper(args):
                calls.append(list(map(str, args)))
                return json.dumps(formats) if '--canonical-format-support' in args else '{}'
            closure = dict(depends=['libc6 (>= 2.41-12)'], dynamicLoads=[])
            with patch.object(B, 'native_baseline', return_value=dict(os='debian13', arch='amd64')), \
                 patch.object(B, 'public_assets'), patch.object(B, 'full_components', return_value=({'model':'fixture-granite'},{'identity':'fixture-docling'})), \
                 patch.object(B, 'runtime_closure', return_value=closure), patch.object(B, 'run', side_effect=helper):
                result = B.assemble(source, spec, root / 'bundle', 'amd64', 32*1024**2)
                self.assertTrue(result['complete'])
                self.assertTrue(any('plan' in call and '--bundle' in call for call in calls))
                manifest = json.loads((root / 'bundle/bundle-manifest.json').read_text())
                self.assertEqual(manifest['files'], B.inventory(root / 'bundle', exclude=('bundle-manifest.json',)))
                manifest.pop('documentExtraction'); (root / 'bundle/bundle-manifest.json').write_text(json.dumps(manifest))
                with self.assertRaisesRegex(ValueError, 'incomplete'):
                    B.verify_bundle(root / 'bundle', 'amd64')


if __name__ == '__main__': unittest.main(verbosity=2)
