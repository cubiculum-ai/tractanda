#!/usr/bin/env python3
"""Verify arrow-navigated TUI menus and optional F11/F12 with real disposable terminals."""
import argparse
import importlib.util
import json
import platform
import subprocess
import tempfile
import time
from pathlib import Path

spec = importlib.util.spec_from_file_location('tui', Path(__file__).with_name('verify-tui.py'))
tui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tui)
wire, ESC = tui.wire, tui.ESC
F10, F11, F12 = ESC+b'[21~', ESC+b'[23~', ESC+b'[24~'
UP, DOWN, LEFT, RIGHT, END = [ESC+key for key in (b'[A', b'[B', b'[D', b'[C', b'[F')]
MENU_BAR_ROW = 1


def wait_closed(ui, text):
    ui.wait(text, absent='Command menu')


def click(ui, column, row):
    ui.send(f"\x1b[<0;{column};{row}M\x1b[<0;{column};{row}m")


def menu_hit(ui, text):
    lines = ui.screen.splitlines()
    if len(lines) <= MENU_BAR_ROW:
        raise AssertionError((text, ui.screen))
    row_text = lines[MENU_BAR_ROW]
    start = row_text.find(text)
    if start < 0:
        raise AssertionError((text, ui.screen))
    return start + 1, MENU_BAR_ROW + 1


def open_menu(ui, name):
    ui.send(F10); ui.wait('Command menu')
    column, row = menu_hit(ui, name)
    click(ui, column, row)
    ui.settle()
    ui.wait("─" + name + "─")


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('native_binary',type=Path)
    parser.add_argument('tui_binary',type=Path)
    parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    native,binary=str(args.native_binary.resolve()),str(args.tui_binary.resolve())
    checks,snapshots=[],[]
    help_text=subprocess.check_output([binary,'--help'],text=True)
    assert '--function-keys auto|10|12' in help_text
    invalid=subprocess.run([binary,'--function-keys','11'],capture_output=True,text=True)
    assert invalid.returncode != 0
    with tempfile.TemporaryDirectory(prefix='trac-menus-',dir='/tmp') as directory:
        root=Path(directory); path=root/'s'
        with wire.server(native,root/'store',path) as client:
            with tui.terminal(binary,path,root/'recovery/pending.json',arguments=[str(path),'--function-keys','12']) as ui:
                ui.wait('No items')
                assert '11Prev' in ui.screen.splitlines()[-1] and '12Ref' in ui.screen.splitlines()[-1]
                open_menu(ui,'File')
                assert '>  New item' in ui.screen
                ui.send(b'\r');wait_closed(ui,'Body / note')
                ui.paste('Menu café 文');ui.send(b'\t');ui.paste('A menu draft with 👩🏽‍💻 and intact Unicode.')
                ui.wait('intact Unicode.')
                open_menu(ui,'Edit')
                for width,height in [(48,12),(80,25),(132,40)]:
                    ui.resize(width,height);ui.wait('Command menu')
                    assert 'Edit' in ui.screen.splitlines()[1], (width, height, ui.screen)
                    assert '>  Undo text edit' in ui.screen
                    assert len(ui.screen.splitlines()[-1]) == width-1
                    snapshots.append({'name':'edit-menu','columns':width,'rows':height,'screen':ui.screen,'ansiFrame':ui.raw.rsplit('\x1b[H',1)[-1]})
                ui.send(b'\r');wait_closed(ui,'Body / note') # Undo.
                open_menu(ui,'Edit');ui.wait('>  Redo text edit')
                ui.send(b'\r');wait_closed(ui,'intact Unicode.')
                open_menu(ui,'File');ui.send(b'\r');wait_closed(ui,'Saved one revision')
                item=tui.wait_item(client,'subject == "Menu café 文"',ui)
                identity=wire.item_id(item)
                assert item['fields']['body'] == wire.text('A menu draft with 👩🏽‍💻 and intact Unicode.')
                assert len(wire.manifest(root/'store')) == 1
                checks.append('Arrow-driven File/New, Edit/Undo/Redo and File/Save preserve one canonical edit and Unicode across menu resizing')

                open_menu(ui,'View');ui.send(END);ui.wait('>✓ Function keys: 12')
                ui.send(UP);ui.wait('>  Function keys: 10');ui.send(b'\r');wait_closed(ui,'10Menu')
                assert '11Preview' not in ui.screen.splitlines()[-1]
                ui.resize(160,40);ui.wait('10Menu');assert '11Preview' not in ui.screen.splitlines()[-1]
                open_menu(ui,'View');ui.send(END+UP+UP);ui.wait('>  Function keys: Automatic');ui.send(b'\r')
                wait_closed(ui,'11Preview');assert '12Refresh' in ui.screen.splitlines()[-1]
                ui.resize(80,25);ui.wait('10Menu');assert '11Preview' not in ui.screen.splitlines()[-1]
                checks.append('CLI and View menu select Auto/10/12 without data writes; Auto responds to terminal width')

                ui.send('f');ui.wait('Filter items');ui.paste('subject == "missing"');ui.send(b'\x13');ui.wait('0 items')
                had_preview = any(line.lstrip().startswith("Preview") for line in ui.screen.splitlines()[:-2])
                ui.send(F11); ui.settle(); ui.wait('0 items')
                assert any(line.lstrip().startswith("Preview") for line in ui.screen.splitlines()[:-2]) != had_preview
                revised=client.commit(wire.intent('revise','menu-external-edit',item=identity,base=wire.revision_id(item),changes={'subject':wire.text('Refreshed through F12')}))['revision']
                ui.send('a');ui.wait('All readable items');ui.send(F12);ui.wait('Refreshed through F12')
                assert client.get(identity) == revised
                checks.append('F11 toggles preview and F12 refreshes using existing read-only commands, even with a ten-key display')

                open_menu(ui,'Item');ui.send(END);ui.wait('>  Delete items');ui.send(b'\r');wait_closed(ui,'Type delete')
                assert client.get(identity) == revised
                ui.send(ESC);ui.wait('Draft canceled');assert client.get(identity) == revised
                open_menu(ui,'Help');ui.resize(48,12);ui.wait('Command menu')
                assert 'Help' in ui.screen.splitlines()[1] and '‹' in ui.screen.splitlines()[1]
                snapshots.append({'name':'narrow-help-menu','columns':48,'rows':12,'screen':ui.screen,'ansiFrame':ui.raw.rsplit('\x1b[H',1)[-1]})
                ui.send(F10);wait_closed(ui,'A All');ui.resize(132,40)
                assert client.get(identity) == revised
                checks.append('Menu deletion still requires explicit confirmation; cancel and narrow horizontal menu scrolling preserve data')
                ui.close()
    result={'status':'passed','platform':platform.platform(),'checks':checks,'snapshots':snapshots}
    if args.output:
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k!='snapshots'},ensure_ascii=False))


if __name__=='__main__': main()
