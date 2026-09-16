#!/usr/bin/env python3
import importlib.util, plistlib, subprocess, tempfile, unittest
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


class AccountFailure(Apple):
    def __init__(self, failures=1, log_kind="valid", receipt_path=None):
        super().__init__()
        self.failures = failures
        self.log_kind = log_kind
        self.receipt_path = receipt_path
        self.bundles = []
        self.intent_counts = []

    def __call__(self, args):
        if args[:2] == ["xcodebuild", "-exportArchive"]:
            self.calls.append(args)
            if self.receipt_path:
                receipt = n.read_json(self.receipt_path)
                self.intent_counts.append(len(receipt.get("uploadAttempts", [])))
                self.assertion = receipt.get("submissionState") == "uploading"
            if self.failures:
                self.failures -= 1
                bundle = Path(
                    tempfile.mkdtemp(
                        prefix="NotarizationWrapper_test_", suffix=".xcdistributionlogs", dir=tempfile.gettempdir()
                    )
                )
                standard = "Running step: IDEDistributionUploadAccountStep\n"
                verbose = (
                    "Step failed: IDEDistributionUploadAccountStep "
                    "IDEProvisioningErrorDomain Code=23 No Accounts\n"
                )
                if self.log_kind == "upload-started":
                    standard += "IDEDistributionUploadStep\n"
                elif self.log_kind == "upload-started-verbose":
                    verbose += "IDEDistributionUploadStep\n"
                elif self.log_kind == "malformed":
                    verbose = "IDEDistributionUploadAccountStep\nNo Accounts\n"
                elif self.log_kind == "untrusted":
                    bundle.chmod(0o777)
                (bundle / "IDEDistribution.standard.log").write_text(standard)
                (bundle / "IDEDistribution.verbose.log").write_text(verbose)
                self.bundles.append(bundle)
                raise subprocess.CalledProcessError(
                    70, args, stderr=f'Created bundle at path "{bundle}".\nerror: exportArchive No Accounts'
                )
            self.calls.pop()
        return super().__call__(args)

    def cleanup(self):
        for bundle in self.bundles:
            shutil.rmtree(bundle, ignore_errors=True)


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

    def test_account_discovery_failure_retries_once_then_succeeds(self):
        t, p, e, o, d = self.fixture()
        with t:
            apple = AccountFailure(1, receipt_path=d / "notarization.json")
            try:
                receipt = self.call(p, e, o, d, apple)
            finally:
                apple.cleanup()
            self.assertTrue(receipt["notarized"])
            self.assertNotIn("failureCategory", receipt)
            exports = [call for call in apple.calls if call[:2] == ["xcodebuild", "-exportArchive"]]
            self.assertEqual(len(exports), 2)
            self.assertEqual(apple.intent_counts, [1, 2])
            self.assertTrue(apple.assertion)
            self.assertEqual(receipt["uploadAttempts"][0]["state"], "accountDiscoveryFailed")
            self.assertEqual(receipt["uploadAttempts"][-1]["state"], "uploaded")

    def test_persistent_account_discovery_failure_is_bounded(self):
        t, p, e, o, d = self.fixture()
        with t:
            apple = AccountFailure(3)
            try:
                with self.assertRaisesRegex(RuntimeError, "failed before upload twice"):
                    self.call(p, e, o, d, apple)
            finally:
                apple.cleanup()
            receipt = n.read_json(d / "notarization.json")
            self.assertEqual(receipt["failureCategory"], "accountDiscovery")
            self.assertEqual(receipt["submissionState"], "notSubmitted")
            self.assertEqual(len(receipt["uploadAttempts"]), 2)

    def test_nonempty_or_ambiguous_distribution_metadata_blocks_upload(self):
        for distributions in (
            [{"teamID": TEAM}],
            [
                {"identifier": ID, "teamID": TEAM, "destination": "upload", "uploadDestination": "Developer ID", "uploadEvent": {"state": "success"}},
                {"teamID": TEAM},
            ],
        ):
            with self.subTest(distributions=distributions):
                t, p, e, o, d = self.fixture()
                with t:
                    first = AccountFailure(3)
                    try:
                        with self.assertRaises(RuntimeError):
                            self.call(p, e, o, d, first)
                        receipt = n.read_json(d / "notarization.json")
                        archive = Path(receipt["archive"])
                        info = plistlib.loads((archive / "Info.plist").read_bytes())
                        info["Distributions"] = distributions
                        (archive / "Info.plist").write_bytes(plistlib.dumps(info))
                        retry = Apple()
                        with self.assertRaisesRegex(RuntimeError, "unrecognized Xcode distribution"):
                            self.call(p, e, o, d, retry)
                        self.assertFalse(any(x[:2] == ["xcodebuild", "-exportArchive"] for x in retry.calls))
                    finally:
                        first.cleanup()

    def test_verified_prior_account_failure_can_resume_on_explicit_run(self):
        t, p, e, o, d = self.fixture()
        with t:
            first = AccountFailure(3)
            try:
                with self.assertRaises(RuntimeError):
                    self.call(p, e, o, d, first)
                # Old receipts retained the raw xcodebuild failure but only an
                # uploading intent. A later explicit run must independently
                # re-verify that receipt before it can retry.
                prior = n.read_json(d / "notarization.json")
                bundle = prior["uploadAttempts"][-1]["proof"]["logBundle"]
                prior["submissionState"] = "uploading"
                prior.pop("preSubmissionFailure")
                prior.pop("failureCategory")
                prior.pop("uploadAttempts")
                prior["lastFailure"] = {
                    "message": 'Created bundle at path "' + bundle + '".'
                }
                n.write_json(d / "notarization.json", prior)
                second = Apple()
                receipt = self.call(p, e, o, d, second)
            finally:
                first.cleanup()
            self.assertTrue(receipt["notarized"])
            self.assertEqual(len([x for x in second.calls if x[:2] == ["xcodebuild", "-exportArchive"]]), 1)

    def test_unproven_or_upload_started_account_logs_do_not_retry(self):
        for kind in ("malformed", "untrusted", "upload-started", "upload-started-verbose"):
            with self.subTest(kind=kind):
                t, p, e, o, d = self.fixture()
                with t:
                    apple = AccountFailure(1, log_kind=kind)
                    try:
                        with self.assertRaises(subprocess.CalledProcessError):
                            self.call(p, e, o, d, apple)
                    finally:
                        apple.cleanup()
                    receipt = n.read_json(d / "notarization.json")
                    self.assertEqual(receipt["submissionState"], "uploading")
                    self.assertNotIn("failureCategory", receipt)
                    self.assertEqual(len(receipt["uploadAttempts"]), 1)

    def test_arbitrary_upload_failure_remains_blocked(self):
        t, p, e, o, d = self.fixture()
        with t:
            class Arbitrary(Apple):
                def __call__(self, args):
                    if args[:2] == ["xcodebuild", "-exportArchive"]:
                        raise subprocess.CalledProcessError(70, args, stderr="network interrupted")
                    return super().__call__(args)

            with self.assertRaises(subprocess.CalledProcessError):
                self.call(p, e, o, d, Arbitrary())
            retry = Apple()
            with self.assertRaisesRegex(RuntimeError, "manual reconciliation"):
                self.call(p, e, o, d, retry)
            self.assertFalse(any(x[:2] == ["xcodebuild", "-exportArchive"] for x in retry.calls))

    def test_second_attempt_crash_cannot_reuse_first_account_proof(self):
        t, p, e, o, d = self.fixture()
        with t:
            class AccountThenCrash(AccountFailure):
                def __call__(self, args):
                    if args[:2] == ["xcodebuild", "-exportArchive"] and not self.failures:
                        self.calls.append(args)
                        raise KeyboardInterrupt()
                    return super().__call__(args)

            first = AccountThenCrash(1)
            try:
                with self.assertRaises(KeyboardInterrupt):
                    self.call(p, e, o, d, first)
                receipt = n.read_json(d / "notarization.json")
                self.assertEqual(receipt["uploadAttempts"][-1]["state"], "uploading")
                self.assertNotIn("lastFailure", receipt)
                retry = Apple()
                with self.assertRaisesRegex(RuntimeError, "manual reconciliation"):
                    self.call(p, e, o, d, retry)
                self.assertFalse(any(x[:2] == ["xcodebuild", "-exportArchive"] for x in retry.calls))
            finally:
                first.cleanup()

    def test_generic_failure_clears_stale_account_category(self):
        t, p, e, o, d = self.fixture()
        with t:
            first = AccountFailure(3)
            try:
                with self.assertRaises(RuntimeError):
                    self.call(p, e, o, d, first)

                class BadVerify(Apple):
                    def __call__(self, args):
                        if args[:3] == ["/usr/bin/codesign", "--verify", "--strict"]:
                            raise RuntimeError("wrapper verification failed")
                        return super().__call__(args)

                with self.assertRaisesRegex(RuntimeError, "wrapper verification"):
                    self.call(p, e, o, d, BadVerify())
                self.assertNotIn("failureCategory", n.read_json(d / "notarization.json"))
            finally:
                first.cleanup()


if __name__ == "__main__":
    unittest.main(verbosity=2)
