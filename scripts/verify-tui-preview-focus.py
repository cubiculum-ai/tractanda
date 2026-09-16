#!/usr/bin/env python3
"""Independent PTY acceptance for preview resizing, repeated field traversal and Fn applicability."""
import argparse, importlib.util, json, os, platform, re, tempfile, time
from pathlib import Path
spec=importlib.util.spec_from_file_location('tui',Path(__file__).with_name('verify-tui.py'))
tui=importlib.util.module_from_spec(spec);spec.loader.exec_module(tui)
wire,ESC=tui.wire,tui.ESC
F2,F8,F9,F10,F11,F12=[ESC+f'[{n}~'.encode() for n in [12,19,20,21,23,24]]
SHIFT_F2=ESC+b'[12;2~'; BACKTAB=ESC+b'[Z'
def val(kind,value):return {'type':kind,'value':value}
def click(ui,x,y):ui.send(f'\x1b[<0;{x};{y}M\x1b[<0;{x};{y}m');ui.settle()
def find(ui,name):
 ui.settle();row,line=next((i+1,line) for i,line in enumerate(ui.screen.splitlines()) if 'Find:' in line)
 click(ui,line.index('Find:')+7,row);ui.send(b'\x15');ui.paste(name);ui.settle()
def preview_row(ui):
 return next(i for i,line in enumerate(ui.screen.splitlines()[:-2]) if line.lstrip().startswith('Preview'))
def preview_height(ui):return ui.height-preview_row(ui)-3
def snapshot(ui,name,report,path):
 ui.settle();report['snapshots'].append({'name':name,'columns':ui.width,'rows':ui.height,'screen':ui.screen,'ansiFrame':ui.raw.rsplit('\x1b[H',1)[-1]})
 path.write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
def field(ui,label):
 deadline=time.monotonic()+8
 while True:
  ui.settle(.06);c=ui.cursor;lines=ui.screen.splitlines()
  if ui.is_frame_complete and c['visible'] and len(lines)>=c['row'] and label in lines[c['row']-1]:return
  assert time.monotonic()<deadline,(label,c,ui.screen)
def slots(ui):
 line=ui.screen.splitlines()[-1];matches=list(re.finditer(r'1[012]|[1-9]',line))
 assert [int(m[0]) for m in matches]==list(range(1,len(matches)+1)),line
 return {int(m[0]):line[m.end():(matches[n+1].start() if n+1<len(matches) else len(line))].strip() for n,m in enumerate(matches)}
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('native_binary',type=Path);p.add_argument('tui_binary',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
 a.output.parent.mkdir(parents=True,exist_ok=True)
 result={'status':'inProgress','platform':platform.platform(),'checks':[],'snapshots':[]};checks=result['checks']
 with tempfile.TemporaryDirectory(prefix='trac-preview-focus-',dir='/tmp') as temp:
  root=Path(temp);recovery=root/'pending.json';preferences=root/'pending.views.json'
  with wire.server(str(a.native_binary.resolve()),root/'store',root/'s') as client:
   def create(name,fields):return client.commit(wire.intent('create','seed-'+name,class_id='Item',changes={'subject':wire.text(name),**fields}))['revision']
   category=create('Alpha',{'body':wire.text('Initial category body'),'selection':val('object',{'language':wire.text('tractanda.spotlight.v0'),'expression':wire.text('bucket == "alpha"')}),'opaque':val('object',{'retain':wire.text('yes')})})
   create('Empty',{'selection':val('object',{'language':wire.text('tractanda.spotlight.v0'),'expression':wire.text('bucket == "empty"')})})
   view=create('Review',{'viewDefinition':val('object',{'language':wire.text('tractanda.spotlight.v0'),'expression':wire.text('bucket == "alpha"')})})
   for n in range(35):create(f'Other {n:02d}',{'bucket':wire.text('alpha'),'body':wire.text(f'OTHER {n:02d}')})
   note=create('Selected item',{'bucket':wire.text('alpha'),'body':wire.text('\n'.join(f'BODY {i:02d}' for i in range(80)))})
   initial=wire.manifest(root/'store')
   def session():return tui.terminal(str(a.tui_binary.resolve()),root/'s',recovery,items_only=False)
   with session() as ui:
    ui.wait('Views');ui.resize(132,48);ui.settle()
    bars=slots(ui)
    assert bars[1] and bars[10]
    assert all(not bars[n] for n in [2,3,4,5,6,7]),bars
    ui.send(F2);ui.settle();assert 'View definition ·' not in ui.screen
    checks.append('Implicit All items has blank inapplicable function slots while Help/Menu remain usable; F2 cannot open an editor')
    find(ui,'Review');ui.send(b'\x05');ui.wait('View definition ·');ui.settle();assert slots(ui)[3],slots(ui)
    ui.send(F9);ui.wait('View definition canceled')
    checks.append('F3 Save As remains advertised when a view definition is editable')
    ui.send(b'\r');ui.wait('BODY 00');ui.resize(80,24);ui.settle()
    assert preview_height(ui)==3,ui.screen
    ui.resize(132,48);ui.settle();assert preview_height(ui)==3
    ui.send(ESC+b'=');ui.settle();assert preview_height(ui)==4
    ui.send(ESC+b'-');ui.settle();assert preview_height(ui)==3
    y=preview_row(ui)+1;target=y-9
    ui.send(f'\x1b[<0;8;{y}M\x1b[<32;8;{target}M\x1b[<0;8;{target}m');ui.settle()
    assert preview_height(ui)==12,(preview_height(ui),ui.screen)
    stored=json.loads(preferences.read_text());assert stored['previewContentHeight']==12 and stored['version']==4
    assert preferences.stat().st_mode&0o777==0o600
    snapshot(ui,'views-preview-grown',result,a.output)
    ui.resize(80,24);ui.settle();assert 1<=preview_height(ui)<=8
    assert json.loads(preferences.read_text())['previewContentHeight']==12
    ui.resize(48,12);ui.settle();assert not any(line.lstrip().startswith('Preview') for line in ui.screen.splitlines()[:-2])
    ui.resize(132,48);ui.settle();assert preview_height(ui)==12
    checks.append('Default three-line preview, keyboard sizing, divider drag, minimum upper workspace and restoration preserve the preferred height privately')
    # Report PageDown moves by the actual visible item capacity with the enlarged preview.
    visible=sum(1 for line in ui.screen.splitlines()[:preview_row(ui)] if 'Selected item' in line or re.search(r'Other \d\d',line))
    ui.send(ESC+b'[6~');ui.wait(f'OTHER {35-visible:02d}')
    ui.send(ESC+b'[H');ui.wait('BODY 00')
    checks.append('Item report PageDown uses the reduced visible capacity when the preview is enlarged')
    # The enlarged preview scrolls by its own capacity, retaining the selected record.
    click(ui,8,preview_row(ui)+2);ui.send(ESC+b'[6~');ui.wait('BODY 12');assert 'BODY 00' not in ui.screen
    ui.send(ESC+b'[F');ui.wait('BODY 68')
    for _ in range(3):ui.send(ESC+b'=')
    ui.settle();ui.wait('BODY 65');ui.send(ESC+b'[5~');ui.wait('BODY 50')
    ui.send(ESC+b'0');ui.settle()
    for _ in range(9):ui.send(ESC+b'=')
    ui.settle();ui.send(ESC+b'[H');ui.wait('BODY 00')
    checks.append('Preview paging uses the resized height without moving the selected item')
    ui.send(b'\x05');ui.settle();assert 'Edit item ·' not in ui.screen
    assert all(not slots(ui)[n] for n in [2,3,4,5,6,7])
    ui.send(F10);ui.wait('Command menu');assert slots(ui)[10]
    menu=ui.screen.splitlines()[1];click(ui,menu.index('Edit')+1,2)
    row,line=next((i+1,line) for i,line in enumerate(ui.screen.splitlines()) if 'Edit item' in line)
    click(ui,line.index('Edit item')+1,row);assert 'Command menu' in ui.screen
    ui.send(F10);ui.settle();assert 'Command menu' not in ui.screen
    ui.send(F8);field(ui,'Find:');click(ui,8,preview_row(ui)+2)
    checks.append('Read-only preview suppresses contextual Fn keys, Control-E and the corresponding menu action; F10 closes the menu and F8 focuses the selector')

    ui.send(F9);ui.wait('Category manager');find(ui,'Alpha');ui.send(b'\r');ui.wait('BODY 00')
    assert preview_height(ui)==12
    click(ui,8,preview_row(ui)+2);ui.send(F8);field(ui,'Find:');ui.send(b'\r');ui.settle()
    y=preview_row(ui)+1;target=y+4
    ui.send(f'\x1b[<0;8;{y}M\x1b[<32;8;{target}M\x1b[<0;8;{target}m');ui.settle()
    assert preview_height(ui)==8
    ui.send(F9);ui.wait('[Views]');ui.settle();assert preview_height(ui)==8
    ui.send(F11);ui.settle();ui.send(F11);ui.wait('BODY 00');assert preview_height(ui)==8
    ui.send(ESC+b'0');ui.settle();assert preview_height(ui)==3
    checks.append('Height is shared across Views/Categories, and hide/show plus keyboard Reset retain the intended layout')
    ui.send(F9);ui.wait('Category manager');find(ui,'Alpha');ui.send(SHIFT_F2);ui.wait('[Category]');field(ui,'Subject')
    snapshot(ui,'category-keyboard-inspector',result,a.output)
    for cycle in range(3):
     field(ui,'Subject');ui.send(b'\x15');ui.paste(f'Alpha cycle {cycle}')
     ui.send(b'\t');field(ui,'Body / note');ui.send(b'\x15');ui.paste(f'Body cycle {cycle}')
     ui.send(b'\t');field(ui,'Class');ui.send(b'\t');field(ui,'Category rule')
     ui.send(b'\x15');ui.paste('bucket == "alpha" && itemID == *')
     ui.send(b'\t');ui.settle();assert 'focused' in ui.screen.splitlines()[preview_row(ui)],ui.screen
     ui.send(b'\t');field(ui,'Find:');ui.send(b'\t');field(ui,'Subject')
    for _ in range(2):
     ui.send(BACKTAB);field(ui,'Find:');ui.send(BACKTAB);ui.settle();assert 'focused' in ui.screen.splitlines()[preview_row(ui)]
     ui.send(BACKTAB);field(ui,'Category rule');ui.send(BACKTAB);field(ui,'Class')
     ui.send(BACKTAB);field(ui,'Body / note');ui.send(BACKTAB);field(ui,'Subject')
    checks.append('Three forward and two reverse field cycles traverse every inspector field, preview and navigator, returning to the proper entry field')
    ui.send(SHIFT_F2);ui.wait('[Items]');ui.send(ESC+b'i');ui.wait('[Category]');field(ui,'Subject')
    assert 'Alpha cycle 2' in ui.screen and 'Body cycle 2' in ui.screen
    ui.send(ESC+b'=');ui.settle();field(ui,'Subject')
    assert wire.manifest(root/'store')==initial
    snapshot(ui,'draft-after-cycles-and-mode-switch',result,a.output)
    ui.send(F8);ui.wait('Saved one revision')
    saved=client.get(wire.item_id(category))
    assert saved['fields']['subject']==wire.text('Alpha cycle 2')
    assert saved['fields']['body']==wire.text('Body cycle 2')
    assert saved['fields']['selection']['value']['expression']==wire.text('bucket == "alpha" && itemID == *')
    assert saved['fields']['opaque']==category['fields']['opaque'] and saved['fields']['classID']==category['fields']['classID']
    assert client.call('TractandaItem/history',{'itemID':wire.item_id(category)})['total']==2
    checks.append('Keyboard mode switches and resizing retain the complete draft; F8 publishes exactly one correct revision with unknown fields and class preserved')
    ui.send(SHIFT_F2);ui.wait('[Items]');find(ui,'Empty');ui.send(b'\r');ui.wait('No matching items');ui.settle()
    bars=slots(ui);assert all(not bars[n] for n in [2,3,4,5,6,7]),bars
    assert bars[1] and bars[10]
    ui.send(F2);ui.settle();assert 'Edit item ·' not in ui.screen
    ui.send(b'\x0e');ui.wait('New item');ui.settle();bars=slots(ui);assert all(not bars[n] for n in [2,3,4]),bars
    ui.send(F9);ui.wait('Draft canceled')
    checks.append('Empty item panes hide inactive edit/choice/done/mark keys; editor copy/cut slots stay blank without a selection')
    ui.send(ESC+b'=');ui.settle();height=json.loads(preferences.read_text())['previewContentHeight']
   with session() as ui:
    ui.wait('Views');ui.resize(132,48);ui.settle();assert preview_height(ui)==height
    assert json.loads(preferences.read_text())['previewContentHeight']==height
    checks.append('Preview height survives a new process without modifying canonical records')
   assert len(wire.manifest(root/'store'))==len(initial)+1
   assert client.get(wire.item_id(note))==note and client.get(wire.item_id(view))==view
   assert not recovery.exists()
 result['status']='passed';a.output.write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n')
 print(json.dumps({k:v for k,v in result.items() if k!='snapshots'},indent=2))
if __name__=='__main__':main()
