#!/usr/bin/env python3
"""Isolated routing and fallback checks for the finite Debian maintainer hooks."""
import importlib.machinery
import importlib.util
import json
import os
import platform
import copy
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


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
import os, sys
path = os.environ["MOCK_DESCRIPTOR"]
open(path, "wb").close()
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
with open(os.environ["MOCK_LOG"], "a", encoding="utf-8") as f:
    f.write(json.dumps({"program":"python-hook", "args":sys.argv[1:]}) + "\\n")
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

    def render(self, hook, *, helper=True, missing=()):
        source = (DEBIAN / hook).read_text()
        fallback = FALLBACK.read_text()
        source = source.replace("@TRACTANDA_PACKAGE_HOOK_FALLBACK_PY@", fallback)
        source = source.replace("@TRACTANDA_PACKAGE_DESCRIPTOR_JSON@", DESCRIPTOR)
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

    def run(self, hook, *arguments, helper=True, missing=()):
        path = self.render(hook, helper=helper, missing=missing)
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
            self.assertEqual(records[0]["args"], ["-I", "-", "verify-helper", str(self.harness.helper)])
            self.assertEqual(records[1]["args"][:2], ["--package-lifecycle", "preinst"])
            self.assertEqual(records[1]["descriptor"], DESCRIPTOR + "\n")

        for args in (("configure",), ("configure", "")):
            self.harness.clear()
            post = self.harness.run("tractanda.postinst.in", *args)
            self.assertEqual(post.returncode, 0, (args, post.stderr))
            records = self.harness.records()
            self.assertEqual(records[0]["args"], ["-I", "-", "verify-helper", str(self.harness.helper)])
            self.assertEqual(records[1]["args"][:2], ["--package-lifecycle", "configure"])
            self.assertEqual(records[1]["descriptor"], DESCRIPTOR + "\n")

    def test_prerm_and_abort_events_route_finitely(self):
        for hook, args, expected in (
            ("tractanda.prerm", ("upgrade", "old"), "prerm-upgrade"),
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
            if args[0] in ("upgrade", "disappear"):
                self.assertEqual(records, [])
            else:
                self.assertEqual(records[0]["args"], ["-I", "-", "postrm"])
                self.assertEqual(records[1], {"program": "systemctl", "args": ["daemon-reload"]})

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
        failed = self.harness.run("tractanda.prerm", "upgrade", "old")
        self.assertEqual(failed.returncode, 42)
        self.assertEqual(len(self.harness.records()), 2)
        self.assertEqual(self.harness.records()[0]["args"][2], "verify-helper")
        self.assertEqual(self.harness.records()[1]["args"][-1], "prerm-upgrade")


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
        def read_owned_fixture(path, maximum=None):
            maximum = self.fallback.MAX_BYTES if maximum is None else maximum
            data = Path(path).read_bytes()
            if not data or len(data) > maximum:
                raise SystemExit("mock bounded-file refusal")
            return data
        with mock.patch.object(self.fallback.os, "geteuid", return_value=0), \
             mock.patch.object(self.fallback, "read_private_regular", side_effect=read_owned_fixture):
            return self.fallback.fallback(arguments)

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
