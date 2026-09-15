#!/usr/bin/env python3
"""Independent UUIDv1 decoding, process/restart and controlled-clock checks."""
import argparse
import concurrent.futures
import datetime
import json
import os
import platform
import subprocess
import time
import uuid
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--clock-library', type=Path)
    args = parser.parse_args()
    binary = str(args.binary.resolve())
    def call(*arguments, env=None):
        return json.loads(subprocess.check_output([binary, *arguments], env=env))
    node = call('uuid-node')
    expected_node = int(node['node'].replace(':', ''), 16)
    assert expected_node and expected_node & (3 << 40) == 0
    started = time.time_ns()
    first = call('uuid-v1', '512')
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        groups = list(pool.map(lambda _: call('uuid-v1', '256'), range(4)))
    ended = time.time_ns()
    values = [uuid.UUID(value) for value in first + [value for group in groups for value in group]]
    assert len(set(values)) == len(values) == 1536
    for value in values:
        assert value.version == 1 and value.node == expected_node
        nanos = (value.time - 0x01B21DD213814000) * 100
        assert started - 1_000_000_000 <= nanos <= ended + 1_000_000_000
    inspected = call('inspect-uuid', str(values[0]))
    assert int(inspected['timestamp100Nanoseconds']) == values[0].time
    assert inspected['clockSequence'] == values[0].clock_seq
    assert inspected['node'] == node['node'] and not inspected['nodeIsLocallyAdministered']
    ticks = values[0].time - 0x01B21DD213814000
    seconds, fraction = divmod(ticks, 10_000_000)
    expected_time = datetime.datetime.fromtimestamp(seconds, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S') + f'.{fraction:07d}Z'
    assert inspected['timestampUTC'] == expected_time
    fixture = call('inspect-uuid', 'c232ab00-9414-11ec-b3c8-9f6bdeced846')
    assert fixture['timestampUTC'] == '2022-02-22T19:22:22.0000000Z'
    assert fixture['clockSequence'] == 0x33C8 and fixture['node'] == '9f:6b:de:ce:d8:46'
    checks = ['1536 unique v1 IDs from five processes, with the selected hardware node and bounded real timestamps',
              'Independent RFC vector and lossless 100ns, clock-sequence and node decoding']
    for address in ['02:11:22:33:44:55', '01:11:22:33:44:55', '00:00:00:00:00:00', 'not-a-mac']:
        result = subprocess.run([binary, 'uuid-v1'], env={**os.environ, 'TRACTANDA_UUID_NODE': address}, capture_output=True)
        assert result.returncode != 0
        assert 'invalidUUIDNode' in (result.stdout + result.stderr).decode()
    wrong = subprocess.run([binary, 'inspect-uuid', str(uuid.uuid4())], capture_output=True)
    assert wrong.returncode != 0
    checks.append('Invalid, zero, multicast and locally-administered configured nodes fail instead of falling back; v4 is not decoded as v1')
    if args.clock_library:
        fake = call('uuid-v1', '16', env={**os.environ, 'LD_PRELOAD': str(args.clock_library.resolve()), 'TRACTANDA_TEST_UUID_CLOCK': '1'})
        altered = [uuid.UUID(value) for value in fake]
        assert len(set(altered)) == len(altered)
        rollbacks = [(a,b) for a,b in zip(altered, altered[1:]) if b.time < a.time]
        assert rollbacks, 'The process-local test clock did not cause an observed rollback.'
        assert all(a.clock_seq != b.clock_seq for a,b in rollbacks)
        assert all(value.version == 1 and value.node == expected_node for value in altered)
        checks.append('Process-local Linux clock rollback changes the v1 clock sequence without duplicate IDs; host time is untouched')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    result = {'status':'passed','platform':platform.platform(),'node':node,'checks':checks,
              'clockRollbackTested':bool(args.clock_library)}
    args.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result))


if __name__ == '__main__': main()
