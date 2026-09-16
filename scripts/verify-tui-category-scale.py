#!/usr/bin/env python3
"""Exercise a dense category DAG in the real TUI, using an isolated store and owned PTY."""
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('native_binary', type=Path)
    parser.add_argument('tui_binary', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    checks, snapshots = [], []
    with tempfile.TemporaryDirectory(prefix='trac-tree-scale-', dir='/tmp') as directory:
        root = Path(directory)
        with wire.server(str(args.native_binary.resolve()), root / 'store', root / 's') as client:
            def create(name, parents=None):
                fields = {'subject': wire.text(name)}
                if parents is not None:
                    fields['selection'] = {'type': 'object', 'value': {
                        'language': wire.text('tractanda.spotlight.v0'),
                        'expression': wire.text('isAction == true'),
                    }}
                    fields['categoryParents'] = {'type': 'list', 'value': [
                        {'type': 'reference', 'value': {'itemID': wire.item_id(parent)}} for parent in parents
                    ]}
                else:
                    fields['isAction'] = {'type': 'boolean', 'value': True}
                return client.commit(wire.intent('create', 'seed-' + name, class_id='Item', changes=fields))['revision']

            start = create('Category root', [])
            parents, categories = [start], [start]
            for level in range(1, 32):
                pair = [create(f'Layer {level:02d} {suffix}', parents) for suffix in ['A', 'B']]
                categories += pair
                parents = pair
            action = create('Only matching action')
            before = wire.manifest(root / 'store')
            state = client.call('TractandaItem/query', {'limit': 256})['queryState']
            with tui.terminal(str(args.tui_binary.resolve()), root / 's', root / 'pending.json') as ui:
                ui.wait('All items')
                ui.resize(132, 30)
                began = time.monotonic()
                ui.send('c')
                ui.wait('Layer 01 B')
                opening_seconds = time.monotonic() - began
                assert 'Layer 02' not in ui.screen and 'too many placements' not in ui.screen
                snapshots.append({'name': 'dense-graph-initial', 'screen': ui.screen})
                checks.append('63-category graph with 2^32-1 possible placements opens with closed descendants')

                # All items is initially selected. Step through the root to the first child.
                ui.send(ESC + b'[B' + ESC + b'[B' + ESC + b'[C')
                ui.wait('Layer 02 B')
                assert 'Layer 03' not in ui.screen
                # Close only this placement, then search all unique nodes and jump to the last.
                ui.send(ESC + b'[D')
                ui.wait('Layer 01 B', absent='Layer 02')
                ui.paste('Layer')
                ui.wait('Find: Layer')
                ui.send(ESC + b'[F')
                # The representative tree is depth-first: its final sibling is Layer 01 B.
                ui.wait(' >   ▸ Layer 01 B')
                ui.send(b'\x15')
                ui.paste('Layer 31 B')
                ui.wait('Find: Layer 31 B')
                ui.wait('Layer 31 B')
                assert sum('Layer 31 B' in line and 'Find:' not in line for line in ui.screen.splitlines()) == 1
                for width, height in [(100, 20), (132, 30), (80, 25)]:
                    ui.resize(width, height)
                    ui.wait('Layer 31 B')
                ui.resize(132, 30)
                snapshots.append({'name': 'deep-search-last-row', 'screen': ui.screen})
                checks.append('Search reaches deep closed descendants once per category; End and resizing retain selection')

                # Meta-Return explicitly applies the Categories path in Views.
                ui.send(b'\x1b\r')
                ui.wait('Added category filter')
                ui.wait('Only matching action')
                assert client.call('TractandaItem/query', {'categoryPath': [wire.item_id(categories[-1])]})['ids'] == [wire.item_id(action)]
                # Meta-Return opened the explicit Views report.  F9 returns to
                # retained Categories before replacing its Find text.
                ui.send(ESC + b'[20~')
                ui.wait('Category manager')
                ui.send(b'\x15')
                ui.paste('Layer 15 A')
                ui.wait('Find: Layer 15 A')
                ui.send(ESC + b'[C')
                ui.wait('Layer 16 A', absent='Find: Layer 15 A')
                ui.send(b'\x1b\r')
                ui.wait('Added category filter')
                ui.wait('Only matching action')
                checks.append('Opening a search result uses a valid native path; Right reveals a searched branch without losing its selection')
                ui.close()
            assert wire.manifest(root / 'store') == before
            assert client.call('TractandaItem/query', {'limit': 256})['queryState'] == state
            assert not (root / 'pending.json').exists()
            checks.append('Browsing/searching leaves all canonical files, query state and recovery state unchanged; terminal restored')
    report = {
        'status': 'passed', 'platform': platform.platform(), 'checks': checks,
        'categoryCount': len(categories), 'possiblePlacements': 2**32 - 1,
        'openingSeconds': opening_seconds,
        'measurementScope': 'One isolated 63-category run, including native discovery and rendering; not a large-store query benchmark.',
        'snapshots': snapshots,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'snapshots'}, ensure_ascii=False))


if __name__ == '__main__':
    main()
