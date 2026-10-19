#!/usr/bin/env python3
"""Explicit development maintenance only; no service stop, discovery or deployment."""
import argparse, os, pathlib, subprocess, uuid
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--root', type=pathlib.Path, required=True)
p.add_argument('--operation', required=True)
p.add_argument('--actor-uid', type=int, required=True)
p.add_argument('--confirm-service-stopped', action='store_true', required=True)
p.add_argument('--maximum-records', type=int, default=8192)
p.add_argument('--maximum-bytes', type=int, default=128 * 1024**2)
p.add_argument('--maximum-work', type=int, default=262144)
a = p.parse_args()
if not a.root.is_absolute() or str(a.root) == '/' or not a.root.is_dir(): p.error('existing absolute dedicated root required')
if str(uuid.UUID(a.operation)) != a.operation or uuid.UUID(a.operation).version != 1: p.error('canonical UUIDv1 operation required')
if not 0 <= a.actor_uid <= 2**32-1: p.error('invalid actor UID')
if not 0 < a.maximum_records <= 32768 or not 0 < a.maximum_bytes <= 16 * 1024**3 or not 0 < a.maximum_work <= 10000000: p.error('explicit policy exceeds supported finite totals')
v = os.statvfs(a.root)
if v.f_bavail * v.f_frsize < 10 * 1024**3 + a.maximum_bytes * 4 + 32 * 1024**2: p.error('actual filesystem reserve/preestimate rejected')
e = os.environ.copy()
for key, value in dict(ROOT=a.root, OPERATION=a.operation, UID=a.actor_uid, RECORDS=a.maximum_records, BYTES=a.maximum_bytes, WORK=a.maximum_work, STOPPED='YES').items():
    e['TRACTANDA_DEV_FIRST_SOURCE_' + key] = str(value)
repo = pathlib.Path(__file__).resolve().parents[3]
raise SystemExit(subprocess.run(['swift', 'test', '--disable-sandbox', '--skip-update', '--jobs', '2', '--filter', 'DevelopmentFirstSourceConversionTests/testRunExplicitStoppedConversion'], cwd=repo, env=e).returncode)
