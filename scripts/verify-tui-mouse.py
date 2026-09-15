#!/usr/bin/env python3
"""Exercise terminal mouse input through real PTYs and disposable native stores."""
import argparse
import importlib.util
import json
import platform
import signal
import subprocess
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location('tui', Path(__file__).with_name('verify-tui.py'))
tui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tui)
wire, ESC = tui.wire, tui.ESC
MODES = '9;1000;1001;1002;1003;1005;1006;1015;1016'


def report(code, x, y, release=False):
    return ESC + f'[<{code};{x+1};{y+1}{"m" if release else "M"}'.encode()


def click(ui, x, y):
    ui.send(report(0,x,y) + report(0,x,y,True))


def find(ui, label, row=None):
    for index, line in enumerate(ui.screen.splitlines()):
        if (row is None or row == index) and label in line:
            # All test targets have an ASCII prefix, so index equals terminal cells here.
            return line.index(label), index
    raise AssertionError((label, ui.screen))


def click_text(ui, label, row=None):
    x,y = find(ui,label,row)
    click(ui,x+1,y)


def create(client, name, fields=None):
    return client.commit(wire.intent('create','seed-'+name,class_id='NoteItem',
        changes={'subject':wire.text(name), **(fields or {})}))['revision']


def check_cleanup(ui):
    assert '\x1b[?1006h' in ui.raw and '\x1b[?1002h' in ui.raw
    assert '\x1b[?'+MODES+'s' in ui.raw
    assert '\x1b[?'+MODES+'l\x1b[?'+MODES+'r' in ui.raw
    assert ui.raw.rfind('\x1b[?'+MODES+'r') < ui.raw.rfind('\x1b[?1049l')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('native_binary',type=Path)
    parser.add_argument('tui_binary',type=Path)
    parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    native,binary=str(args.native_binary.resolve()),str(args.tui_binary.resolve())
    assert '--mouse on|off' in subprocess.check_output([binary,'--help'],text=True)
    assert subprocess.run([binary,'--mouse','invalid'],capture_output=True).returncode != 0
    checks,snapshots=[],[]
    with tempfile.TemporaryDirectory(prefix='trac-mouse-',dir='/tmp') as directory:
        root=Path(directory)
        with wire.server(native,root/'store',root/'s') as client:
            with tui.terminal(binary,root/'s',root/'recovery/pending.json') as ui:
                ui.wait('No items')
                click_text(ui,'10Menu',ui.height-1);ui.wait('Command menu')
                click_text(ui,'New item');ui.wait('New item',absent='Command menu')
                ui.paste('Initial subject');ui.wait('Initial subject')
                click_text(ui,'Body / note:',row=None);ui.wait('New item · Body / note')
                ui.paste('café 文 👩🏽‍💻\nsecond line');ui.wait('second line')
                # Place the caret, wait for its display marker, then drag over the displayed word.
                row,line=next((i,line) for i,line in enumerate(ui.screen.splitlines()) if 'café' in line)
                start=line.index('café')
                ui.send(report(0,start,row));ui.settle();ui.wait(' café')
                ui.send(report(32,start+5,row)+report(0,start+5,row,True));ui.settle();ui.wait('café');assert '⟦' not in ui.screen
                ui.send(b'\x03')
                click_text(ui,'Subject:',row=None);ui.wait('New item · Subject')
                ui.send(ESC+b'[97;9u'+b'\x16');ui.wait('café ')
                click_text(ui,'Ctrl-S/F8 Save');ui.wait('Saved one revision')
                item=tui.wait_item(client,'subject == "café"',ui)
                assert item['fields']['body']==wire.text('café 文 👩🏽‍💻\nsecond line')
                assert len(wire.manifest(root/'store'))==1
                checks.append('Mouse function bar/menu capture, Unicode caret/drag selection and clicked Save produce one whole edit')

                for index in range(45): create(client,f'Mouse item {index:02d}')
                ui.send('r');ui.wait('Refreshed')
                baseline=wire.manifest(root/'store')
                # Scroll the selection using cell-based wheel reports and retain the row under a click.
                ui.send(report(65,15,7)*9);ui.read(0.1)
                ui.wait('A All')
                before=ui.screen.splitlines()[7]
                click(ui,14,7);ui.read(0.1);ui.wait('A All')
                assert ui.screen.splitlines()[7].lstrip('> ')==before.lstrip('> ')
                click(ui,14,7);ui.wait('Item / immutable revision')
                ui.send(ESC);ui.wait('A All',absent='Item / immutable revision')
                snapshots.append({'name':'mouse-browser','columns':ui.width,'rows':ui.height,'screen':ui.screen})
                assert wire.manifest(root/'store')==baseline
                # A resize between button down/up must not activate the relocated key bar.
                x,y=find(ui,'10Menu',ui.height-1)
                ui.send(report(0,x+1,y));ui.resize(132,40);ui.send(report(0,x+1,y,True))
                ui.read(0.1);ui.wait('A All')
                assert 'Command menu' not in ui.screen
                checks.append('Wheel navigation and stable double-click reading are read-only; resize cancels an in-flight click')

                rule={'type':'object','value':{'language':wire.text('tractanda.spotlight.v0'),'expression':wire.text('subject == "none"')}}
                parent=create(client,'Mouse Parent',{'selection':rule})
                create(client,'Mouse Child',{'selection':rule,'categoryParents':{'type':'list','value':[
                    {'type':'reference','value':{'itemID':wire.item_id(parent)}}]}})
                ui.send('c');ui.wait('Mouse Child')
                _,parent_row=find(ui,'Mouse Parent')
                click(ui,3,parent_row);ui.read(0.1);ui.wait('Category manager')
                assert 'Mouse Child' not in ui.screen
                click(ui,3,parent_row);ui.wait('Mouse Child')
                click_text(ui,'Mouse Child');ui.read(0.1);ui.wait('Mouse Child')
                click_text(ui,'Mouse Child');ui.wait('Category manager');ui.send(ESC+b'\r');ui.wait('Added category filter')
                assert 'Mouse Parent ▾ / Mouse Child' in ui.screen
                click_text(ui,'A All',ui.height-2);ui.wait('All readable items')
                checks.append('Category disclosure clicks, double-click path opening and the all-items footer use existing navigation semantics')

                hover_baseline=wire.manifest(root/'store')
                click_text(ui,'10Menu',ui.height-1);ui.wait('Command menu')
                assert ui.raw.rfind('\x1b[?1003h') > ui.raw.rfind('\x1b[?1002h')
                x,y=find(ui,'View',1);ui.send(report(35,x+1,y));ui.wait('─View─')
                x,y=find(ui,'Mouse: Off');ui.send(report(35,x+1,y));ui.wait('>  Mouse: Off')
                assert 'Command menu' in ui.screen and wire.manifest(root/'store')==hover_baseline
                x,y=find(ui,'File',1);ui.send(report(35,x+1,y));ui.wait('─File─')
                x,y=find(ui,'Save view as');ui.send(report(35,x+1,y));ui.wait('>  Save view as')
                ui.send(b'\r');ui.wait('View name',absent='Command menu')
                assert ui.raw.rfind('\x1b[?1002h') > ui.raw.rfind('\x1b[?1003h')
                ui.send(ESC);ui.wait('Draft canceled')
                assert wire.manifest(root/'store')==hover_baseline
                checks.append('Free pointer motion switches menu names and highlights commands without execution; Enter acts on the hovered command and closes hover reporting')

                ui.resize(48,12)
                ui.send(ESC+b'[21~'+(ESC+b'[C')*2+ESC+b'[F');ui.wait('>  Function keys: 12')
                x,y=find(ui,'Function keys: Automatic')
                ui.send(report(35,x+1,y));ui.wait('>✓ Function keys: Automatic')
                assert find(ui,'Function keys: Automatic')[1]==y
                x,y=find(ui,'Function keys: 10')
                ui.send(ESC+b'[M'+bytes([67,x+34,y+33]));ui.wait('>  Function keys: 10')
                snapshots.append({'name':'narrow-hover-menu','columns':48,'rows':12,'screen':ui.screen})
                ui.send(ESC+b'[21~');ui.wait('A All',absent='Command menu')
                ui.resize(132,40);ui.wait('12Refresh')
                assert wire.manifest(root/'store')==hover_baseline
                checks.append('SGR and legacy hover keep a scrolled narrow dropdown stable and do not change the function-key preference')

                click_text(ui,'10Menu',ui.height-1);ui.wait('Command menu')
                click_text(ui,'View',1);ui.wait('─View─')
                click_text(ui,'Mouse: Off');ui.wait('10Menu',absent='Command menu')
                assert ui.raw.count('\x1b[?'+MODES+'l')>=2
                click_text(ui,'10Menu',ui.height-1);ui.read(0.15)
                assert 'Command menu' not in ui.screen
                # Turn reporting on by keyboard, then exercise raw-byte legacy reports.
                ui.send(ESC+b'[21~'+(ESC+b'[C')*2);ui.wait('─View─')
                ui.send(ESC+b'[F'+(ESC+b'[A')*4+b'\r');ui.wait('10Menu',absent='Command menu')
                x,y=find(ui,'10Menu',ui.height-1)
                ui.send(ESC+b'[M'+bytes([32,x+34,y+33])+ESC+b'[M'+bytes([35,x+34,y+33]))
                ui.wait('Command menu')
                click(ui,120,15);ui.wait('10Menu',absent='Command menu')
                checks.append('Mouse can be disabled/re-enabled without changing keys; legacy reports work and outside clicks dismiss overlays')
                ui.close();check_cleanup(ui)

            with tui.terminal(binary,root/'s',root/'off/pending.json',arguments=[str(root/'s'),'--mouse','off']) as ui:
                ui.wait('All items')
                assert '\x1b[?1006h' not in ui.raw
                click_text(ui,'10Menu',ui.height-1);ui.read(0.1)
                assert 'Command menu' not in ui.screen
                ui.close()
            with tui.terminal(binary,root/'s',root/'signal/pending.json') as ui:
                ui.wait('All items');ui.close(signal.SIGTERM);check_cleanup(ui)
            checks.append('CLI mouse-off is inert; normal and signal exits restore terminal modes and request prior mouse-mode restoration')

            proxy=tui.LostResponseProxy(root/'proxy',root/'s')
            recovery=root/'lost/pending.json'
            try:
                with tui.terminal(binary,proxy.path,recovery) as ui:
                    ui.wait('All items');ui.send('n');ui.wait('New item');ui.paste('Mouse retry once');ui.wait('Mouse retry once')
                    click_text(ui,'Ctrl-S/F8 Save');ui.wait('Unconfirmed edit')
                    frozen=json.loads(recovery.read_text())['request']
                    item=tui.wait_item(client,'subject == "Mouse retry once"',ui)
                    click_text(ui,'Ctrl-S/F8 Save');ui.read(0.1)
                    assert json.loads(recovery.read_text())['request']==frozen
                    ui.close();check_cleanup(ui)
                with tui.terminal(binary,proxy.path,recovery) as ui:
                    ui.wait('Recovered unconfirmed edit');ui.send('r');ui.wait('Recovered saved edit')
                    assert not recovery.exists()
                    assert len(client.call('TractandaItem/history',{'itemID':wire.item_id(item)})['list'])==1
                    ui.close();check_cleanup(ui)
                checks.append('A mouse-triggered save retains exact recovery; repeated clicks while unconfirmed cannot send another write')
            finally: proxy.close()
    result={'status':'passed','platform':platform.platform(),'checks':checks,'snapshots':snapshots}
    if args.output:
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k!='snapshots'},ensure_ascii=False))


if __name__=='__main__': main()
