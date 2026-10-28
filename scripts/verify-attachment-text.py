#!/usr/bin/env python3
"""Small deterministic extraction/query/citation fixture; optional child runs inside server lifetime."""
from jmap_client import query_arguments
import argparse
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile

PROJECT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("wire", PROJECT / "scripts/verify-ipc.py")
wire = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(wire)
RESERVE = 10 * 1024**3
CAP = 16 * 1024**2


def capacity(root):
    state = os.statvfs(root)
    available = state.f_bavail * state.f_frsize
    actual = sum(p.stat().st_size for p in root.rglob("*") if p.is_file())
    if actual > CAP or available < RESERVE + CAP:
        raise RuntimeError("Extraction fixture requires a genuine 10 GiB reserve and 16 MiB fixture cap")
    return actual


def verify(binary, child):
    with tempfile.TemporaryDirectory(prefix="tractanda-text-", dir="/tmp") as temporary:
        root = Path(temporary)
        capacity(root)
        store, socket = root / "store", root / "socket"
        subprocess.check_output([binary, "init", str(store)])
        text = "# Grant briefing\r\nCurrent deadline: 15 October 2030 at 17:00 UTC.\r\nBudget: €500 for garden supplies.\r\n"
        original = b"\xef\xbb\xbf" + text.encode("utf-8")
        source = root / "grant-briefing.md"
        source.write_bytes(original)
        with wire.server(binary, store, socket) as client:
            help_text = subprocess.check_output([binary, "--help"], text=True)
            assert "tractanda describe SOCKET" in help_text and "tractanda extracted-text SOCKET" in help_text
            overview = json.loads(subprocess.check_output([binary, "describe", str(socket)]))
            assert overview["topic"] == "overview" and overview["capability"] == wire.CAPABILITY
            properties = json.loads(subprocess.check_output([binary, "describe", str(socket), "properties"]))
            assert properties["topic"] == "properties"
            current = client.commit_with_revision(wire.intent("create", "task", class_id="Item", changes={
                "subject": wire.text("Prepare the community garden grant"),
                "body": wire.text("Current task: prepare and submit the grant application using the attached briefing."),
            }))["revision"]
            history = client.commit_with_revision(wire.intent("create", "discussion", class_id="Item", changes={
                "subject": wire.text("Archived discussion about garden fundraising"),
                "body": wire.text("Historical discussion from 2025: someone suggested an August deadline. No current task was assigned here."),
            }))["revision"]
            item_id, base_id = wire.item_id(current), wire.revision_id(current)
            capacity(root)
            attached = json.loads(subprocess.check_output([binary, "attach", str(socket), item_id, base_id,
                "original", str(source), "text/markdown"]))
            descriptor = client.call("TractandaAttachment/list", {"itemID": item_id})["attachments"][0]
            before = client.call("TractandaItem/query", query_arguments({"text": "garden supplies", "limit": 16}))
            assert before["ids"] == []
            command = [binary, "extract-attachment", str(socket), item_id, attached["revisionID"], "extract", descriptor["attachmentID"]]
            capacity(root)
            extracted = json.loads(subprocess.check_output(command))
            replay = json.loads(subprocess.check_output(command))
            assert extracted["revisionID"] == replay["revisionID"] and replay["replayed"]
            assert "revision" not in extracted
            query = client.call("TractandaItem/query", query_arguments({"text": "garden supplies", "limit": 16}))
            assert query["ids"] == [item_id]
            diagnostic = json.loads(subprocess.check_output([binary, "extracted-text", str(socket), *query["ids"]]))
            assert diagnostic["extractionProfile"] == "tractanda.item-text.v8"
            row = diagnostic["list"][0]
            assert row["sourceText"].count(text) == 1
            assert descriptor["sha256"] not in row["sourceText"]
            location = row["sources"][0]
            assert location["location"]["kind"] == "originalBytes"
            assert set(location["location"]) == {"kind", "byteStart", "byteEnd"}
            assert location["location"]["byteStart"] == 3 and location["location"]["byteEnd"] == len(original)
            assert location["sourceSHA256"] == descriptor["sha256"]
            assert location["revisionID"] == extracted["revisionID"]
            saved = client.get(item_id)
            representation = saved["fields"]["attachmentText"]["value"][0]["value"]
            provenance_revision = representation["source"]["value"]["revisionID"]["value"]
            assert provenance_revision == attached["revisionID"]
            assert location["revisionID"] == wire.revision_id(saved)
            assert location["revisionID"] != provenance_revision
            corpus = row["sourceText"].encode("utf-8")
            assert corpus[location["corpusByteStart"]:location["corpusByteEnd"]] == original[3:]
            summary = client.call("TractandaItem/get", {"ids": [item_id], "projection": "summary", "maxBytes": 8192})
            assert "attachmentText" not in summary["list"][0]["fields"]
            capacity(root)
            client.rebuild("verify-attachment-text-rebuild")
            assert client.call("TractandaItem/query", query_arguments({"text": "garden supplies", "limit": 16}))["ids"] == [item_id]
            manifest = {"binary": binary, "socket": str(socket), "fixtureOnly": True,
                "currentTaskID": item_id, "historicalDiscussionID": wire.item_id(history),
                "attachmentID": descriptor["attachmentID"], "extractedRevisionID": extracted["revisionID"],
                "question": "What is the current grant deadline and budget? Cite exact original-byte evidence and distinguish the archived discussion.",
                "expectedSource": location}
            manifest_path = root / "fixture-manifest.json"
            manifest_path.write_text(json.dumps(manifest, indent=2))
            if child:
                print(json.dumps({"fixtureManifest": str(manifest_path), **manifest}), flush=True)
                environment = dict(os.environ, TRACTANDA_FIXTURE_MANIFEST=str(manifest_path),
                    TRACTANDA_FIXTURE_SOCKET=str(socket), TRACTANDA_FIXTURE_BINARY=binary)
                subprocess.run(child, env=environment, check=True, timeout=180)
            return {"passed": True, "extractionProfile": "tractanda.item-text.v8", "originalBytes": len(original),
                "sourceByteStart": 3, "currentLocatorMatchesDeliveredRevision": True,
                "currentLocatorDiffersFromInputProvenance": True, "fixtureBytes": capacity(root), "fixtureCapBytes": CAP,
                "testReserveBytes": RESERVE, "runtimeReserveBytes": 1024**3,
                "checks": ["CLI describe/help/extracted-text wrappers", "current locator vs input provenance",
                    "CLI attach/extract/replay", "exact Unicode/BOM/CRLF", "FTS before/after/rebuild",
                    "once-only projection and original byte map", "small summary", "optional bounded child lifetime"]}


def stop(signum, frame):
    raise KeyboardInterrupt(f"Fixture supervisor received signal {signum}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary")
    parser.add_argument("--run-command", nargs=argparse.REMAINDER, default=[])
    options = parser.parse_args()
    signal.signal(signal.SIGTERM, stop)
    print(json.dumps(verify(str(Path(options.binary).resolve()), options.run_command), indent=2))
