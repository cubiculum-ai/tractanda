#!/usr/bin/env python3
"""Isolated routing and fallback checks for the finite Debian maintainer hooks."""
import importlib.machinery
import importlib.util
import hashlib
import io
import tarfile
import json
import os
import platform
import stat
import copy
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[1]
DEBIAN = ROOT / "debian"
FALLBACK = DEBIAN / "tractanda-package-hook-fallback.py.in"
DESCRIPTOR = json.dumps({
    "profile": "tractanda.linux-package.v1",
    "manifestSHA256": "a" * 64,
    "version": "0.1.0~poc.16-1",
    "arch": "x86_64",
    "canonicalFormats": {"profile": "test"},
    "semanticProfile": "tractanda.peer-exchange.v2",
    "upgrade": "compatible",
}, separators=(",", ":"))


def module_from_template():
    loader = importlib.machinery.SourceFileLoader("tractanda_hook_fallback", str(FALLBACK))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class HookHarness:
    def __init__(self, root):
        self.root = Path(root)
        self.bin = self.root / "mock-bin"
        self.bin.mkdir()
        self.helper = self.bin / "fixed-helper"
        self.log = self.root / "mock-log.json"
        self.temporary_descriptor = self.root / "descriptor.json"
        self.hook_dir = self.root / "rendered-hooks"
        self.hook_dir.mkdir()
        self._write_mock("mock-mktemp", """
import os, sys, tempfile
pattern = sys.argv[1]
directory, leaf = os.path.split(pattern)
path = tempfile.mkstemp(prefix=leaf.split("XXXXXX", 1)[0], dir=directory)[1]
print(path)
""")
        self._write_mock("mock-cat", """
import sys
sys.stdout.buffer.write(sys.stdin.buffer.read())
""")
        self._write_mock("mock-rm", """
import os, sys
for path in sys.argv[1:]:
    if path == "--" or path == "-f": continue
    try: os.unlink(path)
    except FileNotFoundError: pass
""")
        self._write_mock("mock-systemctl", """
import json, os, sys
with open(os.environ["MOCK_LOG"], "a", encoding="utf-8") as f:
    f.write(json.dumps({"program":"systemctl", "args":sys.argv[1:]}) + "\\n")
sys.exit(int(os.environ.get("MOCK_SYSTEMCTL_EXIT", "0")))
""")
        self._write_mock("mock-python", """
import json, os, sys
arguments = sys.argv[1:]
with open(os.environ["MOCK_LOG"], "a", encoding="utf-8") as f:
    f.write(json.dumps({"program":"python-hook", "args":arguments}) + "\\n")
sys.exit(int(os.environ.get("MOCK_PYTHON_EXIT", "0")))
""")
        self.env = os.environ.copy()
        self.env.update({
            "MOCK_LOG": str(self.log),
            "MOCK_DESCRIPTOR": str(self.temporary_descriptor),
            "MOCK_HELPER_EXIT": "0",
            "MOCK_SYSTEMCTL_EXIT": "0",
            "MOCK_PYTHON_EXIT": "0",
        })

    def _write_mock(self, name, source):
        path = self.bin / name
        path.write_text("#!" + sys.executable + "\n" + source)
        path.chmod(0o700)
        return path

    def render(self, hook, *, helper=True, missing=(), layout17_version="0.1.0~poc.17-1"):
        source = ((ROOT / "Tests/TractandaSetupTests/Fixtures/LegacyDebian/tractanda.prerm")
                  if hook == "legacy.prerm" else (DEBIAN / hook)).read_text()
        fallback = FALLBACK.read_text()
        source = source.replace("@TRACTANDA_PACKAGE_HOOK_FALLBACK_PY@", fallback)
        source = source.replace("@TRACTANDA_PACKAGE_DESCRIPTOR_JSON@", DESCRIPTOR)
        source = source.replace("@TRACTANDA_LAYOUT17_INSPECTOR_SHA256@", "b" * 64)
        source = source.replace("@TRACTANDA_LAYOUT17_DEBIAN_VERSION@", layout17_version)
        source = source.replace("@TRACTANDA_LAYOUT17_MANIFEST_SHA256@", "c" * 64)
        replacements = {
            "/opt/tractanda/current/bin/tractanda-setup": str(self.helper),
            "/run/tractanda-package-descriptor.": str(self.root / "descriptor-"),
            "/usr/bin/mktemp": str(self.bin / "mock-mktemp"),
            "/bin/cat": str(self.bin / "mock-cat"),
            "/bin/rm": str(self.bin / "mock-rm"),
            "/usr/bin/systemctl": str(self.bin / "mock-systemctl"),
            "/usr/bin/python3": str(self.bin / "mock-python"),
        }
        for original, replacement in replacements.items():
            if original in missing:
                replacement = "/tractanda-test-missing/" + Path(original).name
            source = source.replace(original, replacement)
        if helper:
            self._write_mock("fixed-helper", """
import json, os, sys
record = {"program":"setup-helper", "args":sys.argv[1:]}
if "--descriptor" in sys.argv:
    record["descriptor"] = open(sys.argv[sys.argv.index("--descriptor") + 1], encoding="utf-8").read()
with open(os.environ["MOCK_LOG"], "a", encoding="utf-8") as f:
    f.write(json.dumps(record) + "\\n")
sys.exit(int(os.environ.get("MOCK_HELPER_EXIT", "0")))
""")
        else:
            self.helper.unlink(missing_ok=True)
        path = self.hook_dir / hook.removesuffix(".in")
        path.write_text(source)
        path.chmod(0o700)
        return path

    def run(self, hook, *arguments, helper=True, missing=(), layout17_version="0.1.0~poc.17-1"):
        path = self.render(hook, helper=helper, missing=missing, layout17_version=layout17_version)
        return subprocess.run(["/bin/sh", str(path), *arguments], capture_output=True,
                              text=True, timeout=10, env=self.env, cwd=self.root)

    def records(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def clear(self):
        self.log.unlink(missing_ok=True)
        self.temporary_descriptor.unlink(missing_ok=True)


class PackageHookTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tractanda-hook-test-")
        self.harness = HookHarness(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_templates_have_one_builder_embedded_fallback_and_fixed_helper(self):
        expected_fallbacks = {
            "tractanda.preinst.in": 1, "tractanda.prerm": 1,
            "tractanda.postinst.in": 1, "tractanda.postrm": 1,
        }
        expected_descriptors = {
            "tractanda.preinst.in": 1, "tractanda.prerm": 0,
            "tractanda.postinst.in": 1, "tractanda.postrm": 0,
        }
        for name, count in expected_fallbacks.items():
            source = (DEBIAN / name).read_text()
            self.assertEqual(source.count("@TRACTANDA_PACKAGE_HOOK_FALLBACK_PY@"), count)
            self.assertEqual(source.count("@TRACTANDA_PACKAGE_DESCRIPTOR_JSON@"), expected_descriptors[name])
            rendered = source.replace("@TRACTANDA_PACKAGE_HOOK_FALLBACK_PY@", FALLBACK.read_text())
            rendered = rendered.replace("@TRACTANDA_PACKAGE_DESCRIPTOR_JSON@", DESCRIPTOR)
            self.assertNotIn("@TRACTANDA_PACKAGE_HOOK_FALLBACK_PY@", rendered)
            self.assertNotIn("@TRACTANDA_PACKAGE_DESCRIPTOR_JSON@", rendered)
            if name != "tractanda.postrm":
                self.assertIn("/opt/tractanda/current/bin/tractanda-setup", source)
            self.assertNotIn("/usr/local/bin", source)
            self.assertNotIn("store-bootstrap", source)
            self.assertNotIn("useradd", source)

    def test_preinst_and_configure_route_descriptor_to_fixed_stub(self):
        for args in (
            ("install",),
            ("install", "0.1.0~poc.15-1", "0.1.0~poc.16-1"),
            ("upgrade", "0.1.0~poc.15-1", "0.1.0~poc.16-1"),
        ):
            self.harness.clear()
            pre = self.harness.run("tractanda.preinst.in", *args)
            self.assertEqual(pre.returncode, 0, (args, pre.stderr))
            records = self.harness.records()
            self.assertEqual(records[0]["args"][:4], ["-I", "-", "preinst-helper", str(self.harness.helper)])
            self.assertTrue(records[0]["args"][4].startswith(str(self.harness.root / "descriptor-")))
            self.assertEqual(len(records[0]["args"]), 5)
            self.assertEqual(records[1]["args"][:2], ["--package-lifecycle", "preinst"])
            self.assertEqual(records[1]["args"][3], records[0]["args"][4])
            self.assertEqual(json.loads(records[1]["descriptor"]), json.loads(DESCRIPTOR))

        for args in (("configure",), ("configure", "")):
            self.harness.clear()
            post = self.harness.run("tractanda.postinst.in", *args)
            self.assertEqual(post.returncode, 0, (args, post.stderr))
            records = self.harness.records()
            self.assertEqual(records[0]["args"], ["-I", "-", "configure-helper", str(self.harness.helper)])
            self.assertEqual(records[1]["args"][:2], ["--package-lifecycle", "configure"])
            self.assertEqual(records[1]["descriptor"], DESCRIPTOR + "\n")

    def test_uuidd_configuration_failure_prevents_setup_restart(self):
        self.harness.env["MOCK_PYTHON_EXIT"] = "42"
        result = self.harness.run("tractanda.postinst.in", "configure")
        self.assertEqual(result.returncode, 42)
        self.assertEqual(self.harness.records(), [{"program": "python-hook", "args": ["-I", "-", "configure-helper", str(self.harness.helper)]}])

    def test_prerm_and_abort_events_route_finitely(self):
        for hook, args, expected in (
            ("tractanda.prerm", ("remove",), "remove"),
            ("tractanda.prerm", ("failed-upgrade", "old", "new"), "abort-upgrade"),
            ("tractanda.preinst.in", ("abort-upgrade", "old"), "abort-upgrade"),
            ("tractanda.postinst.in", ("abort-upgrade", "old"), "abort-upgrade"),
        ):
            self.harness.clear()
            result = self.harness.run(hook, *args)
            self.assertEqual(result.returncode, 0, result.stderr)
            records = self.harness.records()
            self.assertEqual(records[0]["program"], "python-hook")
            self.assertEqual(records[0]["args"], ["-I", "-", "verify-helper", str(self.harness.helper)])
            self.assertEqual(records[1]["args"], ["--package-lifecycle", expected])

    def test_old_prerm_new_preinst_uses_genuine_stop_only_bridge(self):
        old = "0.1.0~poc.15-1+personal.1793193134.fdaf8ff8b393"
        result = self.harness.run("legacy.prerm", "upgrade", "0.1.0~poc.17-1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.harness.records()[1]["args"], ["--package-lifecycle", "prerm-upgrade"])
        self.harness.clear()
        result = self.harness.run("tractanda.preinst.in", "upgrade", old, "0.1.0~poc.17-1")
        self.assertEqual(result.returncode, 0, result.stderr)
        records = self.harness.records()
        self.assertEqual(len(records), 1)  # This routing double does not execute Python's old-helper call.
        self.assertEqual(records[0]["args"][2], "legacy-preinst-helper")
        self.assertEqual(records[0]["args"][-1], old)

    def test_future_prerm_defers_stop_to_preinst(self):
        result = self.harness.run("tractanda.prerm", "upgrade", "0.1.0~poc.18-1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.harness.records(), [{"program": "python-hook", "args": ["-I", "-", "verify-helper", str(self.harness.helper)]}])

    def test_postinst_abort_remove_forms_dispatch_as_conservative_abort(self):
        for args in (("abort-remove",), ("abort-remove", "in-favour", "conflictor", "1.2")):
            self.harness.clear()
            result = self.harness.run("tractanda.postinst.in", *args)
            self.assertEqual(result.returncode, 0, (args, result.stderr))
            records = self.harness.records()
            self.assertEqual(records[0]["args"], ["-I", "-", "verify-helper", str(self.harness.helper)])
            self.assertEqual(records[1]["args"], ["--package-lifecycle", "abort-upgrade"])

        self.harness.clear()
        result = self.harness.run(
            "tractanda.postinst.in", "abort-remove", "in-favour", "conflictor", "1.2", helper=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.harness.records(), [{"program": "python-hook", "args": ["-I", "-", "postrm"]}])

    def test_prerm_conflict_remove_validates_literal_and_routes_owned_removal(self):
        for helper in (True, False):
            self.harness.clear()
            result = self.harness.run(
                "tractanda.prerm", "remove", "in-favour", "conflictor", "1.2", helper=helper)
            self.assertEqual(result.returncode, 0, (helper, result.stderr))
            records = self.harness.records()
            if helper:
                self.assertEqual(records[0]["args"], ["-I", "-", "verify-helper", str(self.harness.helper)])
                self.assertEqual(records[1]["args"], ["--package-lifecycle", "remove"])
            else:
                self.assertEqual(records, [{"program": "python-hook", "args": ["-I", "-", "remove"]}])
        for args in (("remove", "in-favour"), ("remove", "wrong", "pkg", "1.2"),
                     ("remove", "in-favour", "pkg", "1.2", "extra")):
            self.harness.clear()
            result = self.harness.run("tractanda.prerm", *args)
            self.assertNotEqual(result.returncode, 0, args)
            self.assertEqual(self.harness.records(), [])

    def test_postrm_uses_only_mocked_fallback_and_manager_reload(self):
        for args in (
            ("remove",), ("purge",), ("failed-upgrade", "old", "new"),
            ("abort-install",), ("abort-install", "old", "new"),
            ("abort-upgrade", "old", "new"), ("upgrade", "new"),
            ("disappear", "overwriter", "version"),
        ):
            self.harness.clear()
            result = self.harness.run("tractanda.postrm", *args, helper=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            records = self.harness.records()
            if args[0] == "upgrade":
                self.assertEqual(records, [])
            elif args[0] == "disappear":
                self.assertEqual(records, [{"program": "python-hook", "args": ["-I", "-", "uuidd-remove"]}])
            else:
                self.assertEqual(records[0]["args"], ["-I", "-", "postrm-remove" if args[0] in ("remove", "purge") else "postrm"])
                self.assertEqual(records[1], {"program": "systemctl", "args": ["daemon-reload"]})

    def test_postrm_same_17_abort_binds_the_incoming_manifest(self):
        version = "0.1.0~poc.17-1"
        for arguments, expected in (
            (("abort-upgrade", version, version), ["layout17-reinstall-abort", "c" * 64]),
            (("abort-upgrade", "0.1.0~poc.16.2-1", version), ["layout17-abort-upgrade"]),
            (("abort-upgrade", version, "0.1.0~poc.17-2"), ["postrm"]),
            (("failed-upgrade", version, version), ["postrm"]),
        ):
            self.harness.clear()
            result = self.harness.run("tractanda.postrm", *arguments, helper=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.harness.records()[0]["args"], ["-I", "-", *expected])

    def test_postrm_corrected_patch_abort_routes_only_exact_dpkg_pairs(self):
        corrected = "0.1.0~poc.17.1-1"
        for old, new, expected in (
            ("0.1.0~poc.17-1", corrected, ["layout17-compatible-abort", "c" * 64]),
            ("0.1.0~poc.16.2-1", corrected, ["layout17-abort-upgrade"]),
            (corrected, corrected, ["layout17-reinstall-abort", "c" * 64]),
            ("0.1.0~poc.17-1", "0.1.0~poc.17.2-1", ["postrm"]),
        ):
            self.harness.clear()
            result = self.harness.run("tractanda.postrm", "abort-upgrade", old, new,
                                      helper=False, layout17_version=corrected)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.harness.records()[0]["args"], ["-I", "-", *expected])

    def test_postrm_skips_nonessential_cleanup_if_python_or_systemctl_is_absent(self):
        for missing in (("/usr/bin/python3",), ("/usr/bin/systemctl",)):
            self.harness.clear()
            result = self.harness.run("tractanda.postrm", "remove", missing=missing)
            self.assertEqual(result.returncode, 0, (missing, result.stderr))
            self.assertEqual(self.harness.records(), [])

    def test_unexpected_arguments_and_helper_failure_are_never_masked(self):
        invalid = self.harness.run("tractanda.prerm", "unknown")
        self.assertNotEqual(invalid.returncode, 0)
        self.assertEqual(self.harness.records(), [])

        self.harness.clear()
        self.harness.env["MOCK_HELPER_EXIT"] = "42"
        failed = self.harness.run("tractanda.prerm", "remove")
        self.assertEqual(failed.returncode, 42)
        self.assertEqual(len(self.harness.records()), 2)
        self.assertEqual(self.harness.records()[0]["args"][2], "verify-helper")
        self.assertEqual(self.harness.records()[1]["args"][-1], "remove")


class SystemctlInventoryTests(unittest.TestCase):
    def test_exact_empty_unit_file_inventory_exit_one_is_empty(self):
        fallback = module_from_template()
        args = ("list-unit-files", "--no-legend", "--no-pager", "tractanda-*.service")
        result = subprocess.CompletedProcess([], 1, "", "")
        with mock.patch.object(fallback.subprocess, "run", return_value=result):
            self.assertEqual(fallback.listed_units(args), set())

    def test_other_error_output_status_or_query_cannot_claim_empty_inventory(self):
        fallback = module_from_template()
        args = ("list-unit-files", "--no-legend", "--no-pager", "tractanda-*.service")
        for query, code, out, err in (
            (args, 1, "tractanda-server-other.service disabled\n", ""),
            (args, 1, "", "Failed to connect to bus"),
            (args, 1, "\n", ""),
            (args, 2, "", ""),
            (("list-units", "--all", "--no-legend", "--plain", "--full", "--type=service", "tractanda-*.service"), 1, "", ""),
            (("list-unit-files", "--no-legend", "--no-pager", "other-*.service"), 1, "", ""),
        ):
            with self.subTest(query=query, code=code, out=out, err=err), \
                    mock.patch.object(fallback.subprocess, "run", return_value=subprocess.CompletedProcess([], code, out, err)), \
                    self.assertRaises(SystemExit):
                fallback.run_systemctl(query)


class Layout17ControlInspectorTests(unittest.TestCase):
    def archive(self, manifest_hash='a' * 64, tamper=False):
        data = b'fixture ELF bytes'
        row = {'path': 'bin/tractanda-layout17', 'size': len(data), 'mode': 0o755,
               'sha256': hashlib.sha256(data).hexdigest()}
        inventory = {'profile': 'tractanda.layout17-control.v1', 'manifestSHA256': manifest_hash, 'arch': 'amd64',
                     'files': [row], 'privateSONAMEs': {}, 'systemLibraries': {
                         'libsqlite3.so.0': {'package': 'libsqlite3-0', 'version': '3.46.1-7'},
                         'ld-linux-x86-64.so.2': {'package': 'libc6', 'version': '2.41-12'},
                     }}
        raw = io.BytesIO()
        with tarfile.open(fileobj=raw, mode='w') as tar:
            for name, value, mode in [('layout17-control.json', json.dumps(inventory).encode(), 0o644),
                                      (row['path'], b'x' + data[1:] if tamper else data, 0o755)]:
                entry = tarfile.TarInfo(name); entry.size = len(value); entry.mode = mode
                tar.addfile(entry, io.BytesIO(value))
        return raw.getvalue(), data

    def test_archive_manifest_and_file_hashes_precede_execution(self):
        m = module_from_template(); incoming = {'arch': 'x86_64', 'manifestSHA256': 'a' * 64}
        with tempfile.TemporaryDirectory() as tmp:
            path = str(Path(tmp) / 'layout17-inspector.tar')
            for defect in (None, 'archive', 'manifest', 'file'):
                raw, expected = self.archive(manifest_hash='b' * 64 if defect == 'manifest' else 'a' * 64,
                                             tamper=defect == 'file')
                digest = 'c' * 64 if defect == 'archive' else hashlib.sha256(raw).hexdigest()
                with self.subTest(defect=defect), mock.patch.object(m, 'read_private_regular', return_value=raw), \
                        mock.patch.object(m, 'layout17_check_loader') as verify:
                    if defect is None:
                        with m.layout17_control_inspector(path, digest, incoming) as inspector:
                            self.assertEqual(Path(inspector).read_bytes(), expected)
                            self.assertEqual(Path(inspector).stat().st_mode & 0o777, 0o755)
                            verify.assert_called_once()
                        self.assertFalse(Path(inspector).exists())
                    else:
                        with self.assertRaises(SystemExit), m.layout17_control_inspector(path, digest, incoming):
                            self.fail('Unverified inspector was admitted')
                        verify.assert_not_called()

    def test_old_recovery_uses_original_descriptor_and_refuses_new_reader_barrier(self):
        m = module_from_template()
        original = {'version': '0.1.0-poc.16.2', 'manifestSHA256': 'a' * 64}
        targets = {'one': {'store': '/fixture/private/one'}}
        factory = tempfile.TemporaryDirectory
        with factory() as tmp:
            def run(args, **kwargs):
                self.assertEqual(args[:4], ['/old/setup', '--package-lifecycle', 'configure', '--descriptor'])
                path = Path(args[4]); self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                self.assertEqual(json.loads(path.read_text()), original)
                return subprocess.CompletedProcess(args, 0)
            with mock.patch.object(m.pwd, 'getpwnam', return_value=SimpleNamespace(pw_uid=123)), \
                    mock.patch.object(m, 'verify_helper') as verified, \
                    mock.patch.object(m.tempfile, 'TemporaryDirectory', side_effect=lambda **_: factory(dir=tmp)), \
                    mock.patch.object(m, 'layout17_store_file', return_value=b'{"minimumReaderLevel":18}') as fence, \
                    mock.patch.object(m.subprocess, 'run', side_effect=run) as process:
                m.layout17_restore_original('/old/setup', original, targets)
                verified.assert_called_once_with(['verify-helper', '/old/setup'])
                process.assert_called_once()
                fence.return_value = b'{"minimumReaderLevel":20}'
                process.reset_mock()
                with self.assertRaises(SystemExit): m.layout17_restore_original('/old/setup', original, targets)
                process.assert_not_called()

    def test_abort_accepts_authentic_committed_old_payload_without_stopping_it(self):
        m = module_from_template(); raw = b'{"version":"0.1.0-poc.16.2"}'
        state = {'profile': 'tractanda.package-transaction.v1', 'operationID': 'fixture',
                 'phase': 'committed', 'instances': [], 'startupPermitted': [],
                 'incoming': {'version': '0.1.0-poc.16.2', 'manifestSHA256': hashlib.sha256(raw).hexdigest()}}
        def read(path, *args, **kwargs): return json.dumps(state).encode() if path == m.STATE else raw
        with mock.patch.object(m.os, 'geteuid', return_value=0), \
                mock.patch.object(m, 'read_private_regular', side_effect=read), \
                mock.patch.object(m, 'verify_helper', return_value=0) as verify, \
                mock.patch.object(m, 'safe_state') as stop_check:
            self.assertEqual(m.fallback(['layout17-abort-upgrade']), 0)
            verify.assert_called_once_with(['verify-helper', m.ACTIVE + '/bin/tractanda-setup'])
            stop_check.assert_not_called()
            state['incoming']['manifestSHA256'] = 'b' * 64
            verify.reset_mock()
            with self.assertRaises(SystemExit): m.fallback(['layout17-abort-upgrade'])
            verify.assert_not_called()

    def test_exact_17_reinstall_abort_keeps_committed_services_running(self):
        m = module_from_template()
        raw = b'{"version":"0.1.0-poc.17"}'
        digest = hashlib.sha256(raw).hexdigest()
        state = {"profile": "tractanda.package-transaction.v1", "operationID": "fixture",
                 "phase": "committed", "instances": [], "startupPermitted": [],
                 "incoming": {"version": "0.1.0-poc.17", "manifestSHA256": digest}}
        def read(path, *args, **kwargs):
            return json.dumps(state).encode() if path == m.STATE else raw
        with mock.patch.object(m.os, "geteuid", return_value=0), \
                mock.patch.object(m.os, "lstat"), \
                mock.patch.object(m, "read_private_regular", side_effect=read), \
                mock.patch.object(m, "verify_helper", return_value=0) as verify, \
                mock.patch.object(m, "safe_state", side_effect=SystemExit("writer lock is held")) as stop_check:
            self.assertEqual(m.fallback(["layout17-reinstall-abort", digest]), 0)
            verify.assert_called_once_with(["verify-helper", m.ACTIVE + "/bin/tractanda-setup"])
            stop_check.assert_not_called()
            for argument, change in (("a" * 64, {}), (digest, {"phase": "awaitingUnpack"}),
                                     (digest, {"startupPermitted": ["fixture"]}),
                                     (digest, {"owner": {"pid": 10}})):
                verify.reset_mock()
                with self.subTest(argument=argument, change=change), mock.patch.dict(state, change):
                    with self.assertRaisesRegex(SystemExit, "writer lock is held"):
                        m.fallback(["layout17-reinstall-abort", argument])
                    verify.assert_not_called()

    def test_loader_closure_checks_sqlite_and_rejects_shadowing(self):
        m = module_from_template(); stage = '/verified/stage'
        loader = '/lib64/ld-linux-x86-64.so.2'; real_loader = '/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2'
        sqlite = '/usr/lib/x86_64-linux-gnu/libsqlite3.so.0'
        inventory = {'arch': 'amd64', 'privateSONAMEs': {'libSwiftFixture.so': 'lib/libSwiftFixture.so'},
                     'systemLibraries': {'libsqlite3.so.0': {'package': 'libsqlite3-0', 'version': '3.46.1-7'},
                                         'ld-linux-x86-64.so.2': {'package': 'libc6', 'version': '2.41-12'}}}
        for shadow in (False, True):
            def command(args):
                if args[1] == '--list':
                    private = '/usr/local/lib/libSwiftFixture.so' if shadow else stage + '/lib/libSwiftFixture.so'
                    out = (f'linux-vdso.so.1 (0xabc)\nlibSwiftFixture.so => {private} (0xabc)\n'
                           f'libsqlite3.so.0 => {sqlite} (0xabc)\n{loader} (0xabc)\n')
                elif args[1] == '--search':
                    out = ('libsqlite3-0:amd64: ' if args[2] == sqlite else 'libc6:amd64: ') + args[3] + '\n'
                elif args[1] == '-W':
                    out = 'install ok installed\t9.0\tamd64\n'
                else:
                    self.assertEqual(args[1], '--compare-versions'); out = ''
                return subprocess.CompletedProcess(args, 0, out, '')
            with mock.patch.object(m, 'layout17_native_command', side_effect=command), \
                    mock.patch.object(m, 'root_directory_chain'), \
                    mock.patch.object(m.os, 'lstat', return_value=SimpleNamespace(st_uid=0, st_mode=stat.S_IFREG | 0o644)), \
                    mock.patch.object(m.os.path, 'realpath', side_effect=lambda p: real_loader if p == loader else p):
                if shadow:
                    with self.assertRaises(SystemExit): m.layout17_check_loader(stage, inventory)
                else:
                    m.layout17_check_loader(stage, inventory)

class Layout17PreStopTests(unittest.TestCase):
    def check(self, defect=None, corrected=False):
        m = module_from_template()
        capabilities = ["tractanda.physical-layout.flat-items.v1", "tractanda.message-items.v1"]
        before = {"profile": "tractanda.canonical-formats.v1", "readerLevel": 18, "writerLevel": 18,
                  "read": [1, 2], "write": [2], "capabilities": ["tractanda.personal-workgroup.v1"],
                  "writeCapabilities": ["tractanda.personal-workgroup.v1"]}
        after = dict(before, readerLevel=20, writerLevel=20,
                     capabilities=sorted(before["capabilities"] + capabilities),
                     writeCapabilities=sorted(before["writeCapabilities"] + capabilities))
        previous = {"version": "0.1.0-poc.16.2", "arch": "x86_64", "canonicalFormats": before}
        incoming = dict(previous, version="0.1.0-poc.17", canonicalFormats=after,
                        manifestSHA256="b" * 64, upgrade="coordinated-maintenance")
        if corrected:
            incoming.update(version="0.1.0-poc.17.1", upgrade="compatible")
        if defect in ("provenance", "changedStoredSemantics", "malformedProvenance"):
            document = json.loads((DEBIAN / "components/amd64/documents.json").read_text())["documentExtraction"]
            previous["documentExtraction"] = document
            changed = copy.deepcopy(document)
            changed["identity"].update(converter="new.build-" + "f" * 64, model="historical/model.v2",
                                       modelRevision="d" * 64, runtimeRevision="e" * 40)
            if defect == "changedStoredSemantics": changed["identity"]["preprocessing"] = "opaque-rgb2048-17tiles-v1"
            if defect == "malformedProvenance": changed["identity"]["converter"] = "bad\nprovenance"
            incoming["documentExtraction"] = changed
        store_id = "00000000-0000-1000-8000-000000000001"
        replica_id = "00000000-0000-1000-8000-000000000002"
        profile = {"profile": "tractanda.personal-workgroup.v1", "storeID": store_id, "replicaID": replica_id}
        fence = {"storeID": store_id, "minimumReaderLevel": 18}
        membership = {"profile": "tractanda.personal-membership.v1", "storeID": store_id, "members": [{}, {}]}
        encode = lambda value: json.dumps(value, sort_keys=True).encode()
        raw_fence, raw_membership = encode(fence), encode(membership)
        digest = lambda raw: __import__("hashlib").sha256(raw).hexdigest()
        receipt = {"version": 1, "instance": "a", "release": m.ACTIVE, "manifestSHA256": "a" * 64,
                   "initialized": True, "state": "active", "store": "/store/a"}
        intent = {"profile": "tractanda.layout17-prepare.v1", "mode": "administrator-coordinated",
                  "instance": "a", "storePath": "/store/a", "storeID": store_id, "replicaID": replica_id,
                  "oldManifestSHA256": "a" * 64, "newManifestSHA256": "b" * 64,
                  "membershipDigest": digest(raw_membership), "readerRequirementSHA256": digest(raw_fence),
                  "acknowledgedAllMembersUpgradedBeforeStart": True}
        if defect == "removed":
            receipt.update(state="removed", initialized=False, release="retired", manifestSHA256="d" * 64)
        if defect == "wrongCandidate": intent["newManifestSHA256"] = "c" * 64
        if defect == "changedMembership": intent["membershipDigest"] = "c" * 64
        if defect == "changedFence": intent["readerRequirementSHA256"] = "c" * 64
        if defect == "extraSemantics": after["capabilities"].append("unrelated")
        def private(path, *args):
            return encode(intent if "layout17-intents" in path else receipt)
        def store_file(store, name, owner):
            if defect == "removed": raise AssertionError("Removed store must remain unread")
            return {".tractanda-personal-profile.json": encode(profile), "canonical-reader.json": raw_fence,
                    ".personal-membership.json": raw_membership}[name]
        def exists(path):
            if path == m.RECEIPTS: return True
            if "layout17-intents" in path: return defect != "missingIntent"
            if "layout17-journals" in path: return defect == "oldJournal"
            if path.endswith(".personal-membership.json"): return defect != "standalone"
            return defect == "pending" and path.endswith(".personal-membership.pending.json")
        with mock.patch.object(m, "root_directory_chain"), mock.patch.object(m.os, "listdir", return_value=["a.json"]), \
                mock.patch.object(m, "receipt_instance_paths"), mock.patch.object(m, "read_private_regular", side_effect=private), \
                mock.patch.object(m, "layout17_store_file", side_effect=store_file), \
                mock.patch.object(m, "inspect_stopped_instance"), \
                mock.patch.object(m.pwd, "getpwnam", return_value=SimpleNamespace(pw_uid=123)), \
                mock.patch.object(m.os.path, "lexists", side_effect=exists), \
                mock.patch.object(m.subprocess, "run") as process:
            m.layout17_pre_stop(previous, "a" * 64, incoming)
            process.assert_not_called()  # This gate itself cannot stop or execute a helper.

    def test_matching_cluster_intent_and_standalone_need_no_mutation(self):
        self.check()
        self.check("standalone")
        self.check("removed")
        self.check("provenance")

    def test_document_provenance_changes_preserve_known_semantics_without_mutating_descriptor(self):
        m = module_from_template()
        original = json.loads((DEBIAN / "components/amd64/documents.json").read_text())["documentExtraction"]
        changed = copy.deepcopy(original)
        changed["identity"].update(converter="independent.build-" + "d" * 64, model="historical/model.v2",
                                   modelRevision="e" * 64, runtimeRevision="f" * 40)
        snapshot = copy.deepcopy(changed)
        self.assertEqual(m.layout17_document_semantics(original), m.layout17_document_semantics(changed))
        self.assertEqual(changed, snapshot)
        for key, value in (("parser", "unknown-parser"), ("preprocessing", "unknown-profile"),
                           ("converter", "bad\nidentifier"), ("modelRevision", "A" * 40),
                           ("runtimeRevision", "f" * 39)):
            bad = copy.deepcopy(changed); bad["identity"][key] = value
            with self.subTest(key=key), self.assertRaises(SystemExit): m.layout17_document_semantics(bad)
        legacy = copy.deepcopy(changed); legacy["identity"]["preprocessing"] = "opaque-rgb2048-17tiles-v1"
        self.assertNotEqual(m.layout17_document_semantics(original), m.layout17_document_semantics(legacy))
        for bad in (dict(changed, unknown="schema"), dict(changed, workerProtocol="unknown.v2")):
            with self.assertRaises(SystemExit): m.layout17_document_semantics(bad)

    def test_unprepared_changed_or_pending_cluster_refuses_before_any_stop(self):
        for defect in ("missingIntent", "wrongCandidate", "changedMembership", "changedFence", "pending", "extraSemantics", "changedStoredSemantics", "malformedProvenance"):
            with self.subTest(defect=defect), self.assertRaises(SystemExit): self.check(defect)

    def test_corrected_bridge_refuses_old_intent_or_journal_before_any_stop(self):
        self.check(corrected=True)
        for defect in ("wrongCandidate", "oldJournal"):
            with self.subTest(defect=defect), self.assertRaises(SystemExit):
                self.check(defect, corrected=True)


class Layout17CompatiblePatchTests(unittest.TestCase):
    def test_only_released_current_format_or_exact_update_retry_reaches_old_helper(self):
        m = module_from_template()
        caps = ["tractanda.message-items.v1", "tractanda.physical-layout.flat-items.v1"]
        formats = {"readerLevel": 20, "writerLevel": 20, "capabilities": caps}
        manifest = {"version": m.LAYOUT17_FIRST, "arch": "x86_64", "canonicalFormats": formats}
        raw = json.dumps(manifest).encode()
        digest = hashlib.sha256(raw).hexdigest()
        original = dict(manifest, manifestSHA256=digest, upgrade="coordinated-maintenance")
        incoming = dict(original, version=m.LAYOUT17_CORRECTED, manifestSHA256="c" * 64, upgrade="compatible")
        state = {"profile": "tractanda.package-transaction.v1", "operationID": "fixture",
                 "phase": "committed", "instances": [], "startupPermitted": [], "incoming": original}
        marker = {"profile": "tractanda.physical-layout.v1", "layout": "flat-items-visible-attachments.v1",
                  "recordEncoding": "message-v1"}
        store_id = "00000000-0000-1000-8000-000000000001"
        replica_id = "00000000-0000-1000-8000-000000000002"
        fence = {"profile": "tractanda.canonical-reader.v1", "minimumReaderLevel": 20, "capabilities": caps,
                 "storeID": store_id}
        profile = {"profile": "tractanda.personal-workgroup.v1", "storeID": store_id, "replicaID": replica_id}
        journal = {"phase": "moving", "profile": "tractanda.layout17-journal.v1", "storeID": store_id,
                   "replicaID": replica_id, "originalRequirementSHA256": "d" * 64}
        receipts = {"a": {"state": "active", "initialized": True, "store": "/store/a", "manifestSHA256": digest}}

        def read(path, *args, **kwargs):
            if "layout17-journals" in path:
                return json.dumps(journal).encode()
            return json.dumps(state).encode() if path == m.STATE else raw

        def file(_store, name, _uid):
            return json.dumps({"canonical-layout.json": marker, "canonical-reader.json": fence,
                               ".tractanda-personal-profile.json": profile}[name]).encode()

        with mock.patch.object(m, "read_private_regular", side_effect=read), \
                mock.patch.object(m, "read_receipts", return_value=receipts) as custody, \
                mock.patch.object(m, "layout17_store_file", side_effect=file), \
                mock.patch.object(m.pwd, "getpwnam", return_value=SimpleNamespace(pw_uid=123)), \
                mock.patch.object(m.os.path, "lexists", return_value=False), \
                mock.patch.object(m.subprocess, "run") as process:
            m.layout17_replacement_pre_stop(incoming)
            custody.assert_called_once_with(set(), quiescent=False)
            for changes in ({"phase": "awaitingUnpack"}, {"owner": {"pid": 10}}):
                with mock.patch.dict(state, changes), self.assertRaises(SystemExit):
                    m.layout17_replacement_pre_stop(incoming)
            with mock.patch.dict(state, phase="awaitingUnpack", original=original, incoming=incoming):
                m.layout17_replacement_pre_stop(incoming)
            for name in ("layout17-intents/a.json", "canonical-layout.pending.json"):
                with mock.patch.object(m.os.path, "lexists", side_effect=lambda path: path.endswith(name)), \
                        self.assertRaises(SystemExit):
                    m.layout17_replacement_pre_stop(incoming)
            with mock.patch.dict(fence, minimumReaderLevel=19), self.assertRaises(SystemExit):
                m.layout17_replacement_pre_stop(incoming)
            with (mock.patch.object(m.os.path, "lexists", side_effect=lambda path: "layout17-journals" in path),
                  mock.patch.object(m, "root_directory_chain")):
                with self.assertRaisesRegex(SystemExit, "retained .17 migration journal"):
                    m.layout17_replacement_pre_stop(incoming)
                with mock.patch.dict(journal, phase="complete"):
                    m.layout17_replacement_pre_stop(incoming)
            process.assert_not_called()

    def test_corrected_abort_preserves_the_authenticated_running_old_artifact(self):
        m = module_from_template()
        raw = b'{"version":"0.1.0-poc.17"}'
        digest = hashlib.sha256(raw).hexdigest()
        state = {"profile": "tractanda.package-transaction.v1", "operationID": "fixture",
                 "phase": "committed", "instances": [], "startupPermitted": [],
                 "incoming": {"version": m.LAYOUT17_FIRST, "manifestSHA256": digest}}
        with mock.patch.object(m.os, "geteuid", return_value=0), \
                mock.patch.object(m, "read_private_regular", side_effect=lambda path, *a, **k:
                                  json.dumps(state).encode() if path == m.STATE else raw), \
                mock.patch.object(m, "verify_helper", return_value=0) as verify, \
                mock.patch.object(m, "safe_state", side_effect=SystemExit("writer lock is held")) as quiescent:
            self.assertEqual(m.fallback(["layout17-compatible-abort", "c" * 64]), 0)
            verify.assert_called_once_with(["verify-helper", m.ACTIVE + "/bin/tractanda-setup"])
            quiescent.assert_not_called()


class LegacyBootstrapTests(unittest.TestCase):
    old = "0.1.0~poc.15-1+personal.1793193134.fdaf8ff8b393"

    def invoke(self, *, version=None, status="install reinstreq half-installed", query_version=None,
               stop_code=0, state_change=None, receipt_digest=None,
               verify_failure=False, descriptor_failure=False, quiescence_failure=False, incoming_version=None,
               early_inspection_failure=False, late_inspection_failure=False):
        m = module_from_template()
        version = self.old if version is None else version
        bundle_version = m.LEGACY_DEBIAN_VERSIONS.get(version, "0.1.0-poc.15")
        raw = json.dumps({"version": bundle_version}).encode()
        digest = __import__("hashlib").sha256(raw).hexdigest()
        original = {"manifestSHA256": digest, "version": bundle_version}
        state = {"phase": "quiesced", "original": copy.deepcopy(original), "incoming": None,
                 "instances": [{"name": "one", "originalManifestSHA256": digest}],
                 "startupPermitted": [], "owner": None}
        if state_change: state_change(state)
        incoming = json.loads(DESCRIPTOR)
        if incoming_version is not None: incoming["version"] = incoming_version
        elif version == "0.1.0~poc.16.2-1": incoming["version"] = "0.1.0-poc.17"
        calls, writes = [], []
        helper = m.ACTIVE + "/bin/tractanda-setup"
        def verified(arguments):
            calls.append("verify-old-helper")
            if verify_failure: raise SystemExit("untrusted old helper")
        def descriptor(path):
            calls.append("real-descriptor")
            if descriptor_failure: raise SystemExit("bad actual descriptor")
            return incoming
        def process(argv, **kwargs):
            if argv[0] == "/usr/bin/dpkg-query":
                calls.append("actual-dpkg-state")
                return subprocess.CompletedProcess(argv, 0, status + "\n" + (query_version or version) + "\n", "")
            self.assertEqual(argv, [helper, "--package-lifecycle", "prerm-upgrade"])
            self.assertEqual(writes, [])  # Old SDK runs before the new descriptor is stored.
            calls.append("old-stop-only")
            return subprocess.CompletedProcess(argv, stop_code)
        def quiescent():
            calls.append("quiescence-and-writer-locks")
            if quiescence_failure: raise SystemExit("active unit or writer")
            return state
        def write(value):
            calls.append("atomic-expected-binding")
            writes.append(copy.deepcopy(value))
        def inspect(inspector, targets, quiescent=False):
            calls.append("deep-inspect-quiescent" if quiescent else "deep-inspect-live")
            if (quiescent and late_inspection_failure) or (not quiescent and early_inspection_failure):
                raise SystemExit("deep inspector refused")
        patches = (
            mock.patch.object(m.os, "geteuid", return_value=0), \
            mock.patch.object(m, "verify_helper", side_effect=verified), \
            mock.patch.object(m, "validate_descriptor", side_effect=descriptor), \
            mock.patch.object(m, "read_private_regular", return_value=raw), \
            mock.patch.object(m.subprocess, "run", side_effect=process), \
            mock.patch.object(m, "safe_state", side_effect=quiescent), \
            mock.patch.object(m, "read_receipts", return_value={"one": {"manifestSHA256": receipt_digest or digest}}), \
            mock.patch.object(m, "write_state", side_effect=write), \
            mock.patch.object(m, "layout17_pre_stop", side_effect=lambda *args: calls.append("layout17-prestop") or {}), \
            mock.patch.object(m, "layout17_control_inspector", return_value=__import__("contextlib").nullcontext("/verified/inspector")), \
            mock.patch.object(m, "layout17_inspect_targets", side_effect=inspect), \
            mock.patch.object(m, "layout17_restore_original", side_effect=lambda *args: calls.append("restore-authentic-old")),
        )
        from contextlib import ExitStack
        with ExitStack() as stack:
            for patch in patches: stack.enter_context(patch)
            try:
                arguments = ["legacy-preinst-helper", helper, "/actual-descriptor", version]
                if version == "0.1.0~poc.16.2-1": arguments += ["/actual/layout17-inspector.tar", "b" * 64]
                result = m.fallback(arguments)
                failure = None
            except SystemExit as error:
                result, failure = None, error
        return result, failure, calls, writes, original, incoming

    def test_known_old_stop_precedes_real_expected_binding_and_preserves_original(self):
        for version in module_from_template().LEGACY_DEBIAN_VERSIONS:
            result, failure, calls, writes, original, incoming = self.invoke(version=version)
            self.assertIsNone(failure)
            self.assertEqual(result, 0)
            expected = ["verify-old-helper", "real-descriptor"]
            if version == "0.1.0~poc.16.2-1": expected.append("layout17-prestop")
            expected += ["actual-dpkg-state"]
            if version == "0.1.0~poc.16.2-1": expected.append("deep-inspect-live")
            expected += ["old-stop-only", "quiescence-and-writer-locks"]
            if version == "0.1.0~poc.16.2-1": expected.append("deep-inspect-quiescent")
            expected.append("atomic-expected-binding")
            self.assertEqual(calls, expected)
            self.assertEqual(len(writes), 1)
            self.assertEqual(writes[0]["original"], original)
            self.assertEqual(writes[0]["incoming"], incoming)
            self.assertEqual(writes[0]["phase"], "awaitingUnpack")
            self.assertEqual(writes[0]["startupPermitted"], [])
            self.assertIsNone(writes[0]["owner"])

    def test_layout17_rejects_before_stop_or_restores_old_intent_after_quiescent_refusal(self):
        version = "0.1.0~poc.16.2-1"
        _, failure, calls, writes, _, _ = self.invoke(version=version, early_inspection_failure=True)
        self.assertIsNotNone(failure)
        self.assertEqual(calls[-1], "deep-inspect-live")
        self.assertNotIn("old-stop-only", calls)
        self.assertEqual(writes, [])
        _, failure, calls, writes, _, _ = self.invoke(version=version, late_inspection_failure=True)
        self.assertIsNotNone(failure)
        self.assertEqual(calls[-3:], ["quiescence-and-writer-locks", "deep-inspect-quiescent", "restore-authentic-old"])
        self.assertEqual(writes, [])

    def test_layout17_requires_authentic16_2_before_legacy_stop(self):
        _, failure, calls, writes, _, _ = self.invoke(incoming_version="0.1.0-poc.17")
        self.assertIsNotNone(failure)
        self.assertNotIn("old-stop-only", calls)
        self.assertEqual(writes, [])

    def test_unknown_old_version_cannot_enter_legacy_binding(self):
        _, failure, calls, writes, _, _ = self.invoke(version="0.1.0~poc.99-1")
        self.assertIsNotNone(failure); self.assertEqual(calls, []); self.assertEqual(writes, [])

    def test_wrong_dpkg_version_or_nonupgrade_state_refuses_before_old_stop(self):
        for options in ({"query_version": "other"}, {"status": "install ok installed"},
                        {"status": "install ok half-installed"},
                        {"status": "deinstall reinstreq half-installed"}):
            _, failure, calls, writes, _, _ = self.invoke(**options)
            self.assertIsNotNone(failure); self.assertNotIn("old-stop-only", calls); self.assertEqual(writes, [])

    def test_untrusted_old_helper_cannot_execute_or_bind(self):
        _, failure, calls, writes, _, _ = self.invoke(verify_failure=True)
        self.assertIsNotNone(failure); self.assertEqual(calls, ["verify-old-helper"]); self.assertEqual(writes, [])

    def test_bad_real_descriptor_cannot_execute_old_helper_or_bind(self):
        _, failure, calls, writes, _, _ = self.invoke(descriptor_failure=True)
        self.assertIsNotNone(failure); self.assertNotIn("old-stop-only", calls); self.assertEqual(writes, [])

    def test_old_stop_failure_never_binds_expected_payload(self):
        _, failure, calls, writes, _, _ = self.invoke(stop_code=42)
        self.assertEqual(failure.code, 42); self.assertNotIn("quiescence-and-writer-locks", calls); self.assertEqual(writes, [])

    def test_active_unit_or_writer_refusal_never_binds(self):
        _, failure, _, writes, _, _ = self.invoke(quiescence_failure=True)
        self.assertIsNotNone(failure); self.assertEqual(writes, [])

    def test_original_receipt_or_other_pending_payload_mismatch_never_binds(self):
        changes = [lambda s: s.update(phase="failed"),
                   lambda s: s["original"].update(manifestSHA256="d" * 64),
                   lambda s: s["original"].update(version="other"),
                   lambda s: s["instances"][0].update(originalManifestSHA256="d" * 64),
                   lambda s: s.update(incoming={"manifestSHA256": "d" * 64})]
        for change in changes:
            _, failure, _, writes, _, _ = self.invoke(state_change=change)
            self.assertIsNotNone(failure); self.assertEqual(writes, [])
        _, failure, _, writes, _, _ = self.invoke(receipt_digest="d" * 64)
        self.assertIsNotNone(failure); self.assertEqual(writes, [])


class FallbackUnitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tractanda-fallback-test-")
        self.root = Path(self.temp.name)
        self.fallback = module_from_template()
        self.fallback.STATE = str(self.root / "etc/tractanda/package-transaction.json")
        self.fallback.RECEIPTS = str(self.root / "etc/tractanda/receipts")
        self.fallback.ACTIVE = str(self.root / "opt/tractanda/current")
        self.fallback.UNIT_DIR = str(self.root / "etc/systemd/system")
        self.fallback.run_systemctl = lambda arguments: ""
        self.descriptor = self.root / "incoming.json"
        self.descriptor.write_text(DESCRIPTOR)

    def tearDown(self):
        self.temp.cleanup()

    def invoke_as_root(self, arguments):
        def read_owned_fixture(path, maximum=None, private=True):
            maximum = self.fallback.MAX_BYTES if maximum is None else maximum
            data = Path(path).read_bytes()
            if not data or len(data) > maximum:
                raise SystemExit("mock bounded-file refusal")
            return data
        with mock.patch.object(self.fallback.os, "geteuid", return_value=0), \
             mock.patch.object(self.fallback, "root_uid", return_value=os.getuid()), \
             mock.patch.object(self.fallback, "read_private_regular", side_effect=read_owned_fixture):
            return self.fallback.fallback(arguments)

    def test_preinst_helper_validates_unchanged_strict_descriptor(self):
        with mock.patch.object(self.fallback, "verify_helper") as verify:
            self.assertEqual(self.invoke_as_root(["preinst-helper", "/fixed/setup", str(self.descriptor)]), 0)
            verify.assert_called_once_with(["verify-helper", "/fixed/setup"])
        for key in ("modelProvisioningManifestPath", "modelProvisioningManifestSHA256", "modelProvisioningManifest"):
            descriptor = json.loads(DESCRIPTOR)
            descriptor[key] = "unsupported"
            self.descriptor.write_text(json.dumps(descriptor))
            with mock.patch.object(self.fallback, "verify_helper"), self.assertRaises(SystemExit):
                self.invoke_as_root(["preinst-helper", "/fixed/setup", str(self.descriptor)])

    def test_layout_selection_requires_single_protected_installation(self):
        m = self.fallback
        m.INSTALLATION = str(self.root / "opt/tractanda/var/lib/tractanda/Installation")
        m.LEGACY_ROOT = str(self.root / "etc/tractanda")
        m.CONFIG_ROOT = str(self.root / "opt/tractanda/etc/tractanda")
        legacy = Path(m.LEGACY_ROOT); legacy.mkdir(parents=True)
        with mock.patch.object(m, "root_directory_chain") as custody:
            self.assertEqual(m.select_layout(), "current")
            (legacy / "receipts").mkdir()
            self.assertEqual(m.select_layout(), "legacy")
            custody.assert_called_with(str(legacy))
            current = Path(m.INSTALLATION); current.mkdir(parents=True)
            (current / "receipts").mkdir()
            with self.assertRaises(SystemExit): m.select_layout()
            (legacy / "receipts").rmdir(); legacy.rmdir()
            legacy.symlink_to(m.CONFIG_ROOT)
            self.assertEqual(m.select_layout(), "current")
            legacy.unlink(); legacy.symlink_to("/wrong")
            with self.assertRaises(SystemExit): m.select_layout()

    def test_interrupted_layout_journal_selects_protected_proof_and_resumes(self):
        m = self.fallback
        m.INSTALLATION = str(self.root / "opt/tractanda/var/lib/tractanda/Installation")
        m.LEGACY_ROOT = str(self.root / "etc/tractanda")
        m.CONFIG_ROOT = str(self.root / "opt/tractanda/etc/tractanda")
        current = Path(m.INSTALLATION); current.mkdir(parents=True)
        (current / "receipts").mkdir()
        marker = current / "layout-migration.json"
        value = {"version": 1, "platform": "linux", "phase": "relocated",
                 "sourceConfig": m.LEGACY_ROOT, "targetConfig": m.CONFIG_ROOT,
                 "moves": [], "originalFiles": {}}
        marker.write_text(json.dumps(value))
        legacy = Path(m.LEGACY_ROOT); legacy.mkdir(parents=True)
        (legacy / "receipts").mkdir()
        with mock.patch.object(m, "root_directory_chain"), \
                mock.patch.object(m, "read_private_regular", side_effect=lambda path, *args: Path(path).read_bytes()):
            self.assertEqual(m.select_layout(), "legacy")
            retained = Path(str(legacy) + ".layout-pre20261027")
            legacy.rename(retained)
            self.assertEqual(m.select_layout(), "legacy")
            self.assertTrue(m.RECEIPTS.startswith(str(retained)))
            legacy.symlink_to(m.CONFIG_ROOT)
            self.assertEqual(m.select_layout(), "migrating-current")
            value["phase"] = "committed"; marker.write_text(json.dumps(value))
            self.assertEqual(m.select_layout(), "current")
            value["targetConfig"] = "/wrong"; marker.write_text(json.dumps(value))
            with self.assertRaises(SystemExit): m.select_layout()

    def test_configure_migrates_only_verified_legacy_helper(self):
        m = self.fallback; m.LAYOUT = "legacy"
        calls = []
        with mock.patch.object(m.os, "geteuid", return_value=0), \
                mock.patch.object(m, "verify_helper", side_effect=lambda args: calls.append(("verify", args))), \
                mock.patch.object(m.subprocess, "run", side_effect=lambda args, **kw: calls.append(("migrate", args)) or subprocess.CompletedProcess(args, 0)), \
                mock.patch.object(m, "select_layout", return_value="current"), \
                mock.patch.object(m, "ensure_layout_aliases", side_effect=lambda: calls.append(("aliases", None))), \
                mock.patch.object(m, "uuidd_configure", return_value=0):
            self.assertEqual(m.fallback(["configure-helper", "/fixed/setup"]), 0)
        self.assertEqual([entry[0] for entry in calls], ["verify", "migrate", "verify", "aliases"])
        self.assertEqual(calls[1][1], ["/fixed/setup", "--migrate-system-layout"])
        with mock.patch.object(m.os, "geteuid", return_value=0), \
                mock.patch.object(m, "verify_helper"), \
                mock.patch.object(m.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)), \
                mock.patch.object(m, "uuidd_configure") as configure, \
                self.assertRaises(SystemExit):
            m.fallback(["configure-helper", "/fixed/setup"])
        configure.assert_not_called()

    def test_clean_first_install_fallback_is_noninitializing(self):
        self.assertEqual(self.invoke_as_root(["preinst", "install", str(self.descriptor)]), 0)
        self.assertFalse(Path(self.fallback.STATE).exists())
        self.assertFalse(Path(self.fallback.ACTIVE).exists())

    def test_first_install_refuses_existing_payload_or_unit(self):
        Path(self.fallback.ACTIVE).parent.mkdir(parents=True)
        Path(self.fallback.ACTIVE).mkdir()
        with self.assertRaisesRegex(SystemExit, "clean first install"):
            self.invoke_as_root(["preinst", "install", str(self.descriptor)])
        Path(self.fallback.ACTIVE).rmdir()
        self.fallback.run_systemctl = lambda arguments: "tractanda-server-foreign.service disabled\n"
        with self.assertRaisesRegex(SystemExit, "matching managed"):
            self.invoke_as_root(["preinst", "install", str(self.descriptor)])

    def test_malformed_descriptor_and_unknown_retained_state_fail_closed(self):
        bad = self.root / "bad.json"
        bad.write_text('{"profile":"tractanda.linux-package.v1","extra":true}')
        with self.assertRaisesRegex(SystemExit, "required JSON fields"):
            self.invoke_as_root(["preinst", "install", str(bad)])

        state_path = Path(self.fallback.STATE)
        state_path.parent.mkdir(parents=True)
        state_path.write_text('{}')
        with self.assertRaisesRegex(SystemExit, "required JSON fields"):
            self.invoke_as_root(["preinst", "upgrade", str(self.descriptor)])

    def test_retained_preinst_binds_descriptor_without_replacing_original_intent(self):
        import uuid
        state = {
            "profile": "tractanda.package-transaction.v1",
            "operationID": str(uuid.uuid1()),
            "phase": "failed",
            "instances": [{"name": "production", "originalManifestSHA256": "b" * 64,
                           "wasRunning": True, "wasEnabled": True,
                           "embeddingWasRunning": False, "authenticationWasRunning": True}],
            "startupPermitted": [],
            "original": {"manifestSHA256": "b" * 64},
            "incoming": {"manifestSHA256": "c" * 64},
            "observed": {"manifestSHA256": "c" * 64},
            "owner": None,
            "recoveryReason": "previous-failure",
        }
        Path(self.fallback.STATE).parent.mkdir(parents=True)
        Path(self.fallback.STATE).write_text("placeholder")
        before = copy.deepcopy(state)
        written = []
        with mock.patch.object(self.fallback, "safe_state", return_value=state), \
             mock.patch.object(self.fallback, "write_state", side_effect=written.append):
            self.assertEqual(self.invoke_as_root(["preinst", "upgrade", str(self.descriptor)]), 0)
        self.assertEqual(len(written), 1)
        result = written[0]
        self.assertEqual(result["incoming"], json.loads(DESCRIPTOR))
        self.assertEqual(result["phase"], "awaitingUnpack")
        self.assertEqual(result["operationID"], before["operationID"])
        self.assertEqual(result["instances"], before["instances"])
        self.assertEqual(result["original"], before["original"])
        self.assertEqual(result["observed"], before["observed"])
        self.assertEqual(result["incoming"]["manifestSHA256"], "a" * 64)
        self.assertEqual(result["recoveryReason"], "guarded-missing-helper-pre-unpack")

    def test_layout17_missing_helper_requires_completed_quiescent_inspection(self):
        descriptor = dict(json.loads(DESCRIPTOR), version="0.1.0-poc.17")
        state = {"phase": "awaitingUnpack", "original": {"version": "0.1.0-poc.16.2"},
                 "incoming": descriptor, "recoveryReason": "layout17-inspected-and-quiescent-awaiting-unpack"}
        path = Path(self.fallback.STATE)
        path.parent.mkdir(parents=True)
        path.write_text("placeholder")
        arguments = ["preinst", "upgrade", str(self.descriptor)]
        with mock.patch.object(self.fallback, "validate_descriptor", return_value=descriptor), \
             mock.patch.object(self.fallback, "safe_state", return_value=state), \
             mock.patch.object(self.fallback, "write_state") as write:
            self.assertEqual(self.invoke_as_root(arguments), 0)
            for change in ({"phase": "quiesced"}, {"incoming": {}}, {"recoveryReason": None}):
                with self.subTest(change=change), mock.patch.dict(state, change):
                    with self.assertRaisesRegex(SystemExit, "exact completed pre-unpack inspection"):
                        self.invoke_as_root(arguments)
            write.assert_not_called()

    def test_layout17_missing_helper_reinstall_requires_exact_original_descriptor(self):
        original = dict(json.loads(DESCRIPTOR), version="0.1.0-poc.17", upgrade="coordinated-maintenance")
        path = Path(self.fallback.STATE)
        path.parent.mkdir(parents=True)
        path.write_text("placeholder")
        arguments = ["preinst", "upgrade", str(self.descriptor)]
        for descriptor in (dict(original, upgrade="compatible"),
                           dict(original, manifestSHA256="f" * 64), original):
            with self.subTest(descriptor=descriptor):
                state = {"phase": "awaitingUnpack", "original": original}
                with mock.patch.object(self.fallback, "validate_descriptor", return_value=descriptor), \
                     mock.patch.object(self.fallback, "safe_state", return_value=state), \
                     mock.patch.object(self.fallback, "write_state") as write:
                    if descriptor == original:
                        self.assertEqual(self.invoke_as_root(arguments), 0)
                        write.assert_called_once()
                    else:
                        with self.assertRaisesRegex(SystemExit, "differs from the committed .17 artifact"):
                            self.invoke_as_root(arguments)
                        write.assert_not_called()

    def test_remove_fallback_marks_removed_after_safe_state_proof(self):
        import uuid
        state = {"profile": "tractanda.package-transaction.v1", "operationID": str(uuid.uuid1()),
                 "phase": "committed", "instances": [], "startupPermitted": [],
                 "owner": None, "recoveryReason": None}
        Path(self.fallback.STATE).parent.mkdir(parents=True)
        Path(self.fallback.STATE).write_text("placeholder")
        written = []
        with mock.patch.object(self.fallback, "safe_state", return_value=state), \
             mock.patch.object(self.fallback, "write_state", side_effect=written.append):
            self.assertEqual(self.invoke_as_root(["remove"]), 0)
        self.assertEqual(written[0]["phase"], "removed")
        self.assertEqual(written[0]["instances"], [])

    def test_postrm_without_state_requires_no_matching_units(self):
        with mock.patch.object(self.fallback.os, "geteuid", return_value=0):
            self.assertEqual(self.fallback.fallback(["postrm"]), 0)
            self.assertEqual(self.fallback.fallback(["abort-remove"]), 0)
            self.fallback.run_systemctl = lambda arguments: "tractanda-server-leftover.service disabled\n"
            with self.assertRaisesRegex(SystemExit, "validation-only hook has no captured package state"):
                self.fallback.fallback(["postrm"])
            with self.assertRaisesRegex(SystemExit, "validation-only hook has no captured package state"):
                self.fallback.fallback(["abort-remove"])

    def test_receipts_allow_separate_protected_custom_roots_and_reject_overlap(self):
        import stat
        from types import SimpleNamespace

        name = "production"
        data_root = self.root / "custom-data-root"
        index_root = self.root / "custom-index-root"
        store = data_root / name
        index = index_root / name
        store.mkdir(parents=True)
        index.mkdir(parents=True)
        os.chmod(store, 0o700)
        os.chmod(index, 0o700)
        lock = store / ".writer.lock"
        lock.write_bytes(b"")
        os.chmod(lock, 0o600)
        receipt_directory = Path(self.fallback.RECEIPTS)
        receipt_directory.mkdir(parents=True)
        receipt_path = receipt_directory / (name + ".json")

        def receipt_for(store_path, index_path, definitions=None):
            value = {
                "version": 1, "instance": name, "release": self.fallback.ACTIVE,
                "manifestSHA256": "a" * 64, "initialized": True, "state": "active",
                "store": str(store_path), "indexDirectory": str(index_path),
                "definitionSHA256": None, "embeddingDefinitionSHA256": None,
                "authenticationDefinitionSHA256": None,
            }
            if definitions is not None:
                value["packageDefinitions"] = definitions
            payload = json.dumps(value, separators=(",", ":")).encode()
            receipt_path.write_bytes(payload)
            return payload

        receipt_bytes = receipt_for(store, index)
        real_lstat = os.lstat

        def lstat(path):
            if os.fspath(path) == str(receipt_directory):
                return SimpleNamespace(st_mode=stat.S_IFDIR | 0o755, st_uid=0)
            return real_lstat(path)

        with mock.patch.object(self.fallback.os, "geteuid", return_value=0), \
             mock.patch.object(self.fallback, "root_directory_chain"), \
             mock.patch.object(self.fallback, "read_private_regular", return_value=receipt_bytes), \
             mock.patch.object(self.fallback.pwd, "getpwnam", return_value=SimpleNamespace(pw_uid=os.getuid())), \
             mock.patch.object(self.fallback.os, "lstat", side_effect=lstat):
            receipts = self.fallback.read_receipts({name})
            self.assertEqual(receipts[name]["store"], str(store))
            self.assertEqual(receipts[name]["indexDirectory"], str(index))

            overlapping = receipt_for(store, store)
            with mock.patch.object(self.fallback, "read_private_regular", return_value=overlapping):
                with self.assertRaisesRegex(SystemExit, "roots overlap"):
                    self.fallback.read_receipts({name})

            for definitions in (
                {"server": {"old": "b" * 64, "desired": "c" * 64}}, []
            ):
                pending = receipt_for(store, index, definitions)
                with mock.patch.object(self.fallback, "read_private_regular", return_value=pending):
                    with self.assertRaisesRegex(SystemExit, "publication is pending"):
                        self.fallback.read_receipts({name})

    def test_fallback_file_reader_rejects_untrusted_local_preimage(self):
        with self.assertRaises(SystemExit):
            self.fallback.read_private_regular(str(self.descriptor))

    def test_helper_admission_rejects_nonfixed_executable_path(self):
        with mock.patch.object(self.fallback.os, "geteuid", return_value=0):
            with self.assertRaisesRegex(SystemExit, "fixed active package path"):
                self.fallback.verify_helper(["verify-helper", str(self.root / "attacker-setup")])

    def test_helper_admission_binds_the_fixed_manifest_entry(self):
        machine = platform.machine().lower()
        arch = "arm64" if machine in ("arm64", "aarch64") else "x86_64"
        active = self.root / "opt/tractanda/current"
        helper = active / "bin/tractanda-setup"
        self.fallback.ACTIVE = str(active)
        digest = "c" * 64
        manifest = json.dumps({
            "profile": "tractanda.bundle.v1", "platform": "linux", "arch": arch,
            "files": [{"path": "bin/tractanda-setup", "size": 3, "mode": 0o755, "sha256": digest}],
        }).encode()
        with mock.patch.object(self.fallback.os, "geteuid", return_value=0), \
             mock.patch.object(self.fallback, "root_directory_chain"), \
             mock.patch.object(self.fallback, "read_private_regular", return_value=manifest), \
             mock.patch.object(self.fallback, "hash_payload_file", return_value=digest):
            self.assertEqual(self.fallback.verify_helper(["verify-helper", str(helper)]), 0)
        with mock.patch.object(self.fallback.os, "geteuid", return_value=0), \
             mock.patch.object(self.fallback, "root_directory_chain"), \
             mock.patch.object(self.fallback, "read_private_regular", return_value=manifest), \
             mock.patch.object(self.fallback, "hash_payload_file", return_value="d" * 64):
            with self.assertRaisesRegex(SystemExit, "hash differs"):
                self.fallback.verify_helper(["verify-helper", str(helper)])

    def test_verify_helper_accepts_partial_receipt_manifests_bound_by_observed_state(self):
        import stat
        import uuid
        active = self.root / "opt/tractanda/current"
        helper = active / "bin/tractanda-setup"
        self.fallback.ACTIVE = str(active)
        state_path = Path(self.fallback.STATE)
        state_path.parent.mkdir(parents=True)
        state_path.write_text("operational-state")
        receipts_path = Path(self.fallback.RECEIPTS)
        receipts_path.mkdir(parents=True)
        (receipts_path / "one.json").write_text("one")
        (receipts_path / "two.json").write_text("two")
        original = "a" * 64
        incoming = "b" * 64
        machine = platform.machine().lower()
        arch = "arm64" if machine in ("arm64", "aarch64") else "x86_64"
        manifest = json.dumps({
            "profile": "tractanda.bundle.v1", "platform": "linux", "arch": arch,
            "files": [{"path": "bin/tractanda-setup", "size": 3, "mode": 0o755, "sha256": "c" * 64}],
        }).encode()
        observed = __import__("hashlib").sha256(manifest).hexdigest()
        state = {
            "profile": "tractanda.package-transaction.v1", "operationID": str(uuid.uuid1()),
            "phase": "failed", "instances": [], "startupPermitted": [],
            "original": {"manifestSHA256": original}, "incoming": {"manifestSHA256": incoming},
            "observed": {"manifestSHA256": observed}, "owner": None,
        }
        state_bytes = json.dumps(state).encode()
        receipt_values = {
            "one.json": {"instance": "one", "manifestSHA256": original},
            "two.json": {"instance": "two", "manifestSHA256": observed},
        }

        def read(path, maximum=self.fallback.MAX_BYTES, private=True):
            if path == os.path.join(self.fallback.ACTIVE, "bundle-manifest.json"):
                return manifest
            if path == self.fallback.STATE:
                return state_bytes
            if path in (str(receipts_path / "one.json"), str(receipts_path / "two.json")):
                return json.dumps(receipt_values[Path(path).name]).encode()
            raise AssertionError(f"unexpected fallback read: {path}")

        real_lstat = os.lstat

        def lstat(path):
            if path == self.fallback.RECEIPTS:
                return type("Metadata", (), {"st_mode": stat.S_IFDIR | 0o755, "st_uid": 0})()
            return real_lstat(path)

        with mock.patch.object(self.fallback.os, "geteuid", return_value=0), \
             mock.patch.object(self.fallback, "root_directory_chain"), \
             mock.patch.object(self.fallback, "read_private_regular", side_effect=read), \
             mock.patch.object(self.fallback, "hash_payload_file", return_value="c" * 64), \
             mock.patch.object(self.fallback.os, "lstat", side_effect=lstat):
            self.assertEqual(self.fallback.verify_helper(["verify-helper", str(helper)]), 0)

            receipt_values["two.json"] = {"instance": "two", "manifestSHA256": "d" * 64}
            with self.assertRaisesRegex(SystemExit, "outside the transaction"):
                self.fallback.verify_helper(["verify-helper", str(helper)])

    def test_safe_state_accepts_original_incoming_observed_mixture_and_rejects_unknown(self):
        import uuid
        state_path = Path(self.fallback.STATE)
        state_path.parent.mkdir(parents=True)
        state_path.write_text("operational-state")
        original, incoming, observed = "a" * 64, "b" * 64, "c" * 64
        state = {
            "profile": "tractanda.package-transaction.v1", "operationID": str(uuid.uuid1()),
            "phase": "failed", "startupPermitted": [], "owner": None,
            "original": {"manifestSHA256": original}, "incoming": {"manifestSHA256": incoming},
            "observed": {"manifestSHA256": observed},
            "instances": [
                {"name": name, "originalManifestSHA256": original,
                 "wasRunning": True, "wasEnabled": True,
                 "embeddingWasRunning": False, "authenticationWasRunning": False}
                for name in ("one", "two")
            ],
        }
        receipts = {"one": {"manifestSHA256": original}, "two": {"manifestSHA256": observed}}
        with mock.patch.object(self.fallback, "read_private_regular", return_value=json.dumps(state).encode()), \
             mock.patch.object(self.fallback, "read_receipts", return_value=receipts), \
             mock.patch.object(self.fallback, "inspect_units"):
            self.assertEqual(self.fallback.safe_state(), state)
            receipts["two"]["manifestSHA256"] = "d" * 64
            with self.assertRaisesRegex(SystemExit, "outside original/incoming/observed"):
                self.fallback.safe_state()


class LayoutAliasTests(unittest.TestCase):
    def test_default_alias_table_matches_approved_physical_locations(self):
        self.assertEqual(module_from_template().LAYOUT_ALIASES, (
            ("/etc/tractanda", "/opt/tractanda/etc/tractanda"),
            ("/var/lib/tractanda", "/opt/tractanda/var/lib/tractanda"),
            ("/opt/tractanda/var/log/tractanda", "/var/log/tractanda"),
            ("/opt/tractanda/run/tractanda", "/run/tractanda"),
        ))

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tractanda-layout-alias-")
        self.root = Path(self.temp.name).resolve()
        self.module = module_from_template()
        pairs = (("etc/tractanda", "opt/tractanda/etc/tractanda"),
                 ("var/lib/tractanda", "opt/tractanda/var/lib/tractanda"),
                 ("opt/tractanda/var/log/tractanda", "var/log/tractanda"),
                 ("opt/tractanda/run/tractanda", "run/tractanda"))
        self.module.LAYOUT_ALIASES = tuple((str(self.root / a), str(self.root / b)) for a, b in pairs)
        actual_lstat = os.lstat
        def root_custody(path, *args, **kwargs):
            metadata = actual_lstat(path, *args, **kwargs)
            fields = list(metadata)
            fields[4] = 0  # Only root ownership is simulated; path types/modes/links are real.
            return os.stat_result(fields)
        self.custody = mock.patch.object(self.module.os, "lstat", side_effect=root_custody)
        self.custody.start()

    def tearDown(self):
        self.custody.stop()
        self.temp.cleanup()

    def test_new_layout_directories_are_0755_under_private_hook_umask(self):
        previous = os.umask(0o077)
        try:
            self.module.ensure_layout_aliases()
            self.assertEqual(os.umask(0o077), 0o077)
        finally:
            os.umask(previous)
        for path in self.root.rglob("*"):
            if path.is_dir() and not path.is_symlink():
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o755, str(path))
        self.assertEqual(stat.S_IMODE(self.root.stat().st_mode), 0o700)

    def test_existing_private_layout_directory_is_not_chmodded(self):
        path = self.root / "existing"
        path.mkdir(mode=0o700)
        inode = path.stat().st_ino
        self.module.ensure_layout_directory(str(path))
        self.assertEqual(path.stat().st_ino, inode)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700)

    def test_mkdir_race_does_not_chmod_the_other_creator_directory(self):
        path = self.root / "raced"
        actual_mkdir = os.mkdir
        def another_creator(name, mode):
            self.assertEqual(Path(name), path)
            actual_mkdir(name, 0o700)
            raise FileExistsError(name)
        previous = os.umask(0o077)
        try:
            with mock.patch.object(self.module.os, "mkdir", side_effect=another_creator):
                self.module.ensure_layout_directory(str(path))
            self.assertEqual(os.umask(0o077), 0o077)
        finally:
            os.umask(previous)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700)

    def test_mkdir_error_restores_private_hook_umask(self):
        path = self.root / "denied"
        previous = os.umask(0o077)
        try:
            with mock.patch.object(self.module.os, "mkdir", side_effect=PermissionError("denied")):
                with self.assertRaises(PermissionError):
                    self.module.ensure_layout_directory(str(path))
            self.assertEqual(os.umask(0o077), 0o077)
        finally:
            os.umask(previous)
        self.assertFalse(path.exists())

    def test_fresh_configure_creates_exact_leaf_aliases_and_retry_preserves_inodes(self):
        m = self.module
        m.ensure_layout_aliases()
        first = {}
        for alias, target in m.LAYOUT_ALIASES:
            self.assertEqual(os.readlink(alias), target)
            self.assertTrue(Path(target).is_dir())
            first[alias] = Path(alias).lstat().st_ino
        self.assertFalse((self.root / "opt/tractanda/var").is_symlink())
        self.assertFalse(os.path.lexists(self.root / "opt/tractanda/var/run/tractanda"))
        m.ensure_layout_aliases()
        self.assertEqual(first, {alias: Path(alias).lstat().st_ino for alias, _ in m.LAYOUT_ALIASES})

    def test_occupied_or_wrong_alias_preserves_foreign_contents(self):
        m = self.module
        alias = Path(m.LAYOUT_ALIASES[0][0]); alias.parent.mkdir(parents=True)
        alias.mkdir(); foreign = alias / "foreign"; foreign.write_text("keep")
        with self.assertRaises(SystemExit): m.ensure_layout_aliases()
        self.assertEqual(foreign.read_text(), "keep")
        foreign.unlink(); alias.rmdir()
        victim = self.root / "victim"; victim.mkdir(); (victim / "foreign").write_text("keep")
        alias.symlink_to(victim)
        with self.assertRaises(SystemExit): m.ensure_layout_aliases()
        self.assertEqual(os.readlink(alias), str(victim))
        self.assertEqual((victim / "foreign").read_text(), "keep")

    def test_prefix_var_symlink_and_writable_target_parent_are_refused_without_mutation(self):
        m = self.module
        prefix = self.root / "opt/tractanda"; prefix.mkdir(parents=True)
        victim = self.root / "victim"; victim.mkdir(); (victim / "foreign").write_text("keep")
        (prefix / "var").symlink_to(victim)
        with self.assertRaises(SystemExit): m.ensure_layout_aliases()
        self.assertEqual(list(victim.iterdir()), [victim / "foreign"])
        (prefix / "var").unlink()
        (prefix / "var").mkdir(mode=0o777); (prefix / "var").chmod(0o777)
        with self.assertRaises(SystemExit): m.ensure_layout_aliases()
        self.assertEqual(stat.S_IMODE((prefix / "var").stat().st_mode), 0o777)

    def test_alias_failure_prevents_uuidd_configuration_and_setup_handoff(self):
        m = self.module; m.LAYOUT = "current"
        with mock.patch.object(m.os, "geteuid", return_value=0), \
                mock.patch.object(m, "verify_helper"), \
                mock.patch.object(m, "ensure_layout_aliases", side_effect=SystemExit("occupied alias")), \
                mock.patch.object(m, "uuidd_configure") as uuidd:
            with self.assertRaises(SystemExit): m.fallback(["configure-helper", "/fixed/setup"])
        uuidd.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
