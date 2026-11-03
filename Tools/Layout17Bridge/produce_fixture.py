#!/usr/bin/env python3
"""Create a small private 16.2 canonical-store fixture without using a profile."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
CLI = None
ROOT = None
STORE = None
ORIGINAL = None
PARTIAL_SOURCE = None
MANIFEST = None
SOCKET = None
MAX_FIXTURE_BYTES = 128 * 1024 * 1024
MINIMUM_FREE_BYTES = 10 * 1024 * 1024 * 1024

# Keep only ordinary runtime essentials. No profile/config/home override is set.
ENV = {key: os.environ[key] for key in ("PATH",) if key in os.environ}
ENV["LC_ALL"] = "C"


def run(*args: str) -> str:
    result = subprocess.run([str(CLI), *args], capture_output=True, text=True, env=ENV)
    if result.returncode:
        raise RuntimeError(f"CLI failed ({result.returncode}): {result.stderr or result.stdout}")
    return result.stdout.strip()


def json_cli(*args: str):
    return json.loads(run(*args))


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def commit_ids(result):
    revision = result.get("revision", result)
    item_id = revision.get("itemID") or revision.get("itemId")
    revision_id = revision.get("revisionID") or revision.get("revisionId")
    if not item_id or not revision_id:
        raise RuntimeError(f"Unexpected commit response shape: {result!r}")
    return item_id, revision_id


def set_private(path: Path, mode: int) -> None:
    path.chmod(mode)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path,
                        help="absolute path to an installed tractanda 0.1.0-poc.16.2 CLI")
    parser.add_argument("--output", required=True, type=Path,
                        help="new private fixture directory; it must not already exist")
    args = parser.parse_args()
    global CLI, ROOT, STORE, ORIGINAL, PARTIAL_SOURCE, MANIFEST, SOCKET
    try:
        CLI = args.binary.expanduser().resolve(strict=True)
    except FileNotFoundError:
        parser.error(f"--binary does not exist: {args.binary}")
    if not CLI.is_file() or not os.access(CLI, os.X_OK):
        parser.error(f"--binary must be an executable file: {CLI}")
    if not args.output.is_absolute():
        parser.error("--output must be an absolute path inside a private temporary or user-private directory")
    parent = args.output.parent.resolve(strict=True)
    ROOT = parent / args.output.name
    STORE = ROOT / "store"
    ORIGINAL = ROOT / "fixture-original.txt"
    PARTIAL_SOURCE = ROOT / "fixture-partial-upload.bin"
    MANIFEST = ROOT / "manifest.json"
    SOCKET = Path(tempfile.gettempdir()).resolve() / f"t17-{os.getpid()}.sock"
    if len(str(SOCKET).encode()) >= 100:
        parser.error(f"temporary socket path is too long: {SOCKET}; set TMPDIR to a short path")
    if SOCKET.exists():
        parser.error(f"refusing existing temporary socket path: {SOCKET}")
    if ROOT.exists():
        parser.error(f"refusing to overwrite existing fixture: {ROOT}")
    temp_roots = {Path(tempfile.gettempdir()).resolve()}
    for candidate in (Path("/tmp"), Path("/private/tmp")):
        if candidate.exists():
            temp_roots.add(candidate.resolve())
    in_temp = False
    for temp_root in temp_roots:
        try:
            parent.relative_to(temp_root)
            in_temp = True
            break
        except ValueError:
            continue
    parent_stat = parent.stat()
    parent_private = parent_stat.st_uid == os.getuid() and parent_stat.st_mode & 0o077 == 0
    if not in_temp and not parent_private:
        parser.error("--output parent must be inside the system temporary directory or owned/private (mode 0700)")
    for protected in (Path("/Library/Tractanda/Stores"), Path("/opt/tractanda/var/lib/tractanda")):
        try:
            ROOT.relative_to(protected)
        except ValueError:
            continue
        parser.error(f"--output may not be inside a production Tractanda store root: {protected}")
    if shutil.disk_usage(parent).free < MINIMUM_FREE_BYTES:
        parser.error(f"need 10 GiB free on the output filesystem ({parent})")
    root_created = False
    completed = False
    ROOT.mkdir(mode=0o700, parents=True)
    root_created = True
    set_private(ROOT, 0o700)
    original = b"Layout17 migration fixture: immutable attached original bytes.\n"
    partial = bytes(range(256)) * 1024  # 256 KiB source; retain only an acknowledged prefix.
    if len(original) + len(partial) > MAX_FIXTURE_BYTES:
        raise RuntimeError("Fixture byte limit exceeded")
    try:
        ORIGINAL.write_bytes(original)
        PARTIAL_SOURCE.write_bytes(partial)
        set_private(ORIGINAL, 0o600)
        set_private(PARTIAL_SOURCE, 0o600)
    except Exception:
        shutil.rmtree(ROOT, ignore_errors=True)
        raise

    server: subprocess.Popen[str] | None = None
    server_created_socket = False
    try:
        initialized = json_cli("init", str(STORE))
        server = subprocess.Popen(
            [str(CLI), "daemon", str(STORE), str(SOCKET), "--no-http"],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=ENV,
        )
        deadline = time.monotonic() + 20
        while not SOCKET.exists():
            if server.poll() is not None:
                out, err = server.communicate()
                raise RuntimeError(f"Private fixture server exited: {err or out}")
            if time.monotonic() >= deadline:
                raise RuntimeError("Private fixture server did not create its isolated socket")
            time.sleep(0.05)
        server_created_socket = True

        info = json_cli("info", str(SOCKET))
        version = info.get("server", {}).get("version")
        if version != "0.1.0-poc.16.2":
            raise RuntimeError(f"Expected 0.1.0-poc.16.2; isolated server reports {version!r}")
        first = json_cli(
            "create", str(SOCKET), "Item", "Layout17 fixture with attachment",
            "layout17-fixture-create-1", "Original attached content fixture",
        )
        first_id, first_revision = commit_ids(first)

        # Complete a normal attachment through the old CLI; this creates exactly the
        # second revision and writes the old immutable placement intent without CLI receipts.
        attached = json_cli(
            "attach", str(SOCKET), first_id, first_revision,
            "layout17-fixture-attach-1", str(ORIGINAL), "text/plain",
        )
        _, attached_revision = commit_ids(attached)

        # Begin, then append only a small prefix via explicit local socket API calls.
        begin_args = {
            "itemID": first_id,
            "expectedRevisionID": attached_revision,
            "operationID": "layout17-fixture-partial-1",
            "filename": PARTIAL_SOURCE.name,
            "mediaType": "application/octet-stream",
            "byteCount": len(partial),
            "sha256": sha(partial),
        }
        begin = json_cli(
            "call", str(SOCKET), "TractandaAttachment/begin", json.dumps(begin_args, separators=(",", ":"))
        )
        upload_id = begin.get("uploadID") or begin.get("uploadId")
        if not upload_id:
            raise RuntimeError(f"Unexpected attachment begin response shape: {begin!r}")
        acknowledged = 23
        chunk_args = {
            "uploadID": upload_id, "offset": 0,
            "data": base64.b64encode(partial[:acknowledged]).decode("ascii"),
        }
        chunk = json_cli(
            "call", str(SOCKET), "TractandaAttachment/upload", json.dumps(chunk_args, separators=(",", ":"))
        )
        if int(chunk["offset"]) != acknowledged:
            raise RuntimeError(f"Unexpected partial upload offset: {chunk}")

        second_item = json_cli(
            "create", str(SOCKET), "Item", "Second layout17 fixture item",
            "layout17-fixture-create-2", "One-revision companion record",
        )
        second_item_id, second_item_revision = commit_ids(second_item)
        first_get = json_cli("get", str(SOCKET), first_id)
        first_history = json_cli("history", str(SOCKET), first_id)
        second_get = json_cli("get", str(SOCKET), second_item_id)
        second_history = json_cli("history", str(SOCKET), second_item_id)
        upload_status = json_cli("call", str(SOCKET), "TractandaAttachment/uploadStatus", json.dumps({"uploadID": upload_id}))

        canonical_records = []
        record_counts: dict[str, int] = {}
        for path in sorted(STORE.glob("items/**/*.tractanda")):
            raw = path.read_bytes()
            relative = path.relative_to(STORE)
            item_id = relative.parts[-2]
            record_counts[item_id] = record_counts.get(item_id, 0) + 1
            canonical_records.append({
                "path": relative.as_posix(), "sha256": sha(raw),
                "size": len(raw), "mode": oct(path.stat().st_mode & 0o777),
            })
        payloads = []
        for path in sorted((STORE / "attachments" / "payloads").glob("**/*.payload")):
            raw = path.read_bytes()
            payloads.append({
                "path": path.relative_to(STORE).as_posix(), "sha256": sha(raw),
                "size": len(raw), "mode": oct(path.stat().st_mode & 0o777),
            })
        placements = []
        placement_root = STORE / "attachments" / ".placements"
        if placement_root.exists():
            for path in sorted(placement_root.rglob("*")):
                if path.is_file():
                    raw = path.read_bytes()
                    placements.append({
                        "path": path.relative_to(STORE).as_posix(), "sha256": sha(raw),
                        "size": len(raw), "mode": oct(path.stat().st_mode & 0o777),
                    })
        staging = []
        staging_root = STORE / "attachments" / ".staging"
        if staging_root.exists():
            for path in sorted(staging_root.rglob("*")):
                if path.is_file():
                    raw = path.read_bytes()
                    staging.append({
                        "path": path.relative_to(STORE).as_posix(), "sha256": sha(raw),
                        "size": len(raw), "mode": oct(path.stat().st_mode & 0o777),
                    })
        uploads = []
        upload_root = STORE / "attachments" / ".uploads"
        if upload_root.exists():
            for path in sorted(upload_root.rglob("*")):
                if path.is_file():
                    raw = path.read_bytes()
                    uploads.append({
                        "path": path.relative_to(STORE).as_posix(), "sha256": sha(raw),
                        "size": len(raw), "mode": oct(path.stat().st_mode & 0o777),
                    })
        store_identity = STORE / ".tractanda-store-identity.json"
        replica_identity = STORE / ".tractanda-replica-identity.json"
        identities = {}
        for name, path in (("store", store_identity), ("replica", replica_identity)):
            if path.is_file():
                identities[name] = json.loads(path.read_text())

        manifest = {
            "schema": "tractanda.layout17-fixture.poc16.2.v1",
            "producer": str(CLI),
            "fixtureRoot": str(ROOT),
            "storeRoot": str(STORE),
            "storeIDs": identities,
            "init": initialized,
            "info": info,
            "items": [
                {"itemID": first_id, "initialRevisionID": first_revision,
                 "currentRevisionID": attached_revision,
                 "get": first_get, "history": first_history},
                {"itemID": second_item_id, "currentRevisionID": second_item_revision,
                 "get": second_get, "history": second_history},
            ],
            "records": canonical_records,
            "originalAttachment": {"sourcePath": str(ORIGINAL), "sourceSHA256": sha(original),
                                   "payloads": payloads, "placementIntentFiles": placements},
            "partialUpload": {"uploadID": upload_id, "acknowledgedOffset": acknowledged,
                              "status": upload_status, "sourcePath": str(PARTIAL_SOURCE),
                              "sourceSHA256": sha(partial), "stageFiles": staging,
                              "checkpointFiles": uploads},
            "coverage": {
                "twoItemRecords": len(record_counts) == 2,
                "firstHistoryExactlyTwo": record_counts.get(first_id) == 2,
                "secondHistoryExactlyOne": record_counts.get(second_item_id) == 1,
                "completedOriginalAttachment": bool(payloads),
                "partialUploadOffset": int(chunk["offset"]),
                "placementIntentObserved": bool(placements),
            },
            "limitations": [
                "Fixture is private and generated in a new isolated store; production paths were not read.",
                "No migration was run; the .17 converter has not been supplied.",
                "Partial upload is present only if the runtime emitted both checkpoint and stage files; see arrays above.",
                "Personal recovery inventory intentionally excludes hidden staging/checkpoint data from canonical admission.",
            ],
        }
        encoded = json.dumps(manifest, indent=2, sort_keys=True).encode() + b"\n"
        if len(encoded) + sum(p.stat().st_size for p in ROOT.rglob("*") if p.is_file()) > MAX_FIXTURE_BYTES:
            raise RuntimeError("Fixture exceeded 128 MiB cap")
        MANIFEST.write_bytes(encoded)
        set_private(MANIFEST, 0o600)
        completed = True
        print(json.dumps({"manifest": str(MANIFEST), "recordCount": len(canonical_records),
                          "payloadCount": len(payloads), "placementCount": len(placements),
                          "stageCount": len(staging), "checkpointCount": len(uploads),
                          "partialOffset": chunk["offset"], "storeIDs": identities}, indent=2))
        return 0
    finally:
        if server is not None and server.poll() is None:
            server.send_signal(signal.SIGTERM)
            server.wait()
        if server_created_socket:
            try:
                if SOCKET.is_socket() and SOCKET.lstat().st_uid == os.getuid():
                    SOCKET.unlink()
            except FileNotFoundError:
                pass
        if root_created and not completed:
            shutil.rmtree(ROOT, ignore_errors=True)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"fixture producer failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
