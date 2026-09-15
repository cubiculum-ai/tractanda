#!/usr/bin/env python3
"""Exercise the default Views workspace through an owned PTY and native wire service.

The script deliberately creates a disposable store, recovery journal and preference
file.  It never starts a profile, opens a GUI terminal, or reads a production store.
"""
import argparse
import importlib.util
import json
import platform
import tempfile
import time
import uuid
from pathlib import Path

spec = importlib.util.spec_from_file_location("tui", Path(__file__).with_name("verify-tui.py"))
tui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tui)
wire, ESC = tui.wire, tui.ESC
F1, F2, F5, F7, F8, F9, F10 = ESC + b"OP", ESC + b"OQ", ESC + b"[15~", ESC + b"[18~", ESC + b"[19~", ESC + b"[20~", ESC + b"[21~"
ALT_F5 = ESC + b"[15;3~"
DOWN, PGDN = ESC + b"[B", ESC + b"[6~"


def tagged(kind, value):
    return {"type": kind, "value": value}


def click(ui, column, row, button=0):
    """Send one SGR mouse click, using zero-based PTY coordinates."""
    x, y = column + 1, row + 1
    ui.send(ESC + f"[<{button};{x};{y}M".encode() + ESC + f"[<{button};{x};{y}m".encode())


def wheel(ui, column, row, down=True):
    # SGR button 64 is wheel up and 65 is wheel down.
    x, y, button = column + 1, row + 1, 65 if down else 64
    ui.send(ESC + f"[<{button};{x};{y}M".encode())


def wait_selected(ui, title):
    deadline = time.monotonic() + 10
    while not (ui.is_frame_complete and any(any(part.lstrip().startswith(">") and title in part for part in line.split("│")) for line in ui.screen.splitlines())):
        ui.read()
        assert ui.process.poll() is None and time.monotonic() < deadline, (title, ui.screen)


def wait_any(ui, *texts):
    deadline = time.monotonic() + 10
    while not ui.is_frame_complete or not any(text in ui.screen for text in texts):
        ui.read()
        assert ui.process.poll() is None and time.monotonic() < deadline, (texts, ui.screen)


def wait_selector_filter(ui, text):
    marker = "Find: " + text + " "
    deadline = time.monotonic() + 10
    while not ui.is_frame_complete or marker not in ui.screen:
        ui.read()
        assert ui.process.poll() is None and time.monotonic() < deadline, (marker, ui.screen)


def snapshot(snapshots, ui, name):
    snapshots.append({
        "name": name, "columns": ui.width, "rows": ui.height, "screen": ui.screen,
        "ansiFrame": ui.raw.rsplit("\x1b[H", 1)[-1],
    })


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("native_binary", type=Path)
    parser.add_argument("tui_binary", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    native, binary = str(args.native_binary.resolve()), str(args.tui_binary.resolve())
    checks, snapshots = [], []
    report = {"status": "failed", "platform": platform.platform(), "checks": checks, "snapshots": snapshots}
    try:
        with tempfile.TemporaryDirectory(prefix="tvw-", dir="/tmp") as directory:
            root = Path(directory)
            # Darwin's UNIX-domain path limit is below this temporary directory's
            # descriptive prefix, so keep both socket basenames deliberately short.
            store, socket_path = root / "store", root / "s"
            recovery = root / "recovery" / "pending.json"
            preferences = recovery.with_suffix(".views.json")
            with wire.server(native, store, socket_path) as client:
                def create(name, fields=None, class_id="NoteItem"):
                    return client.commit(wire.intent(
                        "create", "view-workspace-" + uuid.uuid4().hex, class_id=class_id,
                        changes={"subject": wire.text(name), **(fields or {})})) ["revision"]

                def revise(item, changes, operation=None):
                    return client.commit(wire.intent(
                        "revise", operation or "view-workspace-" + uuid.uuid4().hex,
                        item=wire.item_id(item), base=wire.revision_id(item), changes=changes))["revision"]

                north = create("North criteria", {"selection": tagged("object", {
                    "language": wire.text("tractanda.spotlight.v0"), "expression": wire.text("rank >= 0"),
                })})
                south = create("South criteria", {"selection": tagged("object", {
                    "language": wire.text("tractanda.spotlight.v0"), "expression": wire.text("rank >= 65"),
                })})
                for rank in range(70):
                    create(f"Report row {rank:02d}", {"rank": tagged("integer", rank),
                        "body": wire.text(f"Report body {rank:02d}")})
                alpha = create("Alpha ordinary view", {"body": wire.text("Alpha report"), "viewDefinition": tagged("object", {
                    "language": wire.text("tractanda.spotlight.v0"), "expression": wire.text("rank >= 0"),
                })})
                role = create("Role can be a view", {"body": wire.text("Role report"), "viewDefinition": tagged("object", {
                    "language": wire.text("tractanda.spotlight.v0"), "expression": wire.text("rank >= 65"),
                })}, "RoleItem")
                legacy = create("Legacy identifier view", {"body": wire.text("Legacy report"), "viewDefinition": tagged("object", {
                    "language": wire.text("tractanda.spotlight.v0"), "expression": wire.text("rank == 3"),
                })}, "SavedViewItem")
                hidden = create("Tombstoned view", {"viewDefinition": tagged("object", {
                    "language": wire.text("tractanda.spotlight.v0"),
                })})
                hidden = revise(hidden, {"isDeleted": tagged("boolean", True)})
                before_pins = wire.manifest(store)

                # The omitted --items argument is intentional: this is the default workspace contract.
                with tui.terminal(binary, socket_path, recovery, arguments=[str(socket_path)], items_only=False) as ui:
                    ui.wait("Views · focused")
                    ui.wait("All items · implicit")
                    assert "Alpha ordinary view" in ui.screen and "Role can be a view" in ui.screen
                    assert "Legacy identifier view" in ui.screen and "Tombstoned view" not in ui.screen
                    ui.send("e"); wait_selector_filter(ui, "e")
                    assert "View definition" not in ui.screen
                    ui.send(b"\x15"); wait_selector_filter(ui, "")
                    ui.send("V"); wait_selector_filter(ui, "V")
                    ui.send(b"\x15"); wait_selector_filter(ui, "")
                    snapshot(snapshots, ui, "default-views-selector")
                    checks.append("Default startup opens the focused Views selector over the implicit All items report; ordinary, RoleItem and legacy SavedViewItem definitions are discoverable while tombstones are absent, and individual selector letters remain searchable text")

                    # Focus, mouse selection/wheel, F10 menu and F1 help all use a real terminal decoder.
                    role_row = next(i for i, line in enumerate(ui.screen.splitlines()) if "Role can be a view" in line.split("│", 1)[0])
                    click(ui, 8, role_row)
                    wait_selected(ui, "Role can be a view")
                    wheel(ui, 8, role_row, down=False)
                    ui.wait("Opened Legacy identifier view")
                    ui.send(DOWN)
                    ui.wait("Opened Role can be a view")
                    ui.send(b"\r")
                    ui.wait("Views · report focused")
                    ui.send(F10); ui.wait("Command menu")
                    ui.send(ESC); ui.wait("Views · report focused", absent="Command menu")
                    ui.send(F1); ui.wait("Tractanda help")
                    ui.send(ESC); ui.wait("Views · report focused", absent="Tractanda help")
                    for width, height in [(132, 35), (48, 12), (80, 25)]:
                        ui.resize(width, height)
                        if width == 48:
                            ui.wait("Views")
                            ui.wait("Report row")
                        else:
                            ui.wait("Role can be a view")
                        snapshot(snapshots, ui, f"focus-menu-mouse-{width}x{height}")
                    checks.append("Tab/Enter report focus, selector mouse click/wheel, F10 command menu, F1 help and 132x35/48x12/80x25 resizing retain a coherent workspace")

                    ui.resize(132, 35)
                    ui.send(F8); ui.wait("Views · focused")
                    # Pinning only writes the private preference file; canonical bytes stay untouched.
                    ui.paste("Alpha ordinary view"); ui.wait("Alpha ordinary view")
                    ui.send(ESC + b"m"); ui.wait("View pinned locally")
                    assert preferences.exists() and preferences.stat().st_mode & 0o777 == 0o600
                    assert wire.manifest(store) == before_pins
                    snapshot(snapshots, ui, "pinned-view")
                    ui.close()
                with tui.terminal(binary, socket_path, recovery, arguments=[str(socket_path)], items_only=False) as ui:
                    ui.wait("★ Alpha ordinary view")
                    assert "Tombstoned view" not in ui.screen and wire.manifest(store) == before_pins
                    checks.append("Pins survive a restart in a 0600 recovery-adjacent private file, sort ahead of unpinned views, and do not alter canonical view revisions")

                    # New starts from All items.  Build one staged definition then save it once.
                    ui.send(b"\x0e"); ui.wait("View definition ·")  # Ctrl-N from Views.
                    ui.paste("Workspace QA report"); ui.send(b"\t")
                    ui.paste("One guarded definition with filter, categories and columns.")
                    ui.send(b"\t"); ui.paste("rank >= 0"); ui.send(b"\t")
                    ui.send(b"\t\r"); ui.wait("Included categories")
                    ui.paste("North criteria"); ui.send(b" "); ui.send(b"\x13"); ui.wait("View definition ·")
                    ui.send(b"\t\t\r"); ui.wait("Section categories")
                    ui.paste("North criteria"); ui.send(b"\r\x15")
                    ui.paste("South criteria"); ui.send(b"\r\x13"); ui.wait("Sections staged")
                    ui.send(ALT_F5); ui.wait("View definition ·"); ui.paste("rank"); ui.send(b"\t")
                    ui.send(b"\x15"); ui.paste("Rank"); ui.send(b"\t"); ui.send(b"\x15"); ui.paste("12")
                    # Everything above remains local until this one guarded commit.
                    ui.send(F8); ui.wait("Saved one revision")
                    saved = tui.wait_item(client, 'subject == "Workspace QA report"', ui)
                    saved_id = wire.item_id(saved)
                    assert saved["fields"]["classID"] == wire.text("NoteItem")
                    edited = client.get(saved_id)
                    assert client.call("TractandaItem/history", {"itemID": saved_id})["total"] == 1
                    definition = edited["fields"]["viewDefinition"]["value"]
                    assert definition["expression"] == wire.text("rank >= 0")
                    assert [entry["value"]["itemID"] for entry in definition["presentation"]["value"]["sections"]["value"]] == [wire.item_id(north), wire.item_id(south)]
                    assert any(
                        column["value"]["property"] == wire.text("rank")
                        for column in definition["presentation"]["value"]["columns"]["value"])
                    ui.send(b"\r"); ui.wait("Views · report focused")
                    ui.wait("Report row 69")
                    # Move the selected table row to the actual rendered next-page control.
                    ui.send(ESC + b"[H")
                    ui.send(DOWN * 65)
                    wait_selected(ui, "Next page"); ui.send(b"\r"); ui.wait("Report row 05")
                    snapshot(snapshots, ui, "saved-staged-definition-second-page")
                    checks.append("New ordinary NoteItem view stages query, named category sections and a Rank column before one guarded save; its selected report remains reachable past the native 64-row page boundary")

                    # Cancel leaves the revision untouched; a stale guard is rejected and leaves the text draft visible.
                    baseline = client.get(saved_id)
                    ui.send(F8); ui.wait("Views · focused")
                    ui.paste("Workspace QA report"); ui.send(b"\x05"); ui.wait("View definition ·")  # Ctrl-E.
                    ui.send(" cancelled"); ui.send(F9); wait_any(ui, "Draft canceled", "View definition canceled")
                    assert client.get(saved_id) == baseline
                    ui.send(F2); ui.wait("View definition ·"); ui.send(" local conflict")
                    external = revise(baseline, {"foreign.item": wire.text("retain"), "subject": wire.text("Changed elsewhere")})
                    ui.send(F8); ui.wait("revisionConflict")
                    ui.wait("local conflict")
                    assert wire.revision_id(client.get(saved_id)) == wire.revision_id(external)
                    ui.send(ESC); wait_any(ui, "Draft canceled", "View definition canceled")
                    ui.send(b"\r"); ui.wait("Views · report focused")
                    ui.send("r"); ui.wait("Refreshed")
                    checks.append("Cancel makes no mutation; an externally advanced revision rejects the stale definition guard without overwriting it and keeps the editable draft available; R refreshes the renamed view in the selector")

                    # Add unknown nested values through the native service, then perform a normal TUI definition edit.
                    current = client.get(saved_id)
                    unknown_definition = current["fields"]["viewDefinition"]["value"]
                    unknown_definition["foreign.query"] = wire.text("retain")
                    unknown_definition["presentation"]["value"]["foreign.layout"] = wire.text("retain")
                    rank_column = next(column for column in unknown_definition["presentation"]["value"]["columns"]["value"]
                        if column["value"]["property"] == wire.text("rank"))
                    rank_column["value"]["foreign.column"] = wire.text("retain")
                    current = revise(current, {"viewDefinition": tagged("object", unknown_definition)})
                    ui.send(F8); ui.wait("Views · focused"); ui.send(b"\x15"); wait_selector_filter(ui, ""); ui.paste("Changed elsewhere")
                    wait_selected(ui, "Changed elsewhere")
                    ui.send(F2); ui.wait("View definition ·")
                    ui.send(b"\x15"); ui.paste("Unknown fields retained")
                    ui.send(F8); ui.wait("Saved one revision")
                    retained = client.get(saved_id)["fields"]["viewDefinition"]["value"]
                    assert retained["foreign.query"] == wire.text("retain")
                    assert retained["presentation"]["value"]["foreign.layout"] == wire.text("retain")
                    assert next(column for column in retained["presentation"]["value"]["columns"]["value"]
                        if column["value"]["property"] == wire.text("rank"))["value"]["foreign.column"] == wire.text("retain")
                    checks.append("Unknown item, definition, presentation and retained-column properties survive an ordinary TUI view edit")
                    ui.close()

                # A lost response has a durable exact request and retry cannot create a duplicate revision.
                proxy = tui.LostResponseProxy(root / "p", socket_path)
                try:
                    retry = root / "retry" / "pending.json"
                    with tui.terminal(binary, proxy.path, retry, arguments=[str(proxy.path), "--view", saved_id], items_only=False) as ui:
                        ui.wait("Unknown fields retained")
                        ui.send(F8); ui.wait("Views · focused"); ui.send(F2); ui.wait("View definition ·")
                        ui.send(" retry"); ui.send(F8); ui.wait("Unconfirmed edit")
                        request = json.loads(retry.read_text())["request"]
                        count = client.call("TractandaItem/history", {"itemID": saved_id})["total"]
                        ui.close()
                    with tui.terminal(binary, proxy.path, retry, arguments=[str(proxy.path), "--view", saved_id], items_only=False) as ui:
                        ui.wait("Recovered unconfirmed edit"); ui.send("r"); ui.wait("Recovered saved edit")
                        assert client.call("TractandaItem/history", {"itemID": saved_id})["total"] == count
                        assert not retry.exists() and request["operationID"]
                        checks.append("A dropped native save response persists the exact guarded request and restart retry replays one revision without duplication")
                        ui.close()
                finally:
                    proxy.close()

                # --items intentionally stays full-height and does not load the private selector/pins.
                with tui.terminal(binary, socket_path, root / "items" / "pending.json", arguments=[str(socket_path), "--items"]) as ui:
                    ui.wait("All items")
                    assert "Views ·" not in ui.screen
                    ui.close()
                checks.append("--items deliberately opens the full-height familiar browser; all workspace state remained confined to disposable files")

        report["status"] = "passed"
    except Exception as error:
        report["error"] = repr(error)
        raise
    finally:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps({key: value for key, value in report.items() if key != "snapshots"}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
