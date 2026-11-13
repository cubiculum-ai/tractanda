#!/usr/bin/env python3
"""Tiny synthetic package-stage/control/archive checks; no full .deb build or native runtime."""
import hashlib
import contextlib
import importlib.util
import io
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value); return value


D = module('linux_deb_tested', 'build-linux-deb.py')
F = module('linux_bundle_fixtures', 'test_package_linux.py')


class LinuxDebTests(unittest.TestCase):
    def setUp(self):
        self.baseline = dict(os=D.B.PRIMARY_BUILD_OS, arch='amd64')
        baseline = patch.object(D.B, 'native_baseline', return_value=self.baseline)
        self.native = baseline.start()
        self.addCleanup(baseline.stop)

    def test_legacy_v1_descriptor_projects_only_pool_capability_without_mutation(self):
        original = {'version': '0.1.0-poc.19', 'arch': 'arm64', 'embedding': None,
                    'canonicalFormats': {}, 'documentExtraction': {
                        'workerProtocol': 'tractanda.native-document-worker.v1',
                        'workerPoolProtocol': 'tractanda.native-document-pool.v1',
                        'identity': {'converter': 'same'}, 'modelDirectory': 'models/fixed'}}
        saved = json.loads(json.dumps(original))
        result = json.loads(D.package_descriptor(original, 'a' * 64, 'compatible'))
        self.assertEqual(result['manifestSHA256'], 'a' * 64)
        self.assertEqual(result['documentExtraction'], {
            k: v for k, v in original['documentExtraction'].items() if k != 'workerPoolProtocol'})
        self.assertEqual(original, saved)
        for bad in ('unknown', None):
            original['documentExtraction']['workerPoolProtocol'] = bad
            with self.assertRaises(ValueError):
                D.package_descriptor(original, 'a' * 64, 'compatible')
        del original['documentExtraction']['workerPoolProtocol']
        self.assertNotIn('workerPoolProtocol', json.loads(
            D.package_descriptor(original, 'a' * 64, 'compatible'))['documentExtraction'])

    def test_layout17_descriptor_cannot_claim_rolling_or_hide_physical_floor(self):
        manifest = {'version': '0.1.0-poc.17', 'arch': 'x86_64', 'embedding': None, 'documentExtraction': None,
                    'canonicalFormats': {'readerLevel': 20, 'writerLevel': 20,
                        'capabilities': ['tractanda.physical-layout.flat-items.v1', 'tractanda.message-items.v1'],
                        'writeCapabilities': ['tractanda.physical-layout.flat-items.v1', 'tractanda.message-items.v1']}}
        self.assertEqual(json.loads(D.package_descriptor(manifest, 'a' * 64, 'coordinated-maintenance'))['upgrade'], 'coordinated-maintenance')
        with self.assertRaises(ValueError): D.package_descriptor(manifest, 'a' * 64, 'compatible')
        manifest['canonicalFormats']['writerLevel'] = 18
        with self.assertRaises(ValueError): D.package_descriptor(manifest, 'a' * 64, 'coordinated-maintenance')
        manifest['canonicalFormats']['writerLevel'] = 20
        manifest['canonicalFormats']['writeCapabilities'].remove('tractanda.message-items.v1')
        with self.assertRaises(ValueError): D.package_descriptor(manifest, 'a' * 64, 'coordinated-maintenance')

    def test_layout171_compatible_only_with_same_layout_and_message_floor(self):
        manifest = {'version': '0.1.0-poc.17.1', 'arch': 'x86_64', 'embedding': None, 'documentExtraction': None,
                    'canonicalFormats': {'readerLevel': 20, 'writerLevel': 20,
                        'capabilities': ['tractanda.physical-layout.flat-items.v1', 'tractanda.message-items.v1'],
                        'writeCapabilities': ['tractanda.physical-layout.flat-items.v1', 'tractanda.message-items.v1']}}
        self.assertEqual(json.loads(D.package_descriptor(manifest, 'a' * 64, 'compatible'))['upgrade'], 'compatible')
        with self.assertRaises(ValueError): D.package_descriptor(manifest, 'a' * 64, 'coordinated-maintenance')
        manifest['canonicalFormats']['capabilities'].remove('tractanda.message-items.v1')
        with self.assertRaises(ValueError): D.package_descriptor(manifest, 'a' * 64, 'compatible')

    def test_layout17_control_contains_only_exact_reachable_payload_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); payload = root / 'payload'; payload.mkdir()
            members = {'bin/tractanda-layout17': b'helper', 'lib/libSwiftFixture.so': b'private runtime',
                       'lib/unused-worker.so': b'unrelated'}
            rows = []
            for name, data in members.items():
                path = payload / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data)
                rows.append({'path': name, 'size': len(data), 'mode': 0o755 if name.startswith('bin/') else 0o644,
                             'sha256': hashlib.sha256(data).hexdigest()})
            sqlite = {'soname': 'libsqlite3.so.0', 'package': 'libsqlite3-0', 'version': '3.46.1-7',
                      'path': '/usr/lib/x86_64-linux-gnu/libsqlite3.so.0.8.6'}
            loader = {'soname': 'ld-linux-x86-64.so.2', 'package': 'libc6', 'version': '2.41-12',
                      'path': '/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2'}
            closure = {'privateELF': list(members), 'osLibraries': [sqlite, loader], 'edges': {
                'bin/tractanda-layout17': [{'soname': 'libSwiftFixture.so', 'private': 'lib/libSwiftFixture.so'},
                    {'soname': sqlite['soname'], 'system': sqlite['path']}],
                'lib/libSwiftFixture.so': [{'soname': loader['soname'], 'system': loader['path']}],
                sqlite['soname']: [], loader['soname']: [], 'lib/unused-worker.so': [],
            }}
            manifest = {'files': rows}
            commitment = D.layout17_control_inventory(manifest, closure, 'amd64', 'a' * 64)
            self.assertEqual([r['path'] for r in commitment['files']], ['bin/tractanda-layout17', 'lib/libSwiftFixture.so'])
            self.assertEqual(set(commitment['systemLibraries']), {sqlite['soname'], loader['soname']})
            archive = root / 'DEBIAN' / D.LAYOUT17_CONTROL_ARCHIVE
            digest = D.stage_layout17_control(payload, archive, commitment, 1)
            self.assertEqual(digest, hashlib.sha256(archive.read_bytes()).hexdigest())
            with tarfile.open(archive) as t:
                self.assertEqual(t.getnames(), ['layout17-control.json', 'bin/tractanda-layout17', 'lib/libSwiftFixture.so'])
                self.assertEqual(json.load(t.extractfile('layout17-control.json')), commitment)
                for name in ('bin/tractanda-layout17', 'lib/libSwiftFixture.so'):
                    self.assertEqual(t.extractfile(name).read(), members[name])
            closure['edges']['bin/tractanda-layout17'].pop()
            with self.assertRaisesRegex(ValueError, 'SQLite'):
                D.layout17_control_inventory(manifest, closure, 'amd64', 'a' * 64)

    def fixture(self, parent):
        bundle = parent / 'bundle'; bundle.mkdir(); F.payload(bundle)
        catalog = bundle / 'models/manifest.json'; catalog.parent.mkdir(parents=True, exist_ok=True)
        catalog.write_bytes((D.B.ROOT / D.B.MAC.MODEL_ARTIFACT_MANIFEST).read_bytes())
        catalog.chmod(0o644)
        closure = dict(profile='fixture-runtime-closure', depends=['libc6 (>= 2.41-12)'])
        receipt = dict(profile='tractanda.linux-bundle-build.v1', baseline=self.baseline,
                       input=F.input_spec(), runtimeClosure=closure)
        D.write(bundle / 'lib/tractanda/linux-bundle-build.json', D.B.canonical(receipt))
        formats = dict(profile='fixture-only', readerLevel=1, writerLevel=1, read=[1], write=[1],
                       capabilities=[], writeCapabilities=[])
        manifest = dict(profile='tractanda.bundle.v1', platform='linux', arch='x86_64', version='0.1.0-poc.14',
                        linuxBuildOS=D.B.PRIMARY_BUILD_OS,
                        files=D.B.inventory(bundle), canonicalFormats=formats,
                        embedding={'fixture': 'Granite descriptor admission mocked'},
                        documentExtraction={'fixture': 'Docling descriptor admission mocked'},
                        modelProvisioningManifestPath='models/manifest.json',
                        modelProvisioningManifestSHA256=D.B.digest(catalog))
        D.write(bundle / 'bundle-manifest.json', D.B.canonical(manifest))
        return bundle, manifest, closure

    def stage(self, parent, name='stage', maintainer='Packaging Fixture <fixture@example.invalid>'):
        bundle, manifest, closure = self.fixture(parent)
        with patch.object(D.B, 'runtime_closure', return_value=closure):
            result = D.stage_package(bundle, parent/name, D.B.capture_manifest(bundle), 'amd64',
                                     maintainer, b'Explicit fixture copyright\n',
                                     '1', 'compatible', 1_700_000_000, 64*1024**2)
        return parent/name, result

    def test_control_hooks_canonical_descriptor_and_fixed_package_ownership(self):
        with tempfile.TemporaryDirectory() as temporary:
            stage, result = self.stage(Path(temporary))
            control = (stage/'DEBIAN/control').read_text()
            self.assertIn('Version: 0.1.0~poc.14-1\n',control)
            self.assertIn('Maintainer: Packaging Fixture <fixture@example.invalid>\n', control)
            self.assertIn('Bugs: https://github.com/cubiculum-ai/tractanda/issues\n', control)
            self.assertIn('Pre-Depends: python3, systemd\n',control)
            self.assertIn('X-Tractanda-Runtime-CPU-Features: ["cx16"]\n', control)
            self.assertEqual(result['runtimeRequiredCPUFeatures'], ['cx16'])
            self.assertEqual(result['runtimeCPUCheckSHA256'], hashlib.sha256(D.CPU_SOURCE.encode()).hexdigest())
            self.assertIn('libc6 (>= 2.41-12)',control)
            self.assertIn('ca-certificates',control)
            self.assertIn('curl',control);self.assertIn('lsof',control);self.assertIn('sudo',control)
            self.assertIn('uuid-runtime', control);self.assertIn('init-system-helpers', control)
            self.assertFalse((stage/'etc').exists());self.assertFalse((stage/'var').exists())
            self.assertTrue((stage/'opt/tractanda/current/bin/tractanda-setup').is_file())
            self.assertEqual((stage/'usr/bin/tractanda').read_text(), '#!/bin/sh\nexec /opt/tractanda/current/bin/tractanda "$@"\n')
            self.assertFalse((stage/'usr/local').exists())
            for hook in D.HOOKS:
                text=(stage/'DEBIAN'/hook).read_text()
                self.assertNotIn('@TRACTANDA_',text)
                self.assertIn('def unique_object(',text)
                self.assertEqual((stage/'DEBIAN'/hook).stat().st_mode&0o777,0o755)
            pre=(stage/'DEBIAN/preinst').read_text()
            descriptor=pre.split("<<'TRACTANDA_PACKAGE_DESCRIPTOR_EOF'\n",1)[1].split('\nTRACTANDA_PACKAGE_DESCRIPTOR_EOF',1)[0]
            parsed_descriptor=json.loads(descriptor)
            self.assertEqual(D.B.canonical(parsed_descriptor).decode(),descriptor)
            self.assertIn('"upgrade":"compatible"',descriptor)
            self.assertTrue((stage/'opt/tractanda/current/models/manifest.json').is_file())
            for key in ('modelProvisioningManifestPath', 'modelProvisioningManifestSHA256', 'modelProvisioningManifest'):
                self.assertNotIn(key, parsed_descriptor)
            self.assertTrue(all((stage/row['path']).stat().st_mtime==1_700_000_000 for row in result['inventory']))

    def test_identical_inputs_produce_identical_content_inventory_and_version_order(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);a=root/'a';b=root/'b';a.mkdir();b.mkdir()
            _,first=self.stage(a);_,second=self.stage(b)
            self.assertEqual(first,second)
        self.assertEqual(D.debian_version('0.1.0-poc.14','2'),'0.1.0~poc.14-2')
        with self.assertRaises(ValueError):D.debian_version('0.1.0_bad','1')
        for value in ['A <a@example.invalid>\nDepends: evil', 'unknown', 'A <bad address>']:
            with self.assertRaises(ValueError):D.maintainer_field(value)
        with self.assertRaises(ValueError):D.render('@TRACTANDA_UNRESOLVED@',{})
        with self.assertRaises(ValueError):D.package_descriptor({},'a'*64,'guess-from-semver')

    def test_cli_defaults_to_verified_maintainer_and_preserves_explicit_override(self):
        common = ['--bundle', 'fixture.bundle', '--output', 'fixture.deb', '--arch', 'amd64',
                  '--copyright-file', 'fixture.copyright', '--upgrade-class', 'compatible',
                  '--source-date-epoch', '1', '--max-stage-bytes', '1024']
        cases = ((common, D.DEFAULT_MAINTAINER, D.DEFAULT_BUILD_TIMEOUT_SECONDS),
                 (common + ['--maintainer', 'Local Maintainer <local@example.invalid>',
                            '--build-timeout-seconds', '7200'],
                  'Local Maintainer <local@example.invalid>', 7200))
        for argv, expected, expected_timeout in cases:
            with self.subTest(expected=expected), patch.object(D, 'build', return_value={}) as build, \
                    contextlib.redirect_stdout(io.StringIO()):
                D.main(argv)
            self.assertEqual(build.call_args.args[3], expected)
            self.assertEqual(build.call_args.args[9], expected_timeout)
        for invalid in ('0', '-1', 'nan', 'inf'):
            with self.subTest(invalid=invalid), patch.object(D, 'build') as build, \
                    contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                D.main(common + ['--build-timeout-seconds', invalid])
            build.assert_not_called()
        self.assertEqual(D.BUGS_URL, 'https://github.com/cubiculum-ai/tractanda/issues')
        D.maintainer_field(D.DEFAULT_MAINTAINER)

    def test_default_maintainer_and_bugs_url_are_rendered_in_package_control(self):
        with tempfile.TemporaryDirectory() as temporary:
            stage, _ = self.stage(Path(temporary), maintainer=D.DEFAULT_MAINTAINER)
            control = (stage/'DEBIAN/control').read_text()
        self.assertIn('Maintainer: rcfa - Cubiculum-AI <1831995+rcfa@users.noreply.github.com>\n', control)
        self.assertIn('Bugs: https://github.com/cubiculum-ai/tractanda/issues\n', control)

    def test_stale_dependency_receipt_cannot_be_used_to_omit_os_dependencies(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);bundle,manifest,_=self.fixture(root)
            with patch.object(D.B,'runtime_closure',return_value=dict(depends=[])):
                with self.assertRaisesRegex(ValueError,'closure'):
                    D.stage_package(bundle,root/'stage',D.B.capture_manifest(bundle),'amd64','Fixture <test@example.invalid>',b'notice',
                                    '1','compatible',1,64*1024**2)

    def test_bundle_baseline_must_match_actual_packaging_environment(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle, _, _ = self.fixture(root)
            self.native.return_value = dict(self.baseline, os='debian13')
            with self.assertRaisesRegex(ValueError, 'actual native packaging baseline'):
                D.verified_build_receipt(bundle, D.B.capture_manifest(bundle), 'amd64')

    def test_core_only_bundle_rejects_before_package_tool_or_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);bundle,manifest,_=self.fixture(root)
            del manifest['documentExtraction'];D.write(bundle/'bundle-manifest.json',D.B.canonical(manifest))
            copyright=root/'copyright';copyright.write_text('fixture notice')
            with patch.object(D.subprocess,'Popen') as popen:
                with self.assertRaisesRegex(ValueError,'incomplete'):
                    D.build(bundle,root/'output.deb','amd64','Fixture <test@example.invalid>',copyright,
                            '1','compatible',1,128*1024**2)
                popen.assert_not_called();self.assertFalse((root/'output.deb').exists())

    def test_streamed_archive_verifies_exact_bytes_root_ownership_and_no_extras(self):
        data=b'tiny package file';row=dict(path='usr/bin/file',size=len(data),mode=0o755,sha256=hashlib.sha256(data).hexdigest())
        def archive_bytes(extra=False,uid=0):
            out=io.BytesIO()
            with tarfile.open(fileobj=out,mode='w') as archive:
                for name in ['usr/bin/file']+(['extra'] if extra else []):
                    info=tarfile.TarInfo(name);info.size=len(data);info.mode=0o755;info.uid=uid;info.gid=0
                    archive.addfile(info,io.BytesIO(data))
            return out.getvalue()
        class Process:
            def __init__(self,data):self.stdout=io.BytesIO(data)
            def wait(self,timeout):return 0
            def poll(self):return 0
        for extra,uid in [(False,0),(True,0),(False,1001)]:
            with patch.object(D.subprocess,'Popen',return_value=Process(archive_bytes(extra,uid))):
                if not extra and uid==0:D.verify_archive(Path('fixture.deb'),{'usr/bin/file':row})
                else:
                    with self.assertRaises(ValueError):D.verify_archive(Path('fixture.deb'),{'usr/bin/file':row})

    def test_archive_accepts_only_standard_root_directory_metadata(self):
        data = b'tiny package file'
        expected = {'usr/bin/file': dict(size=len(data), mode=0o755,
                                        sha256=hashlib.sha256(data).hexdigest())}
        class Process:
            def __init__(self, raw): self.stdout = io.BytesIO(raw)
            def wait(self, timeout): return 0
            def poll(self): return 0
        cases = [('.', tarfile.DIRTYPE, 0, 0o755, True),
                 ('./', tarfile.DIRTYPE, 0, 0o755, True),
                 ('.', tarfile.REGTYPE, 0, 0o755, False),
                 ('./', tarfile.SYMTYPE, 0, 0o755, False),
                 ('.', tarfile.LNKTYPE, 0, 0o755, False),
                 ('.', tarfile.DIRTYPE, 1001, 0o755, False),
                 ('.', tarfile.DIRTYPE, 0, 0o700, False),
                 ('../', tarfile.DIRTYPE, 0, 0o755, False),
                 ('usr/../', tarfile.DIRTYPE, 0, 0o755, False),
                 ('/tmp/', tarfile.DIRTYPE, 0, 0o755, False),
                 ('', tarfile.REGTYPE, 0, 0o755, False)]
        for name, kind, uid, mode, accepted in cases:
            with self.subTest(name=name, kind=kind, uid=uid, mode=mode):
                out = io.BytesIO()
                with tarfile.open(fileobj=out, mode='w') as archive:
                    info = tarfile.TarInfo(name); info.type = kind
                    info.uid = uid; info.mode = mode
                    info.linkname = 'usr/bin/file' if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE) else ''
                    archive.addfile(info)
                    info = tarfile.TarInfo('usr/bin/file'); info.size = len(data); info.mode = 0o755
                    archive.addfile(info, io.BytesIO(data))
                with patch.object(D.subprocess, 'Popen', return_value=Process(out.getvalue())):
                    if accepted: D.verify_archive(Path('fixture.deb'), expected)
                    else:
                        with self.assertRaises(ValueError): D.verify_archive(Path('fixture.deb'), expected)
        out = io.BytesIO()
        with tarfile.open(fileobj=out, mode='w') as archive:
            for _ in range(2):
                info = tarfile.TarInfo('.'); info.type = tarfile.DIRTYPE; info.mode = 0o755
                archive.addfile(info)
        with patch.object(D.subprocess, 'Popen', return_value=Process(out.getvalue())):
            with self.assertRaisesRegex(ValueError, 'root directory'):
                D.verify_archive(Path('fixture.deb'), {})

    def test_build_waits_verifies_publishes_inventory_and_cleans_only_owned_success_stage(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);bundle,manifest,closure=self.fixture(root)
            copyright=root/'copyright';copyright.write_text('Explicit fixture notice')
            output=root/'tractanda_fixture_amd64.deb';calls=[]
            class Process:
                returncode=0
                def __init__(self,args,**kwargs):
                    calls.append((args,kwargs));Path(args[-1]).write_bytes(b'synthetic-deb-tool-output')
                def poll(self):return 0
            with patch.object(D.B,'verify_bundle',return_value=manifest), \
                 patch.object(D.B,'public_assets'), \
                 patch.object(D.B,'full_components',return_value=(manifest['embedding'],manifest['documentExtraction'])), \
                 patch.object(D.B,'runtime_closure',return_value=closure),patch.object(D.subprocess,'Popen',Process), \
                 patch.object(D,'verify_archive') as verify:
                result=D.build(bundle,output,'amd64','Fixture <test@example.invalid>',copyright,'1','compatible',
                               1_700_000_000,128*1024**2)
            self.assertEqual(verify.call_count,2)
            self.assertIn('--root-owner-group',calls[0][0]);self.assertIn('--threads-max=1',calls[0][0])
            self.assertEqual(calls[0][1]['env']['SOURCE_DATE_EPOCH'],'1700000000')
            self.assertEqual(output.read_bytes(),b'synthetic-deb-tool-output')
            self.assertEqual(result['packageSHA256'],hashlib.sha256(output.read_bytes()).hexdigest())
            self.assertTrue(output.with_name(output.name+'.inventory.json').is_file())
            self.assertEqual(list(root.glob('.tractanda-deb-*')),[])
            self.assertTrue(bundle.exists());self.assertFalse(result['installed']);self.assertFalse(result['published'])

    def test_one_manifest_snapshot_drives_stage_descriptor_and_source_drift_refusal(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);bundle,manifest,closure=self.fixture(root)
            snapshot=D.B.capture_manifest(bundle)
            changed=dict(manifest,version='0.1.0-poc.15')
            copy=D.B.copy_verified;mutated=False
            def concurrent_copy(*args):
                nonlocal mutated
                copy(*args)
                if not mutated:
                    D.write(bundle/'bundle-manifest.json',D.B.canonical(changed));mutated=True
            with patch.object(D.B,'runtime_closure',return_value=closure),patch.object(D.B,'copy_verified',side_effect=concurrent_copy):
                D.stage_package(bundle,root/'stage',snapshot,'amd64','Fixture <test@example.invalid>',b'notice',
                                '1','compatible',1,64*1024**2)
            self.assertEqual((root/'stage/opt/tractanda/current/bundle-manifest.json').read_bytes(),snapshot.raw)
            script=(root/'stage/DEBIAN/preinst').read_text()
            descriptor=json.loads(script.split("<<'TRACTANDA_PACKAGE_DESCRIPTOR_EOF'\n",1)[1].split('\nTRACTANDA_PACKAGE_DESCRIPTOR_EOF',1)[0])
            self.assertEqual(descriptor['manifestSHA256'],snapshot.sha256)
            self.assertEqual(descriptor['version'],'0.1.0-poc.14')
            with patch.object(D.B,'run',return_value='{}'):
                self.assertEqual(D.B.verify_bundle(bundle,'amd64')['version'],'0.1.0-poc.15')
                with self.assertRaisesRegex(ValueError,'snapshot'):
                    D.B.verify_bundle(bundle,'amd64',snapshot)

    def test_valid_replacement_manifest_after_compression_cannot_publish(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);bundle,manifest,closure=self.fixture(root)
            copyright=root/'copyright';copyright.write_text('fixture notice');output=root/'output.deb'
            class Process:
                returncode=0
                def __init__(self,args,**kwargs):
                    Path(args[-1]).write_bytes(b'synthetic package')
                    D.write(bundle/'bundle-manifest.json',D.B.canonical(dict(manifest,version='0.1.0-poc.15')))
                def poll(self):return 0
            with patch.object(D.B,'run',return_value='{}'), \
                 patch.object(D.B,'public_assets'), \
                 patch.object(D.B,'full_components',return_value=(manifest['embedding'],manifest['documentExtraction'])), \
                 patch.object(D.B,'runtime_closure',return_value=closure),patch.object(D.subprocess,'Popen',Process), \
                 patch.object(D,'verify_archive'):
                with self.assertRaisesRegex(ValueError,'snapshot'):
                    D.build(bundle,output,'amd64','Fixture <test@example.invalid>',copyright,'1','compatible',1,128*1024**2)
            self.assertFalse(output.exists());self.assertFalse(output.with_name(output.name+'.inventory.json').exists())

    def test_immediately_completed_child_cannot_publish_over_budget_or_below_reserve(self):
        for failure in ('allocation','reserve'):
            with self.subTest(failure=failure),tempfile.TemporaryDirectory() as temporary:
                root=Path(temporary);bundle,manifest,closure=self.fixture(root)
                copyright=root/'copyright';copyright.write_text('fixture notice');output=root/'output.deb'
                artifact=None;maximum=128*1024**2
                lstat=Path.lstat;statvfs=D.B.os.statvfs
                class Process:
                    returncode=0
                    def __init__(self,args,**kwargs):
                        nonlocal artifact
                        artifact=Path(args[-1]);artifact.write_bytes(b'tiny fixture')
                    def poll(self):return 0
                def allocated(path,*args,**kwargs):
                    info=lstat(path,*args,**kwargs)
                    if failure=='allocation' and artifact is not None and path==artifact:
                        return SimpleNamespace(st_mode=info.st_mode,st_uid=info.st_uid,st_blocks=maximum//512+1)
                    return info
                def available(path):
                    if failure=='reserve' and artifact is not None:
                        return SimpleNamespace(f_frsize=1,f_bavail=D.B.RESERVE-1)
                    return statvfs(path)
                with patch.object(D.B,'verify_bundle',return_value=manifest), \
                     patch.object(D.B,'public_assets'), \
                     patch.object(D.B,'full_components',return_value=(manifest['embedding'],manifest['documentExtraction'])), \
                     patch.object(D.B,'runtime_closure',return_value=closure),patch.object(D.subprocess,'Popen',Process), \
                     patch.object(Path,'lstat',allocated),patch.object(D.B.os,'statvfs',side_effect=available), \
                     patch.object(D,'verify_archive') as verify:
                    with self.assertRaisesRegex(ValueError,'budget|reserve'):
                        D.build(bundle,output,'amd64','Fixture <test@example.invalid>',copyright,'1','compatible',1,maximum)
                    verify.assert_not_called()
                self.assertFalse(output.exists());self.assertFalse(output.with_name(output.name+'.inventory.json').exists())


if __name__=='__main__':unittest.main(verbosity=2)
