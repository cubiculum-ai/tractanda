#!/usr/bin/env python3
"""Read actual ANSI cell colors at overlay frames, including nested and selected text panels."""
import argparse
import copy
import importlib.util
import json
import os
from pathlib import Path
import re
import tempfile
import unicodedata
import uuid

spec = importlib.util.spec_from_file_location('tui', Path(__file__).with_name('verify-tui.py'))
tui = importlib.util.module_from_spec(spec); spec.loader.exec_module(tui)
wire, ESC = tui.wire, tui.ESC
F2, F4, F5, F9, F10 = [ESC + f'[{n}~'.encode() for n in (12, 14, 15, 20, 21)]


def cells(raw):
    state = {'fg': ('default',), 'bg': ('default',), 'inverse': False}
    result, offset = [], 0
    def add(text):
        for c in text:
            if ord(c) < 32 or unicodedata.combining(c): continue
            width = 2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1
            result.extend([(c, copy.deepcopy(state))] * width)
    for match in tui.CONTROL_SEQUENCE.finditer(raw):
        add(raw[offset:match.start()]); offset = match.end()
        sgr = re.fullmatch(r'\x1b\[([0-9;]*)m', match[0])
        if not sgr: continue
        v = [int(n or 0) for n in sgr[1].split(';')]; i = 0
        while i < len(v):
            n = v[i]; i += 1
            if n == 0: state = {'fg': ('default',), 'bg': ('default',), 'inverse': False}
            elif n == 7: state['inverse'] = True
            elif n == 27: state['inverse'] = False
            elif n in (38, 48) and i < len(v):
                key = 'fg' if n == 38 else 'bg'
                if v[i] == 2 and i + 3 < len(v):
                    state[key] = ('rgb', *v[i + 1:i + 4]); i += 4
                elif v[i] == 5 and i + 1 < len(v):
                    state[key] = ('index', v[i + 1]); i += 2
            elif n == 39: state['fg'] = ('default',)
            elif n == 49: state['bg'] = ('default',)
            elif 30 <= n <= 37 or 90 <= n <= 97: state['fg'] = ('ansi', n)
            elif 40 <= n <= 47 or 100 <= n <= 107: state['bg'] = ('ansi', n)
    add(raw[offset:]); return result


def verify_frame(ui, name, snapshots, literal=False):
    ui.settle()
    raw = ui.raw.rsplit('\x1b[H', 1)[-1]
    rows = [cells(r) for r in raw.split('\r\n')]
    boxes = []
    for top, row in enumerate(rows):
        for left, (c, _) in enumerate(row):
            if c not in '╭┌': continue
            right = next((i for i in range(left + 1, len(row)) if row[i][0] in '╮┐'), None)
            if right is None: continue
            bottom = next((j for j in range(top + 1, len(rows))
                           if len(rows[j]) > right and rows[j][left][0] in '╰└' and rows[j][right][0] in '╯┘'), None)
            if bottom is not None: boxes.append((top, left, bottom, right))
    assert boxes, (name, ui.screen)
    top, left, bottom, right = min(boxes, key=lambda b: (b[2]-b[0])*(b[3]-b[1]))
    expected = {'fg': ('rgb', 170, 187, 204), 'bg': ('rgb', 16, 17, 18), 'inverse': False}
    coordinates = [(r, c) for r in range(top, bottom + 1) for c in (left, right)]
    coordinates += [(r, c) for r in (top, bottom) for c in range(left + 1, right)
                    if rows[r][c][0] in '─┬┴┼']
    for r, c in coordinates:
        assert rows[r][c][1] == expected, (name, r, c, rows[r][c], expected, ui.screen)
    interior = [rows[r][c] for r in range(top + 1, bottom) for c in range(left + 1, right)]
    assert any(cell[1]['bg'] != expected['bg'] or cell[1]['inverse'] for cell in interior), (name, 'no distinct interior highlight')
    if literal:
        literal_cells = [cell for cell in interior if cell[0] == '│']
        assert any(cell[1]['inverse'] for cell in literal_cells), (name, 'literal body glyph lost text selection', ui.screen)
    snapshots.append({'name': name, 'columns': ui.width, 'rows': ui.height, 'screen': ui.screen,
                      'ansiFrame': raw, 'checkedFrameCells': len(coordinates)})


def verify_category_split(ui, snapshots):
    """The category editor is now an inline pane, with an unhighlighted divider."""
    ui.settle()
    raw = ui.raw.rsplit('\x1b[H', 1)[-1]
    rows = [cells(row) for row in raw.split('\r\n')]
    assert 'Edit item' in ui.screen and 'Category manager' in ui.screen
    assert '┌' not in ui.screen and '╭' not in ui.screen, ui.screen
    dividers = [(r, c) for r, row in enumerate(rows) for c, (glyph, _) in enumerate(row)
                if glyph == '│']
    assert dividers, ui.screen
    for r, c in dividers:
        style = rows[r][c][1]
        assert not style['inverse'] and style['bg'] != ('rgb', 18, 52, 86), (r, c, style)
    snapshots.append({'name': 'inline-category-divider', 'columns': ui.width, 'rows': ui.height,
                      'screen': ui.screen, 'ansiFrame': raw, 'checkedDividerCells': len(dividers)})


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('native_binary', type=Path); p.add_argument('tui_binary', type=Path)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args(); snapshots, checks = [], []
    with tempfile.TemporaryDirectory(prefix='trac-borders-', dir='/tmp') as directory:
        root = Path(directory); prefs = root / 'appearance.json'
        source = json.loads((Path(__file__).resolve().parents[1] / 'Sources/TractandaTUI/Resources/AppearancePresets.json').read_text())
        roles = source['palettes'][0]['roles']
        if isinstance(roles, list): roles = dict(zip(roles[::2], roles[1::2]))
        roles = copy.deepcopy(roles)
        for role, fg, bg in [('menuSurface', '#aabbcc', '#101112'), ('menuSelection', '#ffeedd', '#244668'),
                             ('heading', '#fedcba', '#654321'), ('activeSelection', '#fff099', '#123456')]:
            roles[role] = {'foreground': fg, 'background': bg, 'bold': False, 'dim': False}
        palette = [part for key, value in roles.items() for part in (key, value)]
        prefs.write_text(json.dumps({'version': 3, 'preset': 'custom', 'roles': palette, 'customRoles': palette,
                                    'savedPalettes': [], 'cursor': {'layout': 'native', 'shape': 'beam', 'color': 'default', 'blink': False}}))
        os.chmod(prefs, 0o600)
        with wire.server(str(args.native_binary.resolve()), root / 'store', root / 's') as client:
            def create(name, fields):
                return client.commit(wire.intent('create', str(uuid.uuid4()), class_id='Item',
                                                changes={'subject': wire.text(name), **fields}))['revision']
            category = create('Border root', {'selection': {'type': 'object', 'value': {
                'language': wire.text('tractanda.spotlight.v0'), 'expression': wire.text('itemID == *')}}})
            create('Border child', {'selection': {'type': 'object', 'value': {
                'language': wire.text('tractanda.spotlight.v0'), 'expression': wire.text('itemID == *')}},
                'categoryParents': {'type': 'list', 'value': [{'type': 'reference', 'value': {'itemID': wire.item_id(category)}}]}})
            create('Border sample', {'body': wire.text('Keep │ literal')})
            manifest = wire.manifest(root / 'store')
            def session(name, items=True):
                return tui.terminal(str(args.tui_binary.resolve()), root / 's', root / (name + '.json'),
                                    arguments=[str(root / 's'), '--appearance-file', str(prefs)], items_only=items)
            with session('settings') as ui:
                ui.wait('Border sample'); ui.send(ESC + b'[44;9u'); ui.wait('Settings / Appearance')
                for size in [(80, 25), (48, 12), (132, 35)]:
                    ui.resize(*size); ui.wait('F8 Save'); verify_frame(ui, f'appearance-{size}', snapshots)
                ui.resize(80, 25); ui.send(F5); ui.wait('Save appearance preset')
                ui.paste('Name │ literal'); ui.send(ESC + b'[97;9u')
                verify_frame(ui, 'preset-name-selected', snapshots, literal=True)
                ui.send(F9); ui.wait('Cursor layout'); ui.send(F9); ui.wait('Appearance changes canceled')
                checks.append('Appearance and nested name frames stay neutral across normal/compact/wide layouts; literal border glyphs remain selectable text')

            with session('items') as ui:
                ui.wait('Border sample'); ui.send(F2); ui.wait('Edit item'); ui.send(b'\t' + ESC + b'[97;9u')
                for size in [(80, 25), (48, 12), (132, 35)]:
                    ui.resize(*size); ui.wait('F8 Save'); verify_frame(ui, f'item-selection-{size}', snapshots, literal=True)
                ui.send(F9); ui.wait('Draft canceled'); ui.resize(80, 25)
                ui.send(b'n'); ui.wait('New item'); verify_frame(ui, 'new-item', snapshots); ui.send(F9); ui.wait('Draft canceled')
                ui.send(b'c'); ui.wait('Category manager'); ui.paste('Border root'); ui.wait('Find: Border root')
                ui.send(F2); ui.wait('Edit item'); verify_category_split(ui, snapshots)
                ui.send(ESC); ui.settle(); ui.wait('Category manager'); ui.send(F9); ui.wait('No expression filter')
                ui.send(F10); ui.wait('Command menu'); verify_frame(ui, 'command-menu', snapshots)
                ui.send(F10); ui.wait('No expression filter', absent='Close / cancel')
                line = ui.screen.splitlines()[1]; column = line.index('▾') + 1
                ui.send(f'\x1b[<0;{column};2M\x1b[<0;{column};2m'); ui.wait('Child categories')
                verify_frame(ui, 'breadcrumb-children', snapshots)
                checks.append('Item/new overlays and command/breadcrumb dropdowns retain neutral frames; the inline category inspector retains a neutral divider')

            with session('views', items=False) as ui:
                ui.wait('Views'); ui.send(b'\x0e'); ui.wait('View definition')
                ui.paste('View │ literal'); ui.send(ESC + b'[97;9u')
                verify_frame(ui, 'view-name-selected', snapshots, literal=True)
                ui.send(b'\t' * 4 + b'\r'); ui.wait('Ctrl-S Apply to form')
                for size in [(80, 25), (48, 12), (132, 35)]:
                    ui.resize(*size); ui.wait('Ctrl-S Apply to form'); verify_frame(ui, f'view-category-picker-{size}', snapshots)
                ui.send(ESC); ui.settle(); ui.wait('View definition', absent='Ctrl-S Apply to form'); ui.send(F9); ui.wait('View definition canceled')
                checks.append('View editor and nested category picker retain neutral borders and selected text styling at all tested sizes')
            assert wire.manifest(root / 'store') == manifest
    report = {'status': 'passed', 'checks': checks, 'snapshots': snapshots, 'canonicalStoreUnchanged': True}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'snapshots'}, indent=2))


if __name__ == '__main__': main()
