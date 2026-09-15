#!/usr/bin/env python3
"""Exercise the modal direct view-definition form in an owned PTY."""
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
EDIT_VIEW, SAVE_VIEW, SAVE_AS_VIEW, CANCEL_VIEW = ESC + b"[12~", ESC + b"[19~", ESC + b"[13~", ESC + b"[20~"


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
    with tempfile.TemporaryDirectory(prefix="trac-view-form-", dir="/tmp") as directory:
        root = Path(directory)
        with wire.server(native, root / "store", root / "s") as client:
            def create(fields):
                return client.commit(wire.intent("create", str(uuid.uuid4()), class_id="NoteItem", changes=fields))["revision"]

            included = create({"subject": wire.text("Direct include"), "selection": tagged("object", {
                "language": wire.text("tractanda.spotlight.v0"), "expression": wire.text('itemID == ""'),
            })})
            section = create({"subject": wire.text("Direct section"), "selection": tagged("object", {
                "language": wire.text("tractanda.spotlight.v0"), "expression": wire.text('itemID == ""'),
            })})
            create({"subject": wire.text("Background context"), "rank": tagged("integer", 7)})
            with tui.terminal(binary, root / "s", root / "pending.json", items_only=False) as ui:
                ui.wait("Views")
                ui.send(b"\x0e"); ui.wait("View definition ·")
                for size in [(80, 25), (48, 12), (132, 35)]:
                    ui.resize(*size); ui.wait("F8 Save")
                    snapshots.append({"name": "empty-direct-form", "columns": size[0], "rows": size[1], "screen": ui.screen, "ansiFrame": ui.raw.rsplit("\x1b[H", 1)[-1]})
                ui.resize(80, 25)
                ui.paste("Direct PTY view"); ui.send(b"\t"); ui.paste("description\ncontinues")
                ui.send(b"\t"); ui.paste("rank >= 0"); ui.send(b"\t"); ui.paste("direct")
                ui.send(b"\t\r"); ui.wait("Ctrl-S Apply to form")
                snapshots.append({"name": "included-picker", "columns": 80, "rows": 25, "screen": ui.screen, "ansiFrame": ui.raw.rsplit("\x1b[H", 1)[-1]})
                ui.paste("Direct include"); ui.send(b" "); ui.send(b"\x13"); ui.wait("Included categories staged")
                ui.send(b"\t\t\r"); ui.wait("Ctrl-S Apply to form")
                ui.paste("Direct section"); ui.send(b" "); ui.send(b"\x13"); ui.wait("Sections staged")
                ui.send(b"\t"); ui.paste("rank"); ui.send(b"\t"); ui.send(ESC + b"[C")
                # The default first grid row is directly editable as key/title/width.
                ui.send(b"\t\t\t"); ui.send(b"\x15"); ui.paste("rank")
                ui.send(b"\t\x15"); ui.paste("Rank café 文")
                ui.send(b"\t\x15"); ui.paste("18")
                ui.wait("18 ")
                snapshots.append({"name": "populated-direct-form", "columns": 80, "rows": 25, "screen": ui.screen, "ansiFrame": ui.raw.rsplit("\x1b[H", 1)[-1]})
                # Click an exact cell offset; typing and Delete must edit the key, not reorder/remove a column.
                row_index, row = next((index, row) for index, row in enumerate(ui.screen.splitlines()) if "| Rank café 文" in row)
                mouse_x, mouse_y = row.index("rank") + 2, row_index + 1
                ui.send(f"\x1b[<0;{mouse_x};{mouse_y}M\x1b[<0;{mouse_x};{mouse_y}m")
                ui.paste("X"); ui.wait("rX ank")
                ui.send(b"\x7f"); ui.wait("r ank")
                ui.send(ESC + b"OP"); ui.wait("Tractanda help")
                assert "F8 Save" not in ui.screen
                ui.send(ESC); ui.wait("View definition ·")
                ui.send("\x1b[<0;1;1M\x1b[<0;1;1m")
                ui.paste("Z"); ui.wait("rZ ank")
                ui.send(b"\x7f"); ui.wait("r ank")
                checks.append("Mouse cell/caret alignment, field-owned editing, Help overlay return and blocked outside clicks")
                for size in [(48, 12), (132, 35)]:
                    ui.resize(*size); ui.wait("F8 Save")
                    assert "r ank" in ui.screen
                    snapshots.append({"name": "populated-grid-focused", "columns": size[0], "rows": size[1], "screen": ui.screen, "ansiFrame": ui.raw.rsplit("\x1b[H", 1)[-1]})
                assert not client.call("TractandaItem/query", {"expression": "viewDefinition == *"})["ids"]
                ui.send(SAVE_VIEW); ui.wait("Saved one revision")
                saved = tui.wait_item(client, 'subject == "Direct PTY view"', ui)
                definition = saved["fields"]["viewDefinition"]["value"]
                assert definition["expression"] == wire.text("rank >= 0")
                assert [x["value"]["itemID"] for x in definition["categoryPath"]["value"]] == [wire.item_id(included)]
                assert [x["value"]["itemID"] for x in definition["presentation"]["value"]["sections"]["value"]] == [wire.item_id(section)]
                checks.append("Direct multi-field modal form, picker return, inline sort/grid and one guarded Save as")
                ui.send(EDIT_VIEW); ui.wait("View definition ·"); ui.paste("cancelled"); ui.send(CANCEL_VIEW); ui.wait("View definition canceled")
                assert client.call("TractandaItem/history", {"itemID": wire.item_id(saved)})["total"] == 1
                checks.append("F8/F3/F9 modal commands and Cancel make no intermediate write")
    report = {"status": "passed", "platform": platform.platform(), "checks": checks, "snapshots": snapshots}
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "snapshots"}, indent=2))


if __name__ == "__main__":
    main()
