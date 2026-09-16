#!/usr/bin/env python3
"""Exercise the item editor panel and selector Appearance menu in an owned PTY."""
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
F2, F8, F9, F10 = ESC + b"[12~", ESC + b"[19~", ESC + b"[20~", ESC + b"[21~"


def mouse_click(ui, column, row):
    ui.send(f"\x1b[<0;{column};{row}M\x1b[<0;{column};{row}m")


def text_hit(ui, text, occurrence=0, row=None):
    for index, line in enumerate(ui.screen.splitlines(), start=1):
        if row is not None and index != row:
            continue
        start = line.find(text)
        if start >= 0:
            if occurrence == 0:
                return start + 1, index
            occurrence -= 1
    raise AssertionError((text, ui.screen))


def click_text(ui, text, row=None):
    column, row = text_hit(ui, text, row=row)
    mouse_click(ui, column, row)
    ui.settle()


def snapshot(ui, name, snapshots):
    snapshots.append({
        "name": name, "columns": ui.width, "rows": ui.height,
        "screen": ui.screen, "ansiFrame": ui.raw.rsplit("\x1b[H", 1)[-1],
    })


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("native_binary", type=Path)
    parser.add_argument("tui_binary", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    checks, snapshots = [], []
    with tempfile.TemporaryDirectory(prefix="trac-item-overlay-", dir="/tmp") as directory:
        root = Path(directory)
        with wire.server(str(args.native_binary.resolve()), root / "store", root / "s") as client:
            background = client.commit(wire.intent(
                "create", str(uuid.uuid4()), class_id="Item",
                changes={"subject": wire.text("Overlay background"), "body": wire.text("context remains visible")},
            ))["revision"]
            with tui.terminal(str(args.tui_binary.resolve()), root / "s", root / "pending.json", items_only=False) as ui:
                ui.wait("Views")
                # Keyboard path: F10 -> Tractanda -> Appearance.  F9 closes the form without writing.
                ui.send(F10); ui.wait("Command menu")
                ui.send(ESC + b"[D"); ui.wait("Tractanda"); ui.send(b"\r"); ui.wait("Cursor layout")
                ui.send(b"\x07"); ui.wait("Appearance changes canceled")
                checks.append("F10 Tractanda Appearance keyboard route opens and cancels the isolated appearance form")

                # Mouse follows the same route from the visible Views selector.
                ui.send(F10); ui.wait("Command menu")
                click_text(ui, "Tractanda", row=2)
                click_text(ui, "Settings / Appearance")
                ui.wait("Cursor layout")
                ui.send(b"\x07"); ui.wait("Appearance changes canceled")
                checks.append("F10 Tractanda Appearance mouse route from Views opens the same form")

                ui.send(b"\t"); ui.wait("Overlay background")
                ui.wait("Views · report focused")
                ui.send(F10); ui.wait("Command menu")
                ui.send(ESC + b"[D"); ui.send(b"\r"); ui.wait("Cursor layout")
                ui.send(b"\x07"); ui.wait("Appearance changes canceled")
                ui.send(F10); ui.wait("Command menu")
                click_text(ui, "Tractanda", row=2)
                click_text(ui, "Settings / Appearance")
                ui.wait("Cursor layout")
                ui.send(b"\x07"); ui.wait("Appearance changes canceled")
                checks.append("F10 Tractanda Appearance keyboard and mouse routes also work from the report")
                ui.send(F2); ui.wait("Edit item")
                for size in [(80, 25), (48, 12), (132, 35)]:
                    ui.resize(*size); ui.wait("F8 Save")
                    assert "Overlay background" in ui.screen
                    snapshot(ui, "item-editor", snapshots)
                ui.resize(80, 25)
                ui.paste(" edited"); ui.send(b"\t")
                ui.send(b"\x15")
                body = "first line\nsecond café 文 👩🏽‍💻\n" + "\n".join(f"Line {index}" for index in range(28))
                ui.paste(body)
                ui.wait("Line 27")
                snapshot(ui, "body-focused-normal", snapshots)
                ui.resize(48, 12); ui.wait("Line 27 "); assert "F8 Save" in ui.screen
                snapshot(ui, "body-focused-compact", snapshots)
                ui.resize(80, 25); ui.wait("Line 27")
                # Drag in the actual rendered body cells, then wheel back through the same panel.
                line_number, line = next((index + 1, value) for index, value in enumerate(ui.screen.splitlines()) if "Line 27" in value)
                start = line.index("Line 27") + 1
                ui.send(f"\x1b[<0;{start};{line_number}M\x1b[<32;{start + 4};{line_number}M\x1b[<0;{start + 4};{line_number}m")
                ui.settle(); ui.wait("Line"); assert "⟦" not in ui.screen
                for _ in range(12): ui.send(f"\x1b[<64;{start};{line_number}M")
                ui.wait("Line 9")
                # A background click is outside all editor hits and must not dismiss or act on the report.
                mouse_click(ui, 1, 2); ui.wait("F8 Save")
                ui.send(F8); ui.wait("Saved one revision")
                saved = tui.wait_item(client, 'subject == "Overlay background edited"', ui)
                assert wire.item_id(saved) == wire.item_id(background)
                assert saved["fields"]["body"] == wire.text(body)
                assert client.call("TractandaItem/history", {"itemID": wire.item_id(saved)})["total"] == 2
                checks.append("Modal edit retains report context, compact/wide geometry, Unicode multiline body, mouse caret/drag/wheel, blocked background click and one guarded F8 save")

                ui.send(F2); ui.wait("Edit item"); ui.paste(" canceled"); ui.send(F9); ui.wait("Draft canceled")
                assert client.call("TractandaItem/history", {"itemID": wire.item_id(saved)})["total"] == 2
                checks.append("F9 cancel restores the report and creates no intermediate revision")

                ui.send(b"n"); ui.wait("New item"); ui.paste("Overlay-created item"); ui.send(F8)
                ui.wait("Saved one revision")
                created = tui.wait_item(client, 'subject == "Overlay-created item"', ui)
                assert client.call("TractandaItem/history", {"itemID": wire.item_id(created)})["total"] == 1
                checks.append("New item uses one guarded F8 whole edit")

                ui.send(b"c"); ui.wait("Category manager")
                ui.send(ESC + b"n"); ui.wait("New category")
                ui.paste("Overlay category"); ui.send(F8); ui.wait("Saved one revision")
                category = tui.wait_item(client, 'subject == "Overlay category"', ui)
                ui.wait("Category manager")
                ui.send(F2); ui.wait("Edit item")
                ui.paste(" canceled"); ui.send(ESC); ui.wait("Draft canceled")
                ui.wait("Category manager")
                assert client.call("TractandaItem/history", {"itemID": wire.item_id(category)})["total"] == 1
                checks.append("Category editing uses the inline Category manager inspector and its cancel is write-free")
    report = {"status": "passed", "platform": platform.platform(), "checks": checks, "snapshots": snapshots}
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "snapshots"}, indent=2))


if __name__ == "__main__":
    main()
