#!/usr/bin/env python3
"""Notarize a signed installer via Xcode's signed-in Developer ID account."""

import argparse, hashlib, json, os, plistlib, re, shutil, subprocess, tempfile, time
import stat
from datetime import datetime, timezone
from pathlib import Path

UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", re.I)


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
    write_json(receipt_path, receipt)

    def observed(args):
        try:
            return runner(args)
        except Exception as error:
            receipt.update(lastFailure=diagnostics(error), failedAt=now())
            write_json(receipt_path, receipt)
            raise

    package_signature(package, expected_team_id, observed)
    created = False
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
        receipt.update(archive=str(archive), submissionState="uploading", submissionIntentAt=now())
        write_json(receipt_path, receipt)
        created = True
    recorded = receipt.get("submissionID")
    found = distribution(archive, expected_team_id)
    if recorded and (not found or found["identifier"] != recorded):
        raise RuntimeError("Recorded Xcode distribution does not match the private archive.")
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
        if receipt.get("submissionState") == "uploading" and not created:
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
        observed(
            [
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
        )
        found = distribution(archive, expected_team_id)
        if not found:
            raise RuntimeError(
                "Xcode upload completed without a valid recorded distribution; manual reconciliation is required."
            )
        receipt.update(
            submissionID=found["identifier"], distribution=found, submissionState="uploaded", uploadedAt=now()
        )
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
