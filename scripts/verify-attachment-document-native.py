#!/usr/bin/env python3
"""One bounded native API trial of the two frozen originals, at most three pages."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import time

PROJECT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("native_trial_ipc", PROJECT / "scripts/verify-ipc.py")
ipc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ipc)
CAP = 4 * 1024**3
RESERVE = 10 * 1024**3
FIXTURE_CAP = 16 * 1024**2


def digest(path):
    hasher = hashlib.sha256()
    with Path(path).open("rb") as stream:
        while block := stream.read(1024 * 1024):
            hasher.update(block)
    return hasher.hexdigest()


def save(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def allocated(root):
    total, seen = 0, set()
    for directory, folders, files in os.walk(root, followlinks=False):
        for path in [Path(directory), *(Path(directory) / name for name in folders + files)]:
            metadata = path.lstat()
            if not hasattr(metadata, "st_blocks") or metadata.st_blocks < 0:
                raise RuntimeError("Filesystem allocated-byte accounting unavailable")
            key = metadata.st_dev, metadata.st_ino
            if key not in seen:
                total += metadata.st_blocks * 512
                seen.add(key)
            if stat.S_ISLNK(metadata.st_mode) and path.name in folders:
                folders.remove(path.name)
    return total


def guard(private, run):
    roots = [PROJECT / "work/docling-smoke-20261001", PROJECT / "work/docling-reference-preprocessing-20261007",
        PROJECT / "work/docling-output-checks-20261007", PROJECT / "work/docling-integration-20261007",
        PROJECT / "Packages/TractandaDocuments", private]
    values = [allocated(root) for root in roots]
    capacity = os.statvfs(private)
    if not isinstance(capacity.f_bavail, int) or capacity.f_bavail < 0 or capacity.f_frsize <= 0:
        raise RuntimeError("Genuine filesystem available bytes unavailable")
    available = capacity.f_bavail * capacity.f_frsize
    if sum(values) > CAP or available < RESERVE:
        raise RuntimeError("Native trial combined4GiB/10GiB guard rejected")
    if run.exists() and allocated(run) > FIXTURE_CAP:
        raise RuntimeError("Native API fixture16MiB cap rejected")
    return {"allocatedBytes": sum(values), "genuineAvailableBytes": available,
        "capBytes": CAP, "reserveBytes": RESERVE}


def cli(binary, args, timeout=30):
    process = subprocess.run([str(binary), *map(str, args)], capture_output=True, text=True, timeout=timeout)
    return process.returncode, process.stdout, process.stderr


def required_cli(binary, args):
    code, output, error = cli(binary, args)
    if code:
        raise RuntimeError(f"Bounded CLI step failed: {args[0]}: {error[:4096]}")
    return json.loads(output)


def extraction_cli(binary, args, private, run, name):
    """The native owner monitors combined capacity while its one client waits."""
    output_path, error_path = run / (name + ".extract.stdout"), run / (name + ".extract.stderr")
    with output_path.open("w") as output, error_path.open("w") as error:
        process = subprocess.Popen([str(binary), *map(str, args)], stdout=output, stderr=error)
        deadline = time.monotonic() + 390
        try:
            while process.poll() is None:
                guard(private, run)
                if time.monotonic() > deadline:
                    raise TimeoutError("Native extraction client exceeded390s")
                time.sleep(0.1)
            process.wait()
        except BaseException as original:
            save(run / (name + ".client-original-failure.json"), {"type": type(original).__name__, "message": str(original)[:4096]})
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)
            raise
    return process.returncode, output_path.read_text(), error_path.read_text()


def stop(signum, frame):
    raise KeyboardInterrupt(f"Owned native trial received signal {signum}")


def run_trial(options, before_case=None, after_case=None):
    private = options.private_root.resolve()
    run = private / "native-api"
    if run.exists():
        raise RuntimeError("Refusing to resume/rerun or overwrite the three-page native trial")
    guard(private, run)
    run.mkdir(mode=0o700)
    store, scratch, socket_path = run / "store", run / "scratch", run / "server.sock"
    scratch.mkdir(mode=0o700)
    main_receipt = json.loads((private / "main-binary-model-gate-receipt.json").read_text())
    binary = Path(main_receipt["binary"])
    converter = private / "native-bin/tractanda-document-converter"
    preparation = private / "preparations"
    model = PROJECT / "work/docling-smoke-20261001/model"
    initial = {"main": digest(binary), "converter": digest(converter)}
    if initial["main"] != main_receipt["sha256"]:
        raise RuntimeError("Frozen main API binary changed")
    expectation_path = private / "input-review/recognition/recognition-expectations.json"
    recognition = json.loads(expectation_path.read_text())
    if digest(expectation_path) != "12af562676e7713cce2b19614004bce399ff8cadd91dea1a634d08953780d694":
        raise RuntimeError("Independent frozen recognition expectations changed")
    binary_receipt = json.loads((private / "native-binary-receipt.json").read_text())
    if initial["converter"] != binary_receipt["sha256"]:
        raise RuntimeError("Frozen native converter changed")
    required_cli(binary, ["init", store])
    command = [str(binary), "daemon", str(store), str(socket_path), "--no-http",
        "--document-converter", str(converter), "--document-model-directory", str(model),
        "--document-scratch-directory", str(scratch), "--document-preparation-directory", str(preparation)]
    report = {"status": "running", "generationPageBudget": 3, "binarySHA256": initial,
        "attempts": [], "daemonCommand": command, "guard": guard(private, run),
        "realNativeAPI": True, "productionUntouched": True}
    save(run / "report.json", report)
    process = None
    try:
        with (run / "daemon.log").open("w") as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            report["daemonPID"] = process.pid
            save(run / "report.json", report)
            deadline = time.monotonic() + 30
            while not socket_path.exists():
                if process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Owned native trial daemon did not become ready")
                time.sleep(0.05)
            client = ipc.Client(socket_path)
            info = client.call("TractandaStore/info")
            if info["documentExtraction"]["state"] != "configured" or not info["documentExtraction"]["requiresPreparedInput"]:
                raise RuntimeError("Native preparation gate is not active")
            save(run / "info.json", info)
            for name, media, pages in [("paragraph-alpha.png", "image/png", 1), ("portrait-landscape.pdf", "application/pdf", 2)]:
                guard(private, run)
                original = private / "raster-fixtures" / name
                source_sha = digest(original)
                prepared = json.loads((preparation / source_sha / "summary.json").read_text())
                if prepared["inputSHA256"] != source_sha or prepared["pages"] != pages or prepared["generationAttempts"] != 0:
                    raise RuntimeError("Frozen original preparation binding differs")
                base = client.commit(ipc.intent("create", "native-create-" + name, class_id="Item",
                    changes={"subject": ipc.text("Frozen native trial " + name)}))["revision"]
                item_id = ipc.item_id(base)
                attached = required_cli(binary, ["attach", socket_path, item_id, ipc.revision_id(base),
                    "native-attach-" + name, original, media])
                descriptor = client.call("TractandaAttachment/list", {"itemID": item_id})["attachments"][0]
                before = client.get(item_id)
                attempt = {"original": name, "inputSHA256": source_sha, "expectedPages": pages,
                    "itemID": item_id, "attachmentID": descriptor["attachmentID"],
                    "headBefore": ipc.revision_id(before), "extractionAttempted": True,
                    "accepted": False, "committed": False}
                report["attempts"].append(attempt)
                save(run / "report.json", report)
                if before_case is not None:
                    before_case(name, attempt, report)
                # Exactly one extraction per original. No retry after any uncertainty.
                request = ["extract-document", socket_path, item_id, attached["revisionID"],
                    descriptor["attachmentID"], "native-extract-" + name]
                code, output, error = extraction_cli(binary, request, private, run, name)
                attempt["cliExit"] = code
                after = client.get(item_id)
                attempt["headAfter"] = ipc.revision_id(after)
                if code:
                    attempt["error"] = error[:4096]
                    attempt["unchangedOnRejection"] = attempt["headAfter"] == attempt["headBefore"]
                    if not attempt["unchangedOnRejection"]:
                        raise RuntimeError("Rejected extraction changed current canonical head")
                else:
                    receipt = json.loads(output)
                    attempt.update(accepted=True, committed=True, receipt=receipt)
                    document = client.call("TractandaAttachment/document", {"itemID": item_id,
                        "attachmentID": descriptor["attachmentID"], "maxBytes": 2097152})
                    save(run / (name + ".document.json"), document)
                    if document["totalPageCount"] != pages or document["source"]["sha256"] != source_sha:
                        raise RuntimeError("Delivered native document provenance differs")
                    attempt["structuredReadPassed"] = True
                    diagnostic = client.call("TractandaItem/extractedText", {"ids": [item_id], "projection": "source", "maxBytes": 524288})
                    save(run / (name + ".sources.json"), diagnostic)
                    sources = diagnostic["list"][0]["sources"]
                    if not sources and any(page["parsed"]["text"] for page in document["pages"]):
                        raise RuntimeError("Nonempty native document has no typed citation sources")
                    raster_receipt = json.loads((private / "raster-fixtures/raster-check-receipt.json").read_text())
                    expected_rasters = [raster_receipt["rasterSHA256"]["paragraphAlpha"]] if pages == 1 else [
                        raster_receipt["rasterSHA256"]["pdfPage1"], raster_receipt["rasterSHA256"]["pdfPage2"]]
                    if [page["rasterSHA256"] for page in document["pages"]] != expected_rasters:
                        raise RuntimeError("Native delivered rasters differ from the preparation gate")
                    for source in sources:
                        if source["location"]["kind"] != "document" or "byteStart" in source["location"] \
                            or source["sourceSHA256"] != source_sha or source["location"]["rasterSHA256"] not in expected_rasters:
                            raise RuntimeError("Native OCR citation invented original byte location")
                    corpus = diagnostic["list"][0]["sourceText"]
                    expectations = sorted([page for page in recognition["pages"] if page["input"] == name], key=lambda page: page["pageNumber"])
                    facts = [[fact["text"] for fact in page["requiredFacts"]] for page in expectations]
                    texts = [page["parsed"]["text"] for page in document["pages"]]
                    for text in texts:
                        if text and corpus.count(text) != 1:
                            raise RuntimeError("Native corpus duplicates or omits a saved page text")
                    fact_results = []
                    for index, phrases in enumerate(facts):
                        for phrase in phrases:
                            present = " ".join(phrase.split()) in " ".join(texts[index].split())
                            fact_results.append({"pageNumber": index + 1, "phrase": phrase, "present": present})
                            if present:
                                query = client.call("TractandaItem/query", {"text": phrase, "limit": 16})
                                if item_id not in query["ids"]:
                                    raise RuntimeError("Native saved phrase is absent from FTS")
                    attempt["recognitionFacts"] = fact_results
                    attempt["recognitionPassed"] = all(fact["present"] for fact in fact_results)
                    attempt["ftsAndCorpusChecked"] = True
                    current = ipc.revision_id(after)
                    copy = client.commit(ipc.intent("copy", "native-copy-" + name, item_id, current))["revision"]
                    copy_id = ipc.item_id(copy)
                    clone = client.call("TractandaAttachment/list", {"itemID": copy_id})["attachments"][0]
                    copied = client.call("TractandaAttachment/document", {"itemID": copy_id,
                        "attachmentID": clone["attachmentID"], "maxBytes": 2097152})
                    if copied["source"] != document["source"] or clone["attachmentID"] == descriptor["attachmentID"]:
                        raise RuntimeError("Native document copy changed immutable provenance")
                    attempt["copyProvenancePassed"] = True
                    client.call("TractandaStore/rebuild")
                    rebuilt = client.call("TractandaAttachment/document", {"itemID": item_id,
                        "attachmentID": descriptor["attachmentID"], "maxBytes": 2097152})
                    if rebuilt != document:
                        raise RuntimeError("Canonical rebuild changed native output")
                    attempt["rebuildPassed"] = True
                destination = run / (name + ".original")
                required_cli(binary, ["export-attachment", socket_path, item_id, descriptor["attachmentID"], destination])
                attempt["originalBytesPreserved"] = digest(destination) == source_sha
                if not attempt["originalBytesPreserved"]:
                    raise RuntimeError("Native trial changed the original")
                report["guard"] = guard(private, run)
                save(run / "report.json", report)
                if after_case is not None:
                    after_case(name, attempt, report)
        if not all(a["committed"] for a in report["attempts"]):
            report["status"] = "fixtureRejected"
        elif not all(a["recognitionPassed"] for a in report["attempts"]):
            report["status"] = "recognitionFailed"
        else:
            report["status"] = "completed"
    except BaseException as error:
        report.update(status="failed", originalFailure={"type": type(error).__name__, "message": str(error)[:4096]})
        save(run / "report.json", report)
        raise
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
        report["daemonExit"] = process.poll() if process else None
        report["socketRemoved"] = not socket_path.exists()
        report["binarySHA256After"] = {"main": digest(binary), "converter": digest(converter)}
        report["binariesUnchanged"] = report["binarySHA256After"] == initial
        save(run / "report.json", report)
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--private-root", type=Path, required=True)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print(json.dumps(run_trial(args), indent=2))
