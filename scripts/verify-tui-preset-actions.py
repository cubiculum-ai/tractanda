#!/usr/bin/env python3
"""Exercise named preset update/copy/delete transactions in an isolated real terminal."""
import argparse
import importlib.util
import json
from pathlib import Path
import tempfile

spec = importlib.util.spec_from_file_location('tui', Path(__file__).with_name('verify-tui.py'))
tui = importlib.util.module_from_spec(spec); spec.loader.exec_module(tui)
ESC, wire = tui.ESC, tui.wire
F5, F6, F8, F9 = [ESC + f'[{n}~'.encode() for n in (15, 17, 19, 20)]


def palette_roles(value):
    r = value['roles']
    return r if isinstance(r, dict) else dict(zip(r[::2], r[1::2]))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('native_binary', type=Path); p.add_argument('tui_binary', type=Path)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args(); checks = []
    with tempfile.TemporaryDirectory(prefix='trac-presets-', dir='/tmp') as directory:
        root = Path(directory); prefs = root / 'r.appearance.json'
        with wire.server(str(args.native_binary.resolve()), root / 'store', root / 's') as client:
            def session(): return tui.terminal(str(args.tui_binary.resolve()), root / 's', root / 'r.json')
            def open_settings(ui):
                ui.send(ESC + b'[44;9u'); ui.wait('Settings / Appearance')
            def choose(ui, name):
                ui.send(b'\x15'); ui.paste(name); ui.settle()
            def save(ui): ui.send(F8); ui.wait('saved locally')
            def foreground(ui, color): ui.send(b'\t' * 6 + b'\x15'); ui.paste(color); ui.settle()
            def read(): return json.loads(prefs.read_text())

            with session() as ui:
                ui.wait('No items'); open_settings(ui); save(ui)
                original = read(); identity = original['preset']
                open_settings(ui); foreground(ui, '#123456')
                assert 'modified' in ui.screen.lower(), ui.screen
                save(ui)
                updated = read(); assert updated['preset'] == identity
                named = next(p for p in updated['savedPalettes'] if p['id'] == identity)
                assert palette_roles(named) == palette_roles(updated)
                assert palette_roles(named)['activeSelection']['foreground'] == '#123456'
                before = prefs.read_bytes()
                open_settings(ui); foreground(ui, '#789abc')
                ui.send((ESC + b'[Z') * 6); choose(ui, 'Amber'); choose(ui, 'Blue')
                assert '#789abc' in ui.screen
                ui.send(F9); ui.wait('Appearance changes canceled')
                assert prefs.read_bytes() == before
                checks.append('Ordinary Save updates selected named ID; switching preserves staged edits, and Cancel restores the saved palette')

                open_settings(ui); foreground(ui, '#abcdef'); ui.send(F5); ui.wait('Save appearance preset')
                ui.paste('Copied Blue'); save(ui)
                copied = read(); copied_id = copied['preset']
                assert copied_id != identity
                assert palette_roles(copied)['activeSelection']['foreground'] == '#abcdef'
                source = next(p for p in copied['savedPalettes'] if p['id'] == identity)
                assert palette_roles(source) == palette_roles(named)
                before = prefs.read_bytes()
                open_settings(ui); ui.send(F6); ui.settle()
                assert prefs.read_bytes() == before
                ui.send(F9); ui.wait('Appearance changes canceled')
                assert prefs.read_bytes() == before
                checks.append('Save as preserves the named source; Delete is staged and Cancel restores it without writing')

                # Click the same visible delete command and commit the staged library change.
                open_settings(ui)
                row, line = next((i + 1, line) for i, line in enumerate(ui.screen.splitlines()) if 'F6 Delete' in line)
                column = line.index('F6 Delete') + 2
                ui.send(f'\x1b[<0;{column};{row}M\x1b[<0;{column};{row}m'); ui.settle(); save(ui)
                assert copied_id not in [p['id'] for p in read()['savedPalettes']]
                for name in [p['name'] for p in read()['savedPalettes']]:
                    open_settings(ui); choose(ui, name); ui.send(F6); ui.settle(); save(ui)
                assert read()['savedPalettes'] == [] and read()['preset'] == 'custom'
                cursor = read()['cursor']
                checks.append('Mouse and keyboard delete supplied/user palettes; deleting the last palette leaves valid Custom settings')

            with session() as ui:
                ui.wait('No items'); open_settings(ui)
                before = prefs.read_bytes(); ui.send(F6); ui.settle(); ui.send(F9)
                ui.wait('Appearance changes canceled')
                assert prefs.read_bytes() == before
                assert read()['savedPalettes'] == [] and read()['cursor'] == cursor
                assert not client.call('TractandaItem/query')['ids']
                checks.append('An empty saved library survives restart; Custom is not deletable; canonical items and cursor settings stay intact')
    report = {'status': 'passed', 'checks': checks}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n'); print(json.dumps(report, indent=2))


if __name__ == '__main__': main()
