#!/usr/bin/env python3
"""Verify category navigation and marked-item operations in the actual Swift TUI.

Uses disposable stores, an owned PTY, and an independent native wire client.
"""
import argparse
import importlib.util
import json
import platform
import tempfile
import uuid
from pathlib import Path

spec = importlib.util.spec_from_file_location("tui", Path(__file__).with_name("verify-tui.py"))
tui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tui)
wire, ESC = tui.wire, tui.ESC


def tagged(kind, value):
    return {"type": kind, "value": value}


def browse(ui, name, refining=False):
    ui.send("c")
    ui.wait("Category manager")
    ui.send(b"\x15")
    ui.paste(name)
    # Enter remains inside Categories.  Meta-Return is the explicit operation
    # which applies/replaces or refines the path in Views.
    ui.send(b"\x1b\r")
    ui.wait("Added category filter")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("native_binary", type=Path)
    parser.add_argument("tui_binary", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    native, binary = str(args.native_binary.resolve()), str(args.tui_binary.resolve())
    checks, snapshots = [], []
    with tempfile.TemporaryDirectory(prefix="trac-groups-", dir="/tmp") as directory:
        root = Path(directory)
        path, store = root / "s", root / "store"
        with wire.server(native, store, path) as client:
            def create(name, fields):
                return client.commit(wire.intent("create", str(uuid.uuid4()), class_id="NoteItem",
                    changes={"subject": wire.text(name), **fields}))["revision"]

            categories = {name: create(name, {"selection": tagged("object", {
                "language": wire.text("tractanda.spotlight.v0"), "expression": wire.text(rule),
            })}) for name, rule in [("Family", "family == 1"), ("Calls", "call == 1"), ("Tasks", "rank >= 0"), ("Completed", 'itemID == ""')]}
            items = [create(name, {"rank": tagged("integer", rank), **fields})
                for rank, (name, fields) in enumerate([
                    ("Family only", {"family": tagged("integer", 1)}),
                    ("Call only", {"call": tagged("integer", 1)}),
                    ("Both contexts", {"family": tagged("integer", 1), "call": tagged("integer", 1)}),
                ])]
            identities = [wire.item_id(item) for item in items]

            def history(identity):
                return client.call("TractandaItem/history", {"itemID": identity})["total"]

            with tui.terminal(binary, path, root / "recovery/pending.json") as ui:
                ui.wait("Preview")
                browse(ui, "Family")
                assert "Family only" in ui.screen and "Call only" not in ui.screen
                # Meta-Return refines the retained Views path.  Clear it explicitly
                # before the independent Calls route.
                ui.send("a")
                ui.wait("All readable items")
                browse(ui, "Calls")
                assert "Call only" in ui.screen and "Family only" not in ui.screen
                browse(ui, "Family", refining=True)
                assert "Calls / Family" in ui.screen and "Both contexts" in ui.screen
                assert "Call only" not in ui.screen and "Family only" not in ui.screen
                ui.send("a")
                ui.wait("All readable items")
                assert "Call only" in ui.screen and "Family only" in ui.screen
                checks.append("Meta-Return replaces or explicitly intersects category filters; A clears Views filters")

                ui.send("g")
                ui.wait("Sections")
                ui.paste("Tasks")
                ui.send(b"\r\x13")
                ui.wait("Sections applied")
                ui.send(ESC + b"[H" + ESC + b"[18~")
                ui.wait("3 marked")
                ui.send("b")
                ui.wait("Group operations")
                ui.send("v")
                ui.wait("Marked items · 3")
                assert all(item["fields"]["subject"]["value"] in ui.screen for item in items)
                ui.send(ESC)
                ui.wait("Group operations")
                ui.send("i")
                ui.wait("Choose category")
                ui.paste("Calls")
                ui.send(b"\r")
                ui.wait("Type apply")
                ui.paste("apply")
                for width, height in [(52, 14), (30, 8), (160, 48), (80, 25)]:
                    ui.resize(width, height)
                    ui.wait("apply" if width >= 48 else "Enlarge terminal")
                    snapshots.append({"name": "group-confirmation", "columns": width, "rows": height, "screen": ui.screen})
                ui.send(ESC)
                ui.wait("Draft canceled")
                assert all(history(identity) == 1 for identity in identities)
                ui.send("b")
                ui.wait("Group operations")
                ui.send("i")
                ui.wait("Choose category")
                ui.paste("Calls")
                ui.send(b"\r")
                ui.wait("Type apply")
                ui.paste("apply")
                ui.send(b"\x13")
                ui.wait("3 saved · 0 unchanged · 0 rejected")
                for identity in identities:
                    assert client.get(identity)["fields"]["categoryOverrides"]["value"] == {
                        wire.item_id(categories["Calls"]): wire.text("include")}
                    assert history(identity) == 2
                ui.send(ESC)
                ui.wait("Preview")
                assert "◆ 3 marked" not in ui.screen
                checks.append("F7 marks a section; group review, resize and cancellation preserve selection; confirmed assignments create one revision per item")

                ui.send(ESC + b"[H" + ESC + b"[18~")
                ui.wait("3 marked")
                ui.send("b")
                ui.wait("Group operations")
                ui.send("d")
                ui.wait("Choose category")
                ui.paste("Completed")
                ui.send(b"\r")
                ui.wait("Type apply")
                before = client.get(identities[0])
                changed = client.commit(wire.intent("revise", "outside-group-edit", item=identities[0],
                    base=wire.revision_id(before), changes={"body": wire.text("External work retained")}))["revision"]
                ui.paste("apply")
                ui.send(b"\x13")
                ui.wait("2 saved · 0 unchanged · 1 rejected")
                assert wire.revision_id(client.get(identities[0])) == wire.revision_id(changed)
                assert all(client.get(identity)["fields"]["categoryOverrides"]["value"][wire.item_id(categories["Completed"])] == wire.text("include") for identity in identities[1:])
                assert all(history(identity) == 3 for identity in identities)
                ui.send(ESC)
                ui.wait("Preview")
                assert "◆ 1 marked" in ui.screen
                ui.send("M")
                ui.wait("All items unmarked")
                ui.close()
                checks.append("Concurrent edits reject only the stale member, retain its newer content and leave it marked for review; Shift-M clears marks")

            prior_assignments = {identity: client.get(identity)["fields"]["categoryOverrides"]["value"] for identity in identities}
            # A real successful response is dropped; the entire frozen group survives a restart.
            proxy = tui.LostResponseProxy(root / "proxy", path)
            try:
                recovery = root / "retry/pending.json"
                with tui.terminal(binary, proxy.path, recovery) as ui:
                    ui.wait("Preview")
                    ui.send("g")
                    ui.wait("Sections")
                    ui.paste("Tasks")
                    ui.send(b"\r\x13")
                    ui.wait("Sections applied")
                    ui.send(ESC + b"[H" + ESC + b"[18~")
                    ui.wait("3 marked")
                    ui.send("b")
                    ui.wait("Group operations")
                    ui.send("i")
                    ui.wait("Choose category")
                    ui.paste("Tasks")
                    ui.send(b"\r")
                    ui.wait("Type apply")
                    ui.paste("apply")
                    ui.send(b"\x13")
                    ui.wait("Unconfirmed group operation")
                    saved_recovery = recovery.read_bytes()
                    assert sorted(history(identity) for identity in identities) == [3, 3, 4]
                    ui.close()
                with tui.terminal(binary, proxy.path, recovery) as ui:
                    ui.wait("Recovered group operation")
                    assert recovery.read_bytes() == saved_recovery
                    assert sorted(history(identity) for identity in identities) == [3, 3, 4]
                    ui.send("r")
                    ui.wait("3 saved · 0 unchanged · 0 rejected")
                    assert all(history(identity) == 4 for identity in identities)
                    assert not recovery.exists()
                    for identity in identities:
                        assert client.get(identity)["fields"]["categoryOverrides"]["value"] == {
                            **prior_assignments[identity],
                            wire.item_id(categories["Tasks"]): wire.text("include"),
                        }
                    snapshots.append({"name": "recovered-group-results", "columns": 80, "rows": 25, "screen": ui.screen})
                    ui.send(ESC)
                    ui.wait("Preview")
                    ui.close()
                checks.append("Dropped native commit response, terminal restart and explicit R resume replay one edit and finish the remaining group without duplicate revisions")
            finally:
                proxy.close()
    report = {"status": "passed", "platform": platform.platform(), "checks": checks, "snapshots": snapshots}
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "snapshots"}, indent=2))


if __name__ == "__main__":
    main()
