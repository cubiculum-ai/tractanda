#!/usr/bin/env python3
"""Validate and assemble one complete native Debian13 Linux bundle; never build or install.

Input is the closed payload produced by the separately reviewed native build recipe, plus
tractanda.linux-bundle-input.v1 JSON. There is no core-only or skip-admission mode.
"""
import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shlex
import shutil
import stat
import struct
import subprocess
import unicodedata

ROOT = Path(__file__).resolve().parents[1]
RESERVE = 10 * 1024**3
MAX_FILES = 20_000
MAX_DIRECTORIES = 20_000
MAX_FILE = 8 * 1024**3
ARCH = {'amd64': ('x86_64', 62, 'x86-64', 'x86_64-linux-gnu', '/lib64/ld-linux-x86-64.so.2'),
        'arm64': ('arm64', 183, 'armv8-a', 'aarch64-linux-gnu', '/lib/ld-linux-aarch64.so.1')}
CORE = ('tractanda', 'tractanda-tui', 'tractanda-mcp', 'tractanda-setup',
        'tractanda-auth-helper', 'tractanda-embeddings', 'tractanda-document-converter')
SEMANTIC_PROFILE = 'tractanda.peer-exchange.v2'
DEBIAN_PACKAGE_OWNER = re.compile(r'[a-z0-9][a-z0-9+.-]+(?::[a-z0-9][a-z0-9-]*)?')
PUBLIC = ('templates', 'examples', 'docs', 'plugins', 'LICENSES', 'LICENSE', 'NOTICE',
          'THIRD_PARTY_NOTICES.md', 'README.md', 'install.sh')


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


MAC = load_module('tractanda_existing_macos_assets', ROOT / 'scripts/package-macos.py')
digest = MAC.digest


def run(arguments, *, timeout_seconds=60, **kwargs):
    if (isinstance(timeout_seconds, bool) or not isinstance(timeout_seconds, (int, float))
            or not math.isfinite(timeout_seconds) or not 0 < timeout_seconds <= 2**31 - 1):
        raise ValueError('Tool timeout must be finite, positive and addressable.')
    environment = {key: value for key, value in os.environ.items() if key not in {'LD_LIBRARY_PATH', 'LD_PRELOAD', 'LD_AUDIT'}}
    environment['LC_ALL'] = 'C'
    result = subprocess.run(list(map(str, arguments)), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            check=False, timeout=timeout_seconds, env=environment, **kwargs)
    if result.returncode:
        raise ValueError(Path(str(arguments[0])).name + ' failed (exit ' + str(result.returncode)
                         + '): ' + result.stderr.decode(errors='replace')[:2048])
    return result.stdout.decode('utf-8')


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate JSON key: ' + key)
        result[key] = value
    return result


def captured_bytes(path, maximum):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= maximum:
            raise ValueError('Expected a bounded regular input: ' + str(path))
        value = bytearray()
        while len(value) <= maximum:
            block = os.read(fd, min(1024**2, maximum + 1 - len(value)))
            if not block:
                break
            value.extend(block)
        after = os.fstat(fd)
        identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mode, s.st_mtime_ns, s.st_ctime_ns)
        if len(value) != before.st_size or len(value) > maximum or identity(before) != identity(after):
            raise ValueError('Bounded input changed during capture.')
        return bytes(value)
    finally:
        os.close(fd)


def read_json(path, maximum=1_048_576):
    return json.loads(captured_bytes(path, maximum), object_pairs_hook=unique)


class ManifestSnapshot(tuple):
    """Immutable admitted bytes; parsed dictionaries are fresh views, never a second authority."""
    def __new__(cls, raw):
        if not isinstance(raw, bytes) or not 0 < len(raw) <= 16 * 1024**2:
            raise ValueError('Manifest snapshot exceeds its byte bound.')
        json.loads(raw, object_pairs_hook=unique)
        return tuple.__new__(cls, (raw,))

    @property
    def raw(self): return self[0]

    @property
    def sha256(self): return hashlib.sha256(self.raw).hexdigest()

    def manifest(self): return json.loads(self.raw, object_pairs_hook=unique)


def capture_manifest(root):
    return ManifestSnapshot(captured_bytes(root / 'bundle-manifest.json', 16 * 1024**2))


def unchanged_manifest(root, snapshot):
    if captured_bytes(root / 'bundle-manifest.json', 16 * 1024**2) != snapshot.raw:
        raise ValueError('Admitted manifest snapshot changed during packaging.')


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def safe_path(name):
    p = PurePosixPath(name)
    if (not name or name == '.' or p.is_absolute() or str(p) != name or '..' in p.parts or '\\' in name
            or len(name.encode()) > 1024 or any(ord(c) < 32 or ord(c) == 127 for c in name)):
        raise ValueError('Unsafe payload path: ' + repr(name))
    return name


def inventory(root, exclude=()):
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Payload root must be a real directory.')
    result = []
    seen = set()
    directory_count = 1
    def failed(error): raise error
    for directory, dirs, names in os.walk(root, followlinks=False, onerror=failed):
        directory_count += len(dirs)
        if directory_count > MAX_DIRECTORIES or len(dirs) + len(names) > MAX_FILES + MAX_DIRECTORIES:
            raise ValueError('Payload directory/entry count exceeds the bounded inventory.')
        for name in sorted(dirs + names):
            path = Path(directory) / name
            info = path.lstat()
            relative = safe_path(path.relative_to(root).as_posix())
            folded = unicodedata.normalize('NFC', relative).casefold()
            if folded in seen:
                raise ValueError('Payload names collide under the shared manifest normalization.')
            seen.add(folded)
            if not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)) or info.st_mode & 0o7022:
                raise ValueError('Payload links, special files, special bits or writable entries are forbidden: ' + relative)
            if stat.S_ISREG(info.st_mode):
                if relative in exclude:
                    continue
                if info.st_size > MAX_FILE or len(result) >= MAX_FILES:
                    raise ValueError('Payload file count/size exceeds the existing manifest bounds.')
                result.append(dict(path=relative, sha256=digest(path), size=info.st_size, mode=info.st_mode & 0o777))
    return sorted(result, key=lambda row: row['path'])


def capacity(parent, additional, maximum):
    fs = os.statvfs(parent)
    if (type(additional) is not int or additional < 0 or additional > maximum or maximum <= 0
            or fs.f_frsize <= 0 or fs.f_bavail < 0 or fs.f_bavail * fs.f_frsize - additional < RESERVE):
        raise ValueError('Staging estimate or genuine10GiB reserve rejected.')


def owned_storage(root, maximum, additional=0):
    """Actual owned allocation, including directories and a compressor's private temporary tree."""
    capacity(root, additional, maximum)
    total, entries = 0, 0
    def failed(error): raise error
    for directory, dirs, names in os.walk(root, followlinks=False, onerror=failed):
        if len(dirs) + len(names) > MAX_FILES + MAX_DIRECTORIES:
            raise ValueError('Owned staging directory has too many entries.')
        for path in [Path(directory)] + [Path(directory) / v for v in names]:
            info = path.lstat()
            entries += 1
            if (entries > MAX_FILES + MAX_DIRECTORIES + 1 or info.st_uid != os.geteuid()
                    or not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode))):
                raise ValueError('Owned stage has an unsafe type, owner or entry count.')
            total += info.st_blocks * 512
            if total + additional > maximum:
                raise ValueError('Owned staging allocation exceeded the declared byte budget.')
        if any((Path(directory) / v).is_symlink() for v in dirs):
            raise ValueError('Owned staging directory contains a link.')
    capacity(root, additional, maximum)
    return total


def copy_verified(source, target, row, maximum):
    fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_size != row['size']:
            raise ValueError('Source changed before bounded payload copy.')
        target.parent.mkdir(parents=True, exist_ok=True)
        copied, checksum = 0, hashlib.sha256()
        with target.open('xb') as output:
            while copied < row['size']:
                count = min(1024 * 1024, row['size'] - copied)
                capacity(target.parent, count, maximum)
                block = os.read(fd, count)
                if not block:
                    raise ValueError('Source was truncated during payload copy.')
                output.write(block)
                checksum.update(block)
                copied += len(block)
            if os.read(fd, 1):
                raise ValueError('Source grew during payload copy.')
        after = os.fstat(fd)
        identity = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mode, value.st_mtime_ns, value.st_ctime_ns)
        if identity(before) != identity(after) or checksum.hexdigest() != row['sha256']:
            raise ValueError('Source identity/content changed during bounded copy.')
        target.chmod(row['mode'])
    finally:
        os.close(fd)


def native_baseline(arch):
    if arch not in ARCH or platform.system() != 'Linux':
        raise ValueError('Package assembly requires native Linux Debian13.')
    actual = platform.machine()
    if actual not in (('x86_64', 'amd64') if arch == 'amd64' else ('arm64', 'aarch64')):
        raise ValueError('Native builder architecture differs from the requested package.')
    values = {}
    for line in Path('/etc/os-release').read_text().splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            values[key] = value.strip('"')
    if values.get('ID') != 'debian' or values.get('VERSION_ID', '').split('.')[0] != '13':
        raise ValueError('Finished packages require the Debian13 baseline; Kali source evidence is supplementary.')
    return dict(os='debian13', arch=arch, minimumCPU=ARCH[arch][2],
                dpkgVersion=run(['dpkg-deb', '--version']).splitlines()[0],
                readelfVersion=run(['readelf', '--version']).splitlines()[0])


def elf(path, arch):
    with path.open('rb') as stream:
        header = stream.read(64)
    if (len(header) != 64 or header[:7] != b'\x7fELF\x02\x01\x01'
            or header[7] not in (0, 3) or struct.unpack_from('<H', header, 16)[0] not in (2, 3)
            or struct.unpack_from('<H', header, 18)[0] != ARCH[arch][1]):
        raise ValueError('Expected a real64-bit little-endian ELF for ' + arch + ': ' + str(path))
    dynamic = run(['readelf', '--wide', '--dynamic', path])
    segments = run(['readelf', '--wide', '--program-headers', path])
    notes = run(['readelf', '--wide', '--notes', path])
    versions = run(['readelf', '--wide', '--version-info', path])
    if re.search(r'\((?:FILTER|AUXILIARY|AUDIT|DEPAUDIT)\)', dynamic):
        raise ValueError('Unsupported implicit ELF loader dependency.')
    needed = re.findall(r'\(NEEDED\).*?\[([^\]]+)\]', dynamic)
    sonames = re.findall(r'\(SONAME\).*?\[([^\]]+)\]', dynamic)
    rpaths = re.findall(r'\((?:RPATH|RUNPATH)\).*?\[([^\]]*)\]', dynamic)
    interpreters = re.findall(r'Requesting program interpreter:\s*([^\]]+)\]', segments)
    if len(sonames) > 1 or len(interpreters) > 1 or any('/' in v or not re.fullmatch(r'[A-Za-z0-9_.+-]+', v) for v in needed + sonames):
        raise ValueError('ELF dependency/SONAME/interpreter metadata is ambiguous.')
    if interpreters and interpreters[0] != ARCH[arch][4]:
        raise ValueError('ELF uses an unapproved interpreter.')
    if any(marker in notes for marker in ('x86-64-v2', 'x86-64-v3', 'x86-64-v4')):
        raise ValueError('ELF requires an ISA above the declared x86-64 baseline.')
    glibc = [tuple(map(int, v.split('.'))) for v in re.findall(r'\bGLIBC_([0-9]+\.[0-9]+)\b', versions)]
    if glibc and max(glibc) > (2, 41):
        raise ValueError('ELF requires glibc newer than the Debian13 baseline.')
    return dict(needed=needed, soname=sonames[0] if sonames else None,
                searchPaths=[p for value in rpaths for p in value.split(':')],
                interpreter=interpreters[0] if interpreters else None)


def _dpkg_search_owners(output, path):
    suffix = ': ' + str(path)
    owners = set()
    for line in output.splitlines():
        if line.endswith(suffix):
            owner = line[:-len(suffix)]
            if DEBIAN_PACKAGE_OWNER.fullmatch(owner):
                owners.add(owner)
    return owners


def system_library(soname, arch):
    triple = ARCH[arch][3]
    candidates = [Path(parent) / soname for parent in ('/usr/lib/' + triple, '/lib/' + triple, '/usr/lib', '/lib')]
    files = {p.resolve() for p in candidates if p.exists()}
    if len(files) != 1:
        raise ValueError('Missing or ambiguous OS dependency: ' + soname)
    path = files.pop()
    if not str(path).startswith('/usr/lib/') or not path.is_file():
        raise ValueError('OS library escaped Debian system directories.')
    packages = set()
    # Debian usr-merge aliases can differ from the spelling retained in dpkg's file list.
    for alias in sorted({path, *[p for p in candidates if p.exists() and p.resolve() == path]}):
        answer = subprocess.run(['dpkg-query', '--search', str(alias)], capture_output=True, text=True,
                                timeout=15, env=dict(os.environ, LC_ALL='C'))
        if answer.returncode not in (0, 1):
            raise ValueError('Debian ownership query failed.')
        # dpkg-query --search also emits free-form "diversion by ..." rows.
        # Only a real Debian binary-package[:arch] prefix is an owner.
        packages.update(_dpkg_search_owners(answer.stdout, alias))
    if len(packages) != 1:
        raise ValueError('OS library has no unique owning Debian package.')
    package = packages.pop()
    fields = run(['dpkg-query', '--show', '--showformat=${binary:Package}\t${Version}\t${Architecture}\n', package]).strip().split('\t')
    if (len(fields) != 3 or fields[2] != arch or not re.fullmatch(r'[a-z0-9][a-z0-9+.-]+(?::(?:amd64|arm64))?', fields[0])
            or not re.fullmatch(r'[0-9][A-Za-z0-9.+:~\-]*', fields[1]) or fields[0].split(':')[0].endswith('-dev')):
        raise ValueError('OS dependency is not an architecture-bound runtime package.')
    return path, dict(soname=soname, path=str(path), sha256=digest(path), package=fields[0].split(':')[0], version=fields[1])


def runtime_closure(root, rows, arch, dynamic_loads):
    private = {}
    for row in rows:
        path = root / row['path']
        with path.open('rb') as stream:
            magic = stream.read(4)
        if magic == b'\x7fELF':
            private[row['path']] = elf(path, arch)
    if any('bin/' + name not in private for name in CORE):
        raise ValueError('Every required first-party/helper executable must be an actual matching ELF.')
    if not isinstance(dynamic_loads, list) or len(set(dynamic_loads)) != len(dynamic_loads) or any(v not in private for v in dynamic_loads):
        raise ValueError('Explicit dlopen roots must be unique bundled ELF files.')
    sonames = {}
    for relative, info in private.items():
        name = info['soname']
        if name:
            if name in ('libc.so.6', 'libm.so.6', 'libpthread.so.0', 'libdl.so.2', 'librt.so.1') or name.startswith('ld-linux'):
                raise ValueError('The Debian libc/loader ABI must remain an explicit OS dependency.')
            if name in sonames:
                raise ValueError('Conflicting private SONAME: ' + name)
            sonames[name] = relative
    external, edges, queue = {}, {}, list(private)
    while queue:
        relative = queue.pop()
        info = private[relative] if relative in private else external[relative]['elf']
        bundled = relative in private
        for search in info['searchPaths']:
            if not bundled or not (search == '$ORIGIN' or search.startswith('$ORIGIN/')) or '$' in search[len('$ORIGIN'):] or not search:
                raise ValueError('Absolute, empty or unsupported ELF search path: ' + relative)
            resolved = (root / relative).parent.joinpath(search[len('$ORIGIN'):].lstrip('/')).resolve()
            if not resolved.is_relative_to(root.resolve()):
                raise ValueError('ELF search path escapes the closed bundle.')
        targets = []
        for needed in info['needed'] + ([Path(info['interpreter']).name] if info['interpreter'] else []):
            searches = [(root / relative).parent / p[len('$ORIGIN'):].lstrip('/') for p in info['searchPaths']] if bundled else []
            shadows = {(p / needed).resolve() for p in searches if (p / needed).exists()}
            if shadows and (needed not in sonames or shadows != {(root / sonames[needed]).resolve()}):
                raise ValueError('Private file shadows a different/unbound ELF dependency: ' + needed)
            if needed in sonames:
                target = sonames[needed]
                if not bundled or not any((p / needed).resolve() == (root / target).resolve() for p in searches):
                    raise ValueError('Private dependency is not reachable by the actual ELF search paths: ' + needed)
                targets.append(dict(soname=needed, private=target))
            else:
                if needed not in external:
                    path, provider = system_library(needed, arch)
                    provider['elf'] = elf(path, arch)
                    external[needed] = provider
                    queue.append(needed)
                targets.append(dict(soname=needed, system=external[needed]['path']))
        edges[relative] = targets
    depends = sorted({v['package'] + ' (>= ' + v['version'] + ')' for v in external.values()})
    return dict(profile='tractanda.linux-runtime-closure.v1', arch=arch,
                privateELF=sorted(private), dynamicLoads=sorted(dynamic_loads), edges=edges,
                osLibraries=[{k: v for k, v in value.items() if k != 'elf'} for _, value in sorted(external.items())],
                depends=depends, qualification='ELF/dlopen declarations are necessary; actual inference/extraction and minimum-CPU execution remain separate acceptance gates.')


def global_isa_flags(flags, arch):
    if not isinstance(flags, list) or len(flags) > 256 or not all(isinstance(v, str) and len(v) <= 1024 for v in flags):
        raise ValueError('Malformed normalized global compiler flags.')
    tokens = []
    for value in flags:
        if any(ord(c) < 32 or ord(c) == 127 for c in value):
            raise ValueError('Control character in compiler flags.')
        for token in shlex.split(value):
            forwarded = re.fullmatch(r'(-X(?:cc|clang|frontend|llvm|linker))=(.*)', token)
            tokens.extend(forwarded.groups() if forwarded else [token])
    # Split driver forwarding has the same policy as joined -Wl, options. Keep harmless
    # linker routing (for example rpath) without hiding LTO CPU/plugin selections.
    normalized, index = [], 0
    while index < len(tokens):
        if tokens[index] == '-Xlinker':
            index += 1
            if index >= len(tokens): raise ValueError('Missing forwarded linker argument.')
            normalized.append('-Wl,' + tokens[index])
        else:
            normalized.append(tokens[index])
        index += 1
    tokens = normalized
    # Routing wrappers do not hide their C/Swift backend selections. Unreviewed arbitrary LLVM
    # or assembler/plugin code-generation forwarding is refused rather than guessed safe.
    if any(v == '-Xllvm' or v.startswith(('-Wa,', '@', '-Wl,@'))
           or v.startswith('-Wl,') and any(key in v for key in ('plugin', 'mllvm', 'target-cpu', 'target-feature', 'mattr', 'mcpu', 'march', 'lto-cpu'))
           for v in tokens):
        raise ValueError('Unsupported forwarded global ISA/backend flags.')
    tokens = [v for v in tokens if v not in ('-Xcc', '-Xclang', '-Xfrontend')]
    baseline_features = {'amd64': {'+sse', '+sse2', '+x87', '+mmx', '+fxsr', '+cx8', '+64bit'},
                         'arm64': {'+neon', '+fp-armv8'}}[arch]
    target = 'x86_64-unknown-linux-gnu' if arch == 'amd64' else 'aarch64-unknown-linux-gnu'
    index = 0
    while index < len(tokens):
        token = tokens[index]
        key, separator, argument = token.partition('=')
        if key in ('-march', '-mcpu', '-mtune', '-target-cpu', '-target-feature', '-target', '--target'):
            if not separator:
                index += 1
                if index >= len(tokens): raise ValueError('Missing global CPU/target flag argument.')
                argument = tokens[index]
            if key == '-target-feature':
                allowed = argument in baseline_features or re.fullmatch(r'-[a-z0-9_.-]+', argument)
            elif key in ('-target', '--target'):
                allowed = argument == target
            else:
                allowed = argument in (ARCH[arch][2], 'generic')
            if not allowed: raise ValueError('Global compiler flags exceed the distributable ISA baseline.')
        elif token.startswith(('-m', '--m', '-target-', '--target-')):
            swift_structural = token.startswith(('-module-', '-main-file-name', '-merge-modules', '-min-runtime-version'))
            disabling = re.fullmatch(r'-mno-[a-z0-9_.-]+', token)
            baseline_switch = arch == 'amd64' and token in ('-m64', '-msse', '-msse2')
            if not (swift_structural or disabling or baseline_switch):
                raise ValueError('Unsupported stronger global machine/ISA flag: ' + token)
        index += 1


def validate_spec(value, arch):
    required = {'profile', 'version', 'arch', 'minimumCPU', 'sourceInputsSHA256', 'buildFlags',
                'semanticProfile', 'documentExtraction', 'dynamicLoads', 'runtimeNotices'}
    if (not isinstance(value, dict) or set(value) != required or value['profile'] != 'tractanda.linux-bundle-input.v1'
            or value['arch'] != arch or value['minimumCPU'] != ARCH[arch][2]
            or not re.fullmatch(r'[0-9][A-Za-z0-9._+\-]{0,79}', value['version'])
            or not re.fullmatch(r'[0-9a-f]{64}', value['sourceInputsSHA256'])
            or value['semanticProfile'] != SEMANTIC_PROFILE):
        raise ValueError('Unsupported complete Linux build-input contract.')
    global_isa_flags(value['buildFlags'], arch)
    if not isinstance(value['runtimeNotices'], list) or not value['runtimeNotices']:
        raise ValueError('Private runtime notices must be declared explicitly.')
    for path in value['runtimeNotices']:
        safe_path(path)
        if not path.startswith('licenses/'):
            raise ValueError('Runtime notice escaped the closed license payload.')
    return value


def public_assets(root):
    # Same reviewed Git index, selection, mode and LICENSES projection as package-macos.py.
    run(['git', '-C', ROOT, 'diff', '--exit-code', '--quiet', '--', *PUBLIC])
    raw = run(['git', '-C', ROOT, 'ls-files', '--stage', '-z', '--', *PUBLIC])
    if not raw:
        raise ValueError('A reviewed public Git asset set is required.')
    for record in raw.split('\0'):
        if not record:
            continue
        metadata, name = record.split('\t', 1)
        mode, object_id, stage = metadata.split()
        if mode not in ('100644', '100755') or stage != '0':
            raise ValueError('Public source index contains an unapproved type/stage.')
        safe_path(name)
        relative = 'licenses/' + name[len('LICENSES/'):] if name.startswith('LICENSES/') else name
        path = root / relative
        if (not path.is_file() or path.is_symlink() or path.stat().st_mode & 0o777 != int(mode, 8) & 0o777
                or run(['git', '-C', ROOT, 'hash-object', '--no-filters', path]).strip() != object_id):
            raise ValueError('Missing/changed reviewed macOS-parity public asset: ' + relative)


def full_components(root, spec, rows, embedding_runner=None):
    names = {v['path'] for v in rows}
    if not any(v.startswith('bin/Tractanda_TractandaWeb.resources/') or v.startswith('bin/Tractanda_TractandaWeb.bundle/') for v in names):
        raise ValueError('The web resource bundle is mandatory.')
    embedding = MAC.embedding_descriptor(root / 'bin/tractanda-embeddings', root / 'models/granite-embedding-311m-multilingual-r2',
                                         runner=embedding_runner)
    document = spec['documentExtraction']
    if (not isinstance(document, dict) or document.get('converterPath') != 'bin/tractanda-document-converter'
            or document.get('modelDirectory') != 'models/granite-docling-258m-mlx'
            or document.get('modelManifestSHA256') != MAC.MODEL_MANIFEST_SHA
            or document.get('runtimePatchManifestSHA256') != MAC.PATCH_MANIFEST_SHA):
        raise ValueError('Complete pinned local document descriptor is mandatory.')
    if digest(ROOT / MAC.MODEL_MANIFEST) != MAC.MODEL_MANIFEST_SHA:
        raise ValueError('Pinned Docling source model manifest changed.')
    MAC.validate_docling_model(root / document['modelDirectory'])
    required = list(spec['runtimeNotices']) + list(document.get('noticePaths', [])) + [
        'licenses/Granite/' + v for v in ('LICENSE', 'README.md', 'NOTICE', 'Gemma-Terms.html', 'Gemma-Prohibited-Use-Policy.html')]
    for key, expected in [('modelManifestPath', MAC.MODEL_MANIFEST_SHA), ('runtimePatchManifestPath', MAC.PATCH_MANIFEST_SHA),
                          ('runtimePatchPath', document.get('runtimePatchSHA256'))]:
        path = safe_path(document[key])
        if path not in names or not re.fullmatch(r'[0-9a-f]{64}', expected or '') or digest(root / path) != expected:
            raise ValueError('Document model/runtime provenance bytes differ: ' + path)
    for path in required:
        safe_path(path)
        if path not in names:
            raise ValueError('Missing bundled model/runtime license: ' + path)
    # Converter identity/closure admission belongs to the actual shipped Setup's finite table.
    # No prefix, arbitrary closure hash, descriptor assertion or fake --describe API admits it.
    return embedding, document


def verify_bundle(root, arch, snapshot=None):
    snapshot = snapshot if snapshot is not None else capture_manifest(root)
    unchanged_manifest(root, snapshot)
    manifest = snapshot.manifest()
    rows = inventory(root, exclude=('bundle-manifest.json',))
    if (manifest.get('profile') != 'tractanda.bundle.v1' or manifest.get('platform') != 'linux'
            or manifest.get('arch') != ARCH[arch][0] or manifest.get('files') != rows
            or not manifest.get('embedding') or not manifest.get('documentExtraction')):
        raise ValueError('Bundle is incomplete, changed or belongs to another architecture.')
    run([root / 'bin/tractanda-setup', 'plan', '--bundle', root])
    unchanged_manifest(root, snapshot)
    return manifest


def assemble(payload, spec_path, output, arch, maximum, embedding_runner=None):
    baseline = native_baseline(arch)
    spec = validate_spec(read_json(spec_path), arch)
    if payload.is_symlink():
        raise ValueError('Prepared payload root cannot be a symlink.')
    payload = payload.resolve(strict=True)
    output = output.parent.resolve(strict=True) / output.name
    if output.exists() or output.is_symlink() or not output.parent.is_dir() or output.is_relative_to(payload) or payload.is_relative_to(output):
        raise ValueError('Output must be a fresh non-overlapping directory with an existing parent.')
    rows = inventory(payload)
    if any(v['path'] == 'bundle-manifest.json' for v in rows):
        raise ValueError('Input payload must not carry a stale generated bundle manifest.')
    public_assets(payload)
    closure = runtime_closure(payload, rows, arch, spec['dynamicLoads'])
    embedding, document = full_components(payload, spec, rows, embedding_runner=embedding_runner)
    formats = json.loads(run([payload / 'bin/tractanda-setup', '--canonical-format-support']), object_pairs_hook=unique)
    if not isinstance(formats, dict) or set(formats) != {'profile', 'readerLevel', 'writerLevel', 'read', 'write', 'capabilities', 'writeCapabilities'}:
        raise ValueError('Actual Setup canonical capability declaration is invalid.')
    metadata = canonical(dict(profile='tractanda.linux-bundle-build.v1', baseline=baseline, input=spec, runtimeClosure=closure)) + b'\n'
    if any(v['path'] == 'lib/tractanda/linux-bundle-build.json' for v in rows):
        raise ValueError('Generated build receipt collides with the prepared payload.')
    total = sum(v['size'] for v in rows) + len(metadata) + 16 * 1024**2
    capacity(output.parent, total, maximum)
    output.mkdir(mode=0o755)
    for row in rows:
        source, target = payload / row['path'], output / row['path']
        copy_verified(source, target, row, maximum)
    receipt = output / 'lib/tractanda/linux-bundle-build.json'
    receipt.parent.mkdir(parents=True, exist_ok=True)
    receipt.write_bytes(metadata)
    receipt.chmod(0o644)
    manifest = dict(profile='tractanda.bundle.v1', version=spec['version'], platform='linux', arch=ARCH[arch][0],
                    files=inventory(output), canonicalFormats=formats, embedding=embedding, documentExtraction=document)
    snapshot = ManifestSnapshot(canonical(manifest) + b'\n')
    (output / 'bundle-manifest.json').write_bytes(snapshot.raw)
    (output / 'bundle-manifest.json').chmod(0o644)
    verify_bundle(output, arch, snapshot)  # Current Linux Docling gate remains closed until real R2 admission.
    owned_storage(output, maximum)
    return dict(bundle=str(output), manifestSHA256=snapshot.sha256,
                logicalBytes=sum(v['size'] for v in manifest['files']), files=len(manifest['files']),
                depends=closure['depends'], complete=True, installed=False, published=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--payload', type=Path, required=True)
    parser.add_argument('--input-spec', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--arch', choices=ARCH, required=True)
    parser.add_argument('--max-stage-bytes', type=int, required=True)
    args = parser.parse_args()
    print(json.dumps(assemble(args.payload, args.input_spec, args.output, args.arch, args.max_stage_bytes), indent=2))


if __name__ == '__main__':
    main()
