#!/usr/bin/env python3
"""Category presentation preferences through a real owned terminal and isolated store."""
import argparse, importlib.util, json, os, platform, tempfile
from pathlib import Path
spec=importlib.util.spec_from_file_location('tui',Path(__file__).with_name('verify-tui.py'));tui=importlib.util.module_from_spec(spec);spec.loader.exec_module(tui)
wire,ESC=tui.wire,tui.ESC
F2,F8,F9,F10=[ESC+f'[{n}~'.encode() for n in [12,19,20,21]]
def tagged(kind,value):return {'type':kind,'value':value}
def click(ui,x,y):ui.send(f'\x1b[<0;{x};{y}M\x1b[<0;{x};{y}m');ui.settle()
def open_preferences(ui):
 ui.send(F10);ui.wait('Command menu');bar=ui.screen.splitlines()[1];click(ui,bar.index('Tractanda')+1,2)
 ui.wait('Settings / Categories');row,line=next((i+1,s) for i,s in enumerate(ui.screen.splitlines()) if 'Settings / Categories' in s)
 click(ui,line.index('Settings / Categories')+1,row);ui.wait('Settings / Categories');ui.settle()
def find(ui,name):
 row,line=next((i+1,s) for i,s in enumerate(ui.screen.splitlines()) if 'Find:' in s);click(ui,line.index('Find:')+7,row)
 ui.send(b'\x15');ui.paste(name);ui.settle()
def picture(ui,name,record,path):
 ui.settle();record['snapshots'].append({'name':name,'columns':ui.width,'rows':ui.height,'screen':ui.screen,'ansiFrame':ui.raw.rsplit('\x1b[H',1)[-1]});path.write_text(json.dumps(record,indent=2)+'\n')
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('native_binary',type=Path);p.add_argument('tui_binary',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args();a.output.parent.mkdir(parents=True,exist_ok=True)
 record={'status':'inProgress','platform':platform.platform(),'checks':[],'snapshots':[]};checks=record['checks']
 with tempfile.TemporaryDirectory(prefix='trac-category-prefs-',dir='/tmp') as tmp:
  root=Path(tmp);r=root/'r.json';views=root/'r.views.json';appearance=root/'r.appearance.json'
  with wire.server(str(a.native_binary.resolve()),root/'store',root/'s') as client:
   def create(name,extra=None):return client.commit(wire.intent('create','seed-'+name,class_id='NoteItem',changes={'subject':wire.text(name),**(extra or {})}))['revision']
   rule=tagged('object',{'language':wire.text('tractanda.spotlight.v0'),'expression':wire.text('itemID == ""')})
   parent=create('Presentation root',{'selection':rule,'body':wire.text('Category description')})
   create('Presentation child',{'selection':rule,'categoryParents':tagged('list',[tagged('reference',{'itemID':wire.item_id(parent)})])})
   create('Known content',{'body':wire.text('Keep this body')})
   baseline=wire.manifest(root/'store')
   def session():return tui.terminal(str(a.tui_binary.resolve()),root/'s',r,items_only=False)
   with session() as ui:
    ui.wait('Views');open_preferences(ui);ui.wait('Outline');ui.paste('invalid choice');ui.settle();assert 'invalid choice' not in ui.screen
    for size in [(80,24),(48,12),(132,35)]:
     ui.resize(*size);ui.wait('Settings / Categories');assert 'F8' in ui.screen and 'F9' in ui.screen
     assert any(c in ui.screen for c in ['╭','┌']),ui.screen
     picture(ui,'category-preferences',record,a.output)
    ui.send(ESC+b'[C');ui.wait('Connected tree');ui.send(F9);ui.settle()
    assert not views.exists() and not appearance.exists()
    ui.send(F9);ui.wait('Category manager');assert 'Outline' in ui.screen
    checks.append('Preferences opens from Views as a normal/compact modal; Cancel writes no file and retains Outline')
    open_preferences(ui);ui.send(ESC+b'[C');ui.wait('Connected tree');ui.send(F8);ui.settle()
    assert 'Settings / Categories' not in ui.screen
    assert 'Connected tree' in ui.screen and ('└─' in ui.screen or '├─' in ui.screen),ui.screen
    prefs=json.loads(views.read_text());assert prefs['categoryConnectedTree'] is True and views.stat().st_mode&0o777==0o600
    assert not appearance.exists()
    checks.append('Save updates the active connected-tree renderer and private view preference without an appearance or canonical write')
    ui.send(b'\x14');ui.settle();assert 'Outline' in ui.screen
    assert json.loads(views.read_text())['categoryConnectedTree'] is False
    open_preferences(ui);ui.wait('Outline');ui.send(ESC+b'[C');ui.send(F8);ui.settle()
    checks.append('Existing Ctrl-T and the preferences choice read/write the same presentation setting')
    find(ui,'Presentation root');ui.send(F2);ui.wait('Edit item');ui.paste(' draft')
    before=views.read_bytes();open_preferences(ui);ui.send(ESC+b'[D');ui.send(F9);ui.settle()
    assert 'Presentation root draft' in ui.screen and views.read_bytes()==before
    open_preferences(ui);ui.send(ESC+b'[D');ui.send(F8);ui.settle()
    assert 'Presentation root draft' in ui.screen and json.loads(views.read_text())['categoryConnectedTree'] is False
    ui.send(ESC);ui.settle();assert client.get(wire.item_id(parent))==parent
    checks.append('Save and Cancel restore an existing inline category draft without publishing it')
    ui.send(F9);ui.wait('[Views]');ui.send(b'\t');ui.settle();ui.send(b'\x0e');ui.wait('New item');ui.paste('Unsubmitted item draft')
    open_preferences(ui);ui.send(ESC+b'[C');ui.send(F8);ui.wait('New item')
    assert 'Unsubmitted item draft' in ui.screen
    ui.send(F9);ui.wait('Draft canceled');assert wire.manifest(root/'store')==baseline
    checks.append('Global preferences preserve an underlying modal item draft and its later cancellation')
    old=views.read_bytes();open_preferences(ui);os.chmod(views,0o644)
    ui.send(ESC+b'[D');ui.send(F8);ui.settle()
    assert 'Settings / Categories' in ui.screen and views.read_bytes()==old,ui.screen
    os.chmod(views,0o600);ui.send(F9);ui.settle()
    assert json.loads(views.read_text())['categoryConnectedTree'] is True
    checks.append('A rejected preference save retains the dialog and existing bytes; Cancel recovers the prior setting')
   with session() as ui:
    ui.wait('Views');ui.resize(132,35);ui.send(F9);ui.wait('Category manager');assert 'Connected tree' in ui.screen,ui.screen
    open_preferences(ui);ui.wait('Connected tree');ui.send(F9);ui.settle()
    assert wire.manifest(root/'store')==baseline and not r.exists() and not appearance.exists()
    checks.append('Restart restores the preference and all navigation leaves canonical data and appearance untouched')
 record['status']='passed';a.output.write_text(json.dumps(record,indent=2)+'\n');print(json.dumps({k:v for k,v in record.items() if k!='snapshots'},indent=2))
if __name__=='__main__':main()
