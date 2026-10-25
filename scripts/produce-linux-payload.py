#!/usr/bin/env python3
"""Build the fixed core, merge admitted local ML components, invoke the full D3 gate.

No downloads, installation, model inference, release or incomplete-output mode. The
tracked input registry deliberately starts unadmitted. See linux-payload-producer.md.
"""
import argparse
import math
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import time
import unicodedata

ROOT = Path(__file__).resolve().parents[1]
import importlib.util
_spec = importlib.util.spec_from_file_location('linux_bundle', ROOT / 'scripts/package-linux.py')
B = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(B)
REGISTRY = ROOT / 'debian/linux-runtime-inputs.json'
COMPONENTS = ('embeddings', 'documents')
PRODUCTS = ('tractanda', 'tractanda-tui', 'tractanda-mcp', 'tractanda-auth-helper', 'tractanda-setup')
PROBE_BYTES = 64 * 1024
COMPILER_THREADS = 4
RUNTIME = '61a4b20d4ad01b10466e8fc94c50402a9f994430'
MODELS = {'embeddings': '44399559930365213510b1ee2eb15ded83374f0e',
          'documents': 'a8b999991fe8c521a0cec749973414eaaf823731'}
MODEL_DIRS = {'embeddings': 'models/granite-embedding-311m-multilingual-r2',
              'documents': 'models/granite-docling-258m-mlx'}
SOURCE_LIMIT = 128 * 1024**2
SKIP = {'.git', '.build', '.swiftpm', '__pycache__'}
SOURCE_ROOTS = ('Sources', 'Tests', 'Packages', 'scripts')
SOURCE_FILES = ('Package.swift', 'Package.resolved', 'VERSION', 'scripts/produce-linux-payload.py',
                'scripts/package-linux.py', 'scripts/package-macos.py', 'scripts/validate-docling-model.py',
                'debian/linux-runtime-inputs.json')


def sha(value):
    return hashlib.sha256(value).hexdigest()


def hash_string(value):
    return isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value) is not None


def build_storage(root, maximum, additional=0):
    """Account for bounded compiler scratch without relaxing source or payload guards."""
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Build-work root must be an owned real directory.')
    root = root.resolve(strict=True)
    B.capacity(root, additional, maximum)
    total, entries = 0, 0
    allowed = tuple((root / name).absolute() for name in ('modules', 'scratch', 'cache'))

    def failed(error):
        raise error

    for directory, dirs, names in os.walk(root, followlinks=False, onerror=failed):
        paths = ([Path(directory)] + [Path(directory) / name for name in names] +
                 [Path(directory) / name for name in dirs if (Path(directory) / name).is_symlink()])
        for path in paths:
            try:
                info = path.lstat()
            except FileNotFoundError:
                if path == root:
                    raise
                continue  # Compiler lock names can disappear between enumeration and lstat.
            entries += 1
            if entries > B.MAX_FILES + B.MAX_DIRECTORIES + 1 or info.st_uid != os.geteuid():
                raise ValueError('Unsafe build-work owner or entry count.')
            if stat.S_ISLNK(info.st_mode):
                parent = next((value for value in allowed if path.absolute().is_relative_to(value)), None)
                if parent is None or not path.resolve(strict=False).is_relative_to(parent):
                    raise ValueError('Build-work link escapes its admitted scratch subtree.')
            elif not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                raise ValueError('Unsafe build-work file type.')
            total += info.st_blocks * 512
            if total + additional > maximum:
                raise ValueError('Build-work allocation exceeded its declared budget.')
        dirs[:] = [name for name in dirs if not (Path(directory) / name).is_symlink()]
    B.capacity(root, additional, maximum)
    return total


def rows(root, roots=None, maximum=SOURCE_LIMIT, skip=()):
    """Bound real source/model/artifact trees, including dirty/untracked source files."""
    root = root.absolute()
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Input root must be a real directory: ' + str(root))
    result, total, entries = [], 0, 0
    names = list(roots) if roots is not None else ['.']
    pending = [root / name for name in names]
    seen, folded_names = set(), {}
    while pending:
        path = pending.pop()
        info = path.lstat()
        relative = path.relative_to(root).as_posix()
        folded = unicodedata.normalize('NFC', relative).casefold()
        if folded in folded_names and folded_names[folded] != relative:
            raise ValueError('Input paths collide under bundle normalization.')
        folded_names[folded] = relative
        entries += 1
        if entries > 40_000 or info.st_mode & 0o7022:
            raise ValueError('Input count or protected mode bound exceeded.')
        if stat.S_ISDIR(info.st_mode):
            pending.extend(sorted((v for v in path.iterdir() if v.name not in skip), reverse=True))
        elif stat.S_ISREG(info.st_mode):
            B.safe_path(relative)
            if relative in seen:
                continue
            seen.add(relative)
            total += info.st_size
            if total > maximum or info.st_size > B.MAX_FILE or len(result) >= B.MAX_FILES:
                raise ValueError('Input logical byte/file budget exceeded.')
            # Stable nofollow capture for tiny sources; stream large models with identity checks.
            with path.open('rb') as stream:
                before = os.fstat(stream.fileno())
                checksum = hashlib.file_digest(stream, 'sha256').hexdigest()
                after = os.fstat(stream.fileno())
            identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns, s.st_mode)
            if identity(info) != identity(before) or identity(before) != identity(after):
                raise ValueError('Input changed while hashing: ' + relative)
            result.append(dict(path=relative, sha256=checksum, size=info.st_size, mode=info.st_mode & 0o777))
        else:
            raise ValueError('Input links/special files are forbidden: ' + relative)
    return sorted(result, key=lambda v: v['path'])


def source_rows(root=ROOT):
    # Public payload uses the identical index selection as macOS, never arbitrary docs/research.
    indexed = B.run(['git', '-C', root, 'ls-files', '-z', '--', *B.PUBLIC]).split('\0')
    extra = [v for v in indexed if v]
    return rows(root, (*SOURCE_ROOTS, *SOURCE_FILES, *extra), skip=SKIP)


def registry(arch):
    value = B.read_json(REGISTRY)
    if (set(value) != {'profile', 'runtimeRevision', 'architectures'}
            or value['profile'] != 'tractanda.linux-runtime-inputs.v1' or value['runtimeRevision'] != RUNTIME
            or set(value['architectures']) != set(B.ARCH)):
        raise ValueError('Tracked packaging input registry is invalid.')
    for entries in value['architectures'].values():
        if set(entries) != set(COMPONENTS) or any(v is not None and not hash_string(v) for v in entries.values()):
            raise ValueError('Registry entries must be reviewed normalized manifest hashes or null.')
    return value['architectures'][arch]


def require_admitted(arch):
    entries = registry(arch)
    missing = [v for v in COMPONENTS if entries[v] is None]
    if missing:
        raise ValueError('Unadmitted ' + arch + ' components: ' + ', '.join(missing)
                         + '. Review stable component artifacts/recipes and runtime identity first; no build/model copy started.')
    return entries


def file_entry(value):
    if (not isinstance(value, dict) or set(value) != {'path', 'sha256', 'size', 'mode'}
            or not hash_string(value['sha256']) or type(value['size']) is not int or not 0 <= value['size'] <= B.MAX_FILE
            or type(value['mode']) is not int or value['mode'] not in (0o644, 0o755)):
        raise ValueError('Component file entry is not the closed payload entry shape.')
    B.safe_path(value['path'])
    return value


def component(path, root, role, arch, expected):
    value = B.read_json(path, 16 * 1024**2)
    keys = {'profile', 'component', 'arch', 'baseline', 'modelRevision', 'runtimeRevision', 'sourceInputsSHA256',
            'recipe', 'patches', 'toolchain', 'files', 'dynamicLoads', 'runtimeNotices', 'documentExtraction'}
    if (not isinstance(value, dict) or set(value) != keys or sha(B.canonical(value)) != expected
            or value['profile'] != 'tractanda.linux-component-artifacts.v1' or value['component'] != role
            or value['arch'] != arch or value['runtimeRevision'] != RUNTIME or value['modelRevision'] != MODELS[role]
            or not hash_string(value['sourceInputsSHA256'])
            or value['baseline'] != {'buildOS': 'debian13', 'minimumCPU': B.ARCH[arch][2], 'swiftABI': '6.4'}):
        raise ValueError('Unapproved or mismatched normalized component manifest: ' + role)
    tool = value['toolchain']
    if (not isinstance(tool, dict) or set(tool) != {'version', 'swiftSHA256', 'swiftFrontendSHA256', 'clangSHA256'}
            or not isinstance(tool['version'], str) or not tool['version'].startswith('Swift version 6.4')
            or any(not hash_string(tool[k]) for k in tool if k != 'version')):
        raise ValueError('Component Swift toolchain/ABI must be bound explicitly.')
    commitments = [value['recipe'], *value['patches']]
    if not commitments or len(commitments) > 128:
        raise ValueError('Component recipe/patch commitments exceed bounds.')
    for item in commitments:
        if not isinstance(item, dict) or set(item) != {'path', 'sha256'} or not hash_string(item['sha256']):
            raise ValueError('A tracked recipe/patch needs an exact source hash.')
        relative = B.safe_path(item['path'])
        if not relative.startswith(('scripts/', 'Packages/')) or B.digest(ROOT / relative) != item['sha256']:
            raise ValueError('Component tracked recipe/patch is missing or changed: ' + relative)
    actual = rows(root, maximum=64 * 1024**3)
    declared = [file_entry(v) for v in value['files']]
    if not declared or declared != actual:
        raise ValueError('Component artifact tree differs from its entire reviewed file inventory.')
    names = {v['path'] for v in declared}
    executable = 'bin/tractanda-' + ('embeddings' if role == 'embeddings' else 'document-converter')
    if executable not in names or any(p.startswith(('models/', 'docs/', 'templates/', 'examples/', 'plugins/'))
                                      or p in {'bin/' + v for v in PRODUCTS} for p in names):
        raise ValueError('Component must supply its helper/runtime/notices, without core/public/model ownership.')
    if next(v for v in declared if v['path'] == executable)['mode'] != 0o755:
        raise ValueError('Component helper is not executable.')
    if (not isinstance(value['dynamicLoads'], list) or len(value['dynamicLoads']) != len(set(value['dynamicLoads']))
            or any(p not in names for p in value['dynamicLoads']) or not value['runtimeNotices']
            or any(p not in names or not p.startswith('licenses/') for p in value['runtimeNotices'])):
        raise ValueError('Complete component runtime roots/notices must be declared.')
    if role == 'embeddings' and value['documentExtraction'] is not None:
        raise ValueError('Embedding component must not declare document identity.')
    if role == 'documents':
        required = {'lib/tractanda/document-native-closure.json',
                    'lib/tractanda/document-native/libtractanda_docling_pdf.so.1',
                    'lib/tractanda/document-native/libtractanda_docling_images.so.1'}
        if not required <= names or not isinstance(value['documentExtraction'], dict):
            raise ValueError('Full Docling native closure and exact descriptor are mandatory.')
    return value


def merge_files(source, target, entries, maximum):
    """An approved shared Swift library may occur in both components only identically."""
    for row in entries:
        destination = target / row['path']
        if destination.exists() or destination.is_symlink():
            if (destination.is_symlink() or not destination.is_file() or B.digest(destination) != row['sha256']
                    or destination.stat().st_size != row['size'] or destination.stat().st_mode & 0o777 != row['mode']):
                raise ValueError('Conflicting final payload path: ' + row['path'])
        else:
            B.copy_verified(source / row['path'], destination, row, maximum)
        B.owned_storage(target, maximum)


def merge_model_files(source, target, entries, maximum):
    """Project private model inputs into readable package files without changing sources."""
    if source.is_symlink() or not source.is_dir() or target.is_symlink() or target.exists():
        raise ValueError('Model source must be a real directory and package destination must be fresh.')

    def identity(info):
        return (info.st_dev, info.st_ino, info.st_size, info.st_mode, info.st_uid, info.st_gid,
                info.st_mtime_ns, info.st_ctime_ns)

    source_root = identity(source.lstat())
    source_rows = {}
    for row in entries:
        path = source / row['path']
        info = path.lstat()
        if (not stat.S_ISREG(info.st_mode) or info.st_size != row['size']
                or info.st_mode & 0o777 != row['mode']):
            raise ValueError('Model source size/mode differs from its captured input row: ' + row['path'])
        source_rows[row['path']] = identity(info)

    target.mkdir(mode=0o755, parents=True)
    merge_files(source, target, entries, maximum)
    projected = []
    for row in entries:
        source_file = source / row['path']
        if identity(source_file.lstat()) != source_rows[row['path']]:
            raise ValueError('Model source metadata changed during payload projection: ' + row['path'])
        package_file = target / row['path']
        info = package_file.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_size != row['size'] or info.st_mode & 0o777 != row['mode']:
            raise ValueError('Private model copy differs from its captured source row: ' + row['path'])
        # Keep private inputs at their captured permissions; only the package copy becomes readable.
        package_file.chmod(0o644)
        projected_info = package_file.lstat()
        if not stat.S_ISREG(projected_info.st_mode) or projected_info.st_size != row['size'] \
                or projected_info.st_mode & 0o777 != 0o644:
            raise ValueError('Model package projection has unexpected size or mode: ' + row['path'])
        if identity(source_file.lstat()) != source_rows[row['path']]:
            raise ValueError('Model source metadata changed during package mode projection: ' + row['path'])
        projected.append({**row, 'mode': 0o644})

    for directory, children, _files in os.walk(target, topdown=True, followlinks=False):
        path = Path(directory)
        for name in children:
            child = path / name
            info = child.lstat()
            if not stat.S_ISDIR(info.st_mode):
                raise ValueError('Model package tree contains a linked or non-directory entry.')
            child.chmod(0o755)
        path.chmod(0o755)
    if identity(source.lstat()) != source_root:
        raise ValueError('Model source directory metadata changed during package projection.')
    B.owned_storage(target, maximum)
    return {'inputFiles': entries, 'payloadFiles': projected, 'sourceMetadataUnchanged': True}


def build_environment():
    packages = ('build-essential', 'libpam0g-dev', 'libsqlite3-dev', 'uuid-dev', 'pkgconf',
                'patchelf', 'git', 'binutils', 'libc6-dev')
    versions = B.run(['/usr/bin/dpkg-query', '-W', '-f=${Package}\t${Version}\t${Status}\n', *packages])
    if any(not line.endswith('\tinstall ok installed') for line in versions.splitlines()) or len(versions.splitlines()) != len(packages):
        raise ValueError('Required Debian build packages are not fully installed.')
    return {'packages': sorted(versions.splitlines()), 'patchelfSHA256': B.digest(Path('/usr/bin/patchelf')),
            'gitSHA256': B.digest(Path('/usr/bin/git')), 'systemCCSHA256': B.digest(Path('/usr/bin/cc'))}


def controlled_environment(work, tool_bin):
    environment = {'PATH': str(tool_bin) + ':/usr/bin:/bin', 'LC_ALL': 'C', 'LANG': 'C',
                   'HOME': str(work / 'home'), 'TMPDIR': str(work / 'tmp'),
                   'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
                   'GIT_ALLOW_PROTOCOL': 'file', 'GIT_TERMINAL_PROMPT': '0',
                   'GIT_CONFIG_COUNT': '2', 'GIT_CONFIG_KEY_0': 'gc.auto', 'GIT_CONFIG_VALUE_0': '0',
                   'GIT_CONFIG_KEY_1': 'maintenance.auto', 'GIT_CONFIG_VALUE_1': 'false',
                   'SWIFTPM_MODULECACHE_OVERRIDE': str(work / 'modules'),
                   'CLANG_MODULE_CACHE_PATH': str(work / 'modules')}
    return environment


def write_json(path, value):
    raw = B.canonical(value) + b'\n'
    # Write the operation checkpoint before launching its child; replace atomically.
    temporary = path.with_suffix('.new')
    path.parent.mkdir(parents=True, exist_ok=True)
    with temporary.open('wb') as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try: os.fsync(directory)
    finally: os.close(directory)


DEFAULT_BUILD_TIMEOUT_SECONDS = 24 * 60 * 60
DEFAULT_TOOLCHAIN_PROBE_TIMEOUT_SECONDS = 30 * 60


def timeout_seconds(value):
    """Finite operator wall budget, not an implicit fast-machine performance test."""
    try:
        if isinstance(value, bool): raise ValueError()
        seconds = float(value)
    except (TypeError, ValueError) as error:
        raise argparse.ArgumentTypeError('Timeout must be finite, positive and addressable.') from error
    if not math.isfinite(seconds) or not 0 < seconds <= 2**31 - 1:
        raise argparse.ArgumentTypeError('Timeout must be finite, positive and addressable.')
    return seconds


def child(arguments, work, environment, maximum, timeout=DEFAULT_BUILD_TIMEOUT_SECONDS, capture=False, storage_guard=None):
    """Single foreground child owner, continuous capacity/log guards and wait/reap on every exit."""
    timeout = timeout_seconds(timeout)
    log = work / 'build.log'
    guard = B.owned_storage if storage_guard is None else storage_guard
    guard(work, maximum)
    write_json(work / 'operation.json', dict(state='launching', command=list(map(str, arguments)), log=str(log), timeoutSeconds=timeout))
    process = None
    captured = work / 'probe-output.json' if capture else None
    capture_created = False
    started = time.monotonic()
    try:
        with ExitStack() as streams:
            output = streams.enter_context(log.open('ab', buffering=0))
            probe = None
            if captured is not None:
                fd = os.open(captured, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
                capture_created = True
                probe = streams.enter_context(os.fdopen(fd, 'wb', buffering=0))
            process = subprocess.Popen(list(map(str, arguments)), stdout=probe if capture else output,
                                       stderr=output if capture else subprocess.STDOUT,
                                       env=environment, cwd=work / 'source', start_new_session=True)
            write_json(work / 'operation.json', dict(state='running', pid=process.pid, command=list(map(str, arguments)), log=str(log), timeoutSeconds=timeout))
            while process.poll() is None:
                guard(work, maximum)
                if log.stat().st_size > 2 * 1024**2 or time.monotonic() - started > timeout:
                    raise ValueError('Build log/time bound exceeded.')
                if captured is not None and captured.stat().st_size > PROBE_BYTES:
                    raise ValueError('Embedding descriptor output bound exceeded.')
                time.sleep(0.25)
            status = process.wait()
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            guard(work, maximum)  # Includes a child that exited before the first poll.
            if log.stat().st_size > 2 * 1024**2:
                raise ValueError('Build log bound exceeded.')
            if time.monotonic() - started > timeout:
                raise ValueError('Build time bound exceeded.')
            if captured is not None and captured.stat().st_size > PROBE_BYTES:
                raise ValueError('Embedding descriptor output bound exceeded.')
            if status:
                raise ValueError('Build command failed, exit ' + str(status) + '; see ' + str(log))
        result = B.captured_bytes(captured, PROBE_BYTES).decode('utf-8') if captured is not None else None
    except BaseException:
        if process is not None:
            # Kill the owned session even if its leader already exited; reap the leader.
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            process.wait()
        write_json(work / 'operation.json', dict(state='failed', log=str(log)))
        raise
    finally:
        if capture_created:
            captured.unlink(missing_ok=True)
    write_json(work / 'operation.json', dict(state='completed', exitCode=0, log=str(log)))
    return result


def descriptor_runner(work, environment, maximum, storage_guard=None):
    def describe(*arguments):
        if len(arguments) != 2 or arguments[1] != '--describe' or Path(arguments[0]).name != 'tractanda-embeddings':
            raise ValueError('Only the fixed embedding descriptor probe is permitted.')
        fixed = (str(Path(arguments[0]).absolute()), arguments[1])
        if storage_guard is None:
            return child(fixed, work, environment, maximum, timeout=60, capture=True)
        return child(fixed, work, environment, maximum, timeout=60, capture=True,
                     storage_guard=storage_guard)
    return describe


def core_build_flags(arch):
    """Bind distributable ISA together with the selected build backend/thread budget."""
    isa = '-march=' + B.ARCH[arch][2]
    flags = [isa, '-target-cpu', 'generic', '--build-system', 'native',
             '-num-threads', str(COMPILER_THREADS)]
    B.global_isa_flags(flags, arch)
    return flags


def core_build_arguments(swift, common, arch, product):
    """Use the R5-probed native Swift driver and explicit bounded frontend threads."""
    isa = '-march=' + B.ARCH[arch][2]
    core_build_flags(arch)
    return [swift, 'build', *common, '--build-system', 'native',
            '--force-resolved-versions', '--skip-update', '--disable-dependency-cache',
            '--disable-build-manifest-caching', '--manifest-cache', 'local', '--disable-index-store',
            '-c', 'release', '-debug-info-format', 'none', '-j', '1',
            '-Xcc', isa, '-Xcxx', isa, '-Xswiftc', '-target-cpu', '-Xswiftc', 'generic',
            '-Xswiftc', '-num-threads', '-Xswiftc', str(COMPILER_THREADS), '--product', product]


def reported_bin_directory(output, work):
    """Accept only one absolute, existing Swift-reported directory under owned scratch."""
    lines = output.strip().splitlines()
    if len(lines) != 1 or not Path(lines[0]).is_absolute():
        raise ValueError('Swift must report exactly one absolute binary directory.')
    directory = Path(lines[0]).resolve(strict=True)
    scratch = (work / 'scratch').resolve(strict=True)
    if not directory.is_dir() or not directory.is_relative_to(scratch):
        raise ValueError('Swift binary directory escapes the owned scratch root.')
    return directory


def build_core_product(swift, common, arch, product, work, environment, maximum,
                       timeout=DEFAULT_BUILD_TIMEOUT_SECONDS):
    command = core_build_arguments(swift, common, arch, product)
    child(command, work, environment, maximum, timeout=timeout, storage_guard=build_storage)
    # Use precisely the same driver arguments to ask SwiftPM for its output path.
    reported = child([*command, '--show-bin-path'], work, environment, maximum,
                     capture=True, timeout=timeout, storage_guard=build_storage)
    return reported_bin_directory(reported, work)


def toolchain(swift, *, probe_timeout_seconds=DEFAULT_TOOLCHAIN_PROBE_TIMEOUT_SECONDS):
    # Keep the 'swift' driver invocation name, while hashing its resolved bytes.
    swift = swift.absolute()
    if swift.name != 'swift':
        raise ValueError('Pass the concrete toolchain usr/bin/swift entry point, not a shim or alternate driver.')
    tools = {'swiftSHA256': swift.resolve(strict=True), 'swiftFrontendSHA256': swift.parent / 'swift-frontend',
             'clangSHA256': (swift.parent / 'clang').resolve(strict=True)}
    result = {'version': B.run([swift, '--version'],
                              timeout_seconds=timeout_seconds(probe_timeout_seconds)).splitlines()[0]}
    for key, path in tools.items():
        if not path.is_file():
            raise ValueError('Missing concrete Swift tool: ' + str(path))
        result[key] = B.digest(path)
    return swift, result


def mirrored_pins(source, mirrors):
    lock = B.read_json(source / 'Package.resolved')
    pins = lock['pins']
    supplied = B.read_json(mirrors)
    if not isinstance(supplied, dict) or set(supplied) != {p['identity'] for p in pins}:
        raise ValueError('Offline mirrors must cover exactly the frozen root Package.resolved pins.')
    config = []
    for pin in pins:
        mirror = Path(supplied[pin['identity']])
        if not mirror.is_absolute() or mirror.is_symlink() or not mirror.is_dir():
            raise ValueError('Offline mirror must be an absolute real Git directory.')
        B.run(['/usr/bin/git', '--git-dir', mirror, 'fsck', '--full', '--strict', '--no-reflogs', '--no-dangling'])
        revision = pin['state']['revision']
        if (not re.fullmatch('[0-9a-f]{40}', revision)
                or B.run(['/usr/bin/git', '--git-dir', mirror, 'rev-parse', revision + '^{commit}']).strip() != revision):
            raise ValueError('Offline mirror does not retain the locked commit.')
        version = pin['state'].get('version')
        if version:
            matches = []
            for tag in (version, 'v' + version):
                try:
                    matches.append(B.run(['/usr/bin/git', '--git-dir', mirror, 'rev-parse', '--verify',
                                          'refs/tags/' + tag + '^{commit}']).strip())
                except ValueError:
                    pass
            if revision not in matches or any(v != revision for v in matches):
                raise ValueError('Offline mirror version tags do not match the lock.')
        config.append({'original': pin['location'], 'mirror': mirror.as_uri()})
    return {'version': 1, 'object': config}


def produce(args):
    # Crucial ordering: a missing reviewed runtime stops before source/model hashing, tools or work creation.
    admitted = require_admitted(args.arch)
    registry_snapshot = B.captured_bytes(REGISTRY, 1024**2)
    if require_admitted(args.arch) != admitted:
        raise ValueError('Runtime packaging approvals changed during capture.')
    baseline = B.native_baseline(args.arch)
    build_inputs = build_environment()
    components = {role: component(getattr(args, role + '_manifest'), getattr(args, role + '_root'),
                                  role, args.arch, admitted[role]) for role in COMPONENTS}
    probe_budget = getattr(args, 'toolchain_probe_timeout_seconds', DEFAULT_TOOLCHAIN_PROBE_TIMEOUT_SECONDS)
    swift, tools = toolchain(args.swift, probe_timeout_seconds=probe_budget)
    if any(value['toolchain'] != tools for value in components.values()):
        raise ValueError('Core/MLX Swift toolchain ABI differs from the admitted components.')
    original = source_rows()
    frozen_hashes = {row['path']: row['sha256'] for row in original}
    if frozen_hashes.get('debian/linux-runtime-inputs.json') != sha(registry_snapshot):
        raise ValueError('Runtime packaging approvals changed before source freeze.')
    for value in components.values():
        for commitment in [value['recipe'], *value['patches']]:
            if frozen_hashes.get(commitment['path']) != commitment['sha256']:
                raise ValueError('Component recipe/patch changed before the frozen source snapshot.')
    models = {role: rows(getattr(args, role + '_model'), maximum=args.max_work_bytes) for role in COMPONENTS}
    B.MAC.validate_docling_model(args.documents_model)
    source_bytes = sum(v['size'] for v in original)
    payload_bytes = sum(v['size'] for entries in models.values() for v in entries)
    payload_bytes += sum(v['size'] for value in components.values() for v in value['files']) + source_bytes
    # Compiler estimate is reserved in addition to source and two complete payload copies.
    output_bound = payload_bytes + B.MAX_DIRECTORIES * 8192 + 16 * 1024**2
    estimate = source_bytes + payload_bytes + output_bound + args.build_allowance_bytes + B.MAX_DIRECTORIES * 8192
    if args.build_allowance_bytes <= 0:
        raise ValueError('A positive explicit compiler allocation estimate is required.')
    work = args.work.parent.resolve(strict=True) / args.work.name
    output = args.output.parent.resolve(strict=True) / args.output.name
    inputs = [ROOT.resolve(), *(getattr(args, role + suffix).resolve(strict=True)
              for role in COMPONENTS for suffix in ('_root', '_model'))]
    overlaps = lambda a, b: a.is_relative_to(b) or b.is_relative_to(a)
    if (work.exists() or work.is_symlink() or output.exists() or output.is_symlink()
            or overlaps(work, output) or any(overlaps(p, source) for p in (work, output) for source in inputs)):
        raise ValueError('Use fresh nonoverlapping external disposable work/output paths.')
    B.capacity(work.parent, estimate, args.max_work_bytes)
    B.capacity(output.parent, output_bound, args.max_work_bytes)
    work_limit = args.max_work_bytes - output_bound
    work.mkdir(mode=0o700)
    for name in ('source', 'payload', 'home', 'tmp', 'modules', 'cache', 'config', 'security'):
        (work / name).mkdir()
    write_json(work / 'source-inputs.json', {'profile': 'tractanda.linux-producer-source.v1', 'files': original,
               'componentManifests': admitted, 'toolchain': tools, 'baseline': baseline, 'buildEnvironment': build_inputs,
               'toolchainProbeTimeoutSeconds': probe_budget})
    write_json(work / 'operation.json', {'state': 'preparing', 'estimatedAdditionalBytes': estimate})
    environment = controlled_environment(work, swift.parent)
    embedding_runner = descriptor_runner(work, environment, work_limit, storage_guard=build_storage)
    B.MAC.embedding_descriptor(args.embeddings_root / 'bin/tractanda-embeddings', args.embeddings_model,
                               runner=embedding_runner)
    merge_files(ROOT, work / 'source', original, work_limit)
    write_json(work / 'source/.swiftpm/configuration/mirrors.json', mirrored_pins(work / 'source', args.mirrors))
    flags = core_build_flags(args.arch)
    common = ['--package-path', work / 'source', '--scratch-path', work / 'scratch',
              '--cache-path', work / 'cache', '--config-path', work / 'config', '--security-path', work / 'security']
    release = None
    for product in PRODUCTS:
        reported = build_core_product(swift, common, args.arch, product, work, environment, work_limit,
                                      timeout=getattr(args, 'build_timeout_seconds', DEFAULT_BUILD_TIMEOUT_SECONDS))
        if release is not None and reported != release:
            raise ValueError('Swift reported inconsistent product directories within the frozen scratch root.')
        release = reported
    if (toolchain(args.swift, probe_timeout_seconds=probe_budget)[1] != tools
            or build_environment() != build_inputs):
        raise ValueError('The compiler or Debian build environment changed during the build.')
    if B.read_json(work / 'source/Package.resolved') != B.read_json(ROOT / 'Package.resolved'):
        raise ValueError('SwiftPM changed the locked dependency graph.')
    # Known native SwiftPM release layout, no arbitrary output command or discovered alternate binary.
    payload = work / 'payload'
    core_changes = []
    for product in PRODUCTS:
        binary = release / product
        B.elf(binary, args.arch)
        entry = rows(release, [product])[0]
        entry['path'] = 'bin/' + product
        B.copy_verified(binary, payload / entry['path'], entry, work_limit)
        before = B.digest(payload / entry['path'])
        child(['/usr/bin/patchelf', '--set-rpath', '$ORIGIN/../lib', payload / entry['path']],
              work, environment, work_limit, storage_guard=build_storage)
        core_changes.append({'path': entry['path'], 'beforeSHA256': before, 'sha256': B.digest(payload / entry['path'])})
    for directory in sorted(release.iterdir()):
        if directory.is_dir() and directory.name.endswith(('.resources', '.bundle')) and 'Tests' not in directory.name:
            resource_rows = rows(release, [directory.name])
            merge_files(release, payload / 'bin', resource_rows, work_limit)
    model_projection = {}
    for role, value in components.items():
        merge_files(getattr(args, role + '_root'), payload, value['files'], work_limit)
        model_projection[role] = merge_model_files(
            getattr(args, role + '_model'), payload / MODEL_DIRS[role], models[role], work_limit)
    write_json(work / 'model-mode-projection.json', model_projection)
    # Copy public assets by reviewed index identity, using bounded copies from the frozen source.
    indexed = B.run(['git', '-C', ROOT, 'ls-files', '-z', '--', *B.PUBLIC]).split('\0')
    by_path = {v['path']: v for v in original}
    for name in filter(None, indexed):
        row = dict(by_path[name])
        row['path'] = 'licenses/' + name[len('LICENSES/'):] if name.startswith('LICENSES/') else name
        destination = payload / row['path']
        if destination.exists():
            if (destination.is_symlink() or not destination.is_file() or B.digest(destination) != row['sha256']
                    or destination.stat().st_size != row['size'] or destination.stat().st_mode & 0o777 != row['mode']):
                raise ValueError('Public/component license ownership collision: ' + row['path'])
        else:
            B.copy_verified(work / 'source' / name, destination, row, work_limit)
    if source_rows() != original:
        raise ValueError('Source drifted during the build; no bundle will be admitted.')
    # Bind stable source/recipe/ABI commitments, not operation PIDs/timestamps/temp paths.
    normalized = {'files': original, 'components': admitted, 'toolchain': tools, 'buildFlags': flags,
                  'buildEnvironment': build_inputs}
    spec = dict(profile='tractanda.linux-bundle-input.v1', version=(work / 'source/VERSION').read_text().strip(),
                arch=args.arch, minimumCPU=B.ARCH[args.arch][2], sourceInputsSHA256=sha(B.canonical(normalized)),
                buildFlags=flags, semanticProfile=B.SEMANTIC_PROFILE,
                documentExtraction=components['documents']['documentExtraction'],
                dynamicLoads=sorted(set(p for v in components.values() for p in v['dynamicLoads'])),
                runtimeNotices=sorted(set(p for v in components.values() for p in v['runtimeNotices'])))
    write_json(work / 'bundle-input.json', spec)
    build_storage(work, work_limit)
    result = B.assemble(payload, work / 'bundle-input.json', output, args.arch, args.max_work_bytes,
                        embedding_runner=embedding_runner)
    used = build_storage(work, work_limit) + B.owned_storage(output, args.max_work_bytes)
    if used > args.max_work_bytes:
        raise ValueError('Combined compiler/work/bundle allocation exceeded the declared budget.')
    if source_rows() != original:
        raise ValueError('Source changed during final actual Setup/closure admission.')
    write_json(work / 'result.json', dict(profile='tractanda.linux-payload-result.v1', bundle=result,
               sourceInputsSHA256=spec['sourceInputsSHA256'], components=admitted, coreRunpathChanges=core_changes,
               modelProjectionReceiptSHA256=B.digest(work / 'model-mode-projection.json'),
               buildEnvironment=build_inputs, baseline=baseline, toolchain=tools,
               toolchainProbeTimeoutSeconds=probe_budget))
    return result


def main():
    os.umask(0o022)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('plan', 'produce'))
    parser.add_argument('--arch', choices=B.ARCH, required=True)
    parser.add_argument('--build-timeout-seconds', type=timeout_seconds, default=DEFAULT_BUILD_TIMEOUT_SECONDS)
    parser.add_argument('--toolchain-probe-timeout-seconds', type=timeout_seconds,
                        default=DEFAULT_TOOLCHAIN_PROBE_TIMEOUT_SECONDS)
    for role in COMPONENTS:
        for suffix in ('manifest', 'root', 'model'):
            parser.add_argument('--' + role + '-' + suffix, type=Path)
    parser.add_argument('--swift', type=Path)
    parser.add_argument('--mirrors', type=Path)
    parser.add_argument('--work', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--max-work-bytes', type=int)
    parser.add_argument('--build-allowance-bytes', type=int)
    args = parser.parse_args()
    if args.action == 'plan':
        admitted = registry(args.arch)
        print(json.dumps(dict(profile='tractanda.linux-producer-plan.v1', arch=args.arch, products=PRODUCTS,
              baseline={'buildOS': 'debian13', 'minimumCPU': B.ARCH[args.arch][2], 'swiftABI': '6.4'},
              admittedComponents=admitted, missingComponents=[v for v in COMPONENTS if admitted[v] is None],
              buildStarted=False, reserveBytes=B.RESERVE,
              toolchainProbeTimeoutSeconds=args.toolchain_probe_timeout_seconds), indent=2))
        return
    required = ('swift', 'mirrors', 'work', 'output', 'max_work_bytes', 'build_allowance_bytes') + tuple(
        role + '_' + suffix for role in COMPONENTS for suffix in ('manifest', 'root', 'model'))
    if any(getattr(args, name) is None for name in required):
        parser.error('produce requires both complete component manifests/trees/models, concrete Swift, offline mirrors, work/output and budgets')
    try:
        def interrupted(signum, frame):
            raise InterruptedError('Interrupted producer; owned child will be reaped.')
        for name in (signal.SIGTERM, signal.SIGHUP):
            signal.signal(name, interrupted)
        print(json.dumps(produce(args), indent=2))
    except (ValueError, OSError, KeyError, TypeError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
