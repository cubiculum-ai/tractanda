#!/usr/bin/env python3
"""Drive saved table views through an owned PTY and inspect the actual native store."""
import argparse
import datetime
import importlib.util
import json
import platform
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("tui", Path(__file__).with_name("verify-tui.py"))
tui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tui)
wire, ESC = tui.wire, tui.ESC


def tagged(kind, value):
    return {"type": kind, "value": value}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("native_binary", type=Path)
    parser.add_argument("tui_binary", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    native, binary = str(args.native_binary.resolve()), str(args.tui_binary.resolve())
    checks, snapshots = [], []
    with tempfile.TemporaryDirectory(prefix="trac-views-", dir="/tmp") as directory:
        root = Path(directory)
        path, store = root / "s", root / "store"
        with wire.server(native, store, path) as client:
            def create(fields):
                import uuid
                return client.commit(wire.intent("create", str(uuid.uuid4()), class_id="NoteItem", changes=fields))["revision"]

            categories = [create({"subject": wire.text(name), "selection": tagged("object", {
                "language": wire.text("tractanda.spotlight.v0"), "expression": wire.text(rule),
            })}) for name, rule in [("North", "rank >= 0"), ("South", "rank >= 65")]]
            items = [create({"subject": wire.text(f"Item {i:02d}"), "rank": tagged("integer", i),
                "body": wire.text(f"Preview for item {i:02d} — café 文")}) for i in range(70)]
            with tui.terminal(binary, path, root / "recovery/pending.json") as ui:
                ui.wait("Preview")
                ui.send("f"); ui.wait("Filter items"); ui.paste("rank >= 0")
                ui.send(b"\x13"); ui.wait("Filter applied")
                recent = sorted(items, key=lambda item: (
                    -datetime.datetime.fromisoformat(item['fields']['modifiedAt']['value'].replace('Z','+00:00')).timestamp(),
                    wire.item_id(item)))
                page = client.call('TractandaItem/query', {'expression':'rank >= 0','limit':64})
                assert page['ids'] == [wire.item_id(item) for item in recent[:64]]
                newest_rank = recent[0]['fields']['rank']['value']
                assert newest_rank != 0
                ui.wait(f'Preview for item {newest_rank:02d}')
                ui.send('o');ui.wait('Sort items');ui.paste('rank');ui.send(b'\x13');ui.wait('Sort applied')
                ui.wait('Preview for item 00')
                ui.send('o');ui.wait('Sort items');ui.send(b'\x15\x13');ui.wait('Sort applied')
                ui.wait(f'Preview for item {newest_rank:02d}')
                client.commit(wire.intent('revise','recently-modified-older-item',item=wire.item_id(items[0]),
                    base=wire.revision_id(items[0]),changes={'body':wire.text('Recently edited older item')}))
                ui.send('r');ui.wait('Refreshed');ui.send(ESC+b'[H');ui.wait('Recently edited older item')
                assert client.call('TractandaItem/query', {'expression':'rank >= 0','limit':1})['ids'] == [wire.item_id(items[0])]
                checks.append('Default ordering is newest modification first; clearing a custom sort restores it and editing an older item moves it to the first page')
                ui.send("o"); ui.wait("Sort items"); ui.paste("rank"); ui.send(b"\t\x15")
                ui.paste("descending"); ui.send(b"\x13"); ui.wait("Sort applied")
                assert "Item 69" in ui.screen
                # Navigate the real 64-row boundary and return, without sorting the page in the client.
                ui.send(ESC + b"[F"); ui.wait("Next page"); ui.send(b"\r")
                ui.wait("Item 05"); assert "Item 69" not in ui.screen
                ui.send(ESC + b"[H"); ui.wait("Previous page"); ui.send(b"\r")
                ui.send(ESC + b"[H"); ui.wait("Item 69")
                checks.append("Real terminal navigation across sorted native 64-item pages")

                ui.send("g"); ui.wait("Sections"); ui.paste("North"); ui.send(b"\r\x15")
                ui.paste("South"); ui.send(b"\r\x13"); ui.wait("Sections applied")
                ui.send(ESC + b"[H" + ESC + b"[D"); ui.wait("[+] North")
                ui.send(ESC + b"[B"); ui.wait("[-] South")
                assert "Item 69" in ui.screen
                ui.send("n"); ui.wait("New item"); ui.paste("Captured in South"); ui.send(b"\x13")
                ui.wait("Saved one revision")
                captured = tui.wait_item(client, 'subject == "Captured in South"', ui)
                assert captured["fields"]["categoryOverrides"]["value"] == {wire.item_id(categories[1]): wire.text("include")}
                ui.wait("Saved one revision")
                for width, height in [(132, 40), (52, 14), (30, 8), (160, 48), (80, 25)]:
                    ui.resize(width, height)
                    if width >= 48:
                        ui.wait("[+] North")
                    else:
                        ui.wait("Enlarge terminal")
                    snapshots.append({"name": "section-browse", "columns": width, "rows": height, "screen": ui.screen})
                checks.append("Overlapping native category sections, collapse/resize, and capture into the selected section")

                ui.send("l"); ui.wait("Columns"); ui.send("n"); ui.wait("Add column")
                ui.paste("rank"); ui.send(b"\t"); ui.paste("Rank 文")
                ui.resize(52, 14); ui.wait("Rank 文"); ui.resize(120, 35); ui.wait("Rank 文")
                ui.send(b"\t\x15"); ui.paste("10"); ui.send(b"\x13"); ui.wait("Column staged")
                ui.send(ESC + b"[D" + ESC + b"[D" + b"\x13"); ui.wait("Columns applied")
                assert "Rank 文" in ui.screen
                ui.send("s"); ui.wait("Save view as"); ui.paste("TUI view fixture"); ui.send(b"\x13")
                ui.wait("Saved one revision")
                view = tui.wait_item(client, 'subject == "TUI view fixture"', ui)
                identity = wire.item_id(view)
                definition = view["fields"]["viewDefinition"]["value"]
                presentation = definition["presentation"]["value"]
                assert presentation["columns"]["value"][0]["value"]["property"] == wire.text("rank")
                assert presentation["collapsedSections"]["value"][0]["value"]["itemID"] == wire.item_id(categories[0])
                page = client.call("TractandaItem/query", {"viewID": identity, "position": 64, "limit": 64})
                assert page["ids"] == [wire.item_id(item) for item in reversed(items[:6])]
                south = client.call("TractandaItem/query", {"viewID": identity, "sectionID": wire.item_id(categories[1])})
                assert south["ids"] == [wire.item_id(item) for item in reversed(items[65:])]
                ui.send("a"); ui.wait("All readable items")
                tui.choose(ui, "v", "TUI view fixture", "Open saved view")
                ui.wait("[+] North"); assert "Rank 文" in ui.screen
                snapshots.append({"name": "saved-view", "columns": 120, "rows": 35, "screen": ui.screen})
                checks.append("Column editing, reordering, save/open and server section queries retain layout and full-result order")
                before = wire.manifest(store)
                client.call("TractandaStore/rebuild")
                assert wire.manifest(store) == before
                assert client.call("TractandaItem/query", {"viewID": identity, "position": 64})["ids"] == page["ids"]
                ui.send("r"); ui.wait("Refreshed"); assert "Rank 文" in ui.screen
                ui.close()
                checks.append("Disposable index rebuild preserves canonical files, saved layout and query order")

            # The first write response is really dropped; recover the same view revision after restart.
            proxy = tui.LostResponseProxy(root / "proxy", path)
            try:
                recovery = root / "retry/pending.json"
                ui = tui.Terminal(binary, proxy.path, recovery,
                    arguments=[str(proxy.path), "--view", identity])
                try:
                    ui.wait("[+] North")
                    ui.send("s"); ui.wait("Save changes to this view"); ui.send(" revised")
                    ui.send(b"\x13"); ui.wait("Unconfirmed edit")
                    assert client.call("TractandaItem/history", {"itemID": identity})["total"] == 2
                    ui.close()
                finally:
                    if ui.process.poll() is None:
                        ui.process.terminate(); ui.process.wait(timeout=10)
                with tui.terminal(binary, proxy.path, recovery) as ui:
                    ui.wait("Recovered unconfirmed edit"); ui.send("r"); ui.wait("Recovered saved edit")
                    assert "Rank 文" in ui.screen and "TUI view fixture revised" in ui.screen
                    assert client.call("TractandaItem/history", {"itemID": identity})["total"] == 2
                    assert not recovery.exists()
                    ui.close()
                checks.append("Lost save-view response, restart and identical retry recover one revision and reopen its layout")
            finally:
                proxy.close()
    report = {"status": "passed", "platform": platform.platform(), "checks": checks, "snapshots": snapshots}
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "snapshots"}, indent=2))


if __name__ == "__main__":
    main()
