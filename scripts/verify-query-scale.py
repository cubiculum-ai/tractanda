#!/usr/bin/env python3
"""Build and measure an isolated native query-scale fixture.

Every invocation creates a fresh temporary store. Presets are logical current
item counts; history depth is independently configurable. Large presets are
opt-in and are never run automatically by this script.
"""
import argparse
import contextlib
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import platform
import random
import shutil
import signal
import socket
import struct
import subprocess
import tempfile
import threading
import time
import uuid

WIRE_SPEC = importlib.util.spec_from_file_location(
    "scale_wire", Path(__file__).with_name("verify-ipc.py"))
wire = importlib.util.module_from_spec(WIRE_SPEC)
WIRE_SPEC.loader.exec_module(wire)

CAPACITY_POLL_SECONDS = 1.0
# Deliberately conservative estimate for canonical records, revisions and SQLite
# indexes. The live byte guard remains authoritative; estimates prevent unsafe
# fixture creation and oversized batches.
ESTIMATED_REVISION_OVERHEAD = 16 * 1024
ESTIMATED_HEAD_INDEX_OVERHEAD = 8 * 1024
ESTIMATE_SAFETY_FACTOR = 2.0


def estimate_fixture_bytes(items, history_depth, body_bytes, writes=0):
    revisions = items * history_depth + writes + 2
    heads = items + writes + 2
    payload = items * history_depth * body_bytes
    return int((payload + revisions * ESTIMATED_REVISION_OVERHEAD
                + heads * ESTIMATED_HEAD_INDEX_OVERHEAD) * ESTIMATE_SAFETY_FACTOR)


def available_bytes(path):
    """Return genuinely available bytes on the filesystem containing path."""
    return shutil.disk_usage(path).free


def require_capacity(path, used, max_bytes, reserve_bytes, estimate=0, phase="fixture"):
    try:
        free = available_bytes(path)
    except (OSError, AttributeError) as exc:
        raise RuntimeError(f"Cannot determine available disk capacity during {phase}; refusing to continue") from exc
    remaining_budget = max_bytes - used
    headroom = free - reserve_bytes
    if used > max_bytes or estimate > remaining_budget:
        raise RuntimeError(f"{phase} exceeds fixture budget: used={used}, estimate={estimate}, "
                           f"cap={max_bytes}, remaining={remaining_budget}")
    if estimate > headroom:
        raise RuntimeError(f"Insufficient available disk space during {phase}: free={free}, "
                           f"reserve={reserve_bytes}, required_estimate={estimate}")
    return free


class CapacityWatchdog:
    """Monitor available space every second and fixture size every ten seconds."""
    SIZE_POLL_SECONDS = 10.0

    def __init__(self, root, store, process, max_bytes, reserve_bytes):
        self.root, self.store, self.process = root, store, process
        self.max_bytes, self.reserve_bytes = max_bytes, reserve_bytes
        self.error = None
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self._run, name="scale-disk-watchdog", daemon=True)

    def start(self):
        self.thread.start()
        try:
            self.check("server startup")
        except Exception as exc:
            self._fail(exc)
            raise RuntimeError(self.error) from exc

    def stop(self):
        self.stop_event.set()
        if self.thread.is_alive():
            self.thread.join(timeout=CAPACITY_POLL_SECONDS + 1)

    def check(self, phase, estimate=0):
        if self.error:
            raise RuntimeError(self.error)
        used = tree_bytes(self.store) if self.store.exists() else 0
        require_capacity(self.root, used, self.max_bytes, self.reserve_bytes, estimate, phase)

    def _fail(self, exc):
        self.error = str(exc)
        if self.process.poll() is None:
            self.process.terminate()

    def _run(self):
        next_size_check = time.monotonic() + self.SIZE_POLL_SECONDS
        while not self.stop_event.wait(CAPACITY_POLL_SECONDS):
            try:
                if time.monotonic() >= next_size_check:
                    self.check("periodic fixture-size monitor")
                    next_size_check = time.monotonic() + self.SIZE_POLL_SECONDS
                require_capacity(self.root, 0, self.max_bytes, self.reserve_bytes,
                                 0, "periodic capacity monitor")
            except Exception as exc:
                self._fail(exc)
                return


def tagged(kind, value):
    return {"type": kind, "value": value}


def make_fields(index, rng, body_bytes, private_every):
    topics = ("invoice", "meeting", "delivery", "research", "archive", "project")
    topic = topics[index % len(topics)]
    body = (f"Message {index} about {topic}. The team discussed quarterly plans, "
            "follow-up actions, dates, and supporting details. ")
    body = (body * (body_bytes // len(body) + 1))[:body_bytes]
    fields = {
        "subject": tagged("text", f"{topic.title()} archive message {index:08d}"),
        "body": tagged("text", body),
        "sender": tagged("text", f"person{index % 97}@example.invalid"),
        "sentAt": tagged("date", f"2024-{index % 12 + 1:02d}-{index % 27 + 1:02d}T12:00:00Z"),
        "keywords": tagged("list", [tagged("text", topic), tagged("text", "archive")]),
    }
    # A realistic shared/private split. ACL syntax follows the POSIX permission
    # object used by the native multi-user fixtures; all fixture data is disposable.
    if private_every and index % private_every == 0:
        fields["permissions"] = tagged("object", {
            "profile": tagged("text", "tractanda.permissions.posix.v1"),
            "owner": tagged("text", "scale-owner"),
            "group": tagged("text", "scale-team"),
            "mode": tagged("integer", 0o600),
            "acl": tagged("object", {}),
        })
    elif rng.randrange(20) == 0:
        fields["permissions"] = tagged("object", {
            "profile": tagged("text", "tractanda.permissions.posix.v1"),
            "owner": tagged("text", "scale-owner"),
            "group": tagged("text", "scale-team"),
            "mode": tagged("integer", 0o660),
            "acl": tagged("object", {}),
        })
    return fields


class MeteredClient:
    def __init__(self, path):
        self.path = path
        self.bytes_sent = 0
        self.bytes_received = 0
        self.lock = threading.Lock()

    def call(self, method, args=None):
        request = json.dumps({"using": [wire.CAPABILITY],
            "methodCalls": [[method, args or {}, "scale"]]}, ensure_ascii=False).encode()
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(60)
            conn.connect(str(self.path))
            conn.sendall(struct.pack("!I", len(request)) + request)
            header = wire.read_exact(conn, 4)
            size = struct.unpack("!I", header)[0]
            response = wire.read_exact(conn, size)
        with self.lock:
            self.bytes_sent += len(request) + 4
            self.bytes_received += len(response) + 4
        envelope = json.loads(response)
        assert "code" not in envelope, envelope
        name, result, _ = envelope["methodResponses"][0]
        assert name == method, envelope
        return result


def rss_kib(pid):
    if platform.system() == "Darwin":
        result = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True)
        return int(result.stdout.strip()) if result.returncode == 0 and result.stdout.strip() else None
    try:
        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    except OSError:
        pass
    return None


def percentile(values, p):
    ordered = sorted(values)
    if not ordered:
        return None
    return ordered[min(len(ordered) - 1, int((len(ordered) - 1) * p))]


def percentile_seconds(values, p):
    value = percentile(values, p)
    return round(value, 6) if value is not None else None


def tree_bytes(root):
    total = 0
    for directory, _, names in os.walk(root):
        for name in names:
            try:
                total += (Path(directory) / name).stat().st_size
            except FileNotFoundError:
                pass
    return total


@contextlib.contextmanager
def measured_server(binary, store, endpoint, root, max_disk_bytes,
                    reserve_disk_bytes, ready_timeout_seconds=20,
                    startup_phase_stats=False):
    """Start the isolated native server and sample startup RSS."""
    with tempfile.TemporaryFile() as log:
        started = time.perf_counter()
        environment = os.environ.copy()
        if startup_phase_stats:
            environment["TRACTANDA_STARTUP_METRICS"] = "1"
        else:
            environment.pop("TRACTANDA_STARTUP_METRICS", None)
        process = subprocess.Popen([binary, "serve", str(store), str(endpoint)],
            stdout=subprocess.DEVNULL, stderr=log, env=environment)
        watchdog = CapacityWatchdog(root, store, process, max_disk_bytes,
                                    reserve_disk_bytes)
        process._scale_watchdog = watchdog
        rss_samples = []
        rss_sampling_error = None
        sampling_done = threading.Event()
        def sample_startup_rss():
            nonlocal rss_sampling_error
            while not sampling_done.is_set():
                sampled_at = time.perf_counter()
                try:
                    value = rss_kib(process.pid)
                except (OSError, subprocess.SubprocessError) as exc:
                    rss_sampling_error = f"{type(exc).__name__}: {exc}"
                    return
                if value is not None:
                    rss_samples.append({"secondsSinceLaunch": round(sampled_at - started, 6),
                                        "monotonicSeconds": time.monotonic(),
                                        "rssKiB": value})
                sampling_done.wait(0.025)
        sampler = threading.Thread(target=sample_startup_rss,
                                   name="scale-startup-rss", daemon=True)
        sampler.start()
        try:
            # Recovery and index rebuild can grow the fixture before readiness.
            watchdog.start()
            deadline = time.monotonic() + ready_timeout_seconds
            while not endpoint.exists():
                if process.poll() is not None or time.monotonic() >= deadline:
                    log.seek(0)
                    raise RuntimeError(log.read().decode())
                time.sleep(0.01)
            socket_ready_seconds = time.perf_counter() - started
            info_started = time.perf_counter()
            ready = subprocess.run([binary, "info", str(endpoint)], check=True,
                                   capture_output=True, text=True, timeout=10)
            startup_mode = json.loads(ready.stdout).get("startupRecovery", {})
            info_seconds = time.perf_counter() - info_started
            startup_seconds = time.perf_counter() - started
            log.seek(0)
            startup_log = log.read().decode(errors="replace")
            phase_stats = None
            for line in startup_log.splitlines():
                marker = "TRACTANDA_STARTUP_METRICS "
                if line.startswith(marker):
                    phase_stats = json.loads(line[len(marker):])
            if phase_stats is not None:
                uptime_phases = {
                    "recovery": (phase_stats["recoveryStartUptime"], phase_stats["recoveryEndUptime"]),
                    "recoveryEnumeration": (phase_stats["recoveryEnumerationStartUptime"],
                                              phase_stats["recoveryEnumerationEndUptime"]),
                    "recoveryValidation": (phase_stats["recoveryValidationStartUptime"],
                                             phase_stats["recoveryValidationEndUptime"]),
                    "recoveryFinalization": (phase_stats["recoveryFinalizationStartUptime"],
                                               phase_stats["recoveryFinalizationEndUptime"]),
                    "sqliteInsert": (phase_stats["insertStartUptime"], phase_stats["insertEndUptime"]),
                    "sqliteCommit": (phase_stats["commitStartUptime"], phase_stats["commitEndUptime"]),
                    "publication": (phase_stats["publicationStartUptime"], phase_stats["publicationEndUptime"]),
                }
                phase_stats["phaseRSS"] = {
                    name: {"peakKiB": max((sample["rssKiB"] for sample in rss_samples
                                             if start <= sample["monotonicSeconds"] <= end), default=None),
                           "sampleCount": sum(start <= sample["monotonicSeconds"] <= end
                                               for sample in rss_samples)}
                    for name, (start, end) in uptime_phases.items()
                }
            yield process, {
                "launchToSocketReadySeconds": round(socket_ready_seconds, 6),
                "infoHandshakeSeconds": round(info_seconds, 6),
                "launchToInfoReadySeconds": round(startup_seconds, 6),
                "startupPeakRSSKiB": max((sample["rssKiB"] for sample in rss_samples), default=None),
                "startupRSSSampleCount": len(rss_samples),
                "startupRSSIntervalSeconds": 0.025,
                "startupRSSSamplingError": rss_sampling_error,
                "startupPhases": phase_stats,
                "startupRecovery": startup_mode,
            }
        finally:
            sampling_done.set()
            sampler.join(timeout=1)
            watchdog.stop()
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                raise RuntimeError("Native server did not stop after SIGTERM")
            watchdog = process._scale_watchdog
            if watchdog is not None and watchdog.error:
                raise RuntimeError(watchdog.error)
            if process.returncode != 0:
                log.seek(0)
                raise RuntimeError(f"Native server exit {process.returncode}: {log.read().decode()}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path, help="built native tractanda executable")
    parser.add_argument("--preset", choices=("10k", "100k", "1m", "custom"), default="10k")
    parser.add_argument("--items", type=int, help="logical current heads for custom preset")
    parser.add_argument("--history-depth", type=int, default=1,
                        help="total revisions per logical item, including its current head")
    parser.add_argument("--body-bytes", type=int, default=1536)
    parser.add_argument("--private-every", type=int, default=5,
                        help="mark every Nth item with private permission metadata; zero disables it")
    parser.add_argument("--readers", type=int, default=4)
    parser.add_argument("--read-rounds", type=int, default=3)
    parser.add_argument("--writes", type=int, default=4,
                        help="concurrent writes performed after loading")
    parser.add_argument("--page-size", type=int, default=64)
    parser.add_argument("--smoke-items", type=int,
                        help="explicit bounded run; also caps the selected preset")
    parser.add_argument("--startup-phase-stats", action="store_true",
                        help="opt in to internal recovery/index phase timings and phase RSS samples")
    parser.add_argument("--compare-checkpoint", action="store_true",
                        help="measure clean reuse and forced full recovery on the same populated fixture")
    parser.add_argument("--max-seconds", type=float, default=1800,
                        help="abort fixture loading after this many seconds (default: 1800)")
    parser.add_argument("--max-disk-bytes", type=int, default=1 * 1024**3,
                        help="fixture byte cap (default: 1 GiB)")
    parser.add_argument("--reserve-disk-bytes", type=int, default=10 * 1024**3,
                        help="keep this much genuinely available space free (default: 10 GiB)")
    args = parser.parse_args()
    counts = {"10k": 10_000, "100k": 100_000, "1m": 1_000_000}
    if args.preset == "custom" and not args.items:
        parser.error("--preset custom requires --items")
    count = args.items if args.preset == "custom" else counts[args.preset]
    if args.smoke_items is not None:
        if args.smoke_items < 1:
            parser.error("--smoke-items must be positive")
        count = min(count, args.smoke_items)
    if args.history_depth < 1 or args.body_bytes < 0 or args.private_every < 0:
        parser.error("history depth, body bytes and private interval must be non-negative (depth >= 1)")
    if args.readers < 1 or args.read_rounds < 1 or args.writes < 0 or not 1 <= args.page_size <= 256:
        parser.error("invalid reader, write, or page-size setting")
    if args.max_seconds <= 0 or args.max_disk_bytes <= 0 or args.reserve_disk_bytes < 0:
        parser.error("--max-seconds and --max-disk-bytes must be positive; reserve must be non-negative")
    if not hasattr(signal, "setitimer"):
        parser.error("this harness requires a platform with interval timer support for its wall-time guard")
    def stop_at_deadline(_signum, _frame):
        raise TimeoutError(f"Harness exceeded --max-seconds={args.max_seconds:g}; disposable store is being removed")
    signal.signal(signal.SIGALRM, stop_at_deadline)
    signal.setitimer(signal.ITIMER_REAL, args.max_seconds)
    estimate = estimate_fixture_bytes(count, args.history_depth, args.body_bytes, args.writes)
    # Check the temp parent before creating anything, then recheck the actual
    # filesystem after TemporaryDirectory chooses its location.
    initial_free = require_capacity(Path(tempfile.gettempdir()), 0, args.max_disk_bytes,
                     args.reserve_disk_bytes, estimate, "startup estimate")
    binary = str(args.binary.resolve())
    rng = random.Random(7741)
    seed_write_timings = []
    history_write_timings = []
    pages = []
    with tempfile.TemporaryDirectory(prefix="tractanda-query-scale-") as temp:
        root = Path(temp)
        store = root / "store"
        initial_free = require_capacity(root, 0, args.max_disk_bytes, args.reserve_disk_bytes,
                         estimate, "initial fixture capacity")
        # Keep the socket beside the script: this stays short enough for
        # sockaddr_un and within the workspace's writable sandbox.
        endpoint = Path(__file__).resolve().parents[1] / f".q{uuid.uuid4().hex[:8]}.s"
        subprocess.run([binary, "init", str(store)], check=True, capture_output=True)
        seed_started = time.perf_counter()
        accounted_store_bytes = tree_bytes(store)
        writes_since_size_scan = 0

        def check_limits(phase, next_batch=0):
            nonlocal accounted_store_bytes, writes_since_size_scan
            elapsed = time.perf_counter() - seed_started
            if elapsed > args.max_seconds:
                raise RuntimeError(f"{phase} exceeded --max-seconds={args.max_seconds:g}; disposable fixture will be removed")
            # Keep a conservative upper bound between occasional exact scans;
            # this avoids walking a large fixture once per small native batch.
            if writes_since_size_scan >= 16_384:
                accounted_store_bytes = max(accounted_store_bytes, tree_bytes(store))
                writes_since_size_scan = 0
            used = accounted_store_bytes
            batch_estimate = next_batch * (args.body_bytes + ESTIMATED_REVISION_OVERHEAD
                                           + ESTIMATED_HEAD_INDEX_OVERHEAD) * ESTIMATE_SAFETY_FACTOR
            require_capacity(root, used, args.max_disk_bytes, args.reserve_disk_bytes,
                             batch_estimate, phase)
            return used

        with measured_server(binary, store, endpoint, root, args.max_disk_bytes,
                             args.reserve_disk_bytes,
                             ready_timeout_seconds=args.max_seconds,
                             startup_phase_stats=args.startup_phase_stats) as (_empty_process, empty_startup):
            watchdog = _empty_process._scale_watchdog
            boot_client = wire.Client(endpoint)
            ids = []
            batch_size = 16
            for first in range(0, count, batch_size):
                check_limits("head seeding", min(batch_size, count - first))
                calls = []
                for index in range(first, min(first + batch_size, count)):
                    calls.append(["TractandaItem/commit", wire.intent("create", str(uuid.uuid4()),
                        class_id="Item", changes=make_fields(index, rng, args.body_bytes, args.private_every)),
                        f"create-{index}"])
                # One bounded native batch keeps each request comfortably below the wire limit.
                started = time.perf_counter()
                response = boot_client.batch(calls)
                accounted_store_bytes += len(calls) * (args.body_bytes + ESTIMATED_REVISION_OVERHEAD
                                                        + ESTIMATED_HEAD_INDEX_OVERHEAD) * ESTIMATE_SAFETY_FACTOR
                writes_since_size_scan += len(calls)
                elapsed = time.perf_counter() - started
                seed_write_timings.extend([elapsed / len(calls)] * len(calls))
                for name, value, _ in response:
                    assert name == "TractandaItem/commit", name
                    ids.append(wire.item_id(value["revision"]))
                if first % (batch_size * 16) == 0 and time.perf_counter() - seed_started > args.max_seconds:
                    raise RuntimeError("head seeding exceeded --max-seconds; disposable fixture will be removed")
                if first % (batch_size * 1024) == 0:
                    check_limits("head seeding")
            check_limits("category and saved-view fixture writes", 2)
            category_revision = boot_client.commit(wire.intent("create", str(uuid.uuid4()), class_id="Item",
                changes={"subject": wire.text("Scale sender category"), "selection": {
                    "type": "object", "value": {"language": wire.text("tractanda.spotlight.v0"),
                        "expression": wire.text('sender == "person7@example.invalid"')}}}))
            category_id = wire.item_id(category_revision["revision"])
            view_revision = boot_client.commit(wire.intent("create", str(uuid.uuid4()), class_id="Item",
                changes={"subject": wire.text("Scale sender saved view"), "viewDefinition": {
                    "type": "object", "value": {"language": wire.text("tractanda.spotlight.v0"),
                        "categoryPath": {"type": "list", "value": [{"type": "reference",
                            "value": {"itemID": category_id}}]}, "sort": {"type": "list", "value": []}}}}))
            accounted_store_bytes += 2 * (args.body_bytes + ESTIMATED_REVISION_OVERHEAD
                                           + ESTIMATED_HEAD_INDEX_OVERHEAD) * ESTIMATE_SAFETY_FACTOR
            writes_since_size_scan += 2
            view_id = wire.item_id(view_revision["revision"])
            for index in range(count):
                for revision in range(1, args.history_depth):
                    check_limits("history seeding", 1)
                    current = boot_client.get(ids[index])
                    fields = {"body": tagged("text", f"History revision {revision} for logical item {index}. "
                                                + ("context " * (args.body_bytes // 8)))}
                    started = time.perf_counter()
                    boot_client.commit(wire.intent("revise", str(uuid.uuid4()), ids[index],
                        wire.revision_id(current), changes=fields))
                    accounted_store_bytes += (args.body_bytes + ESTIMATED_REVISION_OVERHEAD
                                              + ESTIMATED_HEAD_INDEX_OVERHEAD) * ESTIMATE_SAFETY_FACTOR
                    writes_since_size_scan += 1
                    history_write_timings.append(time.perf_counter() - started)
                    if len(history_write_timings) % 16_384 == 0:
                        check_limits("history seeding")
            seed_seconds = time.perf_counter() - seed_started
            estimated_store_bytes_before_measurement = check_limits("fixture loading")
            store_bytes_before_measurement = tree_bytes(store)

        clean_checkpoint_startup = None
        if args.compare_checkpoint:
            # This read-only restart measures the clean catalogue before any query/write phase.
            with measured_server(binary, store, endpoint, root, args.max_disk_bytes,
                                 args.reserve_disk_bytes,
                                 ready_timeout_seconds=args.max_seconds,
                                 startup_phase_stats=args.startup_phase_stats) as (_probe, clean_checkpoint_startup):
                _probe._scale_watchdog.check("clean checkpoint probe")
                if clean_checkpoint_startup["startupRecovery"].get("mode") != "checkpoint":
                    raise RuntimeError("clean restart did not use checkpoint")
            # Simulate the existing unclean marker protocol on this disposable fixture only.
            # Its presence forces a full validated recovery on the next start.
            marker = store / ".tractanda-checkpoint-dirty"
            marker_fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            try:
                os.write(marker_fd, b"dirty-v1\n")
                os.fsync(marker_fd)
            finally:
                os.close(marker_fd)
            root_fd = os.open(store, os.O_RDONLY)
            try:
                os.fsync(root_fd)
            finally:
                os.close(root_fd)

        # Restart from the same populated canonical store. In compare mode the
        # marker forces full recovery; otherwise this is the ordinary cold start.
        with measured_server(binary, store, endpoint, root, args.max_disk_bytes,
                             args.reserve_disk_bytes,
                             ready_timeout_seconds=args.max_seconds,
                             startup_phase_stats=args.startup_phase_stats) as (process, populated_startup):
            if args.compare_checkpoint and (
                    populated_startup["startupRecovery"].get("mode") != "fullRecovery"
                    or populated_startup["startupRecovery"].get("reason") != "dirtyMarker"):
                raise RuntimeError("forced restart did not use full canonical recovery")
            watchdog = process._scale_watchdog
            client = MeteredClient(endpoint)
            expected_saved_view_total = sum(1 for index in range(count) if index % 97 == 7)
            view_args = {"viewID": view_id, "position": 0, "limit": args.page_size}
            first_view_started = time.perf_counter()
            first_view_result = client.call("TractandaItem/query", view_args)
            first_saved_view_seconds = time.perf_counter() - first_view_started
            assert first_view_result["total"] == expected_saved_view_total, (
                first_view_result["total"], expected_saved_view_total)
            warm_view_started = time.perf_counter()
            warm_view_result = client.call("TractandaItem/query", view_args)
            warm_saved_view_seconds = time.perf_counter() - warm_view_started
            assert warm_view_result["ids"] == first_view_result["ids"]
            concurrent_write_timings = []
            query_args = {"limit": args.page_size, "position": 0}
            for _ in range(args.read_rounds):
                started = time.perf_counter()
                result = client.call("TractandaItem/query", query_args)
                pages.append(time.perf_counter() - started)
                assert len(result["ids"]) == min(args.page_size, count)
            def read_loop(worker):
                local = MeteredClient(endpoint)
                measurements = []
                for turn in range(args.read_rounds):
                    pos = ((worker * args.read_rounds + turn) * args.page_size) % max(count, 1)
                    start = time.perf_counter()
                    local.call("TractandaItem/query", {"limit": args.page_size, "position": pos})
                    measurements.append(time.perf_counter() - start)
                return measurements, local.bytes_sent, local.bytes_received
            concurrent_started = time.perf_counter()
            watchdog.check("query and concurrent-write phase",
                           args.writes * (args.body_bytes + ESTIMATED_REVISION_OVERHEAD
                                          + ESTIMATED_HEAD_INDEX_OVERHEAD) * ESTIMATE_SAFETY_FACTOR)
            with concurrent.futures.ThreadPoolExecutor(max_workers=args.readers + 1) as pool:
                reads = [pool.submit(read_loop, worker) for worker in range(args.readers)]
                write_futures = []
                for number in range(args.writes):
                    def concurrent_write(n=number):
                        started = time.perf_counter()
                        result = client.call("TractandaItem/commit", wire.intent(
                            "create", str(uuid.uuid4()), class_id="Item",
                            changes={"subject": tagged("text", f"Concurrent write {n}"),
                                     "body": tagged("text", "Concurrent ingestion sample " * 32)}))
                        concurrent_write_timings.append(time.perf_counter() - started)
                        return result
                    write_futures.append(pool.submit(concurrent_write))
                concurrent_reads = []
                reader_bytes_sent = reader_bytes_received = 0
                for future in reads:
                    latencies, sent, received = future.result()
                    concurrent_reads.extend(latencies)
                    reader_bytes_sent += sent
                    reader_bytes_received += received
                for future in write_futures:
                    future.result()
            concurrency_seconds = time.perf_counter() - concurrent_started
            metrics = {
                "status": "passed", "platform": platform.platform(), "preset": args.preset,
                "logicalItems": count, "historyDepth": args.history_depth,
                "canonicalCurrentHeadsBeforeConcurrentWrites": count + 2,
                "canonicalCurrentHeadsAtEnd": count + 2 + args.writes,
                "bodyBytes": args.body_bytes,
                "permissionMix": {
                    "mode": "metadata-only; single-user fixture; ACL behavior not validated",
                    "privateMetadataItems": ((count + args.private_every - 1) // args.private_every
                                              if args.private_every else 0),
                    "sharedOrUnspecifiedMetadataItems": count - ((count + args.private_every - 1) // args.private_every
                                                                  if args.private_every else 0),
                    "accessControlValidated": False,
                },
                "seedSeconds": round(seed_seconds, 3),
                "storeBytesBeforeMeasurement": store_bytes_before_measurement,
                "estimatedStoreBytesBeforeMeasurement": estimated_store_bytes_before_measurement,
                "fixtureGuards": {"maxSeconds": args.max_seconds, "maxDiskBytes": args.max_disk_bytes,
                    "reserveDiskBytes": args.reserve_disk_bytes, "initialAvailableBytes": initial_free,
                    "estimatedFixtureBytes": estimate, "estimateSafetyFactor": ESTIMATE_SAFETY_FACTOR,
                    "capacityPollSeconds": CAPACITY_POLL_SECONDS,
                    "fixtureSizePollSeconds": CapacityWatchdog.SIZE_POLL_SECONDS},
                "emptyStoreStartup": empty_startup,
                "populatedStoreColdStartup": populated_startup,
                "cleanCheckpointStartup": clean_checkpoint_startup,
                "forcedFullRecoveryStartup": populated_startup if args.compare_checkpoint else None,
                "writeLatencySeconds": {
                    "seedBatchAveragePerHead": {"p50": percentile_seconds(seed_write_timings, .50),
                                                "p95": percentile_seconds(seed_write_timings, .95)},
                    "historyRevision": {"p50": percentile_seconds(history_write_timings, .50),
                                        "p95": percentile_seconds(history_write_timings, .95)},
                    "concurrentWrites": {"p50": percentile_seconds(concurrent_write_timings, .50),
                                         "p95": percentile_seconds(concurrent_write_timings, .95)},
                },
                "pageLatencySeconds": {"p50": round(percentile(pages, .50), 6),
                                       "p95": round(percentile(pages, .95), 6)},
                "savedView": {"categoryRule": 'sender == "person7@example.invalid"',
                              "expectedAndObservedTotal": expected_saved_view_total,
                              "firstPageSeconds": round(first_saved_view_seconds, 6),
                              "warmPageSeconds": round(warm_saved_view_seconds, 6)},
                "concurrentReadLatencySeconds": {"p50": round(percentile(concurrent_reads, .50), 6),
                                                  "p95": round(percentile(concurrent_reads, .95), 6)},
                "concurrencyWindowSeconds": round(concurrency_seconds, 3),
                "concurrentWrites": args.writes, "readers": args.readers,
                "measuredRequestsBytesSent": client.bytes_sent + reader_bytes_sent,
                "measuredResponseBytesReceived": client.bytes_received + reader_bytes_received,
                "measurementScope": "query pages and concurrent write/query phase; excludes fixture loading",
                "populatedServerRSSKiB": rss_kib(process.pid),
                "unavailable": ["cold page latency", "full index rebuild time", "queue delay/index lag",
                                "category graph cost", "vector/extraction cost", "canonical disk bytes"],
            }
    signal.setitimer(signal.ITIMER_REAL, 0)
    print(json.dumps(metrics, indent=2))


if __name__ == "__main__":
    main()
