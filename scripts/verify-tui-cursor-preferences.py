#!/usr/bin/env python3
"""Check real cursor output, the preferences overlay and guarded class choices in owned PTYs."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import signal
import tempfile
import uuid

spec = importlib.util.spec_from_file_location('tui', Path(__file__).with_name('verify-tui.py'))
tui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tui)
wire, ESC = tui.wire, tui.ESC
RIGHT = ESC + b'[C'
F2, F8, F9 = ESC + b'[12~', ESC + b'[19~', ESC + b'[20~'


def preferences(ui):
    ui.send(ESC + b'[44;9u')  # Forwarded Command-comma remains a supported alias.
    ui.wait('Settings / Appearance')


def shot(ui, name, results):
    ui.settle()
    results.append({'name': name, 'columns': ui.width, 'rows': ui.height,
                    'screen': ui.screen, 'cursor': ui.cursor,
                    'ansiFrame': ui.raw.rsplit('\x1b[H', 1)[-1]})


def inversion_at_text(raw, text):
    """Interpret selection SGR independently of Swift's display-cell metadata."""
    characters, inverse, offset = [], False, 0
    for match in tui.CONTROL_SEQUENCE.finditer(raw):
        characters.extend((c, inverse) for c in raw[offset:match.start()])
        sgr = re.fullmatch(r'\x1b\[([0-9;]*)m', match[0])
        if sgr:
            for value in (int(v or 0) for v in sgr[1].split(';')):
                if value in (0, 27): inverse = False
                elif value == 7: inverse = True
        offset = match.end()
    characters.extend((c, inverse) for c in raw[offset:])
    content = ''.join(c for c, _ in characters)
    start = content.index(text)
    return [state for _, state in characters[start:start + len(text)]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('native_binary', type=Path)
    parser.add_argument('tui_binary', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    native, binary = str(args.native_binary.resolve()), str(args.tui_binary.resolve())
    checks, snapshots = [], []
    with tempfile.TemporaryDirectory(prefix='trac-cursor-', dir='/tmp') as directory:
        root = Path(directory)
        appearance, recovery = root / 'r.appearance.json', root / 'r.json'
        with wire.server(native, root / 'store', root / 's') as client:
            with tui.terminal(binary, root / 's', recovery) as ui:
                ui.wait('No items')
                preferences(ui)
                for marker in ['Cursor layout', 'Cursor shape', 'Active selection', 'F8 Save', 'F9 Cancel']:
                    assert marker in ui.screen, ui.screen
                assert not appearance.exists()
                shot(ui, 'default-appearance', snapshots)
                ui.send(RIGHT + b'\t' + RIGHT + b'\t' + RIGHT + b'\t\x15#33ccaa')
                ui.settle()
                ui.send(b'\t' + RIGHT)
                ui.settle()
                shot(ui, 'cursor-configured', snapshots)
                ui.send(F8); ui.wait('Appearance saved locally')
                settings = json.loads(appearance.read_text())
                assert settings['preset'] == 'amber', settings
                assert settings['cursor'] == {'layout': 'native', 'shape': 'block', 'color': '#33ccaa', 'blink': True}, settings
                assert appearance.stat().st_mode & 0o777 == 0o600
                assert ui.cursor['shape'] == 1 and ui.cursor['color'] == '#33ccaa', ui.cursor
                saved = appearance.read_bytes()
                preferences(ui); ui.send(RIGHT); ui.settle(); ui.send(F9)
                ui.wait('Appearance changes canceled')
                assert appearance.read_bytes() == saved
                assert ui.cursor['shape'] == 1 and ui.cursor['color'] == '#33ccaa'
                assert not client.call('TractandaItem/query')['ids']
                checks.append('Table preferences, live preview, independent cursor options, Save/Cancel, private settings and zero canonical writes')

                # Standard cursor moves without a redraw or shifted glyphs. The content
                # includes a double-width CJK glyph, combining accent and emoji.
                ui.send(b'n'); ui.wait('New item'); ui.paste('Stationary cursor')
                ui.send(b'\t'); ui.paste('A文e\u0301🙂Z'); ui.send(b'\x01'); ui.settle()
                original_line = next(line for line in ui.screen.splitlines() if 'A文e\u0301🙂Z' in line)
                position = ui.cursor
                assert position['visible'], position
                for step in [1, 2, 1, 2, 1]:
                    ui.send(RIGHT); ui.settle()
                    current = ui.cursor
                    assert current['row'] == position['row'] and current['column'] == position['column'] + step, (position, current)
                    assert original_line in ui.screen
                    position = current
                shot(ui, 'standard-unicode-editor', snapshots)
                ui.send(b'\x01' + RIGHT + ESC + b'[1;2C'); ui.settle()
                raw = ui.raw.rsplit('\x1b[H', 1)[-1]
                assert inversion_at_text(raw, 'A文e\u0301🙂Z') == [False, True, False, False, False, False], ui.screen
                assert original_line in ui.screen
                shot(ui, 'exact-wide-character-selection', snapshots)
                ui.send(b'\x05'); ui.settle()
                ui.send(b'\x7f'); ui.paste('!'); ui.send(F8); ui.wait('Saved one revision')
                note = tui.wait_item(client, 'subject == "Stationary cursor"', ui)
                assert note['fields']['body'] == wire.text('A文e\u0301🙂!')
                checks.append('Stationary Standard text, exact selected wide-glyph cells, native cursor-only movement across CJK/combining/emoji, conventional insertion and Backspace')

                # Ctrl-U/paste on a class choice must not become arbitrary retyping.
                ui.send(F2); ui.wait('Edit item'); ui.send(b'\t\t\x15'); ui.paste('org.example.Injected')
                ui.settle(); assert 'org.example.Injected' not in ui.screen
                ui.send(RIGHT); ui.settle(); assert 'staged' in ui.screen
                first = next(line for line in ui.screen.splitlines() if 'Class:' in line)
                ui.send(RIGHT); ui.settle()
                second = next(line for line in ui.screen.splitlines() if 'Class:' in line)
                assert first != second, (first, second)
                ui.send(F9); ui.wait('Draft canceled')
                assert wire.revision_id(client.get(wire.item_id(note))) == wire.revision_id(note)
                # Item's next supported class is LegalPersonItem; an empty legal person is valid.
                ui.send(F2); ui.wait('Edit item'); ui.send(b'\t\t' + RIGHT); ui.settle()
                ui.send(F8); ui.wait('Saved one revision')
                changed = client.get(wire.item_id(note))
                assert changed['fields']['classID'] == wire.text('LegalPersonItem'), changed
                assert changed['fields']['body'] == note['fields']['body']
                assert client.call('TractandaItem/history', {'itemID': wire.item_id(note)})['total'] == 2
                checks.append('Class rejects arbitrary buffer edits, cycles staged choices, cancels without revision and retypes with stable identity and history')

                preferences(ui)
                ui.send(b'\t' * 6 + b'\x15#112233\t\x15#445566')
                ui.settle(); ui.send(F8); ui.wait('Appearance saved locally')
                settings = json.loads(appearance.read_text())
                roles = settings['roles']
                # Swift non-string dictionary keys encode as alternating key/value.
                if isinstance(roles, list): roles = dict(zip(roles[::2], roles[1::2]))
                assert roles['activeSelection']['foreground'] == '#112233'
                assert roles['activeSelection']['background'] == '#445566'
                assert settings['cursor']['color'] == '#33ccaa'
                preferences(ui); ui.resize(48, 12); ui.send(b'\t' * 25); ui.settle()
                assert 'Passive pane' in ui.screen and 'F8 Save' in ui.screen and 'F9 Cancel' in ui.screen
                shot(ui, 'compact-appearance', snapshots)
                ui.send(F9); ui.wait('Appearance changes canceled')
                ui.close()
                assert '\x1b[0 q' in ui.raw and '\x1b]112' in ui.raw
                checks.append('Independent RGB foreground/background, cursor retention, compact scrolling with fixed Save/Cancel and fallback restoration')

            # Successful query responses restore the exact preexisting style/color.
            replies = {'\x1bP$q q\x1b\\': '\x1bP1$r3 q\x1b\\',
                       '\x1b]12;?\x07': '\x1b]12;rgb:aaaa/bbbb/cccc\x07'}
            with tui.terminal(binary, root / 's', root / 'reply.json', terminal_replies=replies) as ui:
                ui.wait('Stationary cursor'); ui.send(b'n'); ui.wait('New item')
                ui.paste('Literal │ data'); ui.settle()
                assert 'Literal │ data' in ui.screen
                # Fragmented/late replies are terminal data, never editor content.
                for part in [b'\x1b]12;rgb:1234/', b'5678/9abc', b'\x07', b'\x1bP1$r', b'4 q\x1b\\']:
                    ui.send(part); ui.settle(0.08)
                ui.send(F8); ui.wait('Saved one revision')
                literal = tui.wait_item(client, 'subject == "Literal │ data"', ui)
                assert literal['fields']['subject'] == wire.text('Literal │ data')
                ui.close(signal.SIGTERM)
                assert '\x1b[3 q' in ui.raw and '\x1b]12;rgb:aaaa/bbbb/cccc' in ui.raw
                assert len(ui.answered_queries) == 2
                checks.append('Bounded terminal queries, exact original restore on signal, literal caret glyphs and delayed/fragmented replies excluded from item text')

            future = client.commit(wire.intent('create', str(uuid.uuid4()), class_id='org.example.FutureItem', changes={
                'subject': wire.text('Unknown class fixture'), 'opaque': wire.text('preserve me')}))['revision']
            with tui.terminal(binary, root / 's', root / 'unknown.json') as ui:
                ui.wait('Unknown class fixture'); ui.send(F2); ui.wait('Edit item')
                ui.paste(' edited'); ui.send(F8); ui.wait('Saved one revision')
                updated = client.get(wire.item_id(future))
                assert updated['fields']['classID'] == wire.text('org.example.FutureItem')
                assert updated['fields']['opaque'] == wire.text('preserve me')
                checks.append('Editing an existing unknown class preserves its identifier and opaque metadata')

            invalid = client.commit(wire.intent('create', str(uuid.uuid4()), class_id='Item', changes={
                'subject': wire.text('Retype validation fixture'), 'holdings': wire.text('opaque note value')}))['revision']
            with tui.terminal(binary, root / 's', root / 'validation.json') as ui:
                ui.wait('Retype validation fixture'); ui.send(F2); ui.wait('Edit item')
                ui.send(b'\t\t' + RIGHT * 4); ui.settle()
                assert 'RoleItem' in ui.screen and 'staged' in ui.screen
                ui.send(F8); ui.wait('invalidRole')
                assert 'Edit item' in ui.screen
                assert wire.revision_id(client.get(wire.item_id(invalid))) == wire.revision_id(invalid)
                ui.send(F9); ui.wait('Draft canceled')
                checks.append('A class-specific validation failure preserves the draft and original canonical revision')

    report = {'status': 'passed', 'platform': platform.platform(), 'checks': checks, 'snapshots': snapshots}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'snapshots'}, indent=2))


if __name__ == '__main__':
    main()
