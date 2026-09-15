#!/usr/bin/env python3
"""Verify clickable category prefixes and overflow navigation through a real terminal."""
import argparse
import importlib.util
import json
import platform
import tempfile
import time
import unicodedata
from pathlib import Path

spec=importlib.util.spec_from_file_location('mouse',Path(__file__).with_name('verify-tui-mouse.py'))
mouse=importlib.util.module_from_spec(spec)
spec.loader.exec_module(mouse)
tui,wire,ESC=mouse.tui,mouse.wire,mouse.ESC


def category(client,name,expression='itemID == *',parent=None):
    fields={'selection':{'type':'object','value':{'language':wire.text('tractanda.spotlight.v0'),'expression':wire.text(expression)}}}
    if parent:
        fields['categoryParents']={'type':'list','value':[{'type':'reference','value':{'itemID':wire.item_id(parent)}}]}
    return mouse.create(client,name,fields)


def open_category(ui,name):
    ui.send('c');ui.wait('Category manager')
    ui.send(ESC+b'[24~');ui.wait('Categories refreshed.')
    row,line=next((i,line) for i,line in enumerate(ui.screen.splitlines()) if 'Find:' in line)
    mouse.click(ui,line.index('Find:')+6,row);ui.settle()
    ui.send(b'\x15')
    ui.paste(name);ui.wait('Find: '+name)
    ui.send(b'\r');ui.wait('Category item report focused')


def wait_path(ui,path):
    deadline=time.monotonic()+10
    while not ui.is_frame_complete or not any(line.replace(' ▾','').strip()==path for line in ui.screen.splitlines()):
        ui.read()
        assert ui.process.poll() is None,ui.screen
        assert time.monotonic()<deadline,(path,ui.screen)


def open_children(ui,position):
    line=next(line for line in ui.screen.splitlines() if '▾' in line)
    index=[index for index,character in enumerate(line) if character=='▾'][position]
    x=sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in ['W','F'] else 1 for c in line[:index])
    y=ui.screen.splitlines().index(line)
    mouse.click(ui,x,y);ui.wait('Child categories')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('native_binary',type=Path)
    parser.add_argument('tui_binary',type=Path)
    parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    native,binary=str(args.native_binary.resolve()),str(args.tui_binary.resolve())
    checks,snapshots=[],[]
    with tempfile.TemporaryDirectory(prefix='trac-crumb-',dir='/tmp') as directory:
        root=Path(directory)
        with wire.server(native,root/'store',root/'s') as client:
            item_root=category(client,'Item')
            family=category(client,'Family / 家族','family == 1',item_root)
            dad=category(client,'Dad','dad == 1',family)
            mouse.create(client,'Family only',{'family':{'type':'integer','value':1}})
            mouse.create(client,'Father task',{'dad':{'type':'integer','value':1}})
            mouse.create(client,'Unrelated')
            baseline=wire.manifest(root/'store')
            with tui.terminal(binary,root/'s',root/'recovery/pending.json') as ui:
                ui.resize(132,30);ui.wait('All items')
                open_children(ui,0)
                assert 'Top-level─categories' in ui.screen,ui.screen
                assert 'Item' in ui.screen.splitlines()[3]
                snapshots.append({'name':'all-items-category-menu','columns':132,'rows':30,'screen':ui.screen})
                mouse.click_text(ui,'Item',3);wait_path(ui,'Item')
                open_children(ui,0);mouse.click_text(ui,'Family');wait_path(ui,'Item / Family / 家族')
                open_children(ui,1);mouse.click_text(ui,'Dad');wait_path(ui,'Item / Family / 家族 / Dad')
                assert wire.manifest(root/'store')==baseline
                checks.append('All items dropdown starts at readable roots and reaches descendants entirely by mouse without duplicate All items breadcrumbs or writes')
                assert 'Family only' not in ui.screen and 'Father task' in ui.screen
                ui.send('f');ui.wait('Filter items');ui.paste('subject == "missing"');ui.send(b'\x13');ui.wait('Filter applied')
                mouse.click_text(ui,'Family',1);wait_path(ui,'Item / Family / 家族')
                assert 'Family only' in ui.screen and 'Father task' in ui.screen
                assert 'No expression filter' in ui.screen
                assert '\x1b[0;4m' in ui.raw
                mouse.click_text(ui,'Item',1);wait_path(ui,'Item')
                assert 'Unrelated' in ui.screen
                ui.send('a');ui.wait('All readable items')
                ui.send('f');ui.wait('Filter items');ui.paste('subject == "Family only"');ui.send(b'\x13');ui.wait('Filter applied')
                mouse.click_text(ui,'All items',1);ui.wait('All readable items')
                assert 'Unrelated' in ui.screen
                assert wire.manifest(root/'store')==baseline
                checks.append('Ancestor and root breadcrumb clicks clear later categories and extra filters; the All items link restores the full readable set without revisions')

                category(client,'Sibling','itemID == ""',family)
                category(client,'Grandchild','itemID == ""',dad)
                baseline=wire.manifest(root/'store')
                ui.send('r');ui.wait('Refreshed')
                open_category(ui,'Dad');open_children(ui,1)
                assert ui.raw.rfind('\x1b[?1003h') > ui.raw.rfind('\x1b[?1002h')
                assert 'Sibling' in ui.screen and 'Grandchild' not in ui.screen
                x,y=mouse.find(ui,'Sibling');ui.send(mouse.report(35,x+1,y));ui.wait('>  Sibling')
                mouse.click_text(ui,'Sibling');wait_path(ui,'Item / Family / 家族 / Sibling')
                open_children(ui,1);ui.send(ESC+b'[A'+b'\r');wait_path(ui,'Item / Family / 家族 / Dad')
                open_children(ui,2);ui.wait('Grandchild')
                mouse.click(ui,1,ui.height-3);ui.wait('Category item report focused',absent='Child categories')
                wait_path(ui,'Item / Family / 家族 / Dad')
                assert wire.manifest(root/'store')==baseline
                checks.append('Breadcrumb child dropdowns show only immediate children, follow hover, replace the later branch and cancel without writing records')

                for index in range(12): category(client,f'Z option {index:02d}','itemID == ""',family)
                baseline=wire.manifest(root/'store')
                ui.send(ESC+b'[24~');ui.wait('Categories refreshed.');ui.resize(48,12)
                open_children(ui,1);ui.send(ESC+b'[F');ui.wait('Z option 11')
                snapshots.append({'name':'narrow-child-dropdown','columns':48,'rows':12,'screen':ui.screen})
                ui.resize(132,30);ui.wait('Z option 11');ui.send(b'\r')
                wait_path(ui,'Item / Family / 家族 / Z option 11')
                assert wire.manifest(root/'store')==baseline
                checks.append('Long immediate-child lists scroll by keyboard, preserve selection through resizing and open the selected child under the same parent')

                long_name='A very long family category heading that forces overflow'
                long_parent=category(client,long_name,parent=item_root)
                middle=category(client,'Middle / 家族',parent=long_parent)
                category(client,'Overflow Leaf',parent=middle)
                baseline=wire.manifest(root/'store')
                open_category(ui,'Overflow Leaf')
                ui.resize(48,12);ui.wait('…')
                snapshots.append({'name':'narrow-breadcrumb','columns':48,'rows':12,'screen':ui.screen})
                breadcrumb_row,breadcrumb=next((row,line) for row,line in enumerate(ui.screen.splitlines())
                    if ' / ' in line and '…' in line)
                mouse.click(ui,breadcrumb.rfind('…'),breadcrumb_row);ui.wait('Category path')
                snapshots.append({'name':'path-chooser','columns':48,'rows':12,'screen':ui.screen})
                mouse.click_text(ui,'3  Middle');ui.read(0.1);ui.wait('Category path')
                mouse.click_text(ui,'3  Middle')
                ui.resize(132,30);wait_path(ui,'Item / '+long_name+' / Middle / 家族')
                assert ' / Overflow Leaf' not in ui.screen.splitlines()[1]
                assert wire.manifest(root/'store')==baseline
                checks.append('Narrow terminals expose the full ordered path through an overflow chooser; double-clicking a hidden ancestor preserves its exact identity and path')
                ui.close();mouse.check_cleanup(ui)
    result={'status':'passed','platform':platform.platform(),'checks':checks,'snapshots':snapshots}
    if args.output:
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k!='snapshots'},ensure_ascii=False))


if __name__=='__main__':main()
