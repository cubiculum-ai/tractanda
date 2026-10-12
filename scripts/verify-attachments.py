#!/usr/bin/env python3
"""Tiny guarded original-byte lifecycle fixture; it makes no OCR citation claims."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unicodedata

PROJECT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("wire", PROJECT / "scripts/verify-ipc.py")
wire = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(wire)


def check_capacity(path):
    capacity = os.statvfs(path)
    available = capacity.f_bavail * capacity.f_frsize
    expected = 16 * 1024 * 1024
    if available < 10 * 1024**3 + expected:
        raise RuntimeError("Attachment fixture requires 10 GiB genuine available-space reserve")
    return available


def verify(binary):
    with tempfile.TemporaryDirectory(prefix="tractanda-attachments-", dir="/tmp") as temporary:
        root = Path(temporary)
        available = check_capacity(root)
        store, socket = root / "store", root / "socket"
        subprocess.check_output([binary, "init", str(store)])
        source = root / "résumé.bin"
        content = bytes(range(251)) * 1100
        source.write_bytes(content)
        with wire.server(binary, store, socket) as client:
            base = client.commit(wire.intent("create", "fixture", class_id="Item", changes={"subject": wire.text("attachment fixture")}))["revision"]
            item, revision = wire.item_id(base), wire.revision_id(base)
            command = [binary, "attach", str(socket), item, revision, "attach", str(source), "application/octet-stream"]
            attached = json.loads(subprocess.check_output(command))
            replay = json.loads(subprocess.check_output(command))
            assert replay["replayed"] and replay["revisionID"] == attached["revisionID"]
            assert "revision" not in attached
            attached_revision = client.get(item)
            listing = json.loads(subprocess.check_output([binary, "attachments", str(socket), item]))
            descriptor = listing["attachments"][0]
            assert unicodedata.normalize("NFC", descriptor["filename"]) == unicodedata.normalize("NFC", source.name)
            assert descriptor["byteCount"] == len(content)
            output = root / "original.bin"
            subprocess.check_output([binary, "export-attachment", str(socket), item, descriptor["attachmentID"], str(output)])
            assert output.read_bytes() == content
            bundle = root / "item-export"
            subprocess.check_output([binary, "export-item", str(socket), item, str(bundle)])
            assert json.loads((bundle / "revision.json").read_text()) == attached_revision
            assert (bundle / (descriptor["attachmentID"] + ".original")).read_bytes() == content
            subprocess.check_output([binary, "detach", str(socket), item, wire.revision_id(attached_revision), "detach", descriptor["attachmentID"]])
            assert client.call("TractandaAttachment/list", {"itemID": item})["attachments"] == []
            historical = root / "historical.bin"
            subprocess.check_output([binary, "export-attachment", str(socket), item, descriptor["attachmentID"], str(historical), wire.revision_id(attached_revision)])
            assert historical.read_bytes() == content
            before = list(store.glob("items/**/*.tractanda"))
            client.rebuild("verify-attachments-rebuild")
            assert list(store.glob("items/**/*.tractanda")) == before
        check_capacity(root)
        return {"passed": True, "payloadBytes": len(content), "expectedFixtureCapBytes": 16*1024*1024,
                "initialAvailableBytes": available, "reserveBytes": 10*1024**3,
                "checks": ["native chunks", "CLI attach/replay/list", "byte-exact export", "self-contained item export", "detach/history", "rebuild"]}


if __name__ == "__main__":
    print(json.dumps(verify(str(Path(sys.argv[1]).resolve())), indent=2))
