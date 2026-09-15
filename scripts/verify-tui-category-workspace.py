#!/usr/bin/env python3
"""Verify category previews and inline editing using isolated data and an owned PTY.

The forwarding fixture delays/reorders native replies without touching the real service.
It records query bounds as well as what the user sees; no GUI app is controlled.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import platform
import socket
import struct
import tempfile
import threading
import time

spec = importlib.util.spec_from_file_location('tui', Path(__file__).with_name('verify-tui.py'))
tui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tui)
wire, ESC = tui.wire, tui.ESC
F2, F5, F6, F8, F9 = [ESC + f'[{n}~'.encode() for n in (12, 15, 17, 19, 20)]
F11, F12 = ESC + b'[23~', ESC + b'[24~'
snapshot_path = None


def tagged(kind, value):
    return {'type': kind, 'value': value}


def click(ui, x, y):
    ui.send(f'\x1b[<0;{x};{y}M\x1b[<0;{x};{y}m')


def click_text(ui, text, *, last=False):
    candidates = [(line.index(text) + 1, row + 1)
                  for row, line in enumerate(ui.screen.splitlines()) if text in line]
    assert candidates, (text, ui.screen)
    click(ui, *(candidates[-1] if last else candidates[0]))
    ui.settle()


def snapshot(ui, name, snapshots):
    ui.settle()
    snapshots.append({'name': name, 'columns': ui.width, 'rows': ui.height,
                      'screen': ui.screen, 'ansiFrame': ui.raw.rsplit('\x1b[H', 1)[-1]})
    if snapshot_path:
        snapshot_path.parent.mkdir(parents=True, exist_ok=True)
        snapshot_path.write_text(json.dumps({'status': 'inProgress', 'snapshots': snapshots}, ensure_ascii=False) + '\n')


def find_category(ui, name):
    row, line = next((row + 1, line) for row, line in enumerate(ui.screen.splitlines()) if 'Find:' in line)
    click(ui, line.index('Find:') + 7, row)
    ui.settle()
    ui.send(b'\x15')
    if name:
        ui.paste(name)
    ui.wait('Find: ' + name)
    ui.settle()


def select_all_items(ui):
    candidates = [(line.index('All items') + 1, row + 1)
                  for row, line in enumerate(ui.screen.splitlines())
                  if 'All items' in line.split('│', 1)[0] and row > 1]
    assert candidates, ui.screen
    click(ui, *candidates[0])
    ui.settle()


class ReplyProxy:
    """Concurrent forwarding with one-shot controlled delay/drop of a category query."""
    def __init__(self, path, target):
        self.path, self.target = path, target
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(path))
        self.listener.listen(16)
        self.listener.settimeout(0.1)
        os.chmod(path, 0o600)
        self.lock = threading.Lock()
        self.calls, self.errors, self.children = [], [], []
        self.delay_path, self.drop_path = None, None
        self.delayed = threading.Event()
        self.release = threading.Event()
        self.stopping = False
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        while not self.stopping:
            try:
                connection, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                if self.stopping:
                    return
                raise
            worker = threading.Thread(target=self.forward, args=(connection,), daemon=True)
            self.children.append(worker)
            worker.start()

    def forward(self, connection):
        try:
            with connection:
                connection.settimeout(10)
                length = struct.unpack('!I', wire.read_exact(connection, 4))[0]
                request = json.loads(wire.read_exact(connection, length))
                delay, drop = False, False
                with self.lock:
                    for method, args, _ in request['methodCalls']:
                        self.calls.append({'method': method, 'arguments': args})
                        if method == 'TractandaItem/query' and 'categoryPath' in args:
                            if self.delay_path is not None and args['categoryPath'] == self.delay_path:
                                delay, self.delay_path = True, None
                            if self.drop_path is not None and args['categoryPath'] == self.drop_path:
                                drop, self.drop_path = True, None
                response = wire.wire(self.target, request)
                if delay:
                    self.delayed.set()
                    assert self.release.wait(8), 'Test did not release the delayed category reply'
                if not drop:
                    data = json.dumps(response).encode()
                    try:
                        connection.sendall(struct.pack('!I', len(data)) + data)
                    except (BrokenPipeError, ConnectionResetError):
                        pass  # A canceled read is an allowed client response.
        except Exception as error:
            if not self.stopping:
                self.errors.append(repr(error))

    def close(self):
        self.stopping = True
        self.release.set()
        self.thread.join(2)
        self.listener.close()
        for child in self.children:
            child.join(12)
            assert not child.is_alive(), 'Forwarding worker did not finish'
        self.path.unlink()
        assert not self.errors, self.errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('native_binary', type=Path)
    parser.add_argument('tui_binary', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--skip-read', action='store_true', help='Run editing/presentation checks independently while debugging')
    args = parser.parse_args()
    global snapshot_path
    snapshot_path = args.output.with_suffix('.progress.json')
    checks, snapshots = [], []
    with tempfile.TemporaryDirectory(prefix='trac-category-workspace-', dir='/tmp') as directory:
        root = Path(directory)
        with wire.server(str(args.native_binary.resolve()), root / 'store', root / 's') as client:
            def create(name, fields=None):
                return client.commit(wire.intent('create', 'seed-' + name, class_id='NoteItem',
                    changes={'subject': wire.text(name), **(fields or {})}))['revision']

            def category(name, expression, parents=()):
                return create(name, {
                    'selection': tagged('object', {'language': wire.text('tractanda.spotlight.v0'),
                                                  'expression': wire.text(expression)}),
                    'categoryParents': tagged('list', [tagged('reference', {'itemID': wire.item_id(p)}) for p in parents]),
                    'body': wire.text('Category notes'),
                    'opaque': tagged('object', {'retained': wire.text('unknown field survives')}),
                })

            alpha = category('Alpha', 'bucket == "alpha"')
            beta = category('Beta', 'bucket == "beta"')
            shared = category('Shared', 'bucket == "shared"', (alpha, beta))
            batch = category('Batch', 'bucket == "batch"')
            create('AlphaOnly', {'bucket': wire.text('alpha')})
            create('BetaOnly', {'bucket': wire.text('beta')})
            create('SharedBoth', {'bucket': wire.text('shared')})
            create('ExceptAlpha', {'bucket': wire.text('shared'),
                'categoryOverrides': tagged('object', {wire.item_id(alpha): wire.text('exclude')})})
            for n in range(70):
                create(f'Batch {n:02d}', {'bucket': wire.text('batch'), 'rank': tagged('integer', n)})
            before = wire.manifest(root / 'store')
            if not args.skip_read:
                proxy = ReplyProxy(root / 'proxy', root / 's')
                try:
                    with tui.terminal(str(args.tui_binary.resolve()), root / 'proxy', root / 'pending.json') as ui:
                        ui.wait('All items')
                        ui.resize(132, 35)
                        ui.send('c'); ui.wait('Category manager')
                        ui.wait('Batch 69')
                        snapshot(ui, 'initial-items-preview', snapshots)
                        assert 'All items' in ui.screen
                        checks.append('Category workspace starts on implicit All items and loads the first native page')

                        find_category(ui, 'Alpha')
                        ui.wait('AlphaOnly')
                        assert 'SharedBoth' in ui.screen and 'ExceptAlpha' not in ui.screen
                        expected = client.call('TractandaItem/query', {'categoryPath': [wire.item_id(alpha)]})['ids']
                        assert len(expected) == 2, expected
                        find_category(ui, 'Beta')
                        ui.wait('BetaOnly')
                        assert 'ExceptAlpha' in ui.screen and 'SharedBoth' in ui.screen
                        snapshot(ui, 'category-membership-preview', snapshots)
                        checks.append('Preview follows native inherited membership and manual exclusion without accumulating visited filters')

                        find_category(ui, '')
                        ui.wait('Batch 69')
                        placements = [(line.index('Shared') + 1, row + 1)
                                      for row, line in enumerate(ui.screen.splitlines())
                                      if 'Shared' in line.split('│', 1)[0]]
                        assert len(placements) == 2, ui.screen
                        click(ui, *placements[-1]); ui.wait('ExceptAlpha')
                        assert 'BetaOnly' not in ui.screen
                        click(ui, *placements[0]); ui.wait('SharedBoth', absent='ExceptAlpha')
                        assert 'AlphaOnly' not in ui.screen
                        checks.append('The same child under different parents previews the selected ancestry, including ancestor-specific exclusions')

                        ui.send(ESC); ui.settle(); ui.wait('All items', absent='Category manager')
                        assert 'Batch 69' in ui.screen
                        ui.send('c'); ui.wait('Category manager')
                        find_category(ui, 'Alpha'); ui.wait('AlphaOnly'); ui.send(ESC + b'\r')
                        ui.wait('AlphaOnly', absent='Category manager')
                        assert 'Batch 69' not in ui.screen
                        ui.send('c'); ui.wait('Category manager'); ui.wait('AlphaOnly')
                        snapshot(ui, 'reopened-current-ancestry', snapshots)
                        find_category(ui, 'Beta'); ui.wait('BetaOnly')
                        ui.send(ESC); ui.settle(); ui.wait('AlphaOnly', absent='Category manager')
                        assert 'BetaOnly' not in ui.screen
                        checks.append('Escape returns to the retained Views report, Meta-Return applies one path, and reopening retains Categories ancestry')

                        ui.send('c'); ui.wait('Category manager')
                        find_category(ui, 'Batch'); ui.wait('Batch 69')
                        ui.send(b'\t'); ui.settle()
                        ui.send(ESC + b'[6~'); ui.wait('Batch 00')
                        assert 'Batch 69' not in ui.screen
                        snapshot(ui, 'second-preview-page', snapshots)
                        ui.send(ESC + b'[5~'); ui.wait('Batch 69')
                        checks.append('Preview has independently navigable 64-item pages with newest-first default order')

                        for size in ((80, 25), (48, 12), (132, 35)):
                            ui.resize(*size); ui.wait('Category manager')
                            snapshot(ui, 'preview-resize', snapshots)
                        ui.send(b'\t'); ui.settle()
                        find_category(ui, 'Beta'); ui.wait('BetaOnly')
                        # Hold an obsolete Alpha response and move to Beta while it is in flight.
                        proxy.delay_path = [wire.item_id(alpha)]
                        find_category(ui, 'Alpha')
                        deadline = time.monotonic() + 5
                        while not proxy.delayed.is_set():
                            ui.read(.03)
                            assert time.monotonic() < deadline, ui.screen
                        find_category(ui, 'Beta')
                        assert 'Find: Beta' in ui.screen
                        proxy.release.set()
                        ui.wait('BetaOnly'); ui.settle(.4)
                        assert 'AlphaOnly' not in ui.screen
                        checks.append('A delayed obsolete query keeps keyboard input responsive and cannot replace newer preview results')

                        proxy.drop_path = [wire.item_id(alpha)]
                        find_category(ui, 'Alpha')
                        ui.wait('Preview failed')
                        assert 'BetaOnly' not in ui.screen and not (root / 'pending.json').exists()
                        find_category(ui, 'Beta'); ui.wait('BetaOnly')
                        checks.append('Failed preview clears stale rows, permits a later query, and creates no mutation journal')

                        proxy.delayed.clear(); proxy.release.clear()
                        proxy.delay_path = [wire.item_id(beta)]
                        find_category(ui, 'Beta')
                        deadline = time.monotonic() + 5
                        while not proxy.delayed.is_set():
                            ui.read(.03)
                            assert time.monotonic() < deadline, ui.screen
                        ui.send(ESC); ui.settle(); ui.wait('AlphaOnly', absent='Category manager')
                        ui.send('c'); ui.wait('Category manager'); find_category(ui, 'Alpha')
                        proxy.release.set()
                        ui.wait('AlphaOnly'); ui.settle(.4)
                        assert 'BetaOnly' not in ui.screen
                        checks.append('A reply from a closed category workspace cannot replace the restored ancestry after reopening')
                        ui.send(ESC); ui.settle(); ui.close()
                    assert wire.manifest(root / 'store') == before
                    bounded = [row['arguments'] for row in proxy.calls
                               if row['method'] == 'TractandaItem/query' and 'categoryPath' in row['arguments']]
                    assert bounded and all(row.get('limit', 0) <= 64 for row in bounded), bounded
                    assert any(row.get('position') == 64 for row in bounded), bounded
                    checks.append('All read-only navigation preserves canonical files and every preview request stays within a 64-item page')
                finally:
                    proxy.close()

            # Independent write verification: exact item identity and unknown fields survive.
            with tui.terminal(str(args.tui_binary.resolve()), root / 's', root / 'edit.json') as ui:
                ui.wait('All items'); ui.resize(132, 35)
                ui.send('c'); ui.wait('Category manager'); find_category(ui, 'Alpha')
                ui.send(F2); ui.wait('Edit item')
                ui.paste(' revised'); ui.send(F8); ui.wait('Saved one revision')
                revised = tui.wait_item(client, 'subject == "Alpha revised"', ui)
                assert wire.item_id(revised) == wire.item_id(alpha)
                assert revised['fields']['classID'] == alpha['fields']['classID']
                assert revised['fields']['opaque'] == alpha['fields']['opaque']
                assert client.call('TractandaItem/history', {'itemID': wire.item_id(alpha)})['total'] == 2
                snapshot(ui, 'inline-saved-category', snapshots)
                checks.append('Inline category Save produces one guarded revision with stable identity, class and unknown fields')
                ui.send(F2); ui.wait('Edit item'); ui.paste(' canceled'); ui.send(ESC)
                ui.settle()
                assert client.call('TractandaItem/history', {'itemID': wire.item_id(alpha)})['total'] == 2
                checks.append('Canceling inline changes produces no new revision')

                ui.send(F2); ui.wait('Edit item'); ui.paste(' unsaved')
                select_all_items(ui); ui.wait('Unsaved category draft')
                snapshot(ui, 'dirty-navigation-guard', snapshots)
                ui.send(b'\r'); ui.settle(); ui.wait('unsaved', absent='Unsaved category draft')
                select_all_items(ui); ui.wait('Unsaved category draft')
                ui.send(F9); ui.settle()
                assert client.call('TractandaItem/history', {'itemID': wire.item_id(alpha)})['total'] == 2
                assert 'unsaved' not in ui.screen
                checks.append('Dirty category navigation offers Stay by default and Discard without changing canonical history')

                find_category(ui, 'Alpha revised'); ui.send(F2); ui.wait('Edit item')
                ui.paste(' saved'); select_all_items(ui); ui.wait('Unsaved category draft')
                ui.send(F8); ui.wait('Saved one revision')
                saved = tui.wait_item(client, 'subject == "Alpha revised saved"', ui)
                assert wire.item_id(saved) == wire.item_id(alpha)
                assert client.call('TractandaItem/history', {'itemID': wire.item_id(alpha)})['total'] == 3
                checks.append('Save from the navigation guard records one revision before performing the requested navigation')

                find_category(ui, 'Alpha revised saved'); ui.send(F2); ui.wait('Edit item')
                ui.paste(' from TUI')
                external = client.commit(wire.intent('revise', 'outside-editor', wire.item_id(saved),
                    wire.revision_id(saved), changes={'body': wire.text('Concurrent change')}))['revision']
                ui.send(F8); ui.wait('Draft retained')
                assert 'from TUI' in ui.screen
                assert wire.revision_id(client.get(wire.item_id(alpha))) == wire.revision_id(external)
                assert not (root / 'edit.json').exists()
                ui.send(ESC); ui.settle()
                checks.append('Concurrent revision conflict retains the inline draft and leaves the newer server revision untouched')

            # Drop a committed response to check that the inline inspector preserves exact retry.
            loss = tui.LostResponseProxy(root / 'lost', root / 's')
            try:
                with tui.terminal(str(args.tui_binary.resolve()), root / 'lost', root / 'lost.json') as ui:
                    ui.wait('All items'); ui.resize(132, 35)
                    ui.send('c'); ui.wait('Category manager'); find_category(ui, 'Beta')
                    ui.send(F2); ui.wait('Edit item'); ui.paste(' recovered'); ui.send(F8)
                    ui.wait('Unconfirmed edit')
                    assert (root / 'lost.json').exists()
                    ui.send(b'r'); ui.wait('Recovered saved edit')
                    recovered = tui.wait_item(client, 'subject == "Beta recovered"', ui)
                    assert wire.item_id(recovered) == wire.item_id(beta)
                    assert client.call('TractandaItem/history', {'itemID': wire.item_id(beta)})['total'] == 2
                    assert not (root / 'lost.json').exists()
                    checks.append('Lost inline-save response is retried exactly once without duplicate revisions or a lost draft journal')
            finally:
                loss.close()

            # Presentation choices are private, survive restart and never revise categories.
            presentation_before = wire.manifest(root / 'store')
            presentation_journal = root / 'presentation.json'
            with tui.terminal(str(args.tui_binary.resolve()), root / 's', presentation_journal) as ui:
                ui.wait('All items'); ui.resize(132, 35)
                ui.send('c'); ui.wait('Category manager')
                ui.send(b'\x14'); ui.settle()  # Ctrl-T toggles Outline / Connected tree.
                assert '└─' in ui.screen or '├─' in ui.screen, ui.screen
                snapshot(ui, 'connected-tree', snapshots)
                row, line = next((r + 1, line) for r, line in enumerate(ui.screen.splitlines()) if 'Find:' in line)
                divider = line.index('│') + 1
                moved = divider + 9
                ui.send(f'\x1b[<0;{divider};{row}M\x1b[<32;{moved};{row}M\x1b[<0;{moved};{row}m')
                ui.settle()
                _, changed = next((r + 1, line) for r, line in enumerate(ui.screen.splitlines()) if 'Find:' in line)
                assert changed.index('│') + 1 > divider, ui.screen
                resized_divider = changed.index('│')
                snapshot(ui, 'resized-divider', snapshots)
                find_category(ui, 'Beta recovered'); ui.send(F2); ui.wait('Edit item')
                assert ui.cursor['visible'] and ui.cursor['column'] > resized_divider
                ui.send(ESC + b'[21~'); ui.wait('Command menu')
                click_text(ui, 'Category')
                ui.wait('Category workspace: Items')
                click_text(ui, 'Category workspace: Items')
                ui.wait('Items ·', absent='Edit item / Category')
                find_category(ui, 'Beta recovered'); ui.send(F2); ui.wait('Edit item / Category')
                click_text(ui, 'Maximize'); ui.settle(); snapshot(ui, 'maximized-category', snapshots)
                assert all('│' not in line for line in ui.screen.splitlines()[2:-2]), ui.screen
                click_text(ui, 'Split'); ui.settle()
                ui.send(F9); ui.settle(); ui.close()
            preferences = presentation_journal.with_suffix('.views.json')
            saved_preferences = json.loads(preferences.read_text())
            assert saved_preferences['categoryConnectedTree']
            assert saved_preferences['categoryRightMode'] == 'category'
            assert preferences.stat().st_mode & 0o777 == 0o600
            with tui.terminal(str(args.tui_binary.resolve()), root / 's', presentation_journal) as ui:
                ui.wait('All items'); ui.resize(132, 35)
                ui.send('c'); ui.wait('Category manager'); ui.settle()
                assert '└─' in ui.screen or '├─' in ui.screen, ui.screen
                row = next(line for line in ui.screen.splitlines() if 'Find:' in line)
                assert row.index('│') == resized_divider, ui.screen
                ui.send(F2); ui.settle()
                assert 'All items' in ui.screen and 'Class:' not in ui.screen
                snapshot(ui, 'implicit-root-inspector', snapshots)
            assert wire.manifest(root / 'store') == presentation_before
            checks.append('Connected-tree mode and dragged width persist privately; maximize restores the split and All items remains read-only')

    report = {'status': 'passed', 'platform': platform.platform(), 'checks': checks, 'snapshots': snapshots}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'snapshots'}, indent=2))


if __name__ == '__main__':
    main()
