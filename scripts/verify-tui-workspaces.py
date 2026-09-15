#!/usr/bin/env python3
"""Check the two-workspace contract using an isolated native store and owned PTY."""
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
F2, F8, F9, F10, F11, F12 = [ESC + f'[{n}~'.encode() for n in (12, 19, 20, 21, 23, 24)]


def value(kind, data):
    return {'type': kind, 'value': data}


def click(ui, x, y):
    ui.send(f'\x1b[<0;{x};{y}M\x1b[<0;{x};{y}m')


def click_text(ui, text):
    row, line = next((index+1, line) for index, line in enumerate(ui.screen.splitlines()) if text in line)
    click(ui, line.index(text)+1, row)
    ui.settle()


def menu_group(ui, name):
    row,line=next((index+1,line) for index,line in enumerate(ui.screen.splitlines())
                  if 'File' in line and 'Edit' in line and 'Help' in line)
    click(ui,line.index(name)+1,row)
    ui.settle()


def find(ui, text):
    row, line = next((index+1, line) for index, line in enumerate(ui.screen.splitlines()) if 'Find:' in line)
    click(ui, line.index('Find:')+7, row)
    ui.send(b'\x15')
    ui.paste(text)
    ui.wait('Find: '+text)
    ui.settle()


def wait_workspace(ui, name):
    deadline=time.monotonic()+10
    while not (ui.is_frame_complete and ('['+name+']') in ui.screen.splitlines()[0]):
        ui.read(.03)
        assert ui.process.poll() is None and time.monotonic()<deadline, (name,ui.screen)


def snapshot(ui, name, report, path):
    ui.settle()
    report['snapshots'].append({'name': name, 'columns': ui.width, 'rows': ui.height,
                                'screen': ui.screen, 'ansiFrame': ui.raw.rsplit('\x1b[H',1)[-1]})
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('native_binary',type=Path)
    parser.add_argument('tui_binary',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--read-only',action='store_true',help='Check layout/navigation/draft cancellation without committed edits')
    args=parser.parse_args()
    report={'status':'inProgress','platform':platform.platform(),'checks':[],'snapshots':[]}
    checks=report['checks']
    with tempfile.TemporaryDirectory(prefix='trac-workspaces-',dir='/tmp') as temporary:
        root=Path(temporary)
        with wire.server(str(args.native_binary.resolve()),root/'store',root/'s') as client:
            def create(name, fields=None):
                return client.commit(wire.intent('create','seed-'+name,class_id='NoteItem',
                    changes={'subject':wire.text(name),**(fields or {})}))['revision']
            def category(name, bucket):
                return create(name,{'selection':value('object',{
                    'language':wire.text('tractanda.spotlight.v0'),
                    'expression':wire.text(f'bucket == "{bucket}"')})})
            alpha=category('Alpha category','alpha')
            beta=category('Beta category','beta')
            empty=category('Empty category','empty')
            for n in range(70):
                create(f'Alpha item {n:02d}',{'bucket':wire.text('alpha'),'rank':value('integer',n),
                    'body':wire.text(f'ALPHA PREVIEW {n:02d}\nSecond line café 文\nLong note for scrolling.\nFourth line\nFifth line\nSixth line')})
            beta_item=create('Beta item',{'bucket':wire.text('beta'),'body':wire.text('BETA PREVIEW BODY')})
            saved_views={}
            for name,bucket in [('Alpha view','alpha'),('Beta view','beta')]:
                saved_views[name]=create(name,{'body':wire.text(name+' description'),'viewDefinition':value('object',{
                    'language':wire.text('tractanda.spotlight.v0'),
                    'expression':wire.text(f'bucket == "{bucket}"')})})
            create('Sectioned view',{'viewDefinition':value('object',{
                'language':wire.text('tractanda.spotlight.v0'),'expression':wire.text('bucket == "alpha"'),
                'sort':value('list',[value('object',{'property':wire.text('rank'),'isAscending':value('boolean',True)})]),
                'presentation':value('object',{'profile':wire.text('tractanda.table.v0'),
                    'sections':value('list',[value('reference',{'itemID':wire.item_id(alpha)})])})})})
            initial=wire.manifest(root/'store')
            with tui.terminal(str(args.tui_binary.resolve()),root/'s',root/'pending.json',items_only=False) as ui:
                wait_workspace(ui,'Views'); ui.resize(132,35); ui.settle()
                row,line=next((n+1,line) for n,line in enumerate(ui.screen.splitlines()) if 'Find:' in line)
                divider=line.index('│')+1
                ui.send(f'\x1b[<0;{divider};{row}M\x1b[<32;{divider+8};{row}M\x1b[<0;{divider+8};{row}m')
                ui.settle()
                changed=next(line for line in ui.screen.splitlines() if 'Find:' in line).index('│')+1
                assert changed>divider, ui.screen
                assert json.loads((root/'pending.views.json').read_text())['selectorSplitWidth']>.33
                checks.append('The Views selector divider drags and persists its width in private preferences')
                find(ui,'Alpha view'); ui.send(b'\r'); ui.wait('ALPHA PREVIEW 69')
                snapshot(ui,'views-three-panes',report,args.output)
                ui.send(ESC+b'[B'); ui.wait('ALPHA PREVIEW 68')
                ui.send(F9); wait_workspace(ui,'Categories')
                find(ui,'Beta category'); ui.send(b'\r'); ui.wait('BETA PREVIEW BODY')
                snapshot(ui,'categories-three-panes',report,args.output)
                ui.send(F9); ui.wait('ALPHA PREVIEW 68')
                assert 'BETA PREVIEW BODY' not in ui.screen
                ui.send(F9); ui.wait('BETA PREVIEW BODY')
                checks.append('F9 round-trips preserve independent view/category selection, item row and bottom preview')

                ui.send(F10); ui.wait('Command menu'); menu_group(ui,'Window')
                ui.wait('Views workspace'); click_text(ui,'Views workspace')
                wait_workspace(ui,'Views'); ui.wait('ALPHA PREVIEW 68')
                # The bottom preview is a distinct focus target; Down must not select another item/view.
                ui.send(b'\t'); ui.settle(); ui.send(ESC+b'[B'); ui.settle()
                assert 'ALPHA PREVIEW 68' not in ui.screen, ui.screen
                assert any(part.lstrip().startswith('>') and 'Alpha item 68' in part
                           for line in ui.screen.splitlines() for part in line.split('│')), ui.screen
                assert 'Fourth line' in ui.screen, ui.screen
                ui.send(ESC+b'[H'); ui.wait('ALPHA PREVIEW 68')
                ui.send(b'\t'); ui.settle(); ui.send(b'\t'); ui.settle()
                ui.send(F10); ui.wait('Command menu'); menu_group(ui,'Window')
                ui.wait('Categories workspace'); click_text(ui,'Categories workspace')
                wait_workspace(ui,'Categories'); ui.wait('BETA PREVIEW BODY')
                ui.send(F11); ui.settle(); assert 'BETA PREVIEW BODY' not in ui.screen
                ui.send(F11); ui.wait('BETA PREVIEW BODY')
                checks.append('Window-menu switching works, Tab can focus the bottom preview, and F11 hides/restores it without changing the item')

                find(ui,'Alpha category'); ui.send(b'\r'); ui.wait('ALPHA PREVIEW 69')
                ui.send(ESC+b'[6~'); ui.wait('ALPHA PREVIEW 05')
                ui.send(ESC+b'[B'); ui.wait('ALPHA PREVIEW 04')
                ui.send(F9); wait_workspace(ui,'Views')
                ui.send(F9); wait_workspace(ui,'Categories'); ui.wait('ALPHA PREVIEW 04')
                checks.append('A non-first Categories result page and selected row survive workspace switching')
                find(ui,'Beta category'); ui.send(b'\r'); ui.wait('BETA PREVIEW BODY')

                # Inapplicable text-editing actions stay visible in the global menu.
                ui.send(F10); ui.wait('Command menu')
                ui.send(ESC+b'[C'); ui.wait('Undo text edit')
                click_text(ui,'Undo text edit')
                assert 'Command menu' in ui.screen
                snapshot(ui,'disabled-global-command',report,args.output)
                ui.send(ESC); ui.settle()
                checks.append('Unavailable text-editing commands remain visible and clicking one does not execute or dismiss the menu')

                ui.send(ESC+b'[13~'); ui.wait('Include item in category')
                ui.send(F9); ui.wait('BETA PREVIEW BODY')
                assert '[Categories]' in ui.screen.splitlines()[0]
                checks.append('Canceling an assignment picker restores the same Categories item and preview')

                # Ctrl-E edits the selected content, just like F2, even inside Categories.
                ui.send(b'\x05'); ui.wait('Edit item ·')
                assert 'Beta item' in ui.screen and 'Edit item / Category' not in ui.screen
                ui.send(F9); ui.wait('Draft canceled')
                # Creating the first item must work without an existing row to select.
                find(ui,'Empty category'); ui.send(b'\r'); ui.wait('No matching items')
                ui.send(b'\x0e'); ui.wait('New item')
                ui.paste('Unsubmitted first item'); ui.send(F9); ui.wait('Draft canceled')
                assert not tui.query(client,'subject == "Unsubmitted first item"')
                find(ui,'Beta category'); ui.send(b'\r'); ui.wait('BETA PREVIEW BODY')
                checks.append('Ctrl-E targets Categories content and Ctrl-N can capture into an empty category; both canceled drafts remain write-free')

                if not args.read_only:
                    # Same item editing command must operate on Categories' item, not hidden Views data.
                    ui.send(F2); ui.wait('Edit item')
                    snapshot(ui,'editing-category-content-item',report,args.output)
                    ui.paste(' edited in Categories')
                    ui.send(F8); ui.wait('Saved one revision')
                    edited=tui.wait_item(client,'subject == "Beta item edited in Categories"',ui)
                    assert wire.item_id(edited)==wire.item_id(beta_item)
                    assert edited['fields']['body']==wire.text('BETA PREVIEW BODY')
                    ui.send(F9); ui.wait('ALPHA PREVIEW 68')
                    assert not tui.query(client,'subject == "Alpha item 68 edited in Categories"')
                    checks.append('F2/F8 edits the active Categories item and returns there without modifying hidden Views selection')
                    ui.send(F9); ui.wait('BETA PREVIEW BODY')
                    ui.send(ESC+b'[13~'); ui.wait('Include item in category')
                    ui.paste('Alpha category'); ui.send(b'\r'); ui.wait('Saved one revision')
                    assert client.get(wire.item_id(beta_item))['fields']['categoryOverrides']['value'][wire.item_id(alpha)]==wire.text('include')
                    ui.wait('BETA PREVIEW BODY'); assert '[Categories]' in ui.screen.splitlines()[0]
                    checks.append('An assignment from the Categories item pane revises that item and returns to the same report')
                    ui.send(F9); ui.wait('ALPHA PREVIEW 68')


                    ui.send(F9); ui.wait('BETA PREVIEW BODY')
                    ui.send(b'\x0e'); ui.wait('New item'); ui.paste('Captured from Categories')
                    ui.send(F8); ui.wait('Saved one revision')
                    captured=tui.wait_item(client,'subject == "Captured from Categories"',ui)
                    assert captured['fields']['categoryOverrides']['value'][wire.item_id(beta)]==wire.text('include')
                    checks.append('New item in Categories receives its active category assignment')

                for size in [(80,25),(48,12),(132,35)]:
                    ui.resize(*size); wait_workspace(ui,'Categories')
                    snapshot(ui,'category-resize',report,args.output)
                ui.send(F9); wait_workspace(ui,'Views')
                for size in [(80,25),(48,12),(132,35)]:
                    ui.resize(*size); wait_workspace(ui,'Views')
                    snapshot(ui,'view-resize',report,args.output)
                checks.append('Both main workspaces preserve state through compact, standard and wide terminal layouts')

                # Preferences is available from either workspace and returns to the same report.
                for destination in ['Views','Categories']:
                    if destination=='Categories': ui.send(F9); wait_workspace(ui,'Categories')
                    ui.send(F10); ui.wait('Command menu')
                    ui.send(ESC+b'[D')  # File -> the fixed Tractanda application menu.
                    ui.wait('Settings / Appearance')
                    click_text(ui,'Settings / Appearance')
                    ui.wait('Cursor layout')
                    snapshot(ui,'preferences-from-'+destination.lower(),report,args.output)
                    ui.send(F9); ui.wait('Appearance changes canceled')
                    assert destination in ui.screen
                checks.append('The global Preferences action opens and cancels from both workspaces without losing their state')
                ui.close()

            # Definitions and content are all ordinary items, but edit targets must stay distinct.
            with tui.terminal(str(args.tui_binary.resolve()),root/'s',root/'drafts.json',items_only=False) as ui:
                wait_workspace(ui,'Views'); ui.resize(132,35); ui.settle()
                row,line=next((n+1,line) for n,line in enumerate(ui.screen.splitlines()) if 'Find:' in line)
                divider=line.index('│')+1
                ui.send(f'\x1b[<0;{divider};{row}M\x1b[<32;{divider+8};{row}M\x1b[<0;{divider+8};{row}m')
                ui.settle()
                changed=next(line for line in ui.screen.splitlines() if 'Find:' in line).index('│')+1
                assert changed>divider, ui.screen
                assert json.loads((root/'pending.views.json').read_text())['selectorSplitWidth']>.33
                checks.append('The Views selector divider drags and persists its width in private preferences')
                find(ui,'Alpha view'); ui.send(F2); ui.wait('View definition')
                ui.paste(' draft')
                ui.send(F10); ui.wait('Command menu'); ui.send(ESC+b'[D')
                ui.wait('Settings / Appearance'); click_text(ui,'Settings / Appearance')
                ui.wait('Cursor layout'); ui.send(F9)
                ui.wait('View definition'); ui.wait('Alpha view draft')
                snapshot(ui,'view-draft-after-preferences',report,args.output)
                ui.send(F9); ui.settle(); wait_workspace(ui,'Views')
                assert wire.revision_id(client.get(wire.item_id(saved_views['Alpha view'])))==wire.revision_id(saved_views['Alpha view'])
                checks.append('Preferences suspends and restores the complete view-definition draft; F9 cancel writes no revision')

                ui.send(F9); wait_workspace(ui,'Categories')
                find(ui,'Beta category'); ui.send(F2); ui.wait('Edit item')
                ui.paste(' draft')
                ui.send(F9); wait_workspace(ui,'Views')
                ui.send(F9); wait_workspace(ui,'Categories'); ui.wait('Beta category draft')
                ui.send(F10); ui.wait('Command menu'); ui.send(ESC+b'[D')
                ui.wait('Settings / Appearance'); click_text(ui,'Settings / Appearance')
                ui.wait('Cursor layout'); ui.send(F9)
                ui.wait('Beta category draft')
                snapshot(ui,'category-draft-after-switch-and-preferences',report,args.output)
                ui.send(ESC); ui.settle()
                assert wire.revision_id(client.get(wire.item_id(beta)))==wire.revision_id(beta)
                checks.append('Workspace switching and Preferences retain an inline category draft; explicit cancel is write-free')

                if not args.read_only:
                    ui.send(F9); wait_workspace(ui,'Views')
                    find(ui,'Alpha view'); ui.send(b'\x0e'); ui.wait('View definition')
                    ui.paste('Created view'); ui.send(F8); ui.wait('Saved one revision')
                    new_view=tui.wait_item(client,'subject == "Created view"',ui)
                    assert 'viewDefinition' in new_view['fields']
                    ui.send(F9); wait_workspace(ui,'Categories')
                    find(ui,'Beta category'); ui.send(b'\x0e'); ui.wait('New category')
                    ui.paste('Created child'); ui.send(F8); ui.wait('Saved one revision')
                    new_category=tui.wait_item(client,'subject == "Created child"',ui)
                    assert 'selection' in new_category['fields']
                    assert [entry['value']['itemID'] for entry in new_category['fields']['categoryParents']['value']]==[wire.item_id(beta)]
                    checks.append('CtrlN/F8 creates the selected workspace definition: saved view or child category with the correct parent')
                ui.close()
            if not args.read_only:
                with tui.terminal(str(args.tui_binary.resolve()),root/'s',root/'scoped.json',items_only=False) as ui:
                    wait_workspace(ui,'Views'); ui.resize(132,35)
                    find(ui,'Sectioned view'); ui.send(b'\r'); ui.settle()
                    # Move from a section heading if necessary to select its first item.
                    if 'ALPHA PREVIEW 00' not in ui.screen: ui.send(ESC+b'[B')
                    ui.wait('ALPHA PREVIEW 00')
                    ui.send(F9); wait_workspace(ui,'Categories')
                    find(ui,'Beta category'); ui.send(b'\r'); ui.settle()
                    ui.send(b'\x0e'); ui.wait('New item'); ui.paste('Scoped capture')
                    ui.send(F8); ui.wait('Saved one revision')
                    scoped=tui.wait_item(client,'subject == "Scoped capture"',ui)
                    assert scoped['fields']['categoryOverrides']['value']=={wire.item_id(beta):wire.text('include')}
                    checks.append('A Categories capture does not inherit a section assignment from the hidden Views report')
                    ui.close()
            assert not (root/'pending.json').exists()
            assert not (root/'drafts.json').exists()
            changed=wire.manifest(root/'store')
            assert len(changed)==len(initial)+(0 if args.read_only else 6), (len(initial),len(changed))
            checks.append('No committed edits were made; no pending operation remains' if args.read_only else 'Only the intended content/assignment revisions, two captured items and two definitions were written; navigation/settings leave no pending operation')
    report['checks']=list(dict.fromkeys(report['checks']))
    report['status']='passed'
    args.output.write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='snapshots'},indent=2))


if __name__=='__main__':
    main()
