#!/usr/bin/env python3
"""Check settings groups, focus order and discoverable RGB colors in an owned terminal."""
import argparse
import importlib.util
import json
from pathlib import Path
import platform
import tempfile

spec = importlib.util.spec_from_file_location('tui', Path(__file__).with_name('verify-tui.py'))
tui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tui)
wire, ESC = tui.wire, tui.ESC


def snapshot(ui, name, snapshots):
    ui.settle()
    snapshots.append({'name': name, 'columns': ui.width, 'rows': ui.height, 'screen': ui.screen,
                      'ansiFrame': ui.raw.rsplit('\x1b[H', 1)[-1], 'cursor': ui.cursor})


def roles(record):
    value = record['roles']
    return value if isinstance(value, dict) else dict(zip(value[::2], value[1::2]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('native_binary', type=Path)
    parser.add_argument('tui_binary', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    checks, snapshots = [], []
    with tempfile.TemporaryDirectory(prefix='trac-settings-groups-', dir='/tmp') as directory:
        root = Path(directory)
        settings = root / 'r.appearance.json'
        with wire.server(str(args.native_binary.resolve()), root / 'store', root / 's') as client:
            with tui.terminal(str(args.tui_binary.resolve()), root / 's', root / 'r.json') as ui:
                ui.wait('No items')
                def open_settings():
                    ui.send(ESC + b'[44;9u'); ui.wait('Settings / Appearance')
                def save():
                    ui.send(ESC + b'[19~'); ui.wait('Appearance saved locally')
                open_settings()
                rows = ui.screen.splitlines()
                positions = [next(i for i, row in enumerate(rows) if label in row)
                             for label in ('Cursor layout', 'Cursor shape', 'Cursor color', 'Cursor blink')]
                assert positions == list(range(positions[0], positions[0] + 4)), ui.screen
                assert 'Interface colors' in ui.screen
                assert 'Active selection' in ui.screen and 'Passive pane' in ui.screen
                snapshot(ui, 'grouped-default', snapshots)
                save(); original = json.loads(settings.read_text())
                open_settings(); ui.send(b'\t' * 4 + ESC + b'[C'); save()
                changed = json.loads(settings.read_text())
                assert changed['cursor']['blink'] is True
                assert roles(changed) == roles(original)
                checks.append('Cursor layout/shape/color/blink are adjacent visually and in Tab order; blink edits no color role')

                open_settings(); ui.send(b'\t\t'); ui.settle()
                header = next((i + 1, row) for i, row in enumerate(ui.screen.splitlines())
                              if 'Cursor' in row and not any(x in row for x in ('layout', 'shape', 'color', 'blink')))
                before_cursor = ui.cursor
                x = header[1].index('Cursor') + 1
                ui.send(f'\x1b[<0;{x};{header[0]}M\x1b[<0;{x};{header[0]}m'); ui.settle()
                assert ui.cursor == before_cursor
                ui.send(b'\t'); ui.wait('#RRGGBB')
                ui.send(b'\x15'); ui.paste('#8A2BE2'); ui.settle()
                assert ui.cursor['color'] == '#8a2be2'
                color_row = next((i + 1, line) for i, line in enumerate(ui.screen.splitlines())
                                 if '#8A2BE2' in line or '#8a2be2' in line)
                assert ui.cursor['row'] == color_row[0]
                assert ui.cursor['column'] == color_row[1].lower().index('#8a2be2') + 8, (ui.cursor, color_row)
                # Menu selection foreground/background are fields 20/21 after adding the Effects control.
                ui.send(b'\t' * 17 + b'\x15'); ui.paste('#FFBF00')
                ui.send(b'\t\x15'); ui.paste('#001F3F'); ui.settle()
                raw = ui.raw.rsplit('\x1b[H', 1)[-1]
                assert '38;2;255;191;0' in raw and '48;2;0;31;63' in raw
                snapshot(ui, 'hex-colors-visible', snapshots)
                ui.resize(48, 12); ui.wait('#RRGGBB')
                assert all(label in ui.screen for label in ('F5 Save as', 'F8 Save', 'F9 Cancel'))
                snapshot(ui, 'compact-interface-colors', snapshots)
                ui.send(b'\t' * 4); ui.settle()
                assert 'Passive pane' in ui.screen and 'F9 Cancel' in ui.screen
                save()
                changed = json.loads(settings.read_text())
                assert roles(changed)['menuSelection']['foreground'] == '#ffbf00'
                assert roles(changed)['menuSelection']['background'] == '#001f3f'
                assert changed['cursor']['color'] == '#8a2be2' and changed['cursor']['blink'] is True
                assert '\x1b]4;' not in ui.raw
                checks.append('Group headings are inert; RGB hint, hex cursor color and exact direct-RGB foreground/background survive compact editing and save')
                ui.resize(80, 25)
                open_settings(); ui.send(b'\t' * 4 + ESC + b'[C')
                ui.send(ESC + b'[20~'); ui.wait('Appearance changes canceled')
                assert json.loads(settings.read_text()) == changed
                assert not client.call('TractandaItem/query')['ids']
                checks.append('Cancel retains saved values and all settings activity remains outside canonical items')
    report = {'status': 'passed', 'platform': platform.platform(), 'checks': checks, 'snapshots': snapshots}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'snapshots'}, indent=2))


if __name__ == '__main__':
    main()
