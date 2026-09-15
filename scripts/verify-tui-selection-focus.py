#!/usr/bin/env python3
"""Check split-pane selection ANSI boundaries with an owned disposable PTY.

Call with fixed copied native and TUI binaries.  The caller owns any build/copy step,
so this script never races Swift's build products and never touches a profile/store.
"""
import argparse
import importlib.util
import json
import re
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("tui", Path(__file__).with_name("verify-tui.py"))
tui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tui)


def attributes_at(line, marker):
    """Interpret emitted SGR state at real text, independently of Swift's style flags."""
    state = {'foreground': 39, 'background': 49, 'dim': False, 'bold': False, 'inverse': False}
    for match in re.finditer(r'\x1b\[([0-9;]*)m', line[:line.index(marker)]):
        for value in [int(part) if part else 0 for part in match[1].split(';')]:
            if value == 0:
                state = {'foreground': 39, 'background': 49, 'dim': False, 'bold': False, 'inverse': False}
            elif value == 1: state['bold'] = True
            elif value == 2: state['dim'] = True
            elif value == 22: state['bold'] = state['dim'] = False
            elif value == 7: state['inverse'] = True
            elif value == 27: state['inverse'] = False
            elif 30 <= value <= 37 or value == 39 or 90 <= value <= 97: state['foreground'] = value
            elif 40 <= value <= 47 or value == 49 or 100 <= value <= 107: state['background'] = value
    return state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("native_binary", type=Path)
    parser.add_argument("tui_binary", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = {"status": "failed", "checks": [], "snapshots": []}
    with tempfile.TemporaryDirectory(prefix="tui-focus-", dir="/tmp") as directory:
        root = Path(directory)
        store, socket = root / "store", root / "s"
        recovery, appearance = root / "r.json", root / "appearance.json"
        with tui.wire.server(str(args.native_binary.resolve()), store, socket) as client:
            client.commit(tui.wire.intent("create", "focus-item", class_id="NoteItem", changes={
                "subject": tui.wire.text("Wide 文🙂 selection"), "body": tui.wire.text("Preview remains unselected"),
            }))
            manifest = tui.wire.manifest(store)
            with tui.terminal(
                str(args.tui_binary.resolve()), socket, recovery,
                arguments=[str(socket), "--appearance-file", str(appearance)], items_only=False
            ) as ui:
                ui.resize(132, 28)
                ui.wait("Wide 文🙂 selection")
                raw = ui.raw.rsplit("\x1b[H", 1)[-1]
                row = next(line for line in raw.split("\r\n") if "Wide 文🙂 selection" in line)
                assert "\x1b[0;2;37;44m" in row, row
                preview = next(line for line in raw.split("\r\n") if "Preview remains unselected" in line)
                assert "\x1b[0;2;37;44m" not in preview, preview
                assert attributes_at(row, 'Wide')['background'] == 44
                assert attributes_at(row, 'Wide')['dim']
                assert attributes_at(preview, 'Preview remains')['background'] == 49
                assert attributes_at(preview, 'Preview remains')['dim']
                report["checks"].append("inactive selected list cells stop before separator and preview")
                report["snapshots"].append({"name": "views-focused", "ansiFrame": raw})
                ui.send(b"\t")
                ui.wait("report focused")
                raw = ui.raw.rsplit("\x1b[H", 1)[-1]
                row = next(line for line in raw.split("\r\n") if "Wide 文🙂 selection" in line)
                assert "\x1b[0;97;44m" in row
                assert not attributes_at(row, 'Wide')['dim']
                preview = next(line for line in raw.split("\r\n") if "Preview remains unselected" in line)
                assert attributes_at(preview, 'Preview remains')['background'] == 49
                assert attributes_at(preview, 'Preview remains')['dim']
                header = next(line for line in raw.split('\r\n') if 'Subject' in line)
                assert attributes_at(header, 'Subject')['background'] == 49
                assert attributes_at(header, 'Subject')['bold']
                # The independent bottom pane becomes active only when Tab reaches it.
                ui.send(b"\t"); ui.settle()
                preview = next(line for line in ui.raw.rsplit("\x1b[H", 1)[-1].split("\r\n") if "Preview remains unselected" in line)
                assert not attributes_at(preview, 'Preview remains')['dim']
                ui.send(b"\x1b[Z"); ui.settle()
                report['snapshots'].append({'name': 'report-focused', 'ansiFrame': raw})
                ui.send(b"\x1b[44;9u")  # Cmd-comma forwarded through the standard key map.
                ui.wait("Settings / Appearance")
                assert not appearance.exists()
                ui.send(b"\x1b[C")
                ui.settle(); ui.wait("Amber")
                assert "\x1b[0;30;103m" in ui.raw.rsplit("\x1b[H", 1)[-1]
                ui.send(b"\x07")
                ui.wait("report focused")
                assert not appearance.exists()
                report["checks"].append("Tab focuses report and Cmd-comma opens staged Appearance without a write")
                report["status"] = "passed"
            with tui.terminal(
                str(args.tui_binary.resolve()), socket, recovery,
                arguments=[str(socket), "--appearance-file", str(appearance)], items_only=False
            ) as ui:
                ui.wait("Views · focused")
                ui.send(b"\x1b[44;9u")
                ui.wait("Settings / Appearance")
                ui.send(b"\x1b[C\x13")
                ui.wait("Appearance saved locally")
                assert appearance.exists() and tui.wire.manifest(store) == manifest
                report['snapshots'].append({'name': 'amber-saved', 'ansiFrame': ui.raw.rsplit('\x1b[H', 1)[-1]})
            with tui.terminal(
                str(args.tui_binary.resolve()), socket, recovery,
                arguments=[str(socket), "--appearance-file", str(appearance)], items_only=False
            ) as ui:
                ui.wait("Views · focused")
                ui.send(b"\x1b[44;9u")
                ui.wait("Amber")
                # Function-key label foreground (index 16) and menu-selection background (index 21).
                ui.send(b"\t" * 16 + b"\x15brightCyan" + b"\t" * 5 + b"\x15brightMagenta\x13")
                ui.wait("Appearance saved locally")
                ui.send(b"\x1b[21~")
                ui.wait("Command menu")
                raw = ui.raw.rsplit("\x1b[H", 1)[-1]
                report['snapshots'].append({'name': 'custom-menu', 'ansiFrame': raw})
                assert "\x1b[0;96;43m" in raw and "\x1b[0;30;105m" in raw, raw
                ui.send(b"\x1b[21~")  # Close unambiguously before resizing or sending another escape sequence.
                ui.wait("Views · focused", absent="Close / cancel")
                ui.resize(48, 12)
                ui.send(b"\x1b[44;9u")
                ui.wait("Settings / Appearance")
                ui.send(b"\t" * 25)
                ui.settle(); ui.wait("Passive pane"); assert "F8 Save" in ui.screen
                report['snapshots'].append({'name': 'compact-colors', 'ansiFrame': ui.raw.rsplit('\x1b[H', 1)[-1]})
                ui.send(b"\x07")
                # A selector click restores top focus without changing canonical data.
                ui.send(b"\x1b[<0;5;4M\x1b[<0;5;4m")
                ui.wait("Views · focused")
                assert tui.wire.manifest(store) == manifest
                report["checks"].append("Amber cancel/save/restart, independent custom bright roles, compact final field, mouse focus and popup close preserve the native manifest")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print("tui selection/focus verification passed")


if __name__ == "__main__":
    main()
