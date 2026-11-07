"""Check the incoming package's CPU requirements before starting a Swift helper."""
import os
from pathlib import Path
import platform
import re
import sys

RUNTIME_REQUIRED_CPU_FEATURES = {'amd64': ('cx16',), 'arm64': ()}
NATIVE_MACHINES = {'amd64': ('x86_64', 'amd64'), 'arm64': ('aarch64', 'arm64')}
CPUINFO = Path('/proc/cpuinfo')
ONLINE = Path('/sys/devices/system/cpu/online')
MAX_CPUS = 65_536


def required_features(arch):
    if arch not in RUNTIME_REQUIRED_CPU_FEATURES:
        raise ValueError('unsupported package CPU architecture')
    return RUNTIME_REQUIRED_CPU_FEATURES[arch]


def read_bounded(path, maximum):
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as stream:
        raw = stream.read(maximum + 1)
    if len(raw) > maximum:
        raise ValueError('CPU capability evidence exceeds its bound')
    return raw.decode('ascii')


def online_cpus(text):
    text = text.strip()
    if not re.fullmatch(r'[0-9]+(?:-[0-9]+)?(?:,[0-9]+(?:-[0-9]+)?)*', text):
        raise ValueError('online CPU list is missing or malformed')
    result = set()
    for group in text.split(','):
        values = group.split('-')
        first, last = int(values[0]), int(values[-1])
        if first > last or last - first + 1 > MAX_CPUS:
            raise ValueError('online CPU range is invalid or exceeds its bound')
        selected = set(range(first, last + 1))
        if result & selected or len(result) + len(selected) > MAX_CPUS:
            raise ValueError('online CPU list contains duplicates or exceeds its bound')
        result.update(selected)
    return result


def processor_features(text):
    result = {}
    for block in re.split(r'\n\s*\n', text.strip()):
        fields = {}
        for line in block.splitlines():
            key, separator, value = line.partition(':')
            key = key.strip()
            if key not in ('processor', 'flags'):
                continue
            if not separator or key in fields:
                raise ValueError('CPU feature record is malformed or duplicated')
            fields[key] = value.strip()
        if not fields:
            continue
        if (set(fields) != {'processor', 'flags'} or not re.fullmatch(r'[0-9]+', fields['processor'])
                or not re.fullmatch(r'[a-z0-9_]+(?:\s+[a-z0-9_]+)*', fields['flags'])):
            raise ValueError('CPU processor identifier or flags are missing or malformed')
        processor = int(fields['processor'])
        if processor in result or len(result) >= MAX_CPUS:
            raise ValueError('CPU feature records are duplicated or exceed their bound')
        result[processor] = set(fields['flags'].split())
    return result


def verify_host_cpu(arch):
    features = required_features(arch)
    if platform.system() != 'Linux' or platform.machine() not in NATIVE_MACHINES[arch]:
        raise ValueError('host architecture differs from the incoming package')
    if not features:
        return
    before = online_cpus(read_bounded(ONLINE, 65_536))
    processors = processor_features(read_bounded(CPUINFO, 64 * 1024**2))
    after = online_cpus(read_bounded(ONLINE, 65_536))
    if before != after or set(processors) != before:
        raise ValueError('online CPUs changed or CPU capability evidence is inconsistent')
    for processor in sorted(before):
        missing = set(features) - processors[processor]
        if missing:
            raise ValueError('CPU ' + str(processor) + ' lacks required runtime features: ' + ', '.join(sorted(missing)))


def main():
    try:
        if len(sys.argv) != 2:
            raise ValueError('incoming package architecture is required')
        verify_host_cpu(sys.argv[1])
    except (OSError, UnicodeError, ValueError) as error:
        print('tractanda preinst: CPU compatibility check failed: ' + str(error), file=sys.stderr)
        raise SystemExit(1)


if __name__ == '__main__':
    main()
