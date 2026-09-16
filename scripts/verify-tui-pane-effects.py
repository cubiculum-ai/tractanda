#!/usr/bin/env python3
"""Check active/passive pane colors and layered popup shadows through actual ANSI output."""
import argparse
import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import uuid

spec = importlib.util.spec_from_file_location('borders', Path(__file__).with_name('verify-tui-overlay-borders.py'))
borders = importlib.util.module_from_spec(spec); spec.loader.exec_module(borders)
tui, wire, ESC = borders.tui, borders.wire, borders.ESC
F2, F5, F8, F9, F10 = [ESC + f'[{n}~'.encode() for n in (12, 15, 19, 20, 21)]


def frame(ui):
    ui.settle()
    return [borders.cells(r) for r in ui.raw.rsplit('\x1b[H', 1)[-1].split('\r\n')]


def boxes(rows):
    result = []
    for top, row in enumerate(rows):
        for left, (glyph, _) in enumerate(row):
            if glyph not in '╭┌': continue
            right = next((i for i in range(left + 1, len(row)) if row[i][0] in '╮┐'), None)
            if right is None: continue
            bottom = next((j for j in range(top + 1, len(rows)) if len(rows[j]) > right
                           and rows[j][left][0] in '╰└' and rows[j][right][0] in '╯┘'), None)
            if bottom is not None: result.append((top, left, bottom, right))
    return result


def is_shadow(cell):
    return cell[1]['fg'] == ('ansi', 30) and cell[1]['bg'] == ('ansi', 40) and not cell[1]['inverse']


def contains(box, row, column):
    top, left, bottom, right = box
    return top <= row <= bottom and left <= column <= right


def shadow_cells(box, width, height):
    top, left, bottom, right = box
    candidates = {(r, c) for r in range(top + 1, bottom + 2) for c in range(right + 1, right + 3)}
    candidates |= {(bottom + 1, c) for c in range(left + 2, right + 3)}
    return {(r, c) for r, c in candidates if 0 <= r < height - 2 and 0 <= c < width - 1}


def check_shadows(ui, name, snapshots, nested=False):
    rows = frame(ui); found = boxes(rows)
    assert found, (name, ui.screen)
    # The fixtures use nested rectangles; outer area sorts before its higher layer.
    ordered = sorted(found, key=lambda b: (b[2] - b[0]) * (b[3] - b[1]), reverse=True)
    if nested: assert len(ordered) >= 2, (name, ordered)
    expected = set()
    for i, box in enumerate(ordered):
        expected |= {(r, c) for r, c in shadow_cells(box, ui.width, ui.height)
                     if not any(contains(higher, r, c) for higher in ordered[i + 1:])}
    assert expected, (name, 'no shadow space reserved', ordered, ui.screen)
    for r, c in expected:
        assert is_shadow(rows[r][c]), (name, r, c, rows[r][c], ordered, ui.screen)
    inner = ordered[-1]
    assert not any(is_shadow(rows[r][c]) for r in range(inner[0], inner[2] + 1)
                   for c in range(inner[1], inner[3] + 1)), (name, 'front panel shadowed')
    assert not any(is_shadow(c) for row in rows[-2:] for c in row), (name, 'chrome shadowed')
    snapshots.append({'name': name, 'columns': ui.width, 'rows': ui.height, 'screen': ui.screen,
                      'ansiFrame': ui.raw.rsplit('\x1b[H', 1)[-1], 'shadowCellCount': len(expected)})
    return expected, rows


def find_text(rows, text):
    for row in rows:
        s = ''.join(c for c, _ in row)
        if text in s: return row[s.index(text)]
    raise AssertionError(text)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('native_binary', type=Path); p.add_argument('tui_binary', type=Path)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args(); checks, snapshots = [], []
    with tempfile.TemporaryDirectory(prefix='trac-pane-effects-', dir='/tmp') as directory:
        root = Path(directory); settings = root / 'r.appearance.json'
        data = json.loads((Path(__file__).resolve().parents[1] / 'Sources/TractandaTUI/Resources/AppearancePresets.json').read_text())
        roles = copy.deepcopy(data['palettes'][0]['roles'])
        if isinstance(roles, list): roles = dict(zip(roles[::2], roles[1::2]))
        roles['activePane'] = {'foreground': '#223344', 'background': '#ddeeff', 'bold': False, 'dim': False}
        roles['passivePane'] = {'foreground': '#778899', 'background': '#111820', 'bold': False, 'dim': True}
        flattened = [part for k, v in roles.items() for part in (k, v)]
        settings.write_text(json.dumps({'version': 4, 'preset': 'custom', 'roles': flattened,
                                       'customRoles': flattened, 'savedPalettes': data['palettes'],
                                       'showsDropShadows': False}))
        os.chmod(settings, 0o600)
        with wire.server(str(args.native_binary.resolve()), root / 'store', root / 's') as client:
            for name, body in [('Ordinary sample', 'older item'), ('Selected sample', 'Preview sample\nSecond preview line')]:
                client.commit(wire.intent('create', str(uuid.uuid4()), class_id='Item',
                                          changes={'subject': wire.text(name), 'body': wire.text(body)}))
            baseline = wire.manifest(root / 'store')
            def session(): return tui.terminal(str(args.tui_binary.resolve()), root / 's', root / 'r.json', items_only=False)
            def open_settings(ui): ui.send(ESC + b'[44;9u'); ui.wait('Settings / Appearance')
            def save(ui): ui.send(F8); ui.wait('saved locally')
            active = {'fg': ('rgb', 34, 51, 68), 'bg': ('rgb', 221, 238, 255), 'inverse': False}
            passive = {'fg': ('rgb', 119, 136, 153), 'bg': ('rgb', 17, 24, 32), 'inverse': False}
            with session() as ui:
                ui.resize(132, 35); ui.wait('Views · focused')
                rows = frame(ui)
                assert find_text(rows, 'Find:')[1] == active
                assert find_text(rows, 'Ordinary sample')[1] == passive
                assert find_text(rows, 'Preview sample')[1] == passive
                assert rows[ui.height - 3][5][1] == passive, ('passive blank fill', rows[ui.height - 3][5])
                ui.send(b'\t'); ui.wait('report focused'); rows = frame(ui)
                assert find_text(rows, 'Find:')[1] == passive
                assert find_text(rows, 'Ordinary sample')[1] == active
                assert find_text(rows, 'Preview sample')[1] == passive
                assert rows[ui.height - 3][5][1] == passive
                ui.send(b'\t'); ui.settle(); rows = frame(ui)
                assert find_text(rows, 'Preview sample')[1] == active
                assert rows[ui.height - 3][5][1] == active
                ui.send(ESC + b'[Z'); ui.settle()
                checks.append('Active and passive text, preview and blank fills follow focus independently of selection/header roles')
                open_settings(ui); ui.send(b'\t' * 5 + ESC + b'[C'); ui.settle()
                for size in [(80, 25), (48, 12), (132, 35)]:
                    ui.resize(*size); ui.wait('Drop shadows')
                    assert all(k in ui.screen for k in ('F5 Save as', 'F6 Delete', 'F8 Save', 'F9 Cancel'))
                    check_shadows(ui, f'appearance-{size}', snapshots)
                save(ui); assert json.loads(settings.read_text())['showsDropShadows'] is True
                before = frame(ui); ui.send(F10); ui.wait('Command menu')
                mask, drawn = check_shadows(ui, 'command-menu', snapshots)
                assert all(drawn[r][c][0] == before[r][c][0] for r, c in mask)
                ui.send(F10); ui.wait('report focused', absent='Command menu'); restored = frame(ui)
                assert all(restored[r][c] == before[r][c] for r, c in mask)
                checks.append('Optional shadow is visible at normal/compact sizes, clipped off chrome, preserves background glyphs and clears on menu close')
                open_settings(ui); ui.send(F5); ui.wait('Save appearance preset')
                check_shadows(ui, 'nested-name', snapshots, nested=True)
                ui.send(F9); ui.wait('Cursor layout'); ui.send(F9); ui.wait('Appearance changes canceled')
                ui.send(F2); ui.wait('Edit item'); mask, _ = check_shadows(ui, 'item-editor', snapshots)
                r, c = sorted(mask)[0]; ui.send(f'\x1b[<0;{c+1};{r+1}M\x1b[<0;{c+1};{r+1}m'); ui.settle()
                assert 'Edit item' in ui.screen
                ui.send(F9); ui.wait('Draft canceled')
                checks.append('Nested shadows respect front-panel occlusion; a shadow click does not activate or discard an item draft')
            with session() as ui:
                ui.wait('Views'); open_settings(ui); ui.send(b'\x15'); ui.paste('Blue'); save(ui)
                assert json.loads(settings.read_text())['showsDropShadows'] is True
                open_settings(ui); ui.send(b'\t' * 5 + ESC + b'[D'); ui.send(F9); ui.wait('Appearance changes canceled')
                assert json.loads(settings.read_text())['showsDropShadows'] is True
                open_settings(ui); ui.send(b'\t' * 5 + ESC + b'[D'); save(ui)
                ui.send(F10); ui.wait('Command menu')
                assert not any(is_shadow(c) for row in frame(ui) for c in row)
                checks.append('Shadow setting survives restart and preset selection; Cancel restores it and saving Off removes the effect')
            assert wire.manifest(root / 'store') == baseline
    report = {'status': 'passed', 'checks': checks, 'snapshots': snapshots, 'canonicalStoreUnchanged': True}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'snapshots'}, indent=2))


if __name__ == '__main__': main()
