#!/usr/bin/env python3
"""Exercise view-selection history through the actual TUI and native server in an owned PTY."""
import argparse
import importlib.util
import json
from pathlib import Path
import platform
import tempfile
import time

spec = importlib.util.spec_from_file_location('tui', Path(__file__).with_name('verify-tui.py'))
tui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tui)
wire, ESC = tui.wire, tui.ESC


def tagged(kind, value):
    return {'type': kind, 'value': value}


def command(character):
    return ESC + f'[{ord(character)};9u'.encode()


def choose(ui, key, name, heading):
    ui.send(key)
    ui.wait(heading)
    ui.send(b'\x15')
    ui.paste(name)
    ui.wait('Find: ' + name)
    # Only Categories use Meta-Return to apply the selected path in Views.
    # Leave ordinary picker/assignment Enter behavior untouched.
    ui.send(ESC + b'\r' if heading == 'Category manager' else b'\r')


def selected(ui, name):
    deadline = time.monotonic() + 10
    while not (ui.is_frame_complete and any(
            name in line and (
                line.lstrip().startswith('>')
                or ('│' in line and line.partition('│')[2].lstrip().startswith('>'))
            ) for line in ui.screen.splitlines())):
        ui.read()
        assert ui.process.poll() is None and time.monotonic() < deadline, (name, ui.screen)


def click(ui, x, y):
    ui.send(ESC + f'[<0;{x+1};{y+1}M'.encode() + ESC + f'[<0;{x+1};{y+1}m'.encode())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('native_binary', type=Path)
    parser.add_argument('tui_binary', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    checks, snapshots = [], []
    with tempfile.TemporaryDirectory(prefix='trac-history-', dir='/tmp') as directory:
        root = Path(directory)
        with wire.server(str(args.native_binary.resolve()), root / 'store', root / 's') as client:
            def create(name, fields, kind='Item'):
                return client.commit(wire.intent('create', 'seed-' + name, class_id=kind,
                    changes={'subject': wire.text(name), **fields}))['revision']
            def category(name, rule):
                return create(name, {'selection': tagged('object', {
                    'language': wire.text('tractanda.spotlight.v0'), 'expression': wire.text(rule)})})
            category('Group A', 'rank < 10')
            category('Group B', 'rank >= 10')
            for rank in range(70):
                create(f'Rank item {rank:02d}', {'rank': tagged('integer', rank), 'body': wire.text(f'Body {rank:02d}')})
            create('Numbered view', {'viewDefinition': tagged('object', {
                'language': wire.text('tractanda.spotlight.v0'), 'expression': wire.text('rank >= 0'),
                'sort': tagged('list', [tagged('object', {'property': wire.text('rank'), 'isAscending': tagged('boolean', True)})])
            })}, 'Item')
            before = wire.manifest(root / 'store')
            state = client.call('TractandaItem/query', {'limit': 256})['queryState']
            proxy = tui.LostResponseProxy(root / 'proxy', root / 's', drop_method='TractandaStore/info')
            proxy.drop_commit = False
            try:
                with tui.terminal(str(args.tui_binary.resolve()), root / 'proxy', root / 'pending.json') as ui:
                    ui.wait('All items')
                    ui.resize(132, 30)
                    choose(ui, 'v', 'Numbered view', 'Open saved view')
                    ui.wait('Rank item 00')
                    ui.send(ESC + b'[F\r')
                    ui.wait('Rank item 69', absent='Rank item 00')
                    ui.send(ESC + b'[H' + ESC + b'[B' + ESC + b'[B')
                    selected(ui, 'Rank item 65')
                    choose(ui, 'c', 'Group A', 'Category manager')
                    ui.wait('Rank item 00', absent='Rank item 65')
                    ui.send(ESC + b'[19;3~')  # Previous-view shortcut.
                    ui.wait('Returned to earlier view')
                    selected(ui, 'Rank item 65')
                    for width, height in [(80, 25), (48, 12), (132, 30)]:
                        ui.resize(width, height)
                        selected(ui, 'Rank item 65')
                    snapshots.append({'name': 'restored-second-page', 'screen': ui.screen})
                    checks.append('Alt-F8 restores a saved view, its second page and selected item across terminal resizing')

                    ui.send(command(']'))
                    ui.wait('Returned to later view')
                    ui.wait('Rank item 00', absent='Rank item 65')
                    ui.send(command('['))
                    ui.wait('Returned to earlier view')
                    selected(ui, 'Rank item 65')
                    ui.send('a')
                    ui.wait('All readable items')
                    ui.send(ESC + b'[1;3D')
                    ui.wait('Returned to earlier view')
                    selected(ui, 'Rank item 65')
                    choose(ui, 'c', 'Group B', 'Category manager')
                    ui.wait('Rank item 10', absent='Rank item 00')
                    ui.send(ESC + b'[1;3C')
                    ui.wait('No later view.')
                    checks.append('Forwarded Command brackets and Meta arrows navigate; a new route clears Forward and All items remains reversible')

                    # View menu uses the same command, including a real mouse click on Back.
                    ui.send(ESC + b'[21~')
                    ui.wait('Command menu')
                    # Select the fixed global View group by its visible label,
                    # rather than relying on its former ordinal position.
                    x, y = next((line.index('View'), row) for row, line in enumerate(ui.screen.splitlines())
                                if 'File' in line and 'Edit' in line and 'View' in line)
                    click(ui, x, y)
                    ui.wait('Back')
                    targets = [(line.index('Back'), row) for row, line in enumerate(ui.screen.splitlines()) if ' Back ' in line and 'Meta-F8' in line]
                    assert len(targets) == 1, ui.screen
                    click(ui, *targets[0])
                    ui.wait('Returned to earlier view', absent='Command menu')
                    selected(ui, 'Rank item 65')
                    checks.append('Mouse-selecting View/Back invokes the same read-only navigation command')

                    choose(ui, 'c', 'Group A', 'Category manager')
                    ui.wait('Rank item 00', absent='Rank item 65')
                    proxy.drop_commit = True
                    ui.send(ESC + b'[1;3D')
                    ui.wait('No items.')
                    assert not proxy.drop_commit
                    assert not (root / 'pending.json').exists()
                    ui.send(ESC + b'[1;3D')
                    ui.wait('Returned to earlier view')
                    selected(ui, 'Rank item 65')
                    checks.append('A lost navigation read clears cached rows without consuming the Back entry or creating a mutation journal; retry restores the target')
                    ui.close()
            finally:
                proxy.close()
            assert wire.manifest(root / 'store') == before
            assert client.call('TractandaItem/query', {'limit': 256})['queryState'] == state
            checks.append('All navigation leaves canonical revisions/query state unchanged and restores terminal modes on exit')
    report = {'status': 'passed', 'platform': platform.platform(), 'checks': checks, 'snapshots': snapshots}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'snapshots'}, ensure_ascii=False))


if __name__ == '__main__':
    main()
