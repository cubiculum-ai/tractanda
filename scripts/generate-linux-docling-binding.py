#!/usr/bin/env python3
"""Retain audited Docling helpers; historical recomposition fails closed.

The old CLI accepted converter bytes without an actual compiler input receipt.
Current Kali preparation imports these finite template/provider helpers but uses
its own receipt-bound compiler result and complete native closure audit.
"""
import argparse, hashlib, importlib.util, json, re, subprocess
from pathlib import Path

if not __debug__:
    raise RuntimeError("Docling provenance validation must not run with Python optimization enabled.")

ROOT = Path(__file__).resolve().parents[1]
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module
C = load('component', ROOT / 'scripts/build-linux-ml-component.py'); P = C.P; B = C.B
N = load('normalization', ROOT / 'scripts/linux-docling-provenance.py')
TEMPLATES = {
    N.CLIENT: '21034618f181e500195630bef8d80134d69551596e01efa07b765b2a9bac3d8a',
    N.CONVERTER: 'c18067abb9a5263e6ef99978468572fb9c2eb22a46cb53594d0b0948a5c1aacb',
}
def digest(path):
    with path.open('rb') as f: return hashlib.file_digest(f, 'sha256').hexdigest()
def write(path, value):
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + '\n')
def required_versions(path):
    text = subprocess.check_output(['readelf', '--wide', '--version-info', str(path)], text=True)
    mode = None; current = None; needs = {}
    for line in text.splitlines():
        if line.startswith('Version needs section'): mode = 'needs'
        elif line.startswith('Version definition section') or line.startswith('Version symbols section'): mode = 'other'
        f = re.search(r'File:\s*(\S+)', line)
        if f: current = f.group(1)
        n = re.search(r'Name:\s*(\S+)', line)
        if n and mode == 'needs' and current: needs.setdefault(current, set()).add(n.group(1))
    return needs

def check_converter_elf(arch, facts, recorded, old_descriptor):
    # This single compiler-output delta was audited against the finite Debian supplier bundle;
    # it is not a general allowlist for new dependencies.
    needed = facts['needed']
    direct_zlib = (arch == 'amd64' and needed.count('libz.so.1') == 1
                   and [name for name in needed if name != 'libz.so.1'] == recorded['needed'])
    assert (needed == recorded['needed'] or direct_zlib) and facts['soname'] == recorded['soname'] and facts['searchPaths'] == recorded['runpath'], 'New converter requires fresh ELF closure audit'
    if direct_zlib:
        old_zlib = [x for x in old_descriptor['osDependencies'] if x['soname'] == 'libz.so.1']
        assert len(old_zlib) == 1 and old_zlib[0]['provider'] == 'zlib1g' and old_zlib[0]['version'] == '1:1.3.dfsg+really1.3.1-1+b1'
        zlib_path, zlib_provider = B.system_library('libz.so.1', arch)
        assert zlib_provider['package'] == old_zlib[0]['provider'] and zlib_provider['version'] == old_zlib[0]['version']
        assert digest(zlib_path) == '85590dd58edf5445e18bc7193e5ebc01ac5841f1ae187e97705a662e90c6421e'
    return needed, direct_zlib

def prepare(arch, component_root, manifest, converter, toolchain, output):
    raise ValueError(
        "Historical Docling recomposition lacks an actual compiler input receipt; "
        "use build-linux-ml-component.py and prepare-kali-linux-component.py "
        "with a fresh bound compiler result. New Debian components require a "
        "reviewed receipt-bound preparation route for that baseline.")

def main():
    a = argparse.ArgumentParser(description=__doc__); a.add_argument('--arch', required=True, choices=('amd64', 'arm64')); a.add_argument('--component-root', required=True, type=Path); a.add_argument('--manifest', required=True, type=Path); a.add_argument('--converter', required=True, type=Path); a.add_argument('--toolchain', required=True, type=Path); a.add_argument('--output', required=True, type=Path); x = a.parse_args(); print(json.dumps(prepare(x.arch, x.component_root, x.manifest, x.converter, x.toolchain, x.output), indent=2))
if __name__ == '__main__': main()
