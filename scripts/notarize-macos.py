#!/usr/bin/env python3
"""Notarize a signed installer via Xcode's signed-in Developer ID account."""

import argparse, hashlib, json, os, plistlib, re, shutil, subprocess, tempfile, time
import stat
from datetime import datetime, timezone
from pathlib import Path

UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", re.I)
LOG_BUNDLE = re.compile(r'Created bundle at path "([^"\n]+\.xcdistributionlogs)"')


def now():
    return datetime.now(timezone.utc).isoformat()


def sha256(path):
    with Path(path).open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def valid_uuid(value):
    return isinstance(value, str) and UUID.fullmatch(value)


def read_json(path):
    return json.loads(Path(path).read_text())


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as f:
        json.dump(value, f, indent=2, sort_keys=True)
        f.write("\n")
        temporary = Path(f.name)
    os.replace(temporary, path)


def run(args):
    return subprocess.run([str(a) for a in args], check=True, text=True, capture_output=True).stdout


def diagnostics(error):
    value = {"type": type(error).__name__}
    code = getattr(error, "returncode", None)
    if isinstance(code, int):
        value["returncode"] = code
    text = "\n".join(
        str(x)
        for x in (getattr(error, "stdout", ""), getattr(error, "stderr", ""), str(error))
        if isinstance(x, str)
    )
    lines = [x for x in text.splitlines() if "keychain" not in x.lower() and "password" not in x.lower()]
    if lines:
        value["message"] = "\n".join(lines)[:2000]
    return value


def package_signature(package, team, runner):
    output = runner(["/usr/sbin/pkgutil", "--check-signature", str(package)])
    if team not in re.findall(r"Developer ID Installer:.*\(([A-Z0-9]{10})\)", output):
        raise RuntimeError("Package is not signed by the expected Developer ID Installer team.")


def assessment(package, runner):
    runner(["/usr/sbin/spctl", "--assess", "--type", "install", "--verbose=4", str(package)])


def distribution(archive, team):
    info = plistlib.loads((Path(archive) / "Info.plist").read_bytes())
    matches = []
    for entry in info.get("Distributions", []):
        if (
            entry.get("teamID") == team
            and entry.get("destination") == "upload"
            and entry.get("uploadDestination") == "Developer ID"
            and entry.get("uploadEvent", {}).get("state") == "success"
            and valid_uuid(entry.get("identifier"))
        ):
            matches.append(
                {
                    "identifier": entry["identifier"],
                    "uploadState": "success",
                    "processingState": entry.get("processingEvent", {}).get("state"),
                }
            )
    return matches[0] if len(matches) == 1 else None


def no_distributions(archive):
    info = plistlib.loads((Path(archive) / "Info.plist").read_bytes())
    return "Distributions" not in info or info["Distributions"] == []


def only_distribution(archive, team, identifier):
    info = plistlib.loads((Path(archive) / "Info.plist").read_bytes())
    entries = info.get("Distributions")
    found = distribution(archive, team)
    return isinstance(entries, list) and len(entries) == 1 and found and found["identifier"] == identifier


def private_stage(archive):
    archive = Path(archive)
    stage = archive.parent
    root = Path(tempfile.gettempdir()).resolve()
    if (
        not archive.is_absolute()
        or archive.name != "NotarizationWrapper.xcarchive"
        or not archive.is_dir()
        or archive.is_symlink()
        or stage.is_symlink()
        or stage.resolve().parent != root
        or not stage.name.startswith("tractanda-xcode-notary-")
        or stage.stat().st_uid != os.geteuid()
        or stat.S_IMODE(stage.stat().st_mode) & 0o077
    ):
        raise RuntimeError(
            "Recorded private notarization archive is unsafe or missing; manual reconciliation is required."
        )
    return stage.resolve()


def private_log(path):
    """Return trusted Xcode distribution logs, without exposing their contents."""
    path = Path(path)
    root = Path(tempfile.gettempdir()).resolve()
    if (
        not path.is_absolute()
        or path.parent.resolve() != root
        or not path.name.startswith("NotarizationWrapper_")
        or path.suffix != ".xcdistributionlogs"
        or path.is_symlink()
        or not path.is_dir()
        or path.stat().st_uid != os.geteuid()
        or stat.S_IMODE(path.stat().st_mode) & 0o022
    ):
        raise RuntimeError("Xcode account-discovery logs are unsafe or unavailable.")
    logs = []
    for name in ("IDEDistribution.standard.log", "IDEDistribution.verbose.log"):
        candidate = path / name
        if (
            candidate.is_symlink()
            or not candidate.is_file()
            or candidate.resolve().parent != path.resolve()
            or candidate.stat().st_uid != os.geteuid()
            or stat.S_IMODE(candidate.stat().st_mode) & 0o022
        ):
            raise RuntimeError("Xcode account-discovery logs are unsafe or unavailable.")
        logs.append(candidate)
    return path, logs


def account_discovery_failure(error, archive):
    """Prove the narrow failure mode in Xcode's private, pre-upload logs.

    This intentionally does not treat an exit code, a missing ID, or an error
    string as evidence that Apple received no submission.
    """
    text = "\n".join(
        str(value)
        for value in (getattr(error, "stdout", ""), getattr(error, "stderr", ""), str(error))
        if isinstance(value, str)
    )
    return account_discovery_failure_text(text, archive)


def account_discovery_failure_text(text, archive):
    matches = LOG_BUNDLE.findall(text)
    if len(matches) != 1 or not no_distributions(archive):
        return None
    try:
        bundle, (standard_path, verbose_path) = private_log(matches[0])
        standard = standard_path.read_text(errors="replace")
        verbose = verbose_path.read_text(errors="replace")
    except (OSError, RuntimeError):
        return None
    failure_line = re.compile(
        r"Step failed.*IDEDistributionUploadAccountStep.*IDEProvisioningErrorDomain\s+Code[= ]23.*No Accounts"
    )
    standard_steps = [line for line in standard.splitlines() if "Step" in line]
    if (
        not any(failure_line.search(line) for line in standard.splitlines() + verbose.splitlines())
        or not standard_steps
        or "IDEDistributionUploadAccountStep" not in standard_steps[-1]
        or "IDEDistributionUploadStep" in standard
        or "IDEDistributionUploadStep" in verbose
    ):
        return None
    return {
        "kind": "xcodeAccountDiscovery",
        "logBundle": str(bundle),
        "standardSHA256": sha256(standard_path),
        "verboseSHA256": sha256(verbose_path),
        "verifiedAt": now(),
    }


def verified_pre_submission_failure(receipt, archive):
    proof = receipt.get("preSubmissionFailure")
    if not isinstance(proof, dict) or proof.get("kind") != "xcodeAccountDiscovery":
        return False
    if receipt.get("submissionID") or not no_distributions(archive):
        return False
    try:
        bundle, (standard_path, verbose_path) = private_log(proof.get("logBundle", ""))
    except (TypeError, OSError, RuntimeError):
        return False
    if str(bundle) != proof.get("logBundle"):
        return False
    if proof.get("standardSHA256") != sha256(standard_path) or proof.get("verboseSHA256") != sha256(verbose_path):
        return False
    standard = standard_path.read_text(errors="replace")
    verbose = verbose_path.read_text(errors="replace")
    failure_line = re.compile(
        r"Step failed.*IDEDistributionUploadAccountStep.*IDEProvisioningErrorDomain\s+Code[= ]23.*No Accounts"
    )
    standard_steps = [line for line in standard.splitlines() if "Step" in line]
    return (
        any(failure_line.search(line) for line in standard.splitlines() + verbose.splitlines())
        and bool(standard_steps)
        and "IDEDistributionUploadAccountStep" in standard_steps[-1]
        and "IDEDistributionUploadStep" not in standard
        and "IDEDistributionUploadStep" not in verbose
    )


def make_archive(stage, package, executable, identity, team, runner):
    archive = Path(stage) / "NotarizationWrapper.xcarchive"
    app = archive / "Products/Applications/NotarizationWrapper.app"
    contents = app / "Contents"
    macos = contents / "MacOS"
    resources = contents / "Resources"
    macos.mkdir(parents=True)
    resources.mkdir()
    shutil.copy2(executable, macos / "tractanda")
    (macos / "tractanda").chmod(0o755)
    shutil.copy2(package, resources / package.name)
    if sha256(macos / "tractanda") != sha256(executable) or sha256(resources / package.name) != sha256(
        package
    ):
        raise RuntimeError("Wrapper copy digest mismatch.")
    (contents / "Info.plist").write_bytes(
        plistlib.dumps(
            {
                "CFBundleExecutable": "tractanda",
                "CFBundleIdentifier": "ai.tractanda.notarization-wrapper",
                "CFBundleName": "NotarizationWrapper",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
                "CFBundleSupportedPlatforms": ["MacOSX"],
                "LSMinimumSystemVersion": "15.0",
            }
        )
    )
    runner(
        ["/usr/bin/codesign", "--force", "--sign", identity, "--options", "runtime", "--timestamp", str(app)]
    )
    (archive / "Info.plist").write_bytes(
        plistlib.dumps(
            {
                "ArchiveVersion": 2,
                "Name": "NotarizationWrapper",
                "SchemeName": "NotarizationWrapper",
                "CreationDate": datetime.now(timezone.utc).replace(tzinfo=None),
                "ApplicationProperties": {
                    "ApplicationPath": "Applications/NotarizationWrapper.app",
                    "CFBundleIdentifier": "ai.tractanda.notarization-wrapper",
                    "CFBundleShortVersionString": "1.0",
                    "CFBundleVersion": "1",
                    "SigningIdentity": identity,
                    "Team": team,
                },
            }
        )
    )
    options = Path(stage) / "ExportOptions.plist"
    options.write_bytes(
        plistlib.dumps(
            {
                "method": "developer-id",
                "destination": "upload",
                "signingStyle": "automatic",
                "teamID": team,
                "manageAppVersionAndBuildNumber": False,
            }
        )
    )
    return archive, options


def notarize(
    package,
    output,
    application_identity,
    wrapper_executable,
    expected_team_id,
    evidence_directory,
    timeout=3600,
    runner=run,
    sleeper=time.sleep,
    clock=time.monotonic,
):
    package, output, executable, evidence = (
        Path(package).resolve(),
        Path(output).resolve(),
        Path(wrapper_executable).resolve(),
        Path(evidence_directory).resolve(),
    )
    if (
        not package.is_file()
        or package.suffix != ".pkg"
        or output.suffix != ".pkg"
        or output == package
        or not executable.is_file()
        or not os.access(executable, os.X_OK)
        or not application_identity
        or not re.fullmatch(r"[A-Z0-9]{10}", expected_team_id)
        or timeout < 0
    ):
        raise ValueError("Invalid notarization arguments.")
    evidence.mkdir(parents=True, exist_ok=True)
    receipt_path = evidence / "notarization.json"
    expected = {
        "inputSHA256": sha256(package),
        "wrapperExecutableSHA256": sha256(executable),
        "teamID": expected_team_id,
        "applicationIdentity": application_identity,
    }
    receipt = (
        read_json(receipt_path)
        if receipt_path.exists()
        else {**expected, "notarized": False, "createdAt": now()}
    )
    if any(receipt.get(k) != v for k, v in expected.items()):
        raise RuntimeError(
            "Notarization evidence belongs to different package, executable, identity, or team."
        )
    if receipt.get("notarized") and output.is_file() and receipt.get("outputSHA256") == sha256(output):
        package_signature(output, expected_team_id, runner)
        runner(["xcrun", "stapler", "validate", str(output)])
        assessment(output, runner)
        return receipt
    receipt.pop("failureCategory", None)
    write_json(receipt_path, receipt)

    def observed(args):
        try:
            return runner(args)
        except Exception as error:
            receipt.pop("failureCategory", None)
            receipt.update(lastFailure=diagnostics(error), failedAt=now())
            write_json(receipt_path, receipt)
            raise

    package_signature(package, expected_team_id, observed)
    if receipt.get("archive"):
        archive = Path(receipt["archive"])
        options = archive.parent / "ExportOptions.plist"
        stage = private_stage(archive)
    else:
        stage = Path(tempfile.mkdtemp(prefix="tractanda-xcode-notary-", dir=tempfile.gettempdir()))
        try:
            archive, options = make_archive(
                stage, package, executable, application_identity, expected_team_id, observed
            )
        except BaseException:
            shutil.rmtree(stage)
            raise
        receipt.update(archive=str(archive), submissionState="created")
        write_json(receipt_path, receipt)
    recorded = receipt.get("submissionID")
    found = distribution(archive, expected_team_id)
    if recorded and (not found or found["identifier"] != recorded):
        raise RuntimeError("Recorded Xcode distribution does not match the private archive.")
    if not recorded and not no_distributions(archive) and (
        not found or not only_distribution(archive, expected_team_id, found["identifier"])
    ):
        raise RuntimeError("Private archive contains unrecognized Xcode distribution metadata; manual reconciliation is required.")
    if not recorded and found:
        receipt.update(
            submissionID=found["identifier"],
            distribution=found,
            submissionState="uploaded",
            reconciledAt=now(),
        )
        write_json(receipt_path, receipt)
        recorded = receipt["submissionID"]
    if not recorded:
        # An interrupted prior version may have persisted only its conservative
        # uploading intent. It can be released from reconciliation only by the
        # same independent, on-disk proof used for a new failure.
        if receipt.get("submissionState") == "uploading":
            attempts = receipt.get("uploadAttempts")
            latest = attempts[-1] if isinstance(attempts, list) and attempts else None
            failure = (
                latest.get("failure") if isinstance(latest, dict) and latest.get("state") == "failed" else None
            )
            if latest is None:
                failure = receipt.get("lastFailure")
            prior_text = failure.get("message") if isinstance(failure, dict) else None
            proof = account_discovery_failure_text(prior_text, archive) if isinstance(prior_text, str) else None
            if proof:
                receipt.update(
                    submissionState="notSubmitted",
                    preSubmissionFailure=proof,
                    failureCategory="accountDiscovery",
                    reconciledAt=now(),
                )
                write_json(receipt_path, receipt)
        resumable = receipt.get("submissionState") == "notSubmitted" and verified_pre_submission_failure(
            receipt, archive
        )
        if receipt.get("submissionState") not in ("created", "notSubmitted") or (
            receipt.get("submissionState") == "notSubmitted" and not resumable
        ):
            raise RuntimeError(
                "Previous Xcode upload has no recorded distribution; manual reconciliation is required before retrying."
            )
        app = archive / "Products/Applications/NotarizationWrapper.app"
        if (
            sha256(package) != expected["inputSHA256"]
            or sha256(executable) != expected["wrapperExecutableSHA256"]
            or sha256(app / "Contents/Resources" / package.name) != expected["inputSHA256"]
        ):
            raise RuntimeError("Notarization inputs changed before upload.")
        observed(["/usr/bin/codesign", "--verify", "--strict", str(app)])
        export_args = [
            "xcodebuild",
            "-exportArchive",
            "-archivePath",
            str(archive),
            "-exportOptionsPlist",
            str(options),
            "-exportPath",
            str(archive.parent / "upload"),
            "-allowProvisioningUpdates",
        ]

        def export_once():
            attempt = {"intentAt": now(), "state": "uploading"}
            receipt.setdefault("uploadAttempts", []).append(attempt)
            receipt.pop("failureCategory", None)
            receipt.pop("preSubmissionFailure", None)
            receipt.pop("lastFailure", None)
            receipt.pop("failedAt", None)
            receipt.update(submissionState="uploading", submissionIntentAt=attempt["intentAt"])
            write_json(receipt_path, receipt)
            try:
                runner(export_args)
            except Exception as error:
                attempt.update(state="failed", failedAt=now(), failure=diagnostics(error))
                proof = account_discovery_failure(error, archive)
                if proof:
                    receipt.update(
                        submissionState="notSubmitted",
                        preSubmissionFailure=proof,
                        lastFailure={
                            "type": "XcodeAccountDiscovery",
                            "message": "Xcode could not discover an account before starting upload.",
                        },
                        failureCategory="accountDiscovery",
                        failedAt=now(),
                    )
                    attempt.update(state="accountDiscoveryFailed", proof=proof)
                else:
                    receipt.pop("failureCategory", None)
                    receipt.update(submissionState="uploading", lastFailure=diagnostics(error), failedAt=now())
                write_json(receipt_path, receipt)
                raise
            return attempt

        try:
            uploaded_attempt = export_once()
        except Exception as error:
            # Xcode has demonstrated that this failure happens before its upload
            # step. One fresh CLI invocation is safe; all other errors retain the
            # conservative uploading intent for explicit reconciliation.
            if receipt.get("submissionState") != "notSubmitted" or not verified_pre_submission_failure(receipt, archive):
                raise
            sleeper(2)
            try:
                uploaded_attempt = export_once()
            except Exception as retry_error:
                if receipt.get("submissionState") == "notSubmitted" and verified_pre_submission_failure(receipt, archive):
                    raise RuntimeError(
                        "Xcode account discovery failed before upload twice; no submission was recorded. "
                        "Retry this notarization command later after account discovery recovers."
                    ) from retry_error
                raise
        found = distribution(archive, expected_team_id)
        if not found:
            raise RuntimeError(
                "Xcode upload completed without a valid recorded distribution; manual reconciliation is required."
            )
        receipt.update(
            submissionID=found["identifier"], distribution=found, submissionState="uploaded", uploadedAt=now()
        )
        uploaded_attempt.update(state="uploaded", submissionID=found["identifier"], uploadedAt=receipt["uploadedAt"])
        write_json(receipt_path, receipt)
        recorded = receipt["submissionID"]
    if not valid_uuid(recorded):
        raise RuntimeError("Recorded Xcode distribution identifier is invalid.")
    export = archive.parent / "notarized-export"
    deadline = clock() + timeout
    while True:
        latest = distribution(archive, expected_team_id)
        if not latest or latest["identifier"] != recorded:
            raise RuntimeError("Xcode distribution changed while awaiting notarization.")
        if latest["processingState"] in ("error", "failed", "rejected", "invalid"):
            receipt.update(submissionState="rejected", distribution=latest, rejectedAt=now())
            write_json(receipt_path, receipt)
            raise RuntimeError("Apple rejected the Xcode submission; inspect the saved archive in Xcode.")
        try:
            if receipt.get("submissionState") != "accepted":
                # Retry a failed export from the same uploaded archive, without
                # mistaking an incomplete output directory for a finished app.
                if export.exists():
                    shutil.rmtree(export)
                observed(
                    [
                        "xcodebuild",
                        "-exportNotarizedApp",
                        "-archivePath",
                        str(archive),
                        "-exportPath",
                        str(export),
                    ]
                )
            apps = list(export.glob("*.app"))
            if len(apps) != 1:
                raise RuntimeError("Xcode did not export exactly one notarized wrapper app.")
            observed(["xcrun", "stapler", "validate", str(apps[0])])
            receipt.update(submissionState="accepted", acceptedAt=now(), exportedApp=str(apps[0]))
            write_json(receipt_path, receipt)
            break
        except Exception as error:
            receipt.update(
                submissionState="uploaded", exportFailure=diagnostics(error), exportCheckedAt=now()
            )
            write_json(receipt_path, receipt)
            if clock() >= deadline:
                raise TimeoutError(
                    "Xcode export or ticket validation did not complete; inspect the saved diagnostics. "
                    "Retry will reuse the recorded archive and distribution."
                ) from error
            sleeper(min(30, max(1, deadline - clock())))
    if sha256(package) != expected["inputSHA256"]:
        raise RuntimeError("Input package changed; refusing to staple different bytes.")
    stapled = archive.parent / "stapled.pkg"
    shutil.copy2(package, stapled)
    observed(["xcrun", "stapler", "staple", str(stapled)])
    observed(["xcrun", "stapler", "validate", str(stapled)])
    package_signature(stapled, expected_team_id, observed)
    assessment(stapled, observed)
    digest = sha256(stapled)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        prefix="." + output.stem + ".notarized-", suffix=".pkg", dir=output.parent, delete=False
    ) as f:
        publishing = Path(f.name)
    try:
        shutil.copy2(stapled, publishing)
        if sha256(publishing) != digest:
            raise RuntimeError("Verified package changed while publishing.")
        os.replace(publishing, output)
    finally:
        if publishing.exists():
            publishing.unlink()
    receipt.update(
        notarized=True, outputSHA256=digest, output=str(output), team=expected_team_id, completedAt=now()
    )
    receipt.pop("failureCategory", None)
    write_json(receipt_path, receipt)
    shutil.rmtree(private_stage(archive))
    return receipt


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--package", required=True, type=Path)
    p.add_argument("--output", required=True, type=Path)
    p.add_argument("--application-identity", required=True)
    p.add_argument("--wrapper-executable", required=True, type=Path)
    p.add_argument("--expected-team-id", required=True)
    p.add_argument("--evidence-directory", required=True, type=Path)
    p.add_argument("--timeout", type=int, default=3600)
    a = p.parse_args()
    r = notarize(
        a.package,
        a.output,
        a.application_identity,
        a.wrapper_executable,
        a.expected_team_id,
        a.evidence_directory,
        a.timeout,
    )
    print(
        json.dumps(
            {
                k: r[k]
                for k in (
                    "notarized",
                    "inputSHA256",
                    "outputSHA256",
                    "submissionID",
                    "team",
                    "teamID",
                    "output",
                )
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
