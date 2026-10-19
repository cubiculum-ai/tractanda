#!/usr/bin/env python3
"""Tiny contract/failure-path fixtures. No compiler, models, dpkg or inference."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import sys
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('producer', Path(__file__).with_name('produce-linux-payload.py'))
P = importlib.util.module_from_spec(spec)
spec.loader.exec_module(P)


class ProducerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='tractanda-producer-unit-')
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def put(self, path, data=b'tiny', mode=0o644):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(mode)
        return path

    def fixture(self):
        recipe = self.put(self.root / 'scripts/component.py')
        tree = self.root / 'artifacts'
        self.put(tree / 'bin/tractanda-embeddings', b'fixture-executable', 0o755)
        self.put(tree / 'licenses/runtime/LICENSE')
        value = dict(profile='tractanda.linux-component-artifacts.v1', component='embeddings', arch='amd64',
                     baseline={'buildOS': 'debian13', 'minimumCPU': 'x86-64', 'swiftABI': '6.4'},
                     modelRevision=P.MODELS['embeddings'], runtimeRevision=P.RUNTIME,
                     sourceInputsSHA256='1' * 64, recipe={'path': 'scripts/component.py', 'sha256': P.B.digest(recipe)},
                     patches=[], toolchain={'version': 'Swift version 6.4.1', 'swiftSHA256': '2' * 64,
                     'swiftFrontendSHA256': '3' * 64, 'clangSHA256': '4' * 64}, files=P.rows(tree),
                     dynamicLoads=[], runtimeNotices=['licenses/runtime/LICENSE'], documentExtraction=None)
        manifest = self.root / 'component.json'
        manifest.write_bytes(P.B.canonical(value))
        return manifest, tree, value

    def admit(self, path, tree, value):
        with mock.patch.object(P, 'ROOT', self.root):
            return P.component(path, tree, 'embeddings', 'amd64', P.sha(P.B.canonical(value)))

    def test_unadmitted_stops_before_heavy_or_environment_work(self):
        with mock.patch.object(P.B, 'native_baseline') as native, mock.patch.object(P, 'source_rows') as source:
            with self.assertRaisesRegex(ValueError, 'Unadmitted amd64 components: embeddings, documents'):
                P.produce(argparse.Namespace(arch='amd64'))
            native.assert_not_called()
            source.assert_not_called()
        self.assertEqual(list(self.root.iterdir()), [])

    def test_registry_rejects_unknown_component_or_nonhash(self):
        value = {'profile': 'tractanda.linux-runtime-inputs.v1', 'runtimeRevision': P.RUNTIME,
                 'architectures': {arch: {'embeddings': None, 'documents': None} for arch in P.B.ARCH}}
        path = self.put(self.root / 'registry.json', json.dumps(value).encode())
        with mock.patch.object(P, 'REGISTRY', path):
            self.assertEqual(P.registry('arm64'), {'embeddings': None, 'documents': None})
            value['architectures']['arm64']['documents'] = 'approved'
            path.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, 'reviewed normalized'):
                P.registry('arm64')

    def test_dirty_and_custom_path_sources_are_bound_and_cache_excluded(self):
        self.put(self.root / 'Sources/untracked.swift')
        self.put(self.root / 'scripts/development/first-source-conversion/custom.swift')
        self.put(self.root / 'Packages/P/.build/cache')
        result = P.rows(self.root, skip=P.SKIP)
        self.assertEqual([v['path'] for v in result], [
            'Sources/untracked.swift', 'scripts/development/first-source-conversion/custom.swift'])
        self.put(self.root / 'Sources/untracked.swift', b'changed')
        self.assertNotEqual(result, P.rows(self.root, skip=P.SKIP))

    def test_tree_rejects_links_modes_collisions_and_byte_bound(self):
        target = self.put(self.root / 'real')
        (self.root / 'alias').symlink_to(target)
        with self.assertRaisesRegex(ValueError, 'links/special'):
            P.rows(self.root)
        (self.root / 'alias').unlink()
        with self.assertRaisesRegex(ValueError, 'logical byte'):
            P.rows(self.root, maximum=1)
        target.chmod(0o666)
        with self.assertRaisesRegex(ValueError, 'protected mode'):
            P.rows(self.root)
        target.chmod(0o644)
        # This host folds case at filesystem creation. Inject two distinct directory
        # entries with the same shared normalization instead of relying on that host behavior.
        self.put(self.root / 'alias-name')
        with mock.patch.object(P.unicodedata, 'normalize', side_effect=lambda form, name: 'real' if name == 'alias-name' else name):
            with self.assertRaisesRegex(ValueError, 'collide'):
                P.rows(self.root)

    def test_compiler_storage_accepts_and_accounts_only_contained_scratch_links(self):
        with mock.patch.object(P.B, 'capacity'):
            root = self.root / 'work'
            for name in ('modules', 'scratch', 'cache', 'source', 'payload'):
                (root / name).mkdir(parents=True, exist_ok=True)
            data = self.put(root / 'modules/object.o', b'object')
            (root / 'modules/object.o.lock').symlink_to(root / 'modules/disappearing-lock')
            used = P.build_storage(root, 1024**2)
            self.assertGreaterEqual(used, data.stat().st_blocks * 512)
            with self.assertRaisesRegex(ValueError, 'allocation'):
                P.build_storage(root, 1)

    def test_compiler_storage_rejects_escape_cross_subtree_source_and_special_entries(self):
        with mock.patch.object(P.B, 'capacity'):
            root = self.root / 'work'
            for name in ('modules', 'scratch', 'cache', 'source', 'payload'):
                (root / name).mkdir(parents=True, exist_ok=True)
            link = root / 'modules/lock'
            for target in (Path('/etc/passwd'), root / 'scratch/foreign-target'):
                link.symlink_to(target)
                with self.assertRaisesRegex(ValueError, 'escapes'):
                    P.build_storage(root, 1024**2)
                link.unlink()
            source_link = root / 'source/link'
            source_link.symlink_to(root / 'source/target')
            with self.assertRaisesRegex(ValueError, 'escapes'):
                P.build_storage(root, 1024**2)
            with self.assertRaisesRegex(ValueError, 'links/special'):
                P.rows(root, roots=('source',))
            source_link.unlink()
            payload_link = root / 'payload/link'
            payload_link.symlink_to(root / 'payload/target')
            with self.assertRaisesRegex(ValueError, 'unsafe type'):
                P.B.owned_storage(root / 'payload', 1024**2)
            payload_link.unlink()
            os.mkfifo(root / 'modules/pipe')
            with self.assertRaisesRegex(ValueError, 'file type'):
                P.build_storage(root, 1024**2)

    def test_child_uses_only_explicit_build_guard_and_keeps_default_policy(self):
        work = self.root / 'work'
        for name in ('modules', 'scratch', 'cache', 'source'):
            (work / name).mkdir(parents=True, exist_ok=True)
        (work / 'modules/compiler.lock').symlink_to(work / 'modules/lock-target')
        original = P.B.owned_storage
        process = mock.Mock(pid=999999, poll=mock.Mock(return_value=0), wait=mock.Mock(return_value=0))
        build_guard = mock.Mock(wraps=P.build_storage)
        with mock.patch.object(P.B, 'capacity'), mock.patch.object(P.subprocess, 'Popen', return_value=process), \
                mock.patch.object(P.os, 'killpg'):
            P.child(['/bin/true'], work, {}, 1024**2, storage_guard=build_guard)
        self.assertGreaterEqual(build_guard.call_count, 2)
        self.assertIs(P.B.owned_storage, original)
        failed_process = mock.Mock(pid=999998, poll=mock.Mock(return_value=0), wait=mock.Mock(return_value=1))
        with mock.patch.object(P.B, 'capacity'), mock.patch.object(P.subprocess, 'Popen', return_value=failed_process), \
                mock.patch.object(P.os, 'killpg'):
            with self.assertRaisesRegex(ValueError, 'Build command failed'):
                P.child(['/bin/false'], work, {}, 1024**2, storage_guard=P.build_storage)
        self.assertIs(P.B.owned_storage, original)
        with mock.patch.object(P.B, 'capacity'), mock.patch.object(P.subprocess, 'Popen') as launch:
            with self.assertRaisesRegex(ValueError, 'unsafe type'):
                P.child(['/bin/true'], work, {}, 1024**2)
            launch.assert_not_called()
        self.assertIs(P.B.owned_storage, original)

    def test_component_reordered_json_uses_stable_normalized_hash(self):
        path, tree, value = self.fixture()
        path.write_text(json.dumps(dict(reversed(list(value.items()))), indent=4))
        self.assertEqual(self.admit(path, tree, value), value)

    def test_component_changed_bytes_missing_notice_and_unknown_field_refuse(self):
        path, tree, value = self.fixture()
        self.put(tree / 'bin/tractanda-embeddings', b'other', 0o755)
        with self.assertRaisesRegex(ValueError, 'entire reviewed'):
            self.admit(path, tree, value)
        value['files'] = P.rows(tree)
        value['runtimeNotices'] = ['licenses/missing']
        path.write_bytes(P.B.canonical(value))
        with self.assertRaisesRegex(ValueError, 'roots/notices'):
            self.admit(path, tree, value)
        value['runtimeNotices'] = ['licenses/runtime/LICENSE']
        value['diagnosticPID'] = 123
        path.write_bytes(P.B.canonical(value))
        with self.assertRaisesRegex(ValueError, 'Unapproved'):
            self.admit(path, tree, value)

    def test_component_recipe_source_and_architecture_are_required(self):
        path, tree, value = self.fixture()
        self.put(self.root / 'scripts/component.py', b'new recipe')
        with self.assertRaisesRegex(ValueError, 'recipe/patch is missing or changed'):
            self.admit(path, tree, value)
        with self.assertRaisesRegex(ValueError, 'Unapproved'):
            P.component(path, tree, 'embeddings', 'arm64', P.sha(P.B.canonical(value)))

    def test_component_models_cannot_override_separate_pinned_model_inputs(self):
        path, tree, value = self.fixture()
        self.put(tree / 'models/foreign.bin')
        value['files'] = P.rows(tree)
        path.write_bytes(P.B.canonical(value))
        with self.assertRaisesRegex(ValueError, 'without core/public/model'):
            self.admit(path, tree, value)

    def test_component_duplicate_json_key_is_rejected(self):
        path, tree, value = self.fixture()
        path.write_text('{"component":"documents",' + P.B.canonical(value).decode()[1:])
        with self.assertRaisesRegex(ValueError, 'Duplicate JSON key'):
            self.admit(path, tree, value)

    def test_merge_shared_runtime_accepts_only_identical_bytes_and_modes(self):
        source, destination = self.root / 'input', self.root / 'output'
        self.put(source / 'lib/libswiftCore.so')
        destination.mkdir()
        entries = P.rows(source)
        P.merge_files(source, destination, entries, 1024**2)
        P.merge_files(source, destination, entries, 1024**2)
        (destination / 'lib/libswiftCore.so').chmod(0o755)
        with self.assertRaisesRegex(ValueError, 'Conflicting final'):
            P.merge_files(source, destination, entries, 1024**2)

    def test_clean_environment_drops_host_flags_and_loader_injection(self):
        with mock.patch.dict(os.environ, {'CFLAGS': '-march=native', 'LD_PRELOAD': 'evil.so', 'SWIFT_EXEC': 'evil'}):
            environment = P.controlled_environment(self.root, Path('/opt/swift/usr/bin'))
        self.assertEqual(environment['GIT_ALLOW_PROTOCOL'], 'file')
        self.assertEqual(environment['GIT_CONFIG_GLOBAL'], '/dev/null')
        self.assertFalse({'CFLAGS', 'LD_PRELOAD', 'SWIFT_EXEC'} & environment.keys())

    def test_fixed_flags_include_native_driver_and_declared_thread_budget(self):
        for arch in P.B.ARCH:
            self.assertEqual(P.core_build_flags(arch), ['-march=' + P.B.ARCH[arch][2], '-target-cpu', 'generic',
                                                       '--build-system', 'native', '-num-threads', '4'])
            P.B.global_isa_flags(P.core_build_flags(arch), arch)
        with self.assertRaisesRegex(ValueError, 'baseline'):
            P.B.global_isa_flags(['-march=native', '-num-threads', '4'], 'amd64')

    def test_fast_child_still_checks_final_storage_and_reaps(self):
        (self.root / 'source').mkdir()
        process = mock.Mock(pid=999999, poll=mock.Mock(return_value=0), wait=mock.Mock(return_value=0))
        with mock.patch.object(P.subprocess, 'Popen', return_value=process), \
                mock.patch.object(P.os, 'killpg'), mock.patch.object(P.B, 'owned_storage', side_effect=[0, ValueError('final reserve')]) as storage:
            with self.assertRaisesRegex(ValueError, 'final reserve'):
                P.child(['/bin/true'], self.root, {}, 1024**2)
        self.assertEqual(storage.call_count, 2)
        process.wait.assert_called()
        self.assertEqual(P.B.read_json(self.root / 'operation.json')['state'], 'failed')

    def test_offline_mirrors_require_exact_locked_set(self):
        self.put(self.root / 'Package.resolved', json.dumps({'pins': [{'identity': 'x'}]}).encode())
        mirrors = self.put(self.root / 'mirrors.json', b'{}')
        with self.assertRaisesRegex(ValueError, 'exactly the frozen'):
            P.mirrored_pins(self.root, mirrors)

    def test_offline_mirror_object_validation_and_locked_tag_are_required(self):
        revision = 'a' * 40
        pin = {'identity': 'x', 'location': 'https://example.invalid/x.git',
               'state': {'revision': revision, 'version': '1.0.0'}}
        self.put(self.root / 'Package.resolved', json.dumps({'pins': [pin]}).encode())
        mirror = self.root / 'mirror.git'
        mirror.mkdir()
        contract = self.put(self.root / 'mirrors.json', json.dumps({'x': str(mirror)}).encode())
        def run(command):
            return '' if 'fsck' in command else revision + '\n'
        with mock.patch.object(P.B, 'run', side_effect=run) as checked:
            result = P.mirrored_pins(self.root, contract)
        self.assertEqual(result['object'], [{'original': pin['location'], 'mirror': mirror.as_uri()}])
        self.assertTrue(any('fsck' in call.args[0] and '--strict' in call.args[0] for call in checked.call_args_list))
        with mock.patch.object(P.B, 'run', side_effect=ValueError('corrupt object')):
            with self.assertRaisesRegex(ValueError, 'corrupt object'):
                P.mirrored_pins(self.root, contract)

    def test_swift_reported_product_directory_is_confined_and_actual(self):
        (self.root / 'scratch').mkdir()
        reported = self.root / 'scratch/out/Products/Release-linux-x86_64'
        reported.mkdir(parents=True)
        self.assertEqual(P.reported_bin_directory(str(reported) + '\n', self.root), reported.resolve())
        outside = self.root / 'elsewhere'
        outside.mkdir()
        for output in (str(outside), 'relative/path', str(reported) + '\nextra'):
            with self.subTest(output=output), self.assertRaises(ValueError):
                P.reported_bin_directory(output, self.root)

    def test_build_and_show_bin_path_use_identical_native_arguments(self):
        (self.root / 'scratch').mkdir()
        output = self.root / 'scratch/out/Products/Release-linux-x86_64'
        output.mkdir(parents=True)
        with mock.patch.object(P, 'child', side_effect=[None, str(output) + '\n']) as child:
            actual = P.build_core_product('/opt/swift/usr/bin/swift', ['--package-path', '/owned/source'],
                                          'amd64', 'tractanda', self.root, {}, 1024**2)
        build_call, discovery_call = child.call_args_list
        self.assertEqual(discovery_call.args[0], [*build_call.args[0], '--show-bin-path'])
        self.assertTrue(discovery_call.kwargs['capture'])
        self.assertIs(discovery_call.kwargs['storage_guard'], P.build_storage)
        self.assertEqual(actual, output.resolve())
        command = build_call.args[0]
        self.assertEqual(command[command.index('--build-system') + 1], 'native')
        self.assertEqual(command[command.index('-c') + 1], 'release')
        self.assertEqual(command[command.index('-j') + 1], '1')
        forwarded = [command[i+1] for i, value in enumerate(command[:-1]) if value == '-Xswiftc']
        self.assertEqual(forwarded, ['-target-cpu', 'generic', '-num-threads', '4'])
        self.assertIn('--disable-index-store', command)

    def test_existing_descriptor_default_and_injected_runner_keep_exact_validation(self):
        model = self.root / 'model'
        weight = self.put(model / 'model.safetensors', b'tiny-fixture-only')
        profile = {'alias': 'tractanda-granite-embedding-311m-multilingual-r2-vmlx-fp32-44399559',
                   'modelRevision': P.MODELS['embeddings'], 'vmlxRevision': P.RUNTIME, 'dimensions': 768,
                   'pooling': 'cls', 'normalization': 'l2', 'revision': 'fixture-profile',
                   'assets': {'model.safetensors': P.B.digest(weight)}}
        host = self.root / 'tractanda-embeddings'
        with mock.patch.object(P.B.MAC, 'run', return_value=json.dumps(profile)) as default:
            descriptor = P.B.MAC.embedding_descriptor(host, model)
            default.assert_called_once_with(str(host), '--describe')
        runner = mock.Mock(return_value=json.dumps(profile))
        with mock.patch.object(P.B.MAC, 'run', side_effect=AssertionError('default runner must not execute')):
            self.assertEqual(P.B.MAC.embedding_descriptor(host, model, runner=runner), descriptor)
        runner.assert_called_once_with(str(host), '--describe')
        self.put(weight, b'changed')
        with self.assertRaisesRegex(ValueError, 'pinned hashes'):
            P.B.MAC.embedding_descriptor(host, model, runner=runner)
        profile['dimensions'] = 1024
        runner.return_value = json.dumps(profile)
        with self.assertRaisesRegex(ValueError, 'bundled Granite profile'):
            P.B.MAC.embedding_descriptor(host, model, runner=runner)

    def test_d3_handoff_forwards_same_probe_runner_through_both_levels(self):
        payload = self.root / 'payload'
        payload.mkdir()
        spec = self.put(self.root / 'spec.json', b'{}')
        runner = mock.Mock(side_effect=ValueError('controlled probe sentinel'))
        with mock.patch.object(P.B, 'native_baseline'), mock.patch.object(P.B, 'validate_spec'), \
                mock.patch.object(P.B, 'inventory', return_value=[]), mock.patch.object(P.B, 'public_assets'), \
                mock.patch.object(P.B, 'runtime_closure'), \
                mock.patch.object(P.B, 'full_components', side_effect=ValueError('handoff sentinel')) as components:
            with self.assertRaisesRegex(ValueError, 'handoff sentinel'):
                P.B.assemble(payload, spec, self.root / 'bundle', 'amd64', 1024**2, embedding_runner=runner)
        self.assertIs(components.call_args.kwargs['embedding_runner'], runner)
        web_rows = [{'path': 'bin/Tractanda_TractandaWeb.resources/fixture'}]
        with mock.patch.object(P.B.MAC, 'embedding_descriptor',
                               side_effect=lambda host, model, runner=None: runner(str(host), '--describe')):
            with self.assertRaisesRegex(ValueError, 'controlled probe sentinel'):
                P.B.full_components(payload, {}, web_rows, embedding_runner=runner)
        runner.assert_called_once_with(str(payload / 'bin/tractanda-embeddings'), '--describe')

    def test_probe_runner_is_fixed_bounded_and_uses_controlled_environment(self):
        environment = P.controlled_environment(self.root, Path(sys.executable).parent)
        runner = P.descriptor_runner(self.root, environment, 1024**2)
        with mock.patch.object(P, 'child', return_value='{}') as child:
            self.assertEqual(runner('/fixture/tractanda-embeddings', '--describe'), '{}')
        child.assert_called_once_with(('/fixture/tractanda-embeddings', '--describe'), self.root,
                                      environment, 1024**2, timeout=60, capture=True)
        with self.assertRaisesRegex(ValueError, 'fixed embedding descriptor'):
            runner('/fixture/other', '--describe')

    def synthetic_probe(self, body):
        (self.root / 'source').mkdir(exist_ok=True)
        host = self.put(self.root / 'tractanda-embeddings',
                        ('#!' + sys.executable + '\n' + body).encode(), 0o755)
        return host, P.controlled_environment(self.root, Path(sys.executable).parent)

    def test_synthetic_probe_captures_bounded_stdout_separately_and_cleans(self):
        host, environment = self.synthetic_probe('import os,json,sys\nsys.stderr.write("diagnostic only\\n")\n'
            'print(json.dumps({"loader":os.environ.get("LD_PRELOAD"),"cflags":os.environ.get("CFLAGS")}))\n')
        with mock.patch.dict(os.environ, {'LD_PRELOAD': 'untrusted.so', 'CFLAGS': '-march=native'}):
            result = P.descriptor_runner(self.root, environment, 1024**2)(str(host), '--describe')
        self.assertEqual(json.loads(result), {'loader': None, 'cflags': None})
        self.assertEqual((self.root / 'build.log').read_text(), 'diagnostic only\n')
        self.assertFalse((self.root / 'probe-output.json').exists())
        self.assertEqual(P.B.read_json(self.root / 'operation.json')['state'], 'completed')

    def test_synthetic_probe_timeout_exit_and_oversize_reap_and_remove_partial_output(self):
        scenarios = [('import time\ntime.sleep(10)\n', 0.05, 'time bound'),
                     ('import sys\nprint("partial")\nsys.exit(7)\n', 5, 'exit 7'),
                     ('import os\nos.write(1,b"x"*' + str(P.PROBE_BYTES + 1) + ')\n', 5, 'output bound')]
        real_popen = P.subprocess.Popen
        for body, timeout, message in scenarios:
            with self.subTest(message=message):
                host, environment = self.synthetic_probe(body)
                processes = []
                def launch(*args, **kwargs):
                    process = real_popen(*args, **kwargs)
                    processes.append(process)
                    return process
                with mock.patch.object(P.subprocess, 'Popen', side_effect=launch):
                    with self.assertRaisesRegex(ValueError, message):
                        P.child([host, '--describe'], self.root, environment, 1024**2, timeout=timeout, capture=True)
                self.assertEqual(len(processes), 1)
                self.assertIsNotNone(processes[0].returncode)
                with self.assertRaises(ProcessLookupError):
                    os.kill(processes[0].pid, 0)
                self.assertFalse((self.root / 'probe-output.json').exists())
                self.assertEqual(P.B.read_json(self.root / 'operation.json')['state'], 'failed')

    def test_probe_refuses_existing_capture_without_deleting_it_or_starting_child(self):
        (self.root / 'source').mkdir()
        existing = self.put(self.root / 'probe-output.json', b'retained-existing-bytes')
        with mock.patch.object(P.subprocess, 'Popen') as launch:
            with self.assertRaises(FileExistsError):
                P.child(['/fixture/tractanda-embeddings', '--describe'], self.root, {}, 1024**2, capture=True)
        launch.assert_not_called()
        self.assertEqual(existing.read_bytes(), b'retained-existing-bytes')


class GenerousBuildTimeoutTests(unittest.TestCase):
    def test_configurable_budget_is_finite_and_addressable(self):
        self.assertEqual(P.DEFAULT_BUILD_TIMEOUT_SECONDS, 86400)
        for value in (1, 90000, '604800'):
            self.assertEqual(P.timeout_seconds(value), float(value))
        for value in (True, False, 0, -1, float('inf'), float('nan'), 'invalid', 2**31):
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                P.timeout_seconds(value)

    def test_configured_budget_reaches_build_and_discovery(self):
        with tempfile.TemporaryDirectory() as folder:
            work = Path(folder); output = work / 'scratch/bin'; output.mkdir(parents=True)
            with mock.patch.object(P, 'child', side_effect=[None, str(output) + '\n']) as child:
                P.build_core_product('/usr/bin/swift', [], 'amd64', 'tractanda', work, {}, 2**30, timeout=604800)
            self.assertEqual([call.kwargs['timeout'] for call in child.call_args_list], [604800, 604800])

    def test_invalid_budget_is_rejected_before_guard_or_process(self):
        with mock.patch.object(P.B, 'owned_storage') as guard, mock.patch.object(P.subprocess, 'Popen') as process:
            with self.assertRaises(argparse.ArgumentTypeError):
                P.child([], Path('/not-used'), {}, 1, timeout=float('nan'))
        guard.assert_not_called(); process.assert_not_called()


class ModelModeProjectionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='tractanda-model-projection-')
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def test_private_input_stays_private_and_package_tree_is_readable(self):
        source = self.root / 'private-model'
        nested = source / 'nested'
        nested.mkdir(parents=True, mode=0o700)
        model = nested / 'weights.bin'
        model.write_bytes(b'tiny private model fixture')
        model.chmod(0o600)
        nested.chmod(0o700)
        source.chmod(0o700)

        entries = P.rows(source)
        source_before = {
            path: (path.lstat().st_ino, path.lstat().st_ctime_ns, path.lstat().st_mode,
                   path.read_bytes() if path.is_file() else None)
            for path in (source, nested, model)
        }
        receipt = P.merge_model_files(source, self.root / 'payload-model', entries, 1024**2)

        for path, expected in source_before.items():
            info = path.lstat()
            self.assertEqual((info.st_ino, info.st_ctime_ns, info.st_mode), expected[:3])
            if expected[3] is not None:
                self.assertEqual(path.read_bytes(), expected[3])
        payload = self.root / 'payload-model'
        self.assertEqual(payload.stat().st_mode & 0o777, 0o755)
        self.assertEqual((payload / 'nested').stat().st_mode & 0o777, 0o755)
        projected = payload / 'nested/weights.bin'
        self.assertEqual(projected.stat().st_mode & 0o777, 0o644)
        self.assertEqual(projected.read_bytes(), b'tiny private model fixture')
        self.assertEqual(receipt['inputFiles'][0]['mode'], 0o600)
        self.assertEqual(receipt['payloadFiles'][0]['mode'], 0o644)
        self.assertEqual(receipt['inputFiles'][0]['sha256'], receipt['payloadFiles'][0]['sha256'])
        self.assertTrue(receipt['sourceMetadataUnchanged'])

    def test_same_bytes_with_changed_source_mode_is_rejected(self):
        source = self.root / 'private-model'
        source.mkdir(mode=0o700)
        model = source / 'weights.bin'
        model.write_bytes(b'tiny private model fixture')
        model.chmod(0o600)
        entries = P.rows(source)
        model.chmod(0o644)

        destination = self.root / 'payload-model'
        with self.assertRaisesRegex(ValueError, 'size/mode differs'):
            P.merge_model_files(source, destination, entries, 1024**2)
        self.assertFalse(destination.exists())
        self.assertEqual(model.read_bytes(), b'tiny private model fixture')
        model.chmod(0o600)


if __name__ == '__main__':
    unittest.main()
