#!/usr/bin/env python3
import importlib.util, plistlib, tempfile, unittest
import shutil
from pathlib import Path

spec = importlib.util.spec_from_file_location("n", Path(__file__).with_name("notarize-macos.py"))
n = importlib.util.module_from_spec(spec)
spec.loader.exec_module(n)
TEAM = "ABCDE12345"
ID = "00000000-0000-4000-8000-000000000001"


class Apple:
    def __init__(self, fail=False, crash=False):
        self.calls = []
        self.fail = fail
        self.crash = crash

    def __call__(self, a):
        self.calls.append(a)
        if a[0] == "/usr/sbin/pkgutil":
            return "Developer ID Installer: Test (" + TEAM + ")"
        if a[:2] == ["xcodebuild", "-exportArchive"]:
            ar = Path(a[a.index("-archivePath") + 1])
            x = plistlib.loads((ar / "Info.plist").read_bytes())
            x["Distributions"] = [
                {
                    "identifier": ID,
                    "teamID": TEAM,
                    "destination": "upload",
                    "uploadDestination": "Developer ID",
                    "uploadEvent": {"state": "success"},
                }
            ]
            (ar / "Info.plist").write_bytes(plistlib.dumps(x))
            if self.crash:
                raise KeyboardInterrupt()
        if a[:2] == ["xcodebuild", "-exportNotarizedApp"]:
            if self.fail:
                raise RuntimeError("pending")
            (Path(a[a.index("-exportPath") + 1]) / "NotarizationWrapper.app").mkdir(parents=True)
        return ""


class T(unittest.TestCase):
    def fixture(self):
        t = tempfile.TemporaryDirectory()
        r = Path(t.name)
        p = r / "in.pkg"
        p.write_bytes(b"x")
        e = r / "bin"
        e.write_bytes(b"x")
        e.chmod(0o755)
        return t, p, e, r / "out.pkg", r / "evidence"

    def call(self, p, e, o, d, a, to=30):
        try:
            return n.notarize(
                p,
                o,
                "Developer ID Application: Test (" + TEAM + ")",
                e,
                TEAM,
                d,
                to,
                runner=a,
                sleeper=lambda _: None,
                clock=lambda: 0,
            )
        finally:
            receipt = d / "notarization.json"
            if receipt.is_file():
                archive = n.read_json(receipt).get("archive")
                if archive and Path(archive).exists():
                    try:
                        stage = n.private_stage(archive)
                    except RuntimeError:
                        pass
                    else:
                        self.addCleanup(shutil.rmtree, stage, ignore_errors=True)

    def test_success(self):
        t, p, e, o, d = self.fixture()
        with t:
            a = Apple()
            before = n.sha256(p)
            r = self.call(p, e, o, d, a)
            self.assertTrue(r["notarized"])
            self.assertTrue(o.exists())
            self.assertEqual(before, n.sha256(p))
            self.assertTrue(
                any(x[:3] == ["xcrun", "stapler", "staple"] and x[-1].endswith(".pkg") for x in a.calls)
            )
            self.assertTrue(any(x[0] == "/usr/sbin/spctl" for x in a.calls))
            self.assertFalse(Path(r["archive"]).parent.exists())

    def test_timeout_resume_no_upload(self):
        t, p, e, o, d = self.fixture()
        with t:
            with self.assertRaises(TimeoutError):
                self.call(p, e, o, d, Apple(fail=True), 0)
            a = Apple()
            self.call(p, e, o, d, a)
            self.assertFalse(any(x[:2] == ["xcodebuild", "-exportArchive"] for x in a.calls))

    def test_crash_distribution_reconciles(self):
        t, p, e, o, d = self.fixture()
        with t:
            with self.assertRaises(KeyboardInterrupt):
                self.call(p, e, o, d, Apple(crash=True))
            a = Apple()
            self.call(p, e, o, d, a)
            self.assertFalse(any(x[:2] == ["xcodebuild", "-exportArchive"] for x in a.calls))

    def test_wrong_signature_never_uploads(self):
        t, p, e, o, d = self.fixture()
        with t:

            class Bad(Apple):
                def __call__(self, a):
                    if a[0] == "/usr/sbin/pkgutil":
                        return "Developer ID Installer: Test (ZZZZZ99999)"
                    return super().__call__(a)

            a = Bad()
            with self.assertRaisesRegex(RuntimeError, "expected Developer ID"):
                self.call(p, e, o, d, a)
            self.assertFalse(any(x[:2] == ["xcodebuild", "-exportArchive"] for x in a.calls))

    def test_changed_input_or_executable_rejected_on_resume(self):
        for changed in ("input", "executable"):
            t, p, e, o, d = self.fixture()
            with t:
                with self.assertRaises(TimeoutError):
                    self.call(p, e, o, d, Apple(fail=True), 0)
                target = p if changed == "input" else e
                target.write_bytes(b"changed")
                target.chmod(0o755)
                with self.assertRaisesRegex(RuntimeError, "different package|different package, executable"):
                    self.call(p, e, o, d, Apple())

    def test_package_staple_and_gatekeeper_failure_never_publish(self):
        for bad in ("staple", "gatekeeper"):
            t, p, e, o, d = self.fixture()
            with t:

                class Bad(Apple):
                    def __call__(self, a):
                        if bad == "staple" and a[:3] == ["xcrun", "stapler", "staple"]:
                            raise RuntimeError("pkg staple failed")
                        if bad == "gatekeeper" and a[0] == "/usr/sbin/spctl":
                            raise RuntimeError("pkg rejected")
                        return super().__call__(a)

                with self.assertRaises(RuntimeError):
                    self.call(p, e, o, d, Bad())
                self.assertFalse(o.exists())

    def test_crash_without_distribution_and_unsafe_archive_do_not_upload(self):
        t, p, e, o, d = self.fixture()
        with t:

            class Crash(Apple):
                def __call__(self, a):
                    if a[:2] == ["xcodebuild", "-exportArchive"]:
                        raise KeyboardInterrupt()
                    return super().__call__(a)

            with self.assertRaises(KeyboardInterrupt):
                self.call(p, e, o, d, Crash())
            retry = Apple()
            with self.assertRaisesRegex(RuntimeError, "manual reconciliation"):
                self.call(p, e, o, d, retry)
            self.assertFalse(any(x[:2] == ["xcodebuild", "-exportArchive"] for x in retry.calls))
            receipt = n.read_json(d / "notarization.json")
            receipt["archive"] = "/tmp/not-owned/evil.xcarchive"
            n.write_json(d / "notarization.json", receipt)
            with self.assertRaisesRegex(RuntimeError, "unsafe or missing"):
                self.call(p, e, o, d, Apple())

    def test_completed_resume_validates_package(self):
        t, p, e, o, d = self.fixture()
        with t:
            self.call(p, e, o, d, Apple())
            a = Apple()
            self.call(p, e, o, d, a)
            self.assertTrue(any(x[0] == "/usr/sbin/pkgutil" for x in a.calls))
            self.assertTrue(any(x[:3] == ["xcrun", "stapler", "validate"] for x in a.calls))
            self.assertTrue(any(x[0] == "/usr/sbin/spctl" for x in a.calls))

    def test_invalid_distribution_id_is_not_uploaded_again(self):
        t, p, e, o, d = self.fixture()
        with t:

            class Bad(Apple):
                def __call__(self, a):
                    result = super().__call__(a)
                    if a[:2] == ["xcodebuild", "-exportArchive"]:
                        archive = Path(a[a.index("-archivePath") + 1])
                        info = plistlib.loads((archive / "Info.plist").read_bytes())
                        info["Distributions"][0]["identifier"] = "../../bad"
                        (archive / "Info.plist").write_bytes(plistlib.dumps(info))
                    return result

            with self.assertRaisesRegex(RuntimeError, "manual reconciliation"):
                self.call(p, e, o, d, Bad())

    def test_changed_distribution_or_nonprivate_stage_blocks_resume(self):
        for change in ("identifier", "permissions"):
            with self.subTest(change=change):
                t, p, e, o, d = self.fixture()
                with t:
                    with self.assertRaises(TimeoutError):
                        self.call(p, e, o, d, Apple(fail=True), 0)
                    receipt = n.read_json(d / "notarization.json")
                    if change == "identifier":
                        receipt["submissionID"] = "00000000-0000-4000-8000-000000000002"
                        n.write_json(d / "notarization.json", receipt)
                    else:
                        Path(receipt["archive"]).parent.chmod(0o755)
                    apple = Apple()
                    with self.assertRaises(RuntimeError):
                        self.call(p, e, o, d, apple)
                    self.assertFalse(o.exists())
                    self.assertFalse(any(call[0] == "xcodebuild" for call in apple.calls))

    def test_definite_rejection_does_not_retry_export(self):
        t, p, e, o, d = self.fixture()
        with t:

            class Rejected(Apple):
                def __call__(self, args):
                    result = super().__call__(args)
                    if args[:2] == ["xcodebuild", "-exportArchive"]:
                        archive = Path(args[args.index("-archivePath") + 1])
                        info = plistlib.loads((archive / "Info.plist").read_bytes())
                        info["Distributions"][0]["processingEvent"] = {"state": "failed"}
                        (archive / "Info.plist").write_bytes(plistlib.dumps(info))
                    return result

            apple = Rejected()
            with self.assertRaisesRegex(RuntimeError, "rejected"):
                self.call(p, e, o, d, apple)
            self.assertFalse(o.exists())
            self.assertFalse(any(call[:2] == ["xcodebuild", "-exportNotarizedApp"] for call in apple.calls))


if __name__ == "__main__":
    unittest.main(verbosity=2)
