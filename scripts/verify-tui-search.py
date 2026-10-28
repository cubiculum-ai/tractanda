#!/usr/bin/env python3
"""Tiny actual-native/PTY ad-hoc search smoke; no models or production stores."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import uuid

spec = importlib.util.spec_from_file_location("tui", Path(__file__).with_name("verify-tui.py"))
tui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tui)
wire = tui.wire
RESERVE = 10 * 1024**3
CAP = 16 * 1024**2


def guard(root):
    capacity = os.statvfs(root)
    available = capacity.f_bavail * capacity.f_frsize
    if available < RESERVE:
        raise RuntimeError("Tiny fixture requires genuine 10 GiB free reserve")
    size = sum(p.stat().st_size for p in Path(root).rglob("*") if p.is_file())
    if size > CAP:
        raise RuntimeError("Tiny fixture exceeded its conservative 16 MiB cap")
    return size


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("native_binary", type=Path)
    parser.add_argument("tui_binary", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    capacity = os.statvfs(tempfile.gettempdir())
    if capacity.f_bavail * capacity.f_frsize < RESERVE:
        raise RuntimeError("Insufficient genuine available capacity before fixture creation")
    checks = []
    with tempfile.TemporaryDirectory(prefix="tas-", dir="/tmp") as directory:
        root = Path(directory)
        store, path = root / "store", root / "s"
        # Four tiny canonical records plus indexes, conservatively estimated below 1 MiB.
        expected_bytes = 1024**2
        assert expected_bytes <= CAP
        with wire.server(str(args.native_binary.resolve()), store, path) as client:
            def create(subject, fields=None):
                guard(root)
                item = client.commit_with_revision(wire.intent("create", "search-" + uuid.uuid4().hex, class_id="Item",
                    changes={"subject": wire.text(subject), **(fields or {})}))["revision"]
                guard(root)
                return item

            create("Needle outside", {"scope": wire.text("outside")})
            create("Inside only", {"scope": wire.text("inside")})
            view = create("Inside view", {"viewDefinition": {
                "type": "object", "value": {"language": wire.text("tractanda.spotlight.v0"),
                    "expression": wire.text('scope == "inside"')}}})
            before = wire.manifest(store)
            with tui.terminal(str(args.tui_binary.resolve()), path, root / "pending.json",
                    arguments=[str(path), "--view", wire.item_id(view)]) as ui:
                ui.wait("Inside only", absent="Needle outside")
                ui.send("f"); ui.wait("Search items")
                ui.paste("Needle"); ui.send(b"\r")
                ui.wait("Search results"); ui.wait("Needle outside")
                checks.append("Native FTS ad-hoc search ignores selected saved-view scope")
                ui.send(tui.ESC); ui.wait("Returned from temporary search")
                ui.wait("Inside only", absent="Needle outside")
                ui.send("f"); ui.wait("Search items"); ui.paste("Needle")
                ui.send(b"\t" + tui.ESC + b"[C" + b"\r")
                ui.wait("Semantic unavailable")
                assert "No search results" in ui.screen
                ui.send("f"); ui.wait("Search items"); ui.wait("Needle")
                ui.send(b"\t" + tui.ESC + b"[D" + b"\r")
                ui.wait("Text search ready"); ui.wait("Needle outside")
                checks.append("Unavailable Semantic retains query and requires explicit Text choice")
                ui.send("a"); ui.wait("search cleared"); ui.wait("Inside only"); ui.wait("Needle outside")
                ui.send(tui.ESC + b"[20~"); ui.wait("Categories workspace")
                ui.send(b"\x06"); ui.wait("Search items")
                ui.paste("Needle"); ui.send(b"\r"); ui.wait("Needle outside")
                ui.send(tui.ESC); ui.wait("[Categories]")
                checks.append("Ctrl-F works in Categories; Escape restores category workspace")
                ui.resize(60, 18)
                checks.append("Resize and terminal exit preserve normal PTY modes")
            assert wire.manifest(store) == before, "Search mutated canonical records"
            checks.append("No saved-view or canonical-item mutation")
            fixture_bytes = guard(root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"checks": checks, "fixtureBytes": fixture_bytes,
        "capBytes": CAP, "reserveBytes": RESERVE, "modelCalls": 0}, indent=2) + "\n")
    print(json.dumps({"checks": len(checks), "fixtureBytes": fixture_bytes}))


if __name__ == "__main__":
    main()
