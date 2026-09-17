#!/usr/bin/env python3
"""Verify native category/template/time behavior, PTY navigation, and canonical-only transfers."""
import argparse
import importlib.util
import json
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import uuid

spec = importlib.util.spec_from_file_location('tui', Path(__file__).with_name('verify-tui.py'))
tui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tui)
wire = tui.wire
PROJECT = Path(__file__).resolve().parents[1]


def snapshot(client, ids):
    queries = {
        'phone': {'categoryPath': [ids['means'], ids['means.phone']]},
        'means': {'categoryPath': [ids['means']]},
        'shortCalls': {'viewID': ids['phone-20-minutes']},
        'today': {'categoryPath': [ids['when.deadlines.today']]},
        'tomorrow': {'categoryPath': [ids['when.deadlines.tomorrow']]},
    }
    result = {name: client.call('TractandaItem/query', dict(args, at='2026-09-09T12:00:00Z'))['ids']
              for name, args in queries.items()}
    result['heads'] = {key: wire.revision_id(client.get(identity)) for key, identity in ids.items()}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('--tui', type=Path)
    parser.add_argument('--import-from', dest='source', type=Path)
    parser.add_argument('--export', type=Path)
    parser.add_argument('--append-revision', action='store_true')
    args = parser.parse_args()
    native = str(args.binary.resolve())
    checks = []
    with tempfile.TemporaryDirectory(prefix='trac-categories-', dir='/tmp') as temporary:
        root = Path(temporary)
        store, socket = root / 'store', root / 's'
        if args.source:
            store.mkdir(mode=0o700)
            metadata = json.loads((args.source / 'snapshot.json').read_text())
            ids = metadata['ids']
            shutil.copytree(args.source / 'items', store / 'items')
            assert wire.manifest(store) == metadata['manifest']
        else:
            subprocess.run([native, 'init', str(store)], check=True, capture_output=True)
        with wire.server(native, store, socket) as client:
            if not args.source:
                # Exercise the shipped CLI as well as the server template operation.
                response = subprocess.check_output([native, 'install-categories', str(socket),
                    str(PROJECT / 'templates/starter-categories.json'), 'Europe/Vienna'])
                ids = json.loads(response)['items']
                assert 'item' not in ids and len(ids) == 71
                for key in ['who','what','when','where','means','priority','urgency']:
                    assert client.get(ids[key])['fields']['categoryParents']['value'] == []
                def create(key, fields):
                    result = client.commit(wire.intent('create', str(uuid.uuid4()), class_id='Item', changes=fields))
                    ids[key] = wire.item_id(result['revision'])
                create('call-note', {'subject': wire.text('Talk to Pat about chess')})
                create('site-note', {'subject': wire.text('Talk to Alex about an inspection'), 'location': wire.text('building')})
                create('due-note', {'subject': wire.text('Deadline fixture'), 'dueAt': {'type': 'date', 'value': '2026-09-10T00:00:00Z'}})
                result = snapshot(client, ids)
                assert result['phone'] == result['shortCalls'] == [ids['call-note']]
                assert result['today'] == [] and result['tomorrow'] == [ids['due-note']]
                assert ids['call-note'] in result['means']
                checks.append('CLI installs optional items; native ancestors, permissive Phone and clock windows agree')
            else:
                assert snapshot(client, ids) == metadata['snapshot']
                checks.append('canonical-only transfer preserves IDs, heads, inheritance, saved view and timezone-sensitive results')
            before = wire.manifest(store)
            result = snapshot(client, ids)
            client.call('TractandaStore/rebuild', {})
            assert snapshot(client, ids) == result and wire.manifest(store) == before
            midnight = client.call('TractandaItem/query', {'categoryPath': [ids['when.deadlines.today']], 'at': '2026-09-10T00:00:00Z'})
            assert midnight['ids'] == [ids['due-note']]
            assert wire.manifest(store) == before
            checks.append('index rebuild and clock advance preserve canonical bytes')
            if args.tui:
                with tui.terminal(str(args.tui.resolve()), socket, root / 'recovery.json') as ui:
                    ui.wait('All items')
                    ui.send(tui.ESC+b'[1;9B'); ui.wait('Top-level─categories')
                    assert 'Who' in ui.screen and 'Means' in ui.screen
                    ui.send(tui.ESC); ui.wait('A All',absent='Child categories')
                    ui.send('c'); ui.wait('Category manager')
                    ui.paste('Phone'); ui.wait('Find: Phone')
                    ui.resize(54, 15); assert 'Phone' in ui.screen
                    ui.resize(120, 35)
                    ui.send(b'\r'); ui.wait('Means ▾ / Phone')
                    assert 'Item ▾ /' not in ui.screen
                    assert 'All items /' not in ui.screen
                    ui.wait('Talk to Pat about chess')
                    assert 'Talk to Alex about an inspection' not in ui.screen
                    ui.send(tui.ESC + b'[20~'); ui.wait('Views workspace')
                    assert '[Views]' in ui.screen and 'Categories' in ui.screen
                    ui.send(b'\t'); ui.wait('All items')
                    assert '[Views]' in ui.screen
                    ui.send('a'); ui.wait('All readable items')
                    ui.send('v'); ui.wait('Open saved view'); ui.paste('Phone · 20 minutes')
                    ui.send(b'\r'); ui.wait('Talk to Pat about chess')
                    ui.close()
                checks.append('actual terminal tree search, cumulative path, resizing and saved Phone view')
            if args.append_revision:
                note = client.get(ids['call-note'])
                client.commit(wire.intent('revise', str(uuid.uuid4()), item=wire.item_id(note),
                    base=wire.revision_id(note), changes={'body': wire.text('Portable category fixture revision')}))
                checks.append('new platform revision appended without rewriting earlier files')
            exported = {'ids': ids, 'snapshot': snapshot(client, ids), 'manifest': wire.manifest(store)}
        if args.export:
            args.export.mkdir(parents=True, exist_ok=False)
            shutil.copytree(store / 'items', args.export / 'items')
            (args.export / 'snapshot.json').write_text(json.dumps(exported, indent=2) + '\n')
    print(json.dumps({'status': 'passed', 'platform': platform.platform(), 'checks': checks}, indent=2))


if __name__ == '__main__':
    main()
