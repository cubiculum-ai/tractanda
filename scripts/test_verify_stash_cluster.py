#!/usr/bin/env python3
"""Tiny local fault tests; no SSH, remote mutation, Swift build or large fixture."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('stash_gate', Path(__file__).with_name('verify-stash-cluster.py'))
S = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(S)


class StashGateTests(unittest.TestCase):
    def test_timeout_cli_defaults_overrides_validation_and_derived_owner_headroom(self):
        label = 'stash-cluster-b2-20261016-0123abcd'
        defaults = S.parse_args(['--run-label', label])
        self.assertEqual(defaults.timeout_seconds, 24 * 60 * 60)
        self.assertEqual(defaults.command_timeout_seconds, 24 * 60 * 60)
        selected = S.parse_args(['--run-label', label, '--timeout-seconds', '7200',
                                 '--command-timeout-seconds', '14400'])
        self.assertEqual(selected.timeout_seconds, 7200)
        self.assertEqual(S.effective_command_timeout(selected.timeout_seconds,
                                                     selected.command_timeout_seconds), 7200)
        budgets = S.timeout_budgets(selected.timeout_seconds)
        self.assertEqual(budgets['unitRuntimeSeconds'],
                         selected.timeout_seconds + budgets['unitCleanupHeadroomSeconds'])
        self.assertGreater(budgets['sshOwnerSeconds'], budgets['unitRuntimeSeconds'])
        for flag, invalid in (('--timeout-seconds', '0'), ('--timeout-seconds', '-1'),
                              ('--timeout-seconds', 'nan'), ('--command-timeout-seconds', 'inf')):
            with self.subTest(flag=flag, invalid=invalid), self.assertRaises(SystemExit):
                S.parse_args(['--run-label', label, flag, invalid])

    def d2_selection(self):
        methods = ['SetupTests/testMac' + str(i) for i in range(18)]
        methods += ['SetupLinuxPayloadTests/testPayload' + str(i) for i in range(9)]
        methods += ['SetupPackageLifecycleTests/testLifecycle' + str(i) for i in range(20)]
        methods += ['SetupPeerRuntimeTests/testPeer']
        methods += ['SetupServiceBackendTests/testBackend' + str(i) for i in range(25)]
        fixture = methods[:48]
        return dict(macCount=73, linuxPortableCount=55, methods=methods,
                    linuxMethods=methods[18:], fixtureProofCount=48, linuxFixtureProofCount=30,
                    fixtureProofs=[dict(method=v,source=v.split('/')[0],proofCount=1) for v in fixture])

    def test_d2_exact_selection_preserves_all55_portable_methods_and30_proofs(self):
        mac, portable, excluded, proofs = S.linux_package_selection(self.d2_selection())
        self.assertEqual((len(mac),len(portable),len(excluded),len(proofs)),(73,55,18,30))
        self.assertTrue(all(v.startswith('TractandaSetupTests.SetupTests.') for v in excluded))
        self.assertTrue(set(proofs).issubset(portable))
        self.assertEqual(S.fixture_proof_ids(dict(kind='reviewed-linux-package',fixtureProofIDs=proofs)),proofs)
        self.assertEqual(S.FIXTURE_SOURCES['SetupLinuxPayloadTests'],('TractandaSetupTests','linux-setup'))
        self.assertEqual(S.FIXTURE_SOURCES['SetupPackageLifecycleTests'],('TractandaSetupTests','pkg'))

    def test_d2_selection_rejects_portable_exclusions_unknown_classes_and_duplicate_proofs(self):
        data=self.d2_selection()
        data['linuxMethods']=data['linuxMethods'][:-1]
        with self.assertRaisesRegex(RuntimeError,'exclusions'):
            S.linux_package_selection(data)
        data=self.d2_selection();data['methods'][-1]='UnreviewedTests/testUnknown'
        with self.assertRaisesRegex(RuntimeError,'inventory'):
            S.linux_package_selection(data)
        data=self.d2_selection();data['fixtureProofs'][-1]=data['fixtureProofs'][0]
        with self.assertRaisesRegex(RuntimeError,'proof'):
            S.linux_package_selection(data)

    def test_d2_basis_refuses_unaccepted_candidate_before_any_native_operation(self):
        data=dict(profile='tractanda.stash-linux-package.v1',candidate=dict(sha256='0'*64))
        with patch.object(S.subprocess,'Popen') as popen, patch.object(S,'checked_reference') as checked:
            with self.assertRaisesRegex(RuntimeError,'identity'):
                S.linux_package_basis(Path('isolated.json'),data)
            popen.assert_not_called();checked.assert_not_called()

    def test_d2_new_fixture_sources_use_real_bounded_proof_validator(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary).resolve();fixtures=root/'fixtures';proof=root/'fixture-proof'
            fixtures.mkdir(mode=0o700);proof.mkdir(mode=0o700)
            for source,prefix in [('SetupLinuxPayloadTests','linux-setup'),('SetupPackageLifecycleTests','pkg')]:
                child=fixtures/(prefix+'a'*7);child.mkdir(mode=0o700)
                name=source+'.testBoundedProof'
                row=dict(profile='tractanda.fixture-root-proof.v1',phase='created',source=source,
                         test='TractandaSetupTests.'+name,root=str(child),expectedRoot=str(fixtures),
                         proofRoot=str(proof),uid=os.getuid(),pid=os.getpid())
                path=proof/(source+'-'+child.name+'.json')
                path.write_text(json.dumps(row));path.chmod(0o600)
                result=S.inspect_fixture_proofs(root,fixtures,['TractandaSetupTests.'+name],complete=True)
                self.assertEqual(result['records'],1);self.assertTrue(result['complete'])
                row['source']='UnknownSource';path.write_text(json.dumps(row))
                with self.assertRaisesRegex(RuntimeError,'method'):
                    S.inspect_fixture_proofs(root,fixtures,['TractandaSetupTests.'+name])
                row['source']=source;row['root']=str(fixtures/('x'+'a'*7));path.write_text(json.dumps(row))
                with self.assertRaisesRegex(RuntimeError,'filename'):
                    S.inspect_fixture_proofs(root,fixtures,['TractandaSetupTests.'+name])
                path.unlink();child.rmdir()

    def test_strict_destination_label_and_archive_paths(self):
        home=Path('/home/example').resolve()
        self.assertEqual(S.remote_root(home,'stash-cluster-b2-20261016-0123abcd'),
                         home/'.cache'/'tractanda-stash-cluster-b2-20261016-0123abcd')
        for label in ('../outside', 'stash-cluster-b2-20261016-0123abcd;id', 'stash-cluster-b2-20261016-existing'):
            with self.assertRaises(RuntimeError):
                S.remote_root(home,label)
        for name in ('../escape', '/absolute', 'nested/../../escape', 'a//b', './file', 'a\\b'):
            with self.assertRaises(RuntimeError):
                S.safe_member(name)
        command = S.ssh_command(['python3', '-c', "print('bounded')"])
        self.assertIn('StrictHostKeyChecking=yes', command)
        self.assertIn('BatchMode=yes', command)
        self.assertEqual(command[-2], S.HOST)

    def test_remote_home_comes_from_authenticated_runtime_uid_and_is_normalized(self):
        payload=json.dumps(dict(uid=S.REMOTE_UID,gid=S.REMOTE_GID,home='/home/example'))
        with patch.object(S.subprocess,'check_output',return_value=payload.encode()) as probe:
            home=S.resolve_remote_home()
        self.assertEqual(home,Path('/home/example'))
        command=probe.call_args.args[0]
        self.assertEqual(command[:len(S.SSH)],S.SSH)
        self.assertIn('pwd.getpwuid(os.getuid())',command[-1])
        for invalid in (
            dict(uid=S.REMOTE_UID,gid=S.REMOTE_GID,home='/home/../escape'),
            dict(uid=S.REMOTE_UID+1,gid=S.REMOTE_GID,home='/home/example'),
            dict(uid=S.REMOTE_UID,gid=S.REMOTE_GID+1,home='/home/example'),
        ):
            with self.subTest(invalid=invalid),self.assertRaises(RuntimeError):
                S.validated_remote_home(invalid)
        for source in (S.BOOTSTRAP,S.CLOSURE):
            self.assertIn('pwd.getpwuid(os.getuid()).pw_dir',source)
            self.assertNotIn('Path.home()',source)
            self.assertNotIn('/Users/',source)

    def test_frozen_file_drift_and_parent_symlink_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            p = root / 'file'; p.write_bytes(b'canonical')
            row = dict(path='file', bytes=9, sha256=hashlib.sha256(b'canonical').hexdigest())
            S.verify_files(root, [row], exact=True)
            p.write_bytes(b'changed')
            with self.assertRaises(RuntimeError):
                S.verify_files(root, [row])
            p.write_bytes(b'canonical')
            (root / 'alias').symlink_to(root, target_is_directory=True)
            with self.assertRaises(RuntimeError):
                S.verify_files(root, [dict(row, path='alias/file')])

    def test_capacity_unknown_reserve_work_and_fixture_caps_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); fixtures = root / 'fixtures'; fixtures.mkdir()
            fs = SimpleNamespace(f_frsize=1, f_bavail=S.PREFLIGHT + 1)
            with patch.object(S.os, 'statvfs', return_value=fs), patch.object(S.C.GATE, 'allocated_tree', return_value=0):
                self.assertEqual(S.capacity(root, fixtures, True)['available'], S.PREFLIGHT + 1)
            for available, allocated, fixture in [(S.RESERVE-1,0,0),(S.PREFLIGHT,S.CAP,0),(S.PREFLIGHT,0,S.FIXTURE_CAP+1)]:
                with patch.object(S.os, 'statvfs', return_value=SimpleNamespace(f_frsize=1,f_bavail=available)), \
                        patch.object(S.C.GATE, 'allocated_tree', side_effect=[allocated,fixture]):
                    with self.assertRaises(RuntimeError):
                        S.capacity(root,fixtures)
            with patch.object(S.os, 'statvfs', side_effect=OSError('capacity unknown')):
                with self.assertRaises(OSError):
                    S.capacity(root)

    def test_local_streaming_uses_reserve_without_remote_native_preflight(self):
        # More than reserve+bounded writes, but deliberately less than native12GiB.
        free = S.RESERVE + S.RESULT_CAP + 17*1024**2
        with patch.object(S.os,'statvfs',return_value=SimpleNamespace(f_frsize=1,f_bavail=free)):
            self.assertLess(S.local_space(Path('/tmp'))['available'],S.PREFLIGHT)
        with patch.object(S.os,'statvfs',return_value=SimpleNamespace(f_frsize=1,f_bavail=S.RESERVE)):
            with self.assertRaises(RuntimeError):
                S.local_space(Path('/tmp'))

    def test_lease_source_session_staleness_eof_and_oversized_input(self):
        lease = S.Lease('session','sha')
        with self.assertRaises(RuntimeError): lease.check()
        lease.accept(json.dumps(dict(session='session',sourceSHA256='sha')))
        lease.check()
        with self.assertRaises(RuntimeError): lease.accept(json.dumps(dict(session='other',sourceSHA256='sha')))
        lease.last = time.monotonic() - S.LEASE_SECONDS - 1
        with self.assertRaises(RuntimeError): lease.check()
        lease = S.Lease('session','sha',io.StringIO(''))
        lease.watch()
        with self.assertRaisesRegex(RuntimeError,'EOF'): lease.check()
        lease = S.Lease('session','sha',io.StringIO('x'*600+'\n'))
        lease.watch()
        with self.assertRaisesRegex(RuntimeError,'oversized'): lease.check()

    def test_lease_send_accepts_write_and_flush_broken_pipe_only_after_successful_exit(self):
        class Pipe:
            def __init__(self, failure): self.failure = failure
            def write(self, payload):
                if self.failure == 'write': raise BrokenPipeError('write closed')
                return len(payload)
            def flush(self):
                if self.failure == 'flush': raise BrokenPipeError('flush closed')

        for failure in ('write','flush'):
            with self.subTest(failure=failure):
                process=SimpleNamespace(stdin=Pipe(failure),wait=unittest.mock.Mock(return_value=0))
                with patch.object(S.time,'monotonic',side_effect=[10.0,11.0]):
                    self.assertTrue(S._send_lease(process,b'lease',deadline=20.0))
                process.wait.assert_called_once_with(timeout=3.0)

        process=SimpleNamespace(stdin=Pipe(None),wait=unittest.mock.Mock())
        self.assertFalse(S._send_lease(process,b'lease',deadline=20.0))
        process.wait.assert_not_called()

    def test_lease_send_bounds_wait_by_remaining_deadline(self):
        class Pipe:
            def write(self, payload): raise BrokenPipeError('write closed')
            def flush(self): pass
        process=SimpleNamespace(stdin=Pipe(),wait=unittest.mock.Mock(return_value=0))
        with patch.object(S.time,'monotonic',side_effect=[10.0,11.0]):
            self.assertTrue(S._send_lease(process,b'lease',deadline=11.5))
        process.wait.assert_called_once_with(timeout=1.5)

    def test_lease_send_nonzero_live_deadline_and_interruption_fail_closed(self):
        class Pipe:
            def write(self, payload): raise BrokenPipeError('write closed')
            def flush(self): pass

        process=SimpleNamespace(stdin=Pipe(),wait=unittest.mock.Mock(return_value=23))
        with patch.object(S.time,'monotonic',side_effect=[10.0]):
            with self.assertRaisesRegex(RuntimeError,'original remote unit/SSH exit 23'):
                S._send_lease(process,b'lease',deadline=20.0)

        process=SimpleNamespace(stdin=Pipe(),wait=unittest.mock.Mock(return_value=None))
        with patch.object(S.time,'monotonic',side_effect=[10.0]):
            with self.assertRaisesRegex(RuntimeError,'exit could not be confirmed'):
                S._send_lease(process,b'lease',deadline=20.0)
        process.wait.assert_called_once_with(timeout=3.0)

        process=SimpleNamespace(stdin=Pipe(),wait=unittest.mock.Mock(
            side_effect=subprocess.TimeoutExpired('ssh supervisor',3)))
        with patch.object(S.time,'monotonic',return_value=10.0):
            with self.assertRaisesRegex(RuntimeError,'remained active'):
                S._send_lease(process,b'lease',deadline=20.0)
        process.wait.assert_called_once_with(timeout=3.0)

        process=SimpleNamespace(stdin=Pipe(),wait=unittest.mock.Mock())
        with patch.object(S.time,'monotonic',return_value=10.0):
            with self.assertRaisesRegex(RuntimeError,'deadline exceeded'):
                S._send_lease(process,b'lease',deadline=10.0)
        process.wait.assert_not_called()

        process=SimpleNamespace(stdin=Pipe(),wait=unittest.mock.Mock(return_value=0))
        with patch.object(S.time,'monotonic',side_effect=[10.0,11.5]):
            with self.assertRaisesRegex(RuntimeError,'deadline exceeded'):
                S._send_lease(process,b'lease',deadline=11.0)
        process.wait.assert_called_once_with(timeout=1.0)

        process=SimpleNamespace(stdin=Pipe(),wait=unittest.mock.Mock(
            side_effect=InterruptedError('local signal')))
        with patch.object(S.time,'monotonic',return_value=10.0):
            with self.assertRaisesRegex(InterruptedError,'local signal'):
                S._send_lease(process,b'lease',deadline=20.0)

    def test_linux_support_descriptor_is_byte_stable_across_hash_seeds_and_drift_refuses(self):
        child = textwrap.dedent('''\
            import importlib.util, json, pathlib, sys
            module_path, root_path = sys.argv[1:]
            spec = importlib.util.spec_from_file_location('stash_gate_seed', module_path)
            S = importlib.util.module_from_spec(spec); spec.loader.exec_module(S)
            root = pathlib.Path(root_path); S.REPO = root
            S.SUPPORT = ['verify-peer-transport.py', 'verify-stash-cluster.py']
            candidate = json.loads((root / 'candidate.json').read_text())
            data = json.loads((root / 'checkpoint.json').read_text())
            current, delta = S.reviewed_linux_support(data, candidate)
            assert list(current) == sorted(current)
            descriptor = json.dumps(dict(linuxSupportInputs=current, linuxSupportDelta=delta), separators=(',', ':'))
            (root / 'scripts/verify-stash-cluster.py').write_text('drift')
            try:
                S.reviewed_linux_support(data, candidate)
            except RuntimeError as error:
                assert 'changed Linux support needs its exact reviewed v2 delta' in str(error)
            else:
                raise AssertionError('support drift was accepted')
            print(descriptor, end='')
        ''')
        descriptors=[]
        with tempfile.TemporaryDirectory() as temporary:
            base=Path(temporary)
            for seed in ('1','2'):
                root=base/seed;support=root/'scripts';support.mkdir(parents=True)
                paths=['scripts/verify-peer-transport.py','scripts/verify-stash-cluster.py']
                for path in paths: (root/path).write_text('frozen '+path)
                rows=[dict(path=path,sha256=hashlib.sha256((root/path).read_bytes()).hexdigest()) for path in paths]
                complete=json.dumps(dict(files=rows)).encode();(root/'complete.json').write_bytes(complete)
                reference=dict(path='complete.json',bytes=len(complete),sha256=hashlib.sha256(complete).hexdigest())
                (root/'candidate.json').write_text(json.dumps(dict(files=rows)))
                (root/'checkpoint.json').write_text(json.dumps(dict(macCompleteBefore=reference,linuxSupportDelta=None)))
                env=dict(os.environ,PYTHONHASHSEED=seed)
                descriptors.append(subprocess.check_output(
                    [sys.executable,'-c',child,str(S.__file__),str(root)],env=env,timeout=10))
        self.assertEqual(descriptors[0],descriptors[1])
        decoded=json.loads(descriptors[0])
        self.assertEqual(list(decoded['linuxSupportInputs']),sorted(decoded['linuxSupportInputs']))

    def test_child_does_not_inherit_lease_stdin(self):
        with patch.object(S.subprocess,'Popen') as popen:
            S.ChildCommands().Popen(['unused'])
            self.assertEqual(popen.call_args.kwargs['stdin'],subprocess.DEVNULL)

    def test_separate_stderr_cannot_splice_an_xctest_pass_event(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            script = "import os; os.write(1,b\"Test Case 'Fixture.test\"); os.write(2,b'warning: diagnostic\\n'); os.write(1,b\"One' passed\\nTest Case 'Fixture.testTwo' passed\\nExecuted 2 tests, with 0 failures\\n\")"
            with patch.object(S.C,'LOGS',root), patch.object(S.C,'REPO',root), \
                    patch.object(S.C,'capacity',return_value={}):
                S.C.run([sys.executable,'-c',script], 'separate', dict(os.environ), timeout=5, separate_stderr=True)
            output = (root/'separate.log').read_text()
            self.assertEqual((root/'separate.stderr.log').read_text(), 'warning: diagnostic\n')
            S.C.verify_results(json.loads((root/'separate.status.json').read_text()), output, ['Module.Fixture.testOne','Module.Fixture.testTwo'])

    def test_source_approval_delta_rejects_unreviewed_or_missing_or_duplicate_inputs(self):
        before = {f'input/{i}':'old' for i in range(1174)}
        candidate = {f'input/{i}':'new' for i in range(16)}
        candidate.update({'new/one':'new','new/two':'new'})
        candidate['input/16']='old'  # An explicitly reviewed unchanged input.
        after = dict(before, **candidate)
        rows = [dict(path=p,sha256=v) for p,v in after.items()]
        _, added, modified = S.validate_source_approval_delta(before, rows, candidate)
        self.assertEqual((len(added),len(modified)),(2,16))
        for damaged in (rows[:-1], rows+[rows[0]], rows+[dict(path='unreviewed',sha256='new')],
                        [dict(row,sha256='drift') if row['path']=='input/20' else row for row in rows]):
            with self.assertRaises(RuntimeError):
                S.validate_source_approval_delta(before, damaged, candidate)
        with self.assertRaisesRegex(RuntimeError,'byte commitment differs'):
            S.validate_source_approval_delta(before, rows, dict(candidate, **{'new/one':'other'}))

    def test_recipe_counts_still_reject_unreviewed_source_changes(self):
        before = {'old':'a','retained':'b'}
        rows = [dict(path='old',sha256='changed'),dict(path='retained',sha256='b'),dict(path='new',sha256='c')]
        counts = dict(priorInputs=2,currentInputs=3,addedInputs=1,modifiedInputs=1)
        self.assertEqual(S.validate_source_approval_delta(before,rows,{'old':'changed','new':'c'},counts)[1],{'new'})
        for damaged in (rows+[rows[0]],rows[:-1],rows+[dict(path='extra',sha256='d')]):
            with self.assertRaises(RuntimeError):
                S.validate_source_approval_delta(before,damaged,{'old':'changed','new':'c'},counts)
        with self.assertRaises(RuntimeError):
            S.validate_source_approval_delta(before,rows,{'new':'c'},counts)

    def test_json_and_text_selectors_preserve_exact_methods_and_duplicates_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);data=['Module.Tests/testOne','Module.Tests/testTwo']
            (root/'json').write_text(json.dumps(data));(root/'text').write_text('\n'.join(data)+'\n')
            with patch.object(S,'checked_reference',side_effect=lambda r:root/r['path']):
                self.assertEqual(S.method_list(dict(path='json')),S.method_list(dict(path='text')))
                for damaged in ('Module.Tests/testOne\nModule.Tests.testOne\n','Module.Tests/testOne\n\n',' Module.Tests/testOne\n'):
                    (root/'text').write_text(damaged)
                    with self.assertRaises(RuntimeError):S.method_list(dict(path='text'))

    def test_prior_linux_selection_retains_every_accepted_method(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            old=['Module.Tests.testOld','Module.Tests.testShared'];mac=['Module.Tests.testNew','Module.Tests.testShared']
            (root/'prior').write_text(json.dumps(dict(result='PASS',passed=2,failed=0,skipped=0,exactIDs=old)))
            (root/'expected').write_text(json.dumps(sorted(set(old+mac))))
            data=dict(priorStashReceipt=dict(path='prior'),expectedTests=dict(path='expected'),batch=dict(expectedCases=3))
            with patch.object(S,'checked_reference',side_effect=lambda r:root/r['path']):
                self.assertEqual(S.reviewed_batch_selection(data,mac),sorted(set(old+mac)))
                (root/'expected').write_text(json.dumps(mac))
                with self.assertRaisesRegex(RuntimeError,'method union differs'):S.reviewed_batch_selection(data,mac)

    def test_focused_followup_binds_failed_receipt_and_only_reviewed_fixture_delta(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            def put(name,value):
                raw=(value if isinstance(value,str) else json.dumps(value)).encode();(root/name).write_bytes(raw)
                return dict(path=name,bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())
            passed='TractandaCoreTests.OldTests.testUnchanged';failed='TractandaCoreTests.ResumeTests.testRepair'
            fixture='Tests/TractandaCoreTests/ResumeTests.swift'
            before=[dict(path=fixture,sha256='old'),dict(path='Sources/Store.swift',sha256='product')]
            closure=put('closure',dict(files=before))
            runtime=dict(rawExit=1,failedMethods=1,skippedMethods=0,passedMethods=1,executedMethods=2,passedIDs=[passed],failedIDs=[failed])
            receipt=put('failed',dict(schema='tractanda.target-activation-linux-failed-verification.v1',rootRuntime=runtime,source=dict(closure=closure),closure=dict(allOwnedProcessesClosed=True)))
            patch_ref=put('patch','reviewed fixture patch')
            candidate=dict(sourceDelta=dict(changed=[fixture],added=[],removed=[],patch=patch_ref))
            data=dict(retainedRootRuntime=receipt,retainedFixtureDelta=patch_ref,expectedTests=put('selection',failed+'\n'),expectedIDs=[failed],priorStashReceipt=put('prior',dict(result='PASS',passed=1,failed=0,skipped=0,exactIDs=[passed])),batch=dict(expectedCases=1))
            current=[dict(path=fixture,sha256='repaired'),before[1]]
            with patch.object(S,'REPO',root):
                self.assertEqual(S.reviewed_batch_selection(data,[failed]),[failed])
                self.assertEqual(S.retained_fixture_delta(data,current,candidate)['passedMethods'],1)
                with self.assertRaisesRegex(RuntimeError,'fixture-only'):
                    S.retained_fixture_delta(data,[current[0],dict(current[1],sha256='unreviewed-product-change')],candidate)
                with self.assertRaisesRegex(RuntimeError,'patch reference differs'):
                    S.retained_fixture_delta(dict(data,retainedFixtureDelta=dict(patch_ref,sha256='wrong')),current,candidate)
                (root/'selection').write_text(passed+'\n')
                data['expectedTests']=put('selection',passed+'\n')
                with self.assertRaisesRegex(RuntimeError,'focused selection'):
                    S.reviewed_batch_selection(data,[passed])

    def test_root_and_nested_package_are_sequential_and_keep_partial_failure(self):
        for failure_phase in (None,'tests','postchecks'):
            with self.subTest(failure_phase=failure_phase),tempfile.TemporaryDirectory() as temporary:
                root=Path(temporary);logs=root/'logs';logs.mkdir()
                root_ids=['Root.RootTests.testRoot'];package_ids=['TractandaPeerTLSTests.PeerTLSTests.testTLS']
                pin=dict(identity='dependency',location='https://example.invalid/dependency',state=dict(revision='0'*40))
                package=dict(name='peer-tls',packagePath='Packages/TractandaPeerTLS',ids=package_ids,
                             pins=[pin],mirrorPrefix='mirrors/peer-tls/',testFilter=S.exact_filter(package_ids))
                descriptor=dict(pins=[pin],ids=root_ids,testFilter=S.exact_filter(root_ids),packageTests=[package],sourceProvenance=dict(separateTestStderr=True))
                env=dict(HOME=str(root/'home'),GIT_ALLOW_PROTOCOL='file',TMPDIR=str(root/'fixtures'))
                commands=[]
                def fake_run(command,label,environment,*args,**kwargs):
                    commands.append((command,label,dict(environment),kwargs))
                    if label in ('tests','package-peer-tls-tests'):
                        suite='RootTests.testRoot' if label=='tests' else 'PeerTLSTests.testTLS'
                        failed=failure_phase=='tests' and label!='tests'
                        (logs/(label+'.status.json')).write_text(json.dumps(dict(running=False,exit=1 if failed else 0,seconds=0)))
                        (logs/(label+'.log')).write_text("Test Case '"+suite+"' "+('failed' if failed else 'passed')+'\nExecuted 1 tests, with '+('1' if failed else '0')+' failures\n')
                        if failed:raise RuntimeError('injected TLS failure')
                with patch.object(S.C,'LOGS',logs),patch.object(S.C,'run',side_effect=fake_run), \
                        patch.object(S.C,'capacity',return_value=dict(available=20*1024**3,allocated=300*1024**2)), \
                        patch.object(S,'package_postchecks',side_effect=RuntimeError('injected TLS postchecks') if failure_phase=='postchecks' else None,return_value=dict(binary='isolated ELF')):
                    if failure_phase:
                        with self.assertRaisesRegex(RuntimeError,'injected TLS'):
                            S.configure_and_test(Path('/tools'),['--package-path',str(root/'source/Tractanda')],descriptor,root,env)
                    else:S.configure_and_test(Path('/tools'),['--package-path',str(root/'source/Tractanda')],descriptor,root,env)
                scopes=json.loads((logs/'test-scopes.json').read_text())['scopes']
                self.assertEqual([v['state'] for v in scopes],['passed','failed' if failure_phase else 'passed'])
                self.assertEqual(scopes[1]['runtimePassed'],failure_phase!='tests')
                if failure_phase=='postchecks':self.assertEqual(scopes[1]['phase'],'postchecks')
                tests=[v for v in commands if v[1] in ('tests','package-peer-tls-tests')]
                self.assertEqual([v[1] for v in tests],['tests','package-peer-tls-tests'])
                command,_,package_env,options=tests[1]
                self.assertEqual(command[command.index('--scratch-path')+1],str(root/'package-tests/peer-tls/scratch'))
                self.assertEqual(command[command.index('--jobs')+1],'1')
                self.assertIn('--force-resolved-versions',command);self.assertTrue(options['separate_stderr'])
                mirrors=json.loads(Path(package_env['SWIFTPM_MIRROR_CONFIG']).read_text())['object']
                self.assertEqual(mirrors[0]['mirror'],(root/'mirrors/peer-tls/dependency.git').as_uri())
                self.assertEqual(package_env['GIT_ALLOW_PROTOCOL'],'file')
                self.assertNotIn('SWIFTPM_MIRROR_CONFIG',env)

    def test_nested_package_postchecks_reject_wrong_elf_symbols_linkage_and_drift(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);work=root/'package';binary=work/'scratch/debug/TractandaPeerTLSPackageTests.xctest'
            binary.parent.mkdir(parents=True);logs=root/'logs';logs.mkdir()
            mode='good'
            def fake_run(command,label,*args,**kwargs):
                if label.endswith('symbols'):
                    (logs/(label+'.log')).write_text('0 T '+('CCryptoBoringSSL_wrong' if mode=='symbols' else 'CNIOBoringSSL_tls')+'\n')
                    if mode=='drift':binary.write_bytes(b'changed')
                else:(logs/(label+'.log')).write_text('libc.so => '+('not found' if mode=='libraries' else '/lib/libc.so')+'\n')
            with patch.object(S.C,'LOGS',logs),patch.object(S.C,'run',side_effect=fake_run):
                binary.write_bytes(b'\x7fELFtiny')
                self.assertEqual(S.package_postchecks(work,{})['definedBoringSSLSymbols'],1)
                for mode in ('symbols','libraries','drift'):
                    binary.write_bytes(b'\x7fELFtiny')
                    with self.assertRaises(RuntimeError):S.package_postchecks(work,{})
                binary.write_bytes(b'not-ELF')
                with self.assertRaisesRegex(RuntimeError,'not ELF'):S.package_postchecks(work,{})

    def test_nested_package_estimate_still_rejects_aggregate_cap_or_reserve(self):
        good=dict(available=20*1024**3,allocated=600*1024**2)
        self.assertEqual(S.admit_cold_work(good,S.PACKAGE_OUTPUT_ESTIMATE)['additionalEstimatedBytes'],1024**3+S.RESULT_CAP+S.FIXTURE_CAP)
        for sample in (dict(good,allocated=3*1024**3),dict(good,available=S.RESERVE)):
            with self.assertRaises(RuntimeError):S.admit_cold_work(sample,S.PACKAGE_OUTPUT_ESTIMATE)

    def test_package_scope_binds_full_header_resource_closure_and_dependency_lock(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            def put(name,value):
                path=root/name;path.parent.mkdir(parents=True,exist_ok=True)
                raw=(value if isinstance(value,str) else json.dumps(value)).encode();path.write_bytes(raw)
                return dict(path=name,bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())
            prefix='Packages/TractandaPeerTLS/'
            pins=[dict(identity='dependency',state=dict(revision='0'*40,version='1.0.0'),location='https://example.invalid/dependency')]
            lock=put(prefix+'Package.resolved',dict(pins=pins))
            compiled=[dict(path=prefix+p,sha256='source') for p in ('Package.swift','Sources/C/include/header.h','Sources/TLS/PrivacyInfo.xcprivacy','Tests/Tests.swift')]
            compiled.append(dict(path=lock['path'],sha256=lock['sha256']))
            method='TractandaPeerTLSTests.PeerTLSTests.testTLS'
            candidate=put('candidate',dict(inputs=[]))
            selection=put('selection',[method]);status=put('status',dict(running=False,exit=0))
            log=put('log',"Test Case '"+method+"' passed\nTest Suite 'Selected tests' passed\n Executed 1 test, with 0 failures\n")
            witness=dict(candidateSHA256=candidate['sha256'],files=compiled,dependencies=[dict(identity='dependency',revision='0'*40,version='1.0.0')])
            before=put('before',witness);after=put('after',dict(witness,changed=False))
            receipt=put('receipt',dict(candidate=candidate,result=dict(passed=1,failed=0,skipped=0,exit=0,executedMethods=[method]),references=[candidate,status,log,before,after]))
            scope=dict(name='peer-tls',packagePath=prefix.rstrip('/'),expectedTests=selection,macReceipt=receipt,macReview=put('review','accepted'),candidate=candidate,macStatus=status,macLog=log,macCompleteBefore=before,macCompleteAfter=after)
            with patch.object(S,'REPO',root):
                accepted=S.reviewed_package_tests(dict(packageTests=[scope]),compiled)
                self.assertEqual((accepted[0]['compiledInputs'],accepted[0]['pins']),(5,pins))
                for damaged in (compiled[:-1],compiled+[dict(path=prefix+'Sources/new.h',sha256='new')],
                                [dict(r,sha256='tampered') if r['path'].endswith('PrivacyInfo.xcprivacy') else r for r in compiled]):
                    with self.assertRaisesRegex(RuntimeError,'closure differs'):
                        S.reviewed_package_tests(dict(packageTests=[scope]),damaged)
                bad=dict(witness,changed=False,dependencies=[dict(identity='dependency',revision='f'*40,version='1.0.0')])
                bad_after=put('bad-after',bad)
                bad_receipt=put('bad-receipt',dict(candidate=candidate,result=dict(passed=1,failed=0,skipped=0,exit=0,executedMethods=[method]),references=[candidate,status,log,before,bad_after]))
                with self.assertRaisesRegex(RuntimeError,'dependency revisions differ'):
                    S.reviewed_package_tests(dict(packageTests=[dict(scope,macCompleteAfter=bad_after,macReceipt=bad_receipt)]),compiled)

    def test_reviewed_method_union_normalizes_module_and_rejects_missing_or_duplicate_case(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            def put(name,value):
                (root/name).write_text(json.dumps(value));return dict(path=name)
            prior='TractandaCoreTests.CredentialTests.testOne'
            development='FirstSourceConversionTests.DevelopmentFirstSourceFixtureTests.testTwo'
            data=dict(priorUnitReceipt=put('receipt',dict(candidateSHA256='accepted',coverage=dict(uniquePassedMethods=1,missingMethods=[],extraMethods=[]))),
                      priorUnitReview=put('review',{}),priorUnitExpectedTests=put('prior',['CredentialTests.testOne']),
                      reviewedCandidates=[dict(sha256='accepted')],expectedTests=put('union',sorted([prior,development])),batch=dict(expectedCases=2))
            self.assertEqual(S.normalize_batch_method('TractandaCoreTests.DevelopmentFirstSourceFixtureTests/testTwo'),development)
            with patch.object(S,'checked_reference',side_effect=lambda r:root/r['path']):
                self.assertEqual(S.reviewed_batch_selection(data,[development]),sorted([prior,development]))
                for damaged in ([prior],[prior,development,prior]):
                    (root/'union').write_text(json.dumps(damaged))
                    with self.assertRaises(RuntimeError):
                        S.reviewed_batch_selection(data,[development])

    def test_complete_witness_keeps_both_development_inputs_and_candidate_overlay_exact(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            def put(name,value):
                (root/name).write_text(json.dumps(value));return dict(path=name,sha256=name)
            generic=[dict(path='Sources/Store.swift',sha256='new'),dict(path='Sources/Admission.swift',sha256='admission')]
            extra=[dict(path=p,sha256='development') for p in sorted(S.DEVELOPMENT_SWIFT)]
            candidate=dict(files=[generic[0]]+extra)
            prior=put('prior',dict(files=[dict(generic[0],sha256='old'),generic[1]]))
            final=put('candidate',candidate)
            witness=dict(files=generic+extra,candidateSHA256='candidate',explicitDevelopmentInputs=sorted(S.DEVELOPMENT_SWIFT))
            before=put('before',witness);after=put('after',dict(witness,changed=[],nativeExit=0))
            data=dict(candidate=final,reviewedCandidates=[prior,final],macCompleteBefore=before,macCompleteAfter=after)
            with patch.object(S,'checked_reference',side_effect=lambda r:root/r['path']):
                reviewed,development=S.reviewed_batch_inputs(data,candidate,generic,[before,after])
                self.assertEqual(reviewed['Sources/Store.swift'],'new')
                self.assertEqual(reviewed['Sources/Admission.swift'],'admission')
                self.assertEqual(set(development),S.DEVELOPMENT_SWIFT)
                for damaged in (dict(witness,changed=['Sources/Store.swift'],nativeExit=0),
                                dict(witness,changed=[],nativeExit=1),
                                dict(witness,files=generic+extra[:-1],changed=[],nativeExit=0)):
                    (root/'after').write_text(json.dumps(damaged))
                    with self.assertRaises(RuntimeError):
                        S.reviewed_batch_inputs(data,candidate,generic,[before,after])

    def test_reviewed_source_v2_end_to_end_reference_binding(self):
        for with_count in (True, False):
            with tempfile.TemporaryDirectory() as temporary:
                root=Path(temporary)
                def put(name,value):
                    payload=(value if isinstance(value,str) else json.dumps(value)).encode()
                    (root/name).write_bytes(payload)
                    return dict(path=name,bytes=len(payload),sha256=hashlib.sha256(payload).hexdigest())
                generic=[dict(path='Sources/Store.swift',sha256='new'),dict(path='Sources/Admission.swift',sha256='admission')]
                dev=[dict(path=p,sha256='development') for p in sorted(S.DEVELOPMENT_SWIFT)]
                ancillary=[dict(path=p,sha256='ancillary') for p in sorted(S.DEVELOPMENT_ANCILLARY)]
                old=[dict(generic[0],sha256='old')]+dev+ancillary
                stage=put('stage',dict(files=[dict(r,path='source/Tractanda/'+r['path']) for r in old]))
                prior=put('prior-linux',dict(result='PASS',source=dict(projectFrozenInputs=5),references=[stage]))
                mac_method='FirstSourceConversionTests.DevelopmentFirstSourceFixtureTests.testTwo'
                mac_list=put('mac-list','FirstSourceConversionTests.DevelopmentFirstSourceFixtureTests/testTwo\n')
                unit_list=put('unit-list',['CredentialTests.testOne'])
                unit_candidate=put('unit-candidate',dict(files=[dict(generic[0],sha256='old'),generic[1]]))
                candidate=put('candidate',dict(files=[generic[0]]+dev,expectedMethods=(dict(path=mac_list['path'],sha256=mac_list['sha256'],count=1) if with_count else dict(mac_list))))
                unit=put('unit',dict(candidateSHA256=unit_candidate['sha256'],coverage=dict(uniquePassedMethods=1,missingMethods=[],extraMethods=[])))
                ids=sorted(['TractandaCoreTests.CredentialTests.testOne',mac_method])
                exact=put('exact-list',ids)
                manifest=put('manifest',dict(files=generic))
                status=put('status',dict(running=False,exit=0))
                log=put('log',"Test Case '"+mac_method+"' passed\nTest Suite 'Selected tests' passed\n Executed 1 test, with 0 failures\n")
                witness=dict(files=generic+dev,candidateSHA256=candidate['sha256'],explicitDevelopmentInputs=sorted(S.DEVELOPMENT_SWIFT))
                before=put('before',witness);after=put('after',dict(witness,changed=[],nativeExit=0))
                # Actual final Mac196 shape: hash-only references, no redundant
                # top-level candidate digest. Its immutable candidate ref is authority.
                mac_refs=[dict(path=r['path'],sha256=r['sha256']) for r in [candidate,mac_list,manifest,status,log,before,after]]
                receipt=put('mac-receipt',dict(references=mac_refs))
                review=put('review','accepted synthetic fixture')
                data=dict(profile='tractanda.stash-source-approval.v2',batch=dict(priorInputs=5,currentInputs=6,addedInputs=1,modifiedInputs=1,genericMacInputs=2,acceptedMacCases=1,expectedCases=2),
                          priorStashReceipt=prior,priorStashReview=review,priorStage=stage,candidate=candidate,reviewedCandidates=[unit_candidate,candidate],
                          expectedTests=exact,macExpectedTests=mac_list,expectedIDs=ids,priorUnitReceipt=unit,priorUnitReview=review,priorUnitExpectedTests=unit_list,
                          currentMacReceipt=receipt,currentMacReview=review,macCompiledManifest=manifest,macStatus=status,macLog=log,macCompleteBefore=before,macCompleteAfter=after)
                checkpoint=put('checkpoint',data)
                with patch.object(S,'REPO',root):
                    inputs,provenance,extra=S.source_approval_basis(root/checkpoint['path'],data)
                    self.assertEqual((len(inputs),provenance['exactFocusedIDs'],extra),(6,ids,[]))
                    self.assertEqual(provenance['kind'],'reviewed-source-approval')
                    named=put('named-mac-receipt',dict(candidate=candidate,sourceBefore=before,sourceAfter=after,nativeStatus=status,nativeLog=log))
                    inputs,_,_=S.source_approval_basis(root/checkpoint['path'],dict(data,currentMacReceipt=named))
                    self.assertEqual(len(inputs),6)
                    tampered=[dict(r,sha256='0'*64) if r['path']==candidate['path'] else r for r in mac_refs]
                    bad=put('bad-mac-receipt',dict(references=tampered))
                    with self.assertRaisesRegex(RuntimeError,'reference changed'):
                        S.source_approval_basis(root/checkpoint['path'],dict(data,currentMacReceipt=bad))
                    missing=put('missing-candidate-receipt',dict(references=mac_refs[1:]))
                    with self.assertRaisesRegex(RuntimeError,'Mac result authority differs'):
                        S.source_approval_basis(root/checkpoint['path'],dict(data,currentMacReceipt=missing))
                    for bad_selector, reason in [
                        (dict(mac_list, count=2), 'selector count'),
                        (dict(mac_list, bytes=mac_list['bytes']+1), 'selector reference'),
                        (dict(mac_list, extra='unknown'), 'selector reference')]:
                        bad_body=json.loads((root/'candidate').read_text());bad_body['expectedMethods']=bad_selector
                        bad_candidate=put('bad-selector-candidate',bad_body)
                        with self.assertRaisesRegex(RuntimeError,reason):
                            S.source_approval_basis(root/checkpoint['path'],dict(data,candidate=bad_candidate))
                    altered=put('altered-mac-list','FirstSourceConversionTests.DevelopmentFirstSourceFixtureTests/testChanged\n')
                    with self.assertRaisesRegex(RuntimeError,'expected method authority'):
                        S.source_approval_basis(root/checkpoint['path'],dict(data,macExpectedTests=altered))
                    original_list=(root/'mac-list').read_bytes();(root/'mac-list').write_bytes(b'altered')
                    with self.assertRaisesRegex(RuntimeError,'reference changed'):
                        S.source_approval_basis(root/checkpoint['path'],data)
                    (root/'mac-list').write_bytes(original_list)
                    (root/'after').write_text('{}')
                    with self.assertRaisesRegex(RuntimeError,'reference changed'):
                        S.source_approval_basis(root/checkpoint['path'],data)

    def test_hash_only_receipt_reference_size_is_bounded_before_hashing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);(root/'evidence').write_bytes(b'large')
            with patch.object(S,'REPO',root),patch.object(S,'RESULT_CAP',4),patch.object(S,'digest_reference') as digest:
                with self.assertRaisesRegex(RuntimeError,'bounded evidence size'):
                    S.receipt_references(dict(references=[dict(path='evidence',sha256='unused')]))
                digest.assert_not_called()

    def test_guard_failure_terminates_and_waits_for_owned_real_child(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary); child=[]; original=subprocess.Popen
            def spawn(*args,**kwargs):
                p=original(*args,**dict(kwargs,stdin=subprocess.DEVNULL)); child.append(p); return p
            good=dict(available=S.PREFLIGHT,allocated=0)
            with patch.object(S.C,'LOGS',root),patch.object(S.C,'REPO',root), \
                    patch.object(S.C,'capacity',side_effect=[good,RuntimeError('injected guard failure')]), \
                    patch.object(S.C,'subprocess',SimpleNamespace(Popen=spawn,TimeoutExpired=subprocess.TimeoutExpired,STDOUT=subprocess.STDOUT)):
                with self.assertRaisesRegex(RuntimeError,'validation failed'):
                    S.C.run([sys.executable,'-c','import time; time.sleep(60)'],'guard-fault',{},timeout=2)
            self.assertEqual(len(child),1)
            self.assertIsNotNone(child[0].poll())
            receipt=json.loads((root/'guard-fault.status.json').read_text())
            self.assertFalse(receipt['running'])
            self.assertEqual(receipt['exit'],125)
            self.assertIn('injected guard failure',receipt['failure'])

    def test_cleanup_retains_broken_pipe_failure_and_waits(self):
        process=SimpleNamespace(stdin=SimpleNamespace(closed=False,close=lambda: (_ for _ in ()).throw(BrokenPipeError())),
            poll=unittest.mock.Mock(side_effect=[None,0]),terminate=unittest.mock.Mock(),wait=unittest.mock.Mock())
        S.stop_local_process(process)
        process.terminate.assert_called_once()
        process.wait.assert_called_once_with(timeout=20)

    def test_cleanup_terminate_error_still_kills_and_waits(self):
        process=SimpleNamespace(stdin=None,poll=unittest.mock.Mock(side_effect=[None,None,0]),
            terminate=unittest.mock.Mock(side_effect=OSError('TERM failed')),kill=unittest.mock.Mock(),wait=unittest.mock.Mock())
        S.stop_local_process(process)
        process.kill.assert_called_once()
        process.wait.assert_called_once_with(timeout=10)

    def test_cleanup_timeout_uses_bounded_kill_and_wait(self):
        process=SimpleNamespace(stdin=None,poll=unittest.mock.Mock(side_effect=[None,None,0]),
            terminate=unittest.mock.Mock(),kill=unittest.mock.Mock(),
            wait=unittest.mock.Mock(side_effect=[subprocess.TimeoutExpired('owned SSH',20),0]))
        S.stop_local_process(process)
        process.kill.assert_called_once()
        self.assertEqual(process.wait.call_args_list,[unittest.mock.call(timeout=20),unittest.mock.call(timeout=10)])

    def test_local_cleanup_error_cannot_skip_remote_closure_or_mask_original(self):
        with tempfile.TemporaryDirectory() as temporary:
            local=Path(temporary).resolve();home=local/'remote-home'
            label='stash-cluster-b2-20261016-0123abcd';root=S.remote_root(home,label)
            original=InterruptedError('lease wait interrupted')
            response=json.dumps(dict(closed=True,unit=label+'.service')).encode()
            with patch.object(S,'stop_local_process',side_effect=RuntimeError('cleanup failed')), \
                    patch.object(S.subprocess,'check_output',return_value=response) as closure:
                result=S.close_supervisor(None,local,label,root,'session',original)
            self.assertIs(result,original)
            closure.assert_called_once()
            status=json.loads((local/'supervisor.status.json').read_text())
            self.assertEqual(status['originalFailure'],'lease wait interrupted')
            self.assertEqual(status['localCleanupFailure'],'cleanup failed')

    def test_cold_estimate_checks_post_growth_reserve_and_aggregate_cap(self):
        sample=dict(available=20*1024**3,allocated=50*1024**2)
        accepted=S.admit_cold_work(sample)
        self.assertLess(accepted['finalAllocatedEstimate']+S.ALLOWANCE,S.CAP)
        additional=S.COLD_OUTPUT_ESTIMATE+S.RESULT_CAP
        for modified in (dict(sample,available=S.RESERVE+additional-1),dict(sample,allocated=S.CAP-additional)):
            with self.assertRaises(RuntimeError):S.admit_cold_work(modified)

    def test_actual_unit_properties_and_timespan_normalization(self):
        label='stash-cluster-b2-20261016-0123abcd';root=S.remote_root(Path('/home/example'),label)
        budgets=S.timeout_budgets(7200)
        runtime=budgets['unitRuntimeSeconds']
        hours,remainder=divmod(runtime,3600);minutes,seconds=divmod(remainder,60)
        runtime_text=(str(hours)+'h ' if hours else '')+(str(minutes)+'min ' if minutes else '')+str(seconds)+'s'
        values=dict(RuntimeMaxUSec=runtime_text,TimeoutStopUSec='15s',KillMode='control-group',OOMPolicy='kill',
            MainPID=str(os.getpid()),User='',Group='',Transient='yes',ExecStart=str(root/'support/verify-stash-cluster.py'))
        def text(d):return '\n'.join(k+'='+v for k,v in d.items())
        with patch.object(S.subprocess,'check_output',return_value=text(values)):
            self.assertEqual(S.verify_unit(root,label,runtime)['runtimeSeconds'],runtime)
        for changed in (dict(values,RuntimeMaxUSec='infinity'),dict(values,RuntimeMaxUSec='30min'),dict(values,TimeoutStopUSec='30s'),
                dict(values,KillMode='process'),dict(values,OOMPolicy='continue'),dict(values,MainPID='0')):
            with patch.object(S.subprocess,'check_output',return_value=text(changed)):
                with self.assertRaises(RuntimeError):S.verify_unit(root,label,runtime)
        self.assertEqual(S.seconds('29min 60s'),1800)
        self.assertEqual(S.seconds('1d 14min 24s'),
                         S.timeout_budgets(S.DEFAULT_TIMEOUT_SECONDS)['unitRuntimeSeconds'])
        with self.assertRaises(RuntimeError):S.seconds('unknown')

    def test_nested_fixture_filesystem_is_detected(self):
        mounts='1 0 8:1 / / rw - ext4 /dev/root rw\n2 1 0:1 / /var/tmp rw - tmpfs tmpfs rw\n'
        with patch.object(Path,'read_text',return_value=mounts):
            self.assertEqual(S.filesystem_kind(Path('/var/tmp/fixture')),'tmpfs')
            self.assertEqual(S.filesystem_kind(Path('/home/example/.cache/fixture')),'ext4')

    def test_swiftly_resolution_reads_selection_and_preserves_named_driver_entry(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);shim=root/'shim';shim.mkdir();(shim/'swiftly').write_text('manager')
            (shim/'swift').symlink_to(shim/'swiftly')
            tools=root/'selected/usr/bin';tools.mkdir(parents=True)
            (tools/'swift-driver').write_text('real tool')
            (tools/'swift').symlink_to(tools/'swift-driver')
            for name in ('clang','swift-frontend'):(tools/name).write_text('real tool')
            with patch.object(S.shutil,'which',return_value=str(shim/'swift')), \
                    patch.object(S.subprocess,'check_output',return_value=json.dumps({'path':str(root/'selected')})) as selection:
                selected=S.resolve_toolchain()
            self.assertEqual(selected,tools)
            self.assertEqual(str(selected/'swift'),str(tools/'swift'))
            self.assertNotEqual(selected/'swift',(selected/'swift').resolve())
            self.assertEqual(selection.call_args.args[0],['swiftly','use','--print-location','--format','json'])

    def test_concrete_versions_use_identical_private_environment_and_named_commands(self):
        tools=Path('/selected/usr/bin');environment={'PATH':str(tools)+':/usr/bin:/bin','HOME':'/private/test/home'}
        with patch.object(S.subprocess,'check_output',side_effect=['Swift version 6.5.2','clang version 22']) as command:
            versions=S.toolchain_versions(tools,environment)
        self.assertIn('6.5.2',versions['swift'])
        self.assertEqual([v.args[0] for v in command.call_args_list],[[str(tools/'swift'),'--version'],[str(tools/'clang'),'--version']])
        self.assertTrue(all(v.kwargs['env'] is environment for v in command.call_args_list))

    def test_all_offline_mirrors_precede_the_only_resolving_scoped_command(self):
        root=Path('/private/test');tools=Path('/selected/usr/bin')
        common=['--package-path',str(root/'source/Tractanda'),'--disable-sandbox']
        for kind in ('scratch','cache','config','security'):common+=['--'+kind+'-path',str(root/kind)]
        pins=[dict(identity='dependency'+str(i),location='https://example.invalid/'+str(i),
            state={'revision':'0'*40}) for i in range(9)]
        environment={'HOME':str(root/'home'),'GIT_ALLOW_PROTOCOL':'file'}
        with tempfile.TemporaryDirectory() as temporary:
            logs=Path(temporary)
            def fake_run(command,label,*args,**kwargs):
                if label=='tests':
                    (logs/'tests.status.json').write_text(json.dumps(dict(running=False,exit=0,seconds=0)))
                    (logs/'tests.log').write_text("Test Case 'Tests.testOne' passed\nExecuted 1 tests, with 0 failures\n")
            with patch.object(S.C,'run',side_effect=fake_run) as run,patch.object(S.C,'LOGS',logs):
                S.configure_and_test(tools,common,{'pins':pins,'ids':['Module.Tests.testOne'],'testFilter':'exact116'},
                                     root,environment,command_timeout_seconds=4321)
        commands=[call.args[0] for call in run.call_args_list]
        mirrors=[i for i,command in enumerate(commands) if 'set-mirror' in command]
        resolving=[i for i,command in enumerate(commands) if len(command)>1 and command[1]=='test']
        self.assertEqual(len(mirrors),9)
        self.assertEqual(resolving,[len(commands)-1])
        self.assertLess(max(mirrors),resolving[0])
        for call in run.call_args_list:
            command=call.args[0]
            self.assertIs(call.args[2],environment)
            if command[0]==str(tools/'swift'):
                self.assertEqual(command[2:2+len(common)],common)
                if 'test' in command:
                    self.assertEqual(call.args[3],4321)
                self.assertNotIn('--help',command)
                if command[1]=='package':self.assertIn('set-mirror',command)
        self.assertIn('--force-resolved-versions',commands[-1])

    def test_portability_admission_refuses_undeclared_paths_and_wrong_preimages(self):
        before={p:'old-'+p for p in S.PORTABLE_PATHS};before['Sources/unchanged.swift']='unchanged'
        after={p:('new-'+p if p in S.PORTABLE_PATHS else value) for p,value in before.items()}
        changes={p:dict(beforeSHA256=before[p],afterSHA256=after[p]) for p in S.PORTABLE_PATHS}
        S.validate_delta(before,after,changes)
        with self.assertRaises(RuntimeError):S.validate_delta(before,dict(after,**{'Sources/unchanged.swift':'modified'}),changes)
        omitted=dict(changes);omitted.pop(next(iter(omitted)))
        with self.assertRaises(RuntimeError):S.validate_delta(before,after,omitted)
        wrong=dict(changes);p=next(iter(wrong));wrong[p]=dict(beforeSHA256='wrong',afterSHA256=after[p])
        with self.assertRaises(RuntimeError):S.validate_delta(before,after,wrong)

    def test_mac_provenance_requires_actual_case_events_not_last_empty_bundle(self):
        ids=['Module.Tests.testOne','Module.Tests.testTwo']
        output="Test Case '-[Module.Tests testOne]' passed\nTest Case '-[Module.Tests testTwo]' passed\nExecuted 2 tests, with 0 failures\nExecuted 0 tests, with 0 failures\n"
        S.verify_mac_cases(dict(running=False,exit=0),output,ids)
        for altered in (output.replace('testTwo','testOne'),output.replace("' passed","' skipped",1)):
            with self.assertRaises(RuntimeError):S.verify_mac_cases(dict(running=False,exit=0),altered,ids)
        with self.assertRaises(RuntimeError):S.verify_mac_cases(dict(running=False,exit=1),output,ids)

    def test_credential_delta_requires_exact_modified_added_paths_and_preimages(self):
        before={p:'old-'+p for p in S.CREDENTIAL_MODIFIED}
        before.update({'unchanged/'+str(i):'same' for i in range(1153)})
        after=dict(before)
        after.update({p:'new-'+p for p in S.CREDENTIAL_MODIFIED | S.CREDENTIAL_ADDED})
        receipt=dict(preimages=[dict(path=p,preimage_sha256=before[p],current_sha256=after[p])
            for p in sorted(S.CREDENTIAL_MODIFIED)], references={p:dict(sha256=after[p]) for p in S.CREDENTIAL_ADDED})
        S.validate_credential_delta(before,after,receipt)
        for altered in (dict(after,**{'unexpected.swift':'new'}),
                        {p:v for p,v in after.items() if p!=next(iter(S.CREDENTIAL_ADDED))},
                        dict(after,**{'unchanged/0':'drift'})):
            with self.assertRaises(RuntimeError):S.validate_credential_delta(before,altered,receipt)
        receipt['preimages'][0]['preimage_sha256']='wrong'
        with self.assertRaises(RuntimeError):S.validate_credential_delta(before,after,receipt)

    def test_historical_profiles_reject_current_enrollment_source(self):
        for checkpoint in (None,
                S.REPO/'outputs/verification/cluster-2026-10-16/stash-corpus-portability-source.json',
                S.REPO/'outputs/verification/cluster-2026-10-16/stash-peer-credentials-source.json'):
            with self.assertRaises(RuntimeError): S.local_inputs(checkpoint)

    def test_enrollment_delta_requires_exact_paths_and_preimages(self):
        before={p:'old-'+p for p in S.ENROLLMENT_MODIFIED}
        before.update({'unchanged/'+str(i):'same' for i in range(1160)})
        after=dict(before)
        after.update({p:'new-'+p for p in S.ENROLLMENT_MODIFIED | S.ENROLLMENT_ADDED})
        preimages=[dict(sourcePath=p,sha256=before[p]) for p in sorted(S.ENROLLMENT_MODIFIED)]
        receipt=dict(ownedSource={p:after[p] for p in S.ENROLLMENT_MODIFIED | S.ENROLLMENT_ADDED})
        S.validate_enrollment_delta(before,after,preimages,receipt)
        for altered in (dict(after,**{'unexpected.swift':'new'}),
                {p:v for p,v in after.items() if p!=next(iter(S.ENROLLMENT_ADDED))},
                dict(after,**{'unchanged/0':'drift'})):
            with self.assertRaises(RuntimeError): S.validate_enrollment_delta(before,altered,preimages,receipt)
        for altered in (preimages[:-1], [dict(v,sha256='wrong') for v in preimages]):
            with self.assertRaises(RuntimeError): S.validate_enrollment_delta(before,after,altered,receipt)
        receipt['ownedSource'][next(iter(S.ENROLLMENT_ADDED))]='wrong'
        with self.assertRaises(RuntimeError): S.validate_enrollment_delta(before,after,preimages,receipt)

    def test_enrollment_admission_binds_accepted_authority_and_exact_selection(self):
        path=S.REPO/'outputs/verification/cluster-2026-10-17/enrollment-linux-source.json'
        data=json.loads(path.read_text())
        for key in ('priorStashReceipt','enrollmentReceipt','enrollmentReview'):
            bad=json.loads(json.dumps(data));bad[key]['sha256']='0'*64
            with self.assertRaisesRegex(RuntimeError,'authority differs'): S.enrollment_basis(path,bad)
        for ids in (data['expectedIDs'][:-1],data['expectedIDs']+[data['expectedIDs'][0]]):
            bad=dict(data,expectedIDs=ids)
            with self.assertRaises(RuntimeError): S.enrollment_basis(path,bad)

    def test_historical_enrollment_profile_rejects_changed_source(self):
        path=S.REPO/'outputs/verification/cluster-2026-10-17/enrollment-linux-source.json'
        with self.assertRaises(RuntimeError): S.local_inputs(path)

    def test_fresh_wiring_admission_rejects_wrong_authority_selection_or_missing_dev_input(self):
        path=S.REPO/'outputs/verification/cluster-2026-10-17/fresh-store-linux-source.json'
        data=json.loads(path.read_text())
        for key in ('priorStashReceipt','currentMacReceipt','currentMacReview'):
            bad=json.loads(json.dumps(data));bad[key]['sha256']='0'*64
            with self.assertRaisesRegex(RuntimeError,'authority differs'): S.fresh_store_basis(path,bad)
        # Isolate historical metadata validation from later workspace edits.
        # The separate stale-profile test below exercises live-byte rejection.
        candidate=json.loads((S.REPO/data['currentCandidate']['path']).read_text())['files']
        original=S.digest_reference
        def historical_reference(row):
            if row['path'] in candidate:
                return S.REPO/row['path']
            return original(row)
        with patch.object(S,'digest_reference',side_effect=historical_reference):
            bad=dict(data,expectedIDs=data['expectedIDs'][:-1])
            with self.assertRaisesRegex(RuntimeError,'selection differs'): S.fresh_store_basis(path,bad)
            bad=dict(data,extraCompilationInputs=data['extraCompilationInputs'][:-1])
            with self.assertRaisesRegex(RuntimeError,'compilation inputs differ'): S.fresh_store_basis(path,bad)
            bad=dict(data,excluded={})
            with self.assertRaisesRegex(RuntimeError,'selection differs'): S.fresh_store_basis(path,bad)

    def test_mac_multiple_bundles_require_exact_events_and_terminal_summary_counts(self):
        ids=['ModuleA.Tests.testOne','ModuleB.Tests.testTwo']
        output="Test Case '-[ModuleA.Tests testOne]' passed\nTest Suite 'Selected tests' passed at now\n Executed 1 test, with 0 failures\nTest Case '-[ModuleB.Tests testTwo]' passed\nTest Suite 'Selected tests' passed at now\n Executed 1 test, with 0 failures\n"
        S.verify_mac_cases(dict(running=False,exit=0),output,ids,multiple_bundles=True)
        for altered in (output.replace('testTwo','testOne'),output.replace('Executed 1 test','Executed 0 tests',1),output.replace("' passed\n","' skipped\n",1)):
            with self.assertRaises(RuntimeError):S.verify_mac_cases(dict(running=False,exit=0),altered,ids,multiple_bundles=True)

    def test_fresh_wiring_delta_rejects_unrelated_paths_and_wrong_preimages(self):
        path=S.REPO/'outputs/verification/cluster-2026-10-17/fresh-store-linux-source.json'
        data=json.loads(path.read_text())
        stage=json.loads((S.REPO/data['priorStage']['path']).read_text())
        before={r['path'].removeprefix('source/Tractanda/'):r['sha256'] for r in stage['files'] if r['path'].startswith('source/Tractanda/')}
        after={r['path']:r['sha256'] for r in json.loads((S.REPO/data['fixturePortability']['compiledManifest']['path']).read_text())['files']}
        candidate=json.loads((S.REPO/data['currentCandidate']['path']).read_text())['files']
        override=json.loads((S.REPO/data['fixturePortability']['candidate']['path']).read_text())['files']
        candidate.update({p:v for p,v in override.items() if p in candidate})
        S.validate_fresh_delta(before,after,data,candidate)
        unchanged=next(p for p in before if p not in data['modified'])
        for altered in (dict(after,**{unchanged:'drift'}),dict(after,**{'unexpected':'new'}),{p:v for p,v in after.items() if p!=unchanged}):
            with self.assertRaises(RuntimeError): S.validate_fresh_delta(before,altered,data,candidate)
        bad=json.loads(json.dumps(data));bad['preimages'][0]['sha256']='0'*64
        with self.assertRaisesRegex(RuntimeError,'preimage differs'): S.validate_fresh_delta(before,after,bad,candidate)

    def test_historical_fresh_wiring_profile_rejects_changed_workspace_source(self):
        path=S.REPO/'outputs/verification/cluster-2026-10-17/fresh-store-linux-source.json'
        with self.assertRaisesRegex(RuntimeError,'verification reference changed:'):
            S.local_inputs(path)

    def test_cli_fixture_alias_binds_actual_new_owned_elf_and_rejects_drift(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);source=root/'source/Tractanda';source.mkdir(parents=True)
            debug=root/'scratch/x86_64-unknown-linux-gnu/debug';debug.mkdir(parents=True)
            (root/'scratch/debug').symlink_to(debug,target_is_directory=True)
            alias=source/'.build';alias.symlink_to(root/'scratch',target_is_directory=True)
            cli=debug/'tractanda';cli.write_bytes(b'\x7fELFtiny-fixture')
            binary=debug/'TractandaPackageTests.xctest'
            result=S.verify_cli_alias(root,binary)
            self.assertEqual(result['resolvedCLIPath'],str(cli))
            self.assertEqual(result['sha256'],S.C.sha(cli))
            cli.write_bytes(b'not-ELF')
            with self.assertRaisesRegex(RuntimeError,'not ELF'):S.verify_cli_alias(root,binary)
            cli.unlink();cli.symlink_to(binary)
            with self.assertRaises(RuntimeError):S.verify_cli_alias(root,binary)
            alias.unlink();alias.symlink_to(root/'foreign',target_is_directory=True)
            with self.assertRaisesRegex(RuntimeError,'alias differs'):S.verify_cli_alias(root)

    def test_split_general_and_strict_fixture_roots_share_unchanged_cap(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary).resolve();fixtures=root/'fixtures';general=root/'tmp'
            for path in (fixtures,general):path.mkdir(mode=0o700)
            with patch.object(S.C.GATE,'allocated_tree',return_value=16*1024**2):
                result=S.account_general_fixture_tmp(root,fixtures,dict(fixtureAllocated=S.FIXTURE_CAP-16*1024**2,available=S.RESERVE+1))
                self.assertEqual(result['fixtureAllocated'],S.FIXTURE_CAP)
                with self.assertRaisesRegex(RuntimeError,'aggregate'):S.account_general_fixture_tmp(root,fixtures,dict(fixtureAllocated=S.FIXTURE_CAP-16*1024**2+512))
            general.rmdir();general.symlink_to(fixtures,target_is_directory=True)
            with self.assertRaisesRegex(RuntimeError,'parent differs'):S.account_general_fixture_tmp(root,fixtures,dict(fixtureAllocated=0))

    def test_fixture_early_deadline_waits_for_an_affected_actual_method(self):
        ids=['Module.SharedDaemonTests.testOne']
        self.assertFalse(S.fixture_runtime_seen("Test Case 'AttachmentResumableUploadTests.testUnrelated' started",ids))
        self.assertFalse(S.fixture_runtime_seen("Test Case 'SharedDaemonTests.testOne' passed",ids))
        self.assertTrue(S.fixture_runtime_seen("Test Case 'SharedDaemonTests.testOne' started",ids))
        self.assertTrue(S.fixture_runtime_seen("Test Case 'Module.SharedDaemonTests.testOne' started",ids))

    def test_fixture_proof_requires_actual_contained_exact_methods_and_no_stale_publication(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary).resolve();fixtures=root/'fixtures';proof=root/'fixture-proof'
            for directory in (fixtures,proof):directory.mkdir(mode=0o700)
            ids=['Module.SharedDaemonTests.testCase'+str(i) for i in range(11)]
            self.assertEqual(S.inspect_fixture_proofs(root,fixtures,ids)['records'],0)
            with self.assertRaisesRegex(RuntimeError,'missing'):S.inspect_fixture_proofs(root,fixtures,ids,complete=True)
            paths=[];rows=[]
            def write(path,row):path.write_text(json.dumps(row));path.chmod(0o600)
            for i,case in enumerate(ids):
                leaf='t'+format(i,'07x');path=proof/('SharedDaemonTests-'+leaf+'.json')
                row=dict(profile='tractanda.fixture-root-proof.v1',source='SharedDaemonTests',test=case,
                    root=str(fixtures/leaf),expectedRoot=str(fixtures),proofRoot=str(proof),
                    uid=os.getuid(),pid=os.getpid(),phase='created')
                write(path,row);paths.append(path);rows.append(row)
            self.assertTrue(S.inspect_fixture_proofs(root,fixtures,ids,complete=True)['complete'])
            with self.assertRaisesRegex(RuntimeError,'freshness'):S.inspect_fixture_proofs(root,fixtures,ids,not_before_ns=time.time_ns()+10**9)
            unknown=fixtures/'unrecorded';unknown.mkdir(mode=0o700)
            with self.assertRaisesRegex(RuntimeError,'unknown'):S.inspect_fixture_proofs(root,fixtures,ids,complete=True)
            unknown.rmdir()
            unknown.symlink_to(root,target_is_directory=True)
            with self.assertRaisesRegex(RuntimeError,'unknown'):S.inspect_fixture_proofs(root,fixtures,ids,complete=True)
            unknown.unlink()
            for altered in (dict(rows[0],root=str(root/'outside')),dict(rows[0],uid=os.getuid()+1),
                    dict(rows[0],unknown='injected'),dict(rows[0],test=ids[1]),dict(rows[0],proofRoot=str(root))):
                write(paths[0],altered)
                with self.assertRaises(RuntimeError):S.inspect_fixture_proofs(root,fixtures,ids)
            write(paths[0],rows[0])
            paths[0].write_bytes(b'x'*2049)
            with self.assertRaisesRegex(RuntimeError,'size/freshness differs'):S.inspect_fixture_proofs(root,fixtures,ids)
            write(paths[0],rows[0]);paths[0].chmod(0o666)
            with self.assertRaisesRegex(RuntimeError,'mode/size'):S.inspect_fixture_proofs(root,fixtures,ids)
            write(paths[0],rows[0]);paths[0].unlink();paths[0].symlink_to(paths[1])
            with self.assertRaises(OSError):S.inspect_fixture_proofs(root,fixtures,ids)
            paths[0].unlink();write(paths[0],rows[0]);os.link(paths[0],root/'external-link')
            with self.assertRaisesRegex(RuntimeError,'mode/size'):S.inspect_fixture_proofs(root,fixtures,ids)
            (root/'external-link').unlink()
            temp=fixtures/'.fixture-proof-00000000-0000-4000-8000-000000000000.tmp';temp.write_bytes(b'');temp.chmod(0o600)
            self.assertEqual(len(S.inspect_fixture_proofs(root,fixtures,ids)['temporary']),1)
            with self.assertRaisesRegex(RuntimeError,'unpublished'):S.inspect_fixture_proofs(root,fixtures,ids,complete=True)
            temp.unlink();paths[0].unlink()
            with self.assertRaisesRegex(RuntimeError,'missing'):S.inspect_fixture_proofs(root,fixtures,ids,complete=True)

    def test_fresh_bootstrap_adds_only_explicit_owned_cli_alias(self):
        self.assertIn("os.symlink(str(root/'scratch'),root/'source/Tractanda/.build')",S.BOOTSTRAP)
        self.assertIn("d.get('sourceProvenance',{}).get('kind')=='reviewed-fresh-store-wiring'",S.BOOTSTRAP)

    def test_result_zero_exit_missing_duplicate_or_skipped_is_rejected(self):
        ids=['Module.Tests.testOne','Module.Tests.testTwo']; status=dict(exit=0,running=False)
        text="Test Case 'Tests.testOne' passed\nTest Case 'Tests.testTwo' passed\nExecuted 2 tests, with 0 failures\n"
        S.C.verify_results(status,text,ids)
        for altered in (text.replace('Tests.testTwo','Tests.testOne'),text.replace("' passed","' skipped",1),text.replace("Test Case 'Tests.testTwo' passed\n",'')):
            with self.assertRaises(RuntimeError): S.C.verify_results(status,altered,ids)

    def test_embedded_remote_code_parses_without_executing(self):
        import ast
        for source in (S.BOOTSTRAP,S.CLOSURE,S.FETCH): ast.parse(source)


if __name__=='__main__':
    unittest.main()
