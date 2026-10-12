#!/usr/bin/env python3
"""Exercise document extraction on a disposable daemon with a deterministic fake converter."""
import argparse
import contextlib
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

PROJECT = Path(__file__).resolve().parents[1]
import importlib.util
SPEC = importlib.util.spec_from_file_location("ipc", PROJECT / "scripts/verify-ipc.py")
ipc = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ipc)

RESERVE = 10 * 1024**3
CAP = 16 * 1024**2
MAX_RESPONSE = 2 * 1024**2


class CapacityError(RuntimeError):
    pass


def capacity(root, *, statvfs=os.statvfs, used_bytes=None, projected_bytes=0):
    """Fail closed unless genuine available bytes and the fixture cap both hold."""
    root = Path(root)
    try:
        status = statvfs(root)
        available = status.f_bavail * status.f_frsize
        used = used_bytes if used_bytes is not None else sum(
            path.stat().st_size for path in root.rglob("*") if path.is_file()
        )
    except (OSError, AttributeError, TypeError) as error:
        raise CapacityError("Cannot determine genuine filesystem capacity") from error
    if min(available, used, projected_bytes) < 0 or used + projected_bytes > CAP:
        raise CapacityError("Document fixture would exceed its 16 MiB cap")
    if available < RESERVE + projected_bytes:
        raise CapacityError("Document fixture requires a genuine 10 GiB available-byte reserve")
    return used


def write_guarded(root, path, data, mode=0o600):
    capacity(root, projected_bytes=len(data))
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_bytes(data)
    os.chmod(path, mode)
    capacity(root)


def check_capacity(root, projected=1024 * 1024):
    capacity(root, projected_bytes=projected)


def fake_converter_source():
    return r'''#!/usr/bin/env python3
import hashlib, json, os, pathlib, sys, tempfile

if len(sys.argv) != 6 or sys.argv[1] != "convert":
    raise SystemExit("expected convert MODEL_DIRECTORY INPUT_FILE MEDIA_TYPE OUTPUT_FILE")
model = pathlib.Path(sys.argv[2])
original = pathlib.Path(sys.argv[3])
media = sys.argv[4]
output = pathlib.Path(sys.argv[5])
root = pathlib.Path(os.environ["TRACTANDA_TEST_ROOT"])
RESERVE, CAP = 10 * 1024**3, 16 * 1024**2

def guard(extra=0):
    s = os.statvfs(root)
    available = s.f_bavail * s.f_frsize
    used = sum(p.stat().st_size for p in root.rglob("*") if p.is_file())
    if available < RESERVE + extra or used + extra > CAP:
        raise SystemExit("fixture capacity guard rejected converter write")

calls = model / "calls.jsonl"
guard(2048 * 1024)
with calls.open("a", encoding="utf-8") as stream:
    stream.write(json.dumps({"mediaType": media, "inputSHA256": hashlib.sha256(original.read_bytes()).hexdigest()}) + "\n")
guard()

def geometry(width, height, unit="pixel"):
    if width >= height:
        content_width, content_height = 2048.0, 2048.0 * height / width
        left, top = 0.0, (2048.0 - content_height) / 2
    else:
        content_height, content_width = 2048.0, 2048.0 * width / height
        left, top = (2048.0 - content_width) / 2, 0.0
    crop_left, crop_top = math.floor(left), math.floor(top)
    canvas_width = math.ceil(left + content_width) - crop_left
    canvas_height = math.ceil(top + content_height) - crop_top
    return {"sourceWidth": float(width), "sourceHeight": float(height), "sourceOriginX": 0,
        "sourceOriginY": 0, "sourceRotation": 0, "sourceUnit": unit,
        "displayWidth": float(width), "displayHeight": float(height), "canvasWidth": canvas_width,
        "canvasHeight": canvas_height, "contentLeft": left - crop_left, "contentTop": top - crop_top,
        "contentWidth": content_width, "contentHeight": content_height}

def page(number, width, height, text, unit="pixel", raw=None):
    return {"pageNumber": number, "geometry": geometry(width, height, unit),
        "rasterSHA256": ("b" if number == 1 else "c") * 64,
        "rawDocTags": raw or ("<doctag><text><loc_10><loc_20><loc_300><loc_120>" + text + "</text></doctag>"),
        "generatedTokens": 40, "stopReason": "stop"}

raw_pdf2 = "<doctag><otsl><loc_10><loc_10><loc_400><loc_400><fcel>LEFT<ched>RIGHT<nl><fcel>17<ched>29</otsl></doctag>"
pages = ([page(1, 640, 320, "SYNTHETIC IMAGE garden supplies")]
    if media in ("image/png", "image/jpeg") else [
        page(1, 612, 792, "SYNTHETIC PDF portrait garden supplies", "pdfPoint"),
        page(2, 792, 612, "", "pdfPoint", raw_pdf2)])
mode_file = model / "fake-mode.txt"
if mode_file.exists() and mode_file.read_text().strip() == "malformed":
    pages[0]["rawDocTags"] = "<doctag><text>truncated"
document = {"inputSHA256": hashlib.sha256(original.read_bytes()).hexdigest(), "identity": {
    "converter": "tractanda.docling-native.v2-idefics3-gelu-f32", "model": "ibm-granite/granite-docling-258M-mlx",
    "modelRevision": "a8b999991fe8c521a0cec749973414eaaf823731",
    "runtimeRevision": "61a4b20d4ad01b10466e8fc94c50402a9f994430",
    "preprocessing": "opaque-rgb-content-crop-hf4561-pillow123-grid-v2", "parser": "doctags-strict-v1"}, "pages": pages}
encoded = json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode()
if len(encoded) > 2 * 1024 * 1024:
    raise SystemExit("fake converter output over limit")
guard(len(encoded) + 2048)
temporary = output.with_name(output.name + ".fake-tmp")
temporary.write_bytes(encoded)
os.replace(temporary, output)
guard()
'''


def create_item(client, subject, body):
    return client.commit(ipc.intent("create", "document-fixture-" + subject.replace(" ", "-").lower(),
        class_id="Item", changes={"subject": ipc.text(subject), "body": ipc.text(body)}))["revision"]


def error_code(binary, args):
    process = subprocess.run([binary, *args], capture_output=True, text=True, timeout=20)
    if process.returncode == 0:
        raise AssertionError("Expected CLI failure: " + " ".join(args))
    try:
        return json.loads(process.stderr).get("code") or json.loads(process.stderr).get("type")
    except json.JSONDecodeError:
        return None


def cli_output(root, binary, args, timeout=20):
    """Capture the original owned-child failure before the disposable tree unwinds."""
    try:
        result = subprocess.run(
            [binary, *args], capture_output=True, text=True, timeout=timeout, check=False
        )
    except subprocess.TimeoutExpired as error:
        receipt = {
            "stage": args[0] if args else "unknown",
            "kind": "timeout",
            "timeoutSeconds": timeout,
            "stdout": (error.stdout or b"").decode(errors="replace")[-8192:]
                if isinstance(error.stdout, bytes) else str(error.stdout or "")[-8192:],
            "stderr": (error.stderr or b"").decode(errors="replace")[-8192:]
                if isinstance(error.stderr, bytes) else str(error.stderr or "")[-8192:],
        }
        failure_dir = PROJECT / "work/docling-integration-20261007/cli"
        failure_dir.mkdir(parents=True, exist_ok=True)
        (failure_dir / "last-failure.json").write_text(json.dumps(receipt, indent=2) + "\n")
        raise
    if result.returncode != 0:
        receipt = {
            "stage": args[0] if args else "unknown",
            "returnCode": result.returncode,
            "argv": [binary, *args],
            "stdout": result.stdout[-8192:],
            "stderr": result.stderr[-8192:],
        }
        failure_dir = PROJECT / "work/docling-integration-20261007/cli"
        failure_dir.mkdir(parents=True, exist_ok=True)
        (failure_dir / "last-failure.json").write_text(json.dumps(receipt, indent=2) + "\n")
        raise subprocess.CalledProcessError(
            result.returncode, [binary, *args], output=result.stdout, stderr=result.stderr
        )
    return result.stdout


@contextlib.contextmanager
def daemon(binary, store, socket_path, converter, model, scratch, root):
    log = tempfile.TemporaryFile()
    environment = dict(os.environ, TRACTANDA_TEST_ROOT=str(root))
    process = subprocess.Popen([
        binary, "daemon", str(store), str(socket_path), "--no-http",
        "--document-converter", str(converter), "--document-model-directory", str(model),
        "--document-scratch-directory", str(scratch),
    ], stdout=subprocess.DEVNULL, stderr=log, env=environment)
    try:
        deadline = time.monotonic() + 30
        while not socket_path.exists():
            if process.poll() is not None or time.monotonic() > deadline:
                log.seek(0)
                raise RuntimeError("Disposable document daemon did not become ready: " + log.read().decode())
            time.sleep(0.05)
        yield ipc.Client(socket_path)
    finally:
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=30)
        except subprocess.TimeoutExpired as error:
            process.kill()
            process.wait()
            log.close()
            raise RuntimeError("Owned disposable daemon did not stop after SIGTERM") from error
        if process.returncode != 0:
            log.seek(0)
            detail = log.read().decode(errors="replace")[-4096:]
            log.close()
            raise RuntimeError(f"Disposable daemon exited {process.returncode}: {detail}")
        if socket_path.exists():
            raise RuntimeError("Graceful daemon shutdown left its socket behind")
        log.close()


def verify(binary):
    binary = str(Path(binary).resolve())
    fixtures = PROJECT / "work/docling-integration-20261007/raster"
    image = fixtures / "paragraph-alpha.png"
    pdf = fixtures / "portrait-landscape.pdf"
    manifest = json.loads((fixtures / "fixture-manifest.json").read_text())
    assert hashlib.sha256(image.read_bytes()).hexdigest() == manifest["files"]["paragraphAlpha"]["sha256"]
    assert hashlib.sha256(pdf.read_bytes()).hexdigest() == manifest["files"]["twoPagePDF"]["sha256"]
    with tempfile.TemporaryDirectory(prefix="tractanda-document-", dir="/tmp") as temporary:
        root = Path(temporary)
        check_capacity(root, projected=2 * 1024 * 1024)
        store, socket_path = root / "store", root / "daemon.sock"
        model = root / "fake-model"
        scratch = root / "scratch"
        model.mkdir(mode=0o700)
        scratch.mkdir(mode=0o700)
        converter = root / "fake-document-converter.py"
        write_guarded(root, converter, fake_converter_source().encode())
        converter.chmod(0o700)
        model_arg = model
        check_capacity(root, projected=1024 * 1024)
        subprocess.run([binary, "init", str(store)], check=True, capture_output=True, timeout=30)
        check_capacity(root)
        with daemon(binary, store, socket_path, converter, model_arg, scratch, root) as client:
            info = json.loads(subprocess.check_output([binary, "info", str(socket_path)], timeout=20))
            assert "tractanda.attachment-document.v1" in info["features"]
            assert info["documentExtraction"]["state"] == "configured"

            image_revision = create_item(client, "Synthetic image document", "Disposable image extraction test.")
            item_id, initial_revision = ipc.item_id(image_revision), ipc.revision_id(image_revision)
            check_capacity(root, projected=1024 * 1024)
            attached_image = json.loads(subprocess.check_output([
                binary, "attach", str(socket_path), item_id, initial_revision, "attach-image",
                str(image), "image/png"], timeout=30))
            check_capacity(root)
            image_attachment = client.call("TractandaAttachment/list", {"itemID": item_id})["attachments"][0]
            extract_args = ["extract-document", str(socket_path), item_id, attached_image["revisionID"],
                image_attachment["attachmentID"], "extract-image"]
            check_capacity(root, projected=1024 * 1024)
            image_receipt = json.loads(cli_output(root, binary, extract_args, timeout=390))
            calls_file = model_arg / "calls.jsonl"
            first_calls = calls_file.read_text().splitlines()
            assert len(first_calls) == 1
            replay = json.loads(subprocess.check_output([binary, *extract_args], timeout=30))
            assert replay["revisionID"] == image_receipt["revisionID"] and replay["replayed"]
            assert len(calls_file.read_text().splitlines()) == 1, "Exact replay invoked converter again"

            full = json.loads(subprocess.check_output([
                binary, "attachment-document", str(socket_path), item_id, image_attachment["attachmentID"]],
                timeout=30))
            assert full["totalPageCount"] == 1 and full.get("selectedPageNumber") is None
            assert full["pages"][0]["parsed"]["text"] == "SYNTHETIC IMAGE garden supplies"
            selected = json.loads(subprocess.check_output([
                binary, "attachment-document", str(socket_path), item_id, image_attachment["attachmentID"],
                "--page", "1", "--max-bytes", "2097152"], timeout=30))
            assert selected["selectedPageNumber"] == 1 and len(selected["pages"]) == 1
            document_text = full["pages"][0]["parsed"]["text"]
            assert "garden supplies" in document_text
            query = client.call("TractandaItem/query", {"text": "garden supplies", "limit": 16})
            assert item_id in query["ids"]
            diagnostic = client.call("TractandaItem/extractedText", {
                "ids": [item_id], "projection": "source", "maxBytes": 524288})
            assert diagnostic["extractionProfile"] == "tractanda.item-text.v5"
            row = diagnostic["list"][0]
            assert row["sourceText"].count(document_text) == 1
            source = next(entry for entry in row["sources"] if entry["attachmentID"] == image_attachment["attachmentID"])
            assert source["location"]["kind"] == "document"
            assert "byteStart" not in source["location"] and "byteEnd" not in source["location"]
            assert source["sourceSHA256"] == image_attachment["sha256"]
            corpus = row["sourceText"].encode("utf-8")
            assert corpus[source["corpusByteStart"]:source["corpusByteEnd"]] == document_text.encode("utf-8")
            assert source["location"]["rasterSHA256"] == "b" * 64

            check_capacity(root, projected=1024 * 1024)
            exported = root / "image.original"
            subprocess.run([binary, "export-attachment", str(socket_path), item_id,
                image_attachment["attachmentID"], str(exported)], check=True, capture_output=True, timeout=30)
            assert exported.read_bytes() == image.read_bytes()
            image_after = client.get(item_id)
            assert ipc.revision_id(image_after) == image_receipt["revisionID"]

            pdf_revision = create_item(client, "Synthetic PDF document", "Two page disposable PDF test.")
            pdf_id, pdf_base = ipc.item_id(pdf_revision), ipc.revision_id(pdf_revision)
            check_capacity(root, projected=1024 * 1024)
            attached_pdf = json.loads(subprocess.check_output([
                binary, "attach", str(socket_path), pdf_id, pdf_base, "attach-pdf", str(pdf),
                "application/pdf"], timeout=30))
            check_capacity(root)
            pdf_attachment = client.call("TractandaAttachment/list", {"itemID": pdf_id})["attachments"][0]
            pdf_args = ["extract-document", str(socket_path), pdf_id, attached_pdf["revisionID"],
                pdf_attachment["attachmentID"], "extract-pdf"]
            check_capacity(root, projected=1024 * 1024)
            pdf_receipt = json.loads(cli_output(root, binary, pdf_args, timeout=390))
            pdf_read = json.loads(subprocess.check_output([
                binary, "attachment-document", str(socket_path), pdf_id, pdf_attachment["attachmentID"]],
                timeout=30))
            assert pdf_read["totalPageCount"] == 2 and len(pdf_read["pages"]) == 2
            page_two = json.loads(subprocess.check_output([
                binary, "attachment-document", str(socket_path), pdf_id, pdf_attachment["attachmentID"],
                "--page", "2"], timeout=30))
            assert page_two["totalPageCount"] == 2 and page_two["selectedPageNumber"] == 2
            assert page_two["pages"][0]["parsed"]["text"] == "LEFT\tRIGHT\n17\t29"
            assert pdf_receipt["revisionID"] == pdf_read["revisionID"]
            pdf_diagnostic = client.call("TractandaItem/extractedText", {
                "ids": [pdf_id], "projection": "source", "maxBytes": 524288})["list"][0]
            pdf_source = next(entry for entry in pdf_diagnostic["sources"]
                if entry["attachmentID"] == pdf_attachment["attachmentID"]
                and entry["location"]["pageNumber"] == 2)
            assert pdf_source["location"]["kind"] == "document"
            assert pdf_source["location"]["pageNumber"] == 2
            assert pdf_source["location"]["rasterSHA256"] == "c" * 64
            pdf_export = root / "pdf.original"
            check_capacity(root, projected=1024 * 1024)
            subprocess.run([binary, "export-attachment", str(socket_path), pdf_id,
                pdf_attachment["attachmentID"], str(pdf_export)], check=True, capture_output=True, timeout=30)
            assert pdf_export.read_bytes() == pdf.read_bytes()

            stale_error = error_code(binary, ["extract-document", str(socket_path), item_id,
                attached_image["revisionID"], image_attachment["attachmentID"], "different-operation"])
            assert stale_error == "revisionConflict", stale_error
            assert len(calls_file.read_text().splitlines()) == 2, "CAS rejection ran the converter"

            # Unknown/malformed converter output must preserve canonical revision and original bytes.
            before_bad_output = client.get(item_id)
            write_guarded(root, model_arg / "fake-mode.txt", b"malformed\n")
            bad_output_error = error_code(binary, ["extract-document", str(socket_path), item_id,
                ipc.revision_id(before_bad_output), image_attachment["attachmentID"], "bad-output"])
            (model_arg / "fake-mode.txt").unlink()
            assert bad_output_error in {"unsupportedDocumentOutput", "invalidDocumentOutput"}, bad_output_error
            after_bad_output = client.get(item_id)
            assert ipc.revision_id(after_bad_output) == ipc.revision_id(before_bad_output)
            assert exported.read_bytes() == image.read_bytes()

            summary = client.call("TractandaItem/get", {
                "ids": [item_id], "projection": "summary", "maxBytes": 8192})
            assert "attachmentDocument" not in summary["list"][0]["fields"]
            before_query = client.call("TractandaItem/query", {"text": "garden supplies", "limit": 16})["ids"]
            check_capacity(root, projected=1024 * 1024)
            client.call("TractandaStore/rebuild")
            after_query = client.call("TractandaItem/query", {"text": "garden supplies", "limit": 16})["ids"]
            assert after_query == before_query and item_id in after_query

            copied = client.commit(ipc.intent("copy", "copy-document-fixture", item_id,
                ipc.revision_id(client.get(item_id))))["revision"]
            copy_id = ipc.item_id(copied)
            copied_attachment = client.call("TractandaAttachment/list", {"itemID": copy_id})["attachments"][0]
            copied_document = client.call("TractandaAttachment/document", {
                "itemID": copy_id, "attachmentID": copied_attachment["attachmentID"], "maxBytes": 1_048_576})
            assert copied_document["source"]["sha256"] == image_attachment["sha256"]
            assert copied_attachment["attachmentID"] != image_attachment["attachmentID"]
            copied_export = root / "copied.original"
            check_capacity(root, projected=1024 * 1024)
            subprocess.run([binary, "export-attachment", str(socket_path), copy_id,
                copied_attachment["attachmentID"], str(copied_export)], check=True, capture_output=True, timeout=30)
            assert copied_export.read_bytes() == image.read_bytes()
            copy_history_before = client.call("TractandaItem/history", {"itemID": copy_id})["total"]
            detach = json.loads(subprocess.check_output([binary, "detach", str(socket_path), copy_id,
                ipc.revision_id(copied), "detach-copied-document", copied_attachment["attachmentID"]],
                timeout=30))
            assert detach["revisionID"] != ipc.revision_id(copied)
            assert client.call("TractandaItem/history", {"itemID": copy_id})["total"] == copy_history_before + 1
            historical_document = client.call("TractandaAttachment/document", {
                "itemID": copy_id, "revisionID": ipc.revision_id(copied),
                "attachmentID": copied_attachment["attachmentID"], "maxBytes": 1_048_576})
            assert historical_document["representationID"] == copied_document["representationID"]
            assert copied_export.read_bytes() == image.read_bytes()

            report = {
                "passed": True, "fixtureOnly": True, "converter": "controlled fake; no MLX/model weights loaded",
                "fixtureImageSHA256": hashlib.sha256(image.read_bytes()).hexdigest(),
                "fixturePDFSHA256": hashlib.sha256(pdf.read_bytes()).hexdigest(),
                "originalsByteIdenticalAfterExtractionCopyDetach": True,
                "fakeConverterCalls": len(calls_file.read_text().splitlines()),
                "checks": ["configured disposable async daemon", "feature/info", "image extraction and complete read",
                    "PDF two-page extraction and page-two read", "table text and typed document citation without byte offsets",
                    "FTS once-only text", "exact replay without converter reinvocation", "stale-head CAS before conversion",
                    "malformed output preserves current revision", "compact summary exclusion", "history and rebuild",
                    "copy locator remap and original bytes", "detach preserves historical output and original"],
                "fixtureCapBytes": CAP, "reserveBytes": RESERVE,
            }
            capacity(root)
            return report


def stop(signum, frame):
    raise KeyboardInterrupt(f"Document fixture received signal {signum}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary")
    options = parser.parse_args()
    signal.signal(signal.SIGTERM, stop)
    try:
        # /tmp is shared; only genuine free capacity is global. The fixture tree's
        # own byte count is checked immediately after its private temp directory exists.
        capacity("/tmp", used_bytes=0, projected_bytes=CAP)
        print(json.dumps(verify(options.binary), indent=2))
    except CapacityError as error:
        raise SystemExit(str(error)) from error
