#!/usr/bin/env python3
"""Verify retained Custom colors and named presets through real isolated TUI sessions."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import platform
import tempfile

spec = importlib.util.spec_from_file_location('tui', Path(__file__).with_name('verify-tui.py'))
tui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tui)
wire, ESC = tui.wire, tui.ESC
RIGHT, LEFT, BACKTAB = ESC + b'[C', ESC + b'[D', ESC + b'[Z'
F5, F8, F9 = ESC + b'[15~', ESC + b'[19~', ESC + b'[20~'


def role_map(value):
    roles = value['roles']
    return roles if isinstance(roles, dict) else dict(zip(roles[::2], roles[1::2]))


def open_settings(ui):
    ui.send(ESC + b'[44;9u')
    ui.wait('Settings / Appearance')


def set_preset(ui, name):
    # The preset cell is focused on opening Settings. Exercise the text route as
    # well as the arrow route instead of assuming an enum index for user presets.
    ui.send(b'\x15')
    ui.paste(name)
    ui.settle()


def save(ui):
    ui.send(F8)
    ui.wait('saved locally')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('native_binary', type=Path)
    parser.add_argument('tui_binary', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--retention-only', action='store_true')
    args = parser.parse_args()
    checks = []
    with tempfile.TemporaryDirectory(prefix='trac-custom-', dir='/tmp') as directory:
        root = Path(directory)
        preferences, recovery = root / 'r.appearance.json', root / 'r.json'
        with wire.server(str(args.native_binary.resolve()), root / 'store', root / 's') as client:
            manifest = wire.manifest(root / 'store')
            def session(journal=recovery):
                return tui.terminal(str(args.tui_binary.resolve()), root / 's', journal,
                                    arguments=[str(root / 's'), '--appearance-file', str(preferences)])

            with session() as ui:
                ui.wait('No items'); open_settings(ui); set_preset(ui, 'custom')
                ui.send(b'\t' * 6 + b'\x15'); ui.paste('#1a2b3c')
                ui.send(b'\t\x15'); ui.paste('#4d5e6f')
                ui.send(BACKTAB * 6 + RIGHT)  # Cursor layout becomes Standard.
                save(ui)
                original = json.loads(preferences.read_text())
                assert original['preset'] == 'custom' and original['cursor']['layout'] == 'native'
                open_settings(ui)
                ui.send(RIGHT * 3); ui.settle()  # Custom -> Blue -> Amber -> Custom.
                assert '#1a2b3c' in ui.screen and '#4d5e6f' in ui.screen, ui.screen
                save(ui)
                current = json.loads(preferences.read_text())
                assert role_map(current) == role_map(original) and current['cursor'] == original['cursor']
                open_settings(ui); set_preset(ui, 'blue'); save(ui)
                assert json.loads(preferences.read_text())['preset'] == 'blue'
                checks.append('Arrow round trip restores exact custom colors and preserves cursor options')

            with session() as ui:
                ui.wait('No items'); open_settings(ui); set_preset(ui, 'custom'); save(ui)
                assert role_map(json.loads(preferences.read_text())) == role_map(original)
                saved_bytes = preferences.read_bytes()
                open_settings(ui); ui.send(b'\t' * 6 + b'\x15'); ui.paste('#abcdef')
                ui.send(BACKTAB * 6); set_preset(ui, 'amber'); ui.send(F9)
                ui.wait('Appearance changes canceled')
                assert preferences.read_bytes() == saved_bytes
                open_settings(ui); set_preset(ui, 'blue'); set_preset(ui, 'custom'); save(ui)
                assert role_map(json.loads(preferences.read_text())) == role_map(original)
                checks.append('Saved built-in choice survives restart without erasing Custom; typed switching and Cancel preserve retained palette')

                if not args.retention_only:
                    open_settings(ui); ui.send(F5); ui.wait('Save appearance preset')
                    ui.paste('My evening colors'); ui.send(F9); ui.settle()
                    assert 'Cursor layout' in ui.screen
                    ui.send(F5); ui.wait('Save appearance preset'); ui.paste('My evening colors'); save(ui)
                    named_saved = preferences.read_bytes()
                    open_settings(ui); set_preset(ui, 'amber'); save(ui)
                    checks.append('Cancel naming returns to Appearance; Save as creates and selects a named palette in private settings')

            if not args.retention_only:
                with session() as ui:
                    ui.wait('No items'); open_settings(ui); set_preset(ui, 'My evening colors')
                    assert '#1a2b3c' in ui.screen and '#4d5e6f' in ui.screen
                    save(ui)
                    assert role_map(json.loads(preferences.read_text())) == role_map(original)
                    selected_id = json.loads(preferences.read_text())['preset']
                    open_settings(ui); ui.send(b'\t' * 6 + b'\x15'); ui.paste('#abcdef'); save(ui)
                    updated = json.loads(preferences.read_text())
                    assert updated['preset'] == selected_id
                    assert role_map(updated)['activeSelection']['foreground'] == '#abcdef'
                    open_settings(ui); set_preset(ui, 'My evening colors'); save(ui)
                    assert role_map(json.loads(preferences.read_text())) == role_map(updated)
                    open_settings(ui); ui.send(b'\t' * 6 + b'\x15'); ui.paste('#fedcba')
                    ui.send(F5); ui.wait('Save appearance preset'); ui.paste('My alternate colors'); save(ui)
                    copied = json.loads(preferences.read_text())
                    assert copied['preset'] != selected_id
                    assert role_map(copied)['activeSelection']['foreground'] == '#fedcba'
                    source = next(p for p in copied['savedPalettes'] if p['id'] == selected_id)
                    assert role_map(source) == role_map(updated)
                    open_settings(ui); set_preset(ui, 'custom'); save(ui)
                    assert role_map(json.loads(preferences.read_text())) == role_map(original)
                    assert json.loads(preferences.read_text())['cursor'] == original['cursor']
                    before_duplicate = preferences.read_bytes()
                    open_settings(ui); ui.send(F5); ui.wait('Save appearance preset')
                    ui.paste('my EVENING colors'); ui.send(F8); ui.settle()
                    assert preferences.read_bytes() == before_duplicate
                    assert 'Save appearance preset' in ui.screen
                    ui.send(F9); ui.settle(); ui.send(F9); ui.wait('Appearance changes canceled')
                    assert preferences.read_bytes() == before_duplicate
                    checks.append('Named Save updates stable ID, Save as preserves the source snapshot, retained Custom stays independent and duplicate names do not write')

            # Existing preferences have no retained palette property. Migrate from
            # their active Custom colors without touching the real user's file.
            legacy_map = role_map(original).copy()
            legacy_map.pop('activePane', None)
            legacy_roles = [part for key, value in legacy_map.items() for part in (key, value)]
            preferences.write_text(json.dumps({'version': 1, 'preset': 'custom', 'roles': legacy_roles}))
            os.chmod(preferences, 0o600)
            with session() as ui:
                ui.wait('No items'); open_settings(ui); ui.send(RIGHT * 3); ui.settle(); save(ui)
                assert role_map(json.loads(preferences.read_text())) == role_map(original)
                assert preferences.stat().st_mode & 0o777 == 0o600
                checks.append('Legacy custom preferences seed retained colors, preserve private permissions and survive preset round trips')
            assert wire.manifest(root / 'store') == manifest
    result = {'status': 'passed', 'platform': platform.platform(), 'checks': checks, 'canonicalStoreUnchanged': True}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
