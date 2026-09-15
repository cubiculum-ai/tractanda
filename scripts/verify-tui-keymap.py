#!/usr/bin/env python3
"""Exercise forwarded Command, Meta, terminal function keys and the compact key bar in a real PTY."""
import argparse
import importlib.util
import json
import platform
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("tui", Path(__file__).with_name("verify-tui.py"))
tui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tui)
wire, ESC = tui.wire, tui.ESC


def command(letter, shift=False, release=False):
    return ESC + f"[{ord(letter)};{10 if shift else 9}{':3' if release else ''}u".encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("native_binary", type=Path)
    parser.add_argument("tui_binary", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    native, binary = str(args.native_binary.resolve()), str(args.tui_binary.resolve())
    checks, snapshots = [], []
    with tempfile.TemporaryDirectory(prefix="trac-keymap-", dir="/tmp") as directory:
        root = Path(directory)
        with wire.server(native, root / "store", root / "s") as client:
            with tui.terminal(binary, root / "s", root / "recovery/pending.json") as ui:
                ui.wait("No items")
                assert "\x1b[>1u" in ui.raw
                assert "2Edit" not in ui.screen.splitlines()[-1] and "10Menu" in ui.screen, ui.screen
                ui.send(b"\x0e"); ui.wait("New item")
                ui.paste("Shortcut café")
                ui.send(b"\x01\x06\x02\x05\t")
                ui.paste("alpha\nbeta")
                ui.send(b"\x01\x10\x0e\x05!")
                ui.wait("beta! ")
                ui.send(command("s", release=True))
                ui.send(ESC + b"[21~"); ui.wait("Command menu")
                assert client.call("TractandaItem/query", {})["total"] == 0
                ui.send(ESC); ui.wait("Body / note", absent="Command menu")
                assert "2Paste" not in ui.screen.splitlines()[-1] and "3Copy" not in ui.screen.splitlines()[-1]
                ui.resize(30, 8); ui.wait("Enlarge terminal")
                ui.send("qSHOULD NOT EDIT"); ui.read(0.2)
                ui.resize(48, 12); ui.wait("Body / note")
                for width, height in [(48, 12), (80, 25), (132, 40)]:
                    ui.resize(width, height)
                    ui.wait("Body / note")
                    last = ui.screen.splitlines()[-1]
                    assert len(last) == width - 1 and last.startswith("1"), (width, last)
                    snapshots.append({"name": "text-editor", "columns": width, "rows": height, "screen": ui.screen})
                ui.send(command("s")); ui.wait("Saved one revision")
                item = tui.wait_item(client, 'subject == "Shortcut café"', ui)
                identity = wire.item_id(item)
                assert item["fields"]["body"] == wire.text("alpha\nbeta!")
                assert len(wire.manifest(root / "store")) == 1
                ui.send(b"\x05"); ui.wait("Edit item")
                ui.send(b"\x07"); ui.wait("Draft canceled")
                checks.append("Control-N capture; Ctrl-A/B/E/F/N/P edit text; forwarded Command-S commits once and its release does not commit")
                checks.append("Editor command menu preserves its draft; undersized windows ignore typing including Q; context F-key bar fits 48, 80 and 132 columns")

                # F5 enters note editing; F7 selects, F3 copies, F2 pastes.
                ui.send(ESC + b"[15~"); ui.wait("Body / note")
                ui.send(command("a")); ui.send(ESC + b"OR")
                ui.send(ESC + b"[Z") # Previous field: subject.
                ui.wait("Subject")
                ui.send(command("a")); ui.send(ESC + b"OQ")
                ui.wait("alpha")
                ui.send(b"\x1a"); ui.wait("Shortcut café")
                ui.send(command("w")); ui.wait("Draft canceled")
                assert client.get(identity) == item
                checks.append("F5 note editing, local copy/paste, Control-Z undo and Command-W cancel preserve the canonical item")

                ui.send(ESC + b"[18~"); ui.wait("1 marked")
                ui.send(ESC + b"[18;3~"); ui.wait("All items unmarked")
                ui.send(ESC + b"[20~"); ui.wait("Category manager")
                ui.send(b"\x0e"); ui.wait("New category")
                ui.paste("Fixture category"); ui.send(b"\x13"); ui.wait("Saved one revision")
                category = tui.wait_item(client, 'subject == "Fixture category"', ui)
                category_id = wire.item_id(category)
                ui.wait("Category manager")
                ui.paste("Fixture category"); ui.wait("Find: Fixture category")
                ui.send(ESC + b"[17~"); ui.wait("Category rule")
                ui.send(b"\x07"); ui.wait("Draft canceled")
                assert client.get(category_id) == category
                ui.wait("Find: Fixture category ")  # Cancel retains the category manager's search.
                ui.send(ESC + b"\r"); ui.wait("Added category filter")
                ui.send("a"); ui.wait("All readable items")
                ui.send(ESC + b"[20~"); ui.wait("Category manager")
                ui.send(ESC + b"[20~"); ui.wait("No expression filter")
                checks.append("Alt-F7 clears marks; Ctrl-N creates a category; Ctrl-E edits an item, F6 edits properties, Meta-Return refines and F9 returns")

                ui.send(b"\x13"); ui.wait("Save view as")
                ui.paste("First keyboard view"); ui.send(b"\x13"); ui.wait("Saved one revision")
                first = tui.wait_item(client, 'subject == "First keyboard view"', ui)
                ui.send(command("s")); ui.wait("Save changes to this view")
                ui.send(" revised"); ui.send(b"\x13"); ui.wait("Saved one revision")
                revised = tui.wait_item(client, 'subject == "First keyboard view revised"', ui)
                assert wire.item_id(revised) == wire.item_id(first)
                ui.send(command("s", shift=True)); ui.wait("Save view as")
                ui.paste("Second keyboard view"); ui.send(command("s")); ui.wait("Saved one revision")
                second = tui.wait_item(client, 'subject == "Second keyboard view"', ui)
                assert wire.item_id(second) != wire.item_id(first)
                assert client.get(wire.item_id(first)) == revised
                checks.append("Save revises the open view; forwarded Command-Shift-S creates an independent saved view")
                ui.send("a"); ui.wait("All readable items")
                ui.close()
                assert "\x1b[<u" in ui.raw
                assert ui.raw.index("\x1b[<u") < ui.raw.index("\x1b[?1049l")
                checks.append("Keyboard protocol state, bracketed paste, cursor, screen and POSIX terminal modes are restored on exit")
    result = {"platform": platform.platform(), "status": "passed", "checks": checks, "snapshots": snapshots}
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key != "snapshots"}, ensure_ascii=False))


if __name__ == "__main__":
    main()
