#!/usr/bin/env python3
"""Disposable integration checks against an explicit private 16.2 store fixture."""
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
TEMP_ROOT = Path(tempfile.gettempdir()).resolve()
FIXTURE = None
PREBUILT_BINARY = None
BOUNDARIES = ("prepared", "pending", "fence", "dirty", "moving", "move-intent",
              "move-completed", "move-cleared", "completion-marker", "journal-complete", "pending-removed")


class BridgeFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if FIXTURE is None:
            raise RuntimeError("Fixture path was not configured; run with --fixture PRIVATE_FIXTURE_DIR")
        fixture_store = FIXTURE / "store"
        manifest_path = FIXTURE / "manifest.json"
        if not manifest_path.is_file() or not fixture_store.is_dir():
            raise RuntimeError(
                f"Fixture is incomplete at {FIXTURE}; create it with "
                "produce_fixture.py --binary /path/to/tractanda-0.1.0-poc.16.2 --output PRIVATE_DIR"
            )
        if shutil.disk_usage(TEMP_ROOT).free < 10 * 1024**3:
            raise RuntimeError(f"Need at least 10 GiB free on the temporary filesystem ({TEMP_ROOT})")
        fixture_size = sum(p.stat().st_size for p in fixture_store.rglob("*") if p.is_file())
        if fixture_size > 128 * 1024**2:
            raise RuntimeError(f"Fixture is {fixture_size} bytes; limit is 128 MiB")
        fixture_stat = FIXTURE.stat()
        store_stat = fixture_store.stat()
        if os.name == "posix" and (
            fixture_stat.st_uid != os.getuid() or fixture_stat.st_mode & 0o077
            or store_stat.st_uid != os.getuid() or store_stat.st_mode & 0o077
        ):
            raise RuntimeError("Fixture directory and store must be owned by the current user and private (mode 0700)")
        cls.build = None
        if PREBUILT_BINARY is not None:
            cls.binary = PREBUILT_BINARY
        else:
            if platform.system() != "Darwin":
                raise RuntimeError(
                    "Automatic helper compilation is supported on macOS only. On Linux, pass --binary PATH "
                    "to an instrumented helper built with LAYOUT17_PRIVATE_FIXTURE and the configured Swift Crypto/SPM dependencies."
                )
            cls.build = tempfile.TemporaryDirectory(prefix="layout17-build-", dir=TEMP_ROOT)
            build = Path(cls.build.name)
            cache = build / "cache"
            cache.mkdir(mode=0o700)
            cls.binary = build / "bridge"
            subprocess.run(["clang", "-c", "-std=c11", "-D_DARWIN_C_SOURCE", str(HERE / "moves.c"),
                            "-o", str(build / "moves.o")], check=True)
            subprocess.run(["swiftc", "-D", "LAYOUT17_PRIVATE_FIXTURE", "-module-cache-path", str(cache),
                            str(HERE / "main.swift"), str(build / "moves.o"), "-o", str(cls.binary)], check=True)
        if not cls.binary.is_file() or not os.access(cls.binary, os.X_OK):
            raise RuntimeError(f"Instrumented helper is not an executable file: {cls.binary}")
        cls.manifest = json.loads(manifest_path.read_text())
        if cls.manifest.get("schema") != "tractanda.layout17-fixture.poc16.2.v1":
            raise RuntimeError(f"Unsupported fixture manifest schema: {cls.manifest.get('schema')!r}")

    @classmethod
    def tearDownClass(cls):
        if cls.build is not None:
            cls.build.cleanup()

    def check_content(self, store):
        for record in self.manifest["records"]:
            old = Path(record["path"])
            new = old.parent.parent / (old.parent.name + "." + old.name)
            self.assertFalse((store / old).exists())
            self.check_file(store / new, record)
        attachment = self.manifest["originalAttachment"]
        for record in attachment["payloads"]:
            self.check_file(store / record["path"], record)
        for record in attachment["placementIntentFiles"]:
            self.check_file(store / record["path"].replace("attachments/.placements/", "attachments/placements/"), record)
        upload = self.manifest["partialUpload"]
        for record in upload["stageFiles"]:
            self.check_file(store / record["path"].replace("attachments/.staging/", "attachments/staging/"), record)
        for record in upload["checkpointFiles"]:
            self.check_file(store / record["path"], record)
        self.assertFalse((store / "canonical-layout.pending.json").exists())
        self.assertTrue((store / ".tractanda-checkpoint-dirty").is_file())
        marker = json.loads((store / "canonical-layout.json").read_text())
        self.assertEqual(marker["layout"], "flat-items-visible-attachments.v1")
        requirement = json.loads((store / "canonical-reader.json").read_text())
        self.assertEqual(requirement["minimumReaderLevel"], 19)
        self.assertIn("tractanda.physical-layout.flat-items.v1", requirement["capabilities"])
        self.assertEqual(requirement["storeID"], self.manifest["storeIDs"]["store"]["storeID"])

    def check_file(self, path, expected):
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), expected["sha256"])
        self.assertEqual(path.stat().st_size, expected["size"])
        self.assertEqual(oct(path.stat().st_mode & 0o777), expected["mode"])

    def test_each_boundary_resumes_and_preserves_fixture(self):
        store_id = self.manifest["storeIDs"]["store"]["storeID"]
        replica_id = self.manifest["storeIDs"]["replica"]["replicaID"]
        metadata_cuts = ("metadata-temp:layout17-" + store_id + "-" + replica_id + ".json",
                         "metadata-temp:canonical-layout.pending.json",
                         "metadata-temp:canonical-reader.json",
                         "metadata-temp:.tractanda-checkpoint-dirty",
                         "metadata-temp:canonical-layout.json")
        for boundary in BOUNDARIES + metadata_cuts:
            with self.subTest(boundary=boundary), tempfile.TemporaryDirectory(prefix="layout17-cut-", dir=TEMP_ROOT) as temp:
                root = Path(temp)
                store, journal = root / "store", root / "journal"
                shutil.copytree(FIXTURE / "store", store)
                journal.mkdir(mode=0o700)
                env = dict(os.environ, LAYOUT17_TEST_FAULT=boundary)
                failed = subprocess.run([str(self.binary), str(store), str(journal)], env=env, capture_output=True, text=True)
                self.assertEqual(failed.returncode, 90, failed.stderr)
                resumed = subprocess.run([str(self.binary), str(store), str(journal)], capture_output=True, text=True)
                self.assertEqual(resumed.returncode, 0, resumed.stderr)
                self.check_content(store)
                repeated = subprocess.run([str(self.binary), str(store), str(journal)], capture_output=True, text=True)
                self.assertEqual(repeated.returncode, 0, repeated.stderr)

    def test_bad_arrival_minute_and_envelope_fail_before_any_marker(self):
        for corruption in ("minute", "header"):
            with self.subTest(corruption=corruption), tempfile.TemporaryDirectory(prefix="layout17-bad-", dir=TEMP_ROOT) as temp:
                root = Path(temp)
                store, journal = root / "store", root / "journal"
                shutil.copytree(FIXTURE / "store", store)
                journal.mkdir(mode=0o700)
                record = store / self.manifest["records"][0]["path"]
                if corruption == "minute":
                    minute = record.parent.parent
                    minute.rename(minute.parent / "99")
                else:
                    old = record.parent
                    old.rename(old.parent / "00000000-0000-1000-8000-000000000001")
                result = subprocess.run([str(self.binary), str(store), str(journal)], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((store / "canonical-layout.pending.json").exists())
                self.assertFalse((store / "canonical-layout.json").exists())
                self.assertEqual(list(journal.iterdir()), [])

    def test_enospc_is_recoverable_before_and_during_migration(self):
        store_id = self.manifest["storeIDs"]["store"]["storeID"]
        replica_id = self.manifest["storeIDs"]["replica"]["replicaID"]
        for failure in ("metadata:layout17-" + store_id + "-" + replica_id + ".json",
                        "metadata:canonical-reader.json", "move", "metadata:canonical-layout.json"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory(prefix="layout17-space-", dir=TEMP_ROOT) as temp:
                root = Path(temp)
                store, journal = root / "store", root / "journal"
                shutil.copytree(FIXTURE / "store", store)
                journal.mkdir(mode=0o700)
                env = dict(os.environ, LAYOUT17_TEST_ENOSPC=failure)
                failed = subprocess.run([str(self.binary), str(store), str(journal)], env=env, capture_output=True, text=True)
                self.assertNotEqual(failed.returncode, 0)
                resumed = subprocess.run([str(self.binary), str(store), str(journal)], capture_output=True, text=True)
                self.assertEqual(resumed.returncode, 0, resumed.stderr)
                self.check_content(store)

    def test_nested_journal_and_tampered_pending_fail_closed(self):
        with tempfile.TemporaryDirectory(prefix="layout17-guard-", dir=TEMP_ROOT) as temp:
            root = Path(temp)
            store, journal = root / "store", root / "journal"
            shutil.copytree(FIXTURE / "store", store)
            nested = store / "attachments/.staging/journal"
            nested.mkdir(mode=0o700)
            failed = subprocess.run([str(self.binary), str(store), str(nested)], capture_output=True, text=True)
            self.assertNotEqual(failed.returncode, 0)
            self.assertFalse((store / "canonical-layout.pending.json").exists())
            nested.rmdir()
            journal.mkdir(mode=0o700)
            env = dict(os.environ, LAYOUT17_TEST_FAULT="pending")
            failed = subprocess.run([str(self.binary), str(store), str(journal)], env=env, capture_output=True, text=True)
            self.assertEqual(failed.returncode, 90)
            pending = store / "canonical-layout.pending.json"
            pending.write_bytes(b"unexpected")
            retry = subprocess.run([str(self.binary), str(store), str(journal)], capture_output=True, text=True)
            self.assertNotEqual(retry.returncode, 0)
            self.assertEqual(pending.read_bytes(), b"unexpected")
            self.assertFalse((store / "canonical-layout.json").exists())

    def test_cluster_without_intent_stops_before_any_marker(self):
        with tempfile.TemporaryDirectory(prefix="layout17-cluster-", dir=TEMP_ROOT) as temp:
            root = Path(temp)
            store, journal = root / "store", root / "journal"
            shutil.copytree(FIXTURE / "store", store)
            journal.mkdir(mode=0o700)
            ids = self.manifest["storeIDs"]
            config = {"profile": "tractanda.personal-membership.v1", "storeID": ids["store"]["storeID"],
                      "configurationID": "00000000-0000-1000-8000-000000000003",
                      "members": [{"replicaID": ids["replica"]["replicaID"], "hostname": "first.example"},
                                  {"replicaID": "00000000-0000-1000-8000-000000000004", "hostname": "second.example"}]}
            membership = store / ".personal-membership.json"
            membership.write_text(json.dumps(config))
            membership.chmod(0o600)
            result = subprocess.run([str(self.binary), str(store), str(journal)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("requires administrator-coordinated", result.stderr)
            self.assertFalse((store / "canonical-layout.pending.json").exists())
            self.assertEqual(list(journal.iterdir()), [])

    def test_two_local_replicas_share_journal_directory_without_collision(self):
        with tempfile.TemporaryDirectory(prefix="layout17-replicas-", dir=TEMP_ROOT) as temp:
            root = Path(temp)
            first, second, journal = root / "first", root / "second", root / "journal"
            shutil.copytree(FIXTURE / "store", first)
            shutil.copytree(FIXTURE / "store", second)
            journal.mkdir(mode=0o700)
            replica = "00000000-0000-1000-8000-000000000004"
            for name in (".tractanda-personal-profile.json", ".tractanda-replica-identity.json"):
                path = second / name
                content = json.loads(path.read_text())
                content["replicaID"] = replica
                prior_mode = path.stat().st_mode & 0o777
                path.chmod(0o600)
                path.write_text(json.dumps(content))
                path.chmod(prior_mode)
            for store in (first, second):
                result = subprocess.run([str(self.binary), str(store), str(journal)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.check_content(store)
            store_id = self.manifest["storeIDs"]["store"]["storeID"]
            original_replica = self.manifest["storeIDs"]["replica"]["replicaID"]
            self.assertEqual({p.name for p in journal.iterdir()}, {
                "layout17-" + store_id + "-" + original_replica + ".json",
                "layout17-" + store_id + "-" + replica + ".json",
            })

    def test_candidate_staging_validates_inventory_and_cleans_up(self):
        for corruption in ("none", "hash", "mode", "symlink", "collision"):
            with self.subTest(corruption=corruption), tempfile.TemporaryDirectory(prefix="layout17-stage-", dir=TEMP_ROOT) as temp:
                root = Path(temp)
                source, stages = root / "source", root / "stages"
                (source / "bin").mkdir(parents=True, mode=0o700)
                stages.mkdir(mode=0o700)
                setup = source / "bin/tractanda-setup"
                setup.write_bytes(b"#!/bin/sh\nexit 0\n")
                setup.chmod(0o755)
                asset = source / "asset"
                asset.write_bytes(b"candidate asset")
                asset.chmod(0o400)
                files = [{"path": "bin/tractanda-setup", "sha256": hashlib.sha256(setup.read_bytes()).hexdigest(),
                          "size": setup.stat().st_size, "mode": 0o755},
                         {"path": "asset", "sha256": hashlib.sha256(asset.read_bytes()).hexdigest(),
                          "size": asset.stat().st_size, "mode": 0o400}]
                if corruption == "hash": files[1]["sha256"] = "0" * 64
                if corruption == "mode": asset.chmod(0o600)
                if corruption == "symlink":
                    asset.unlink()
                    asset.symlink_to(setup)
                if corruption == "collision": files.append(dict(files[1], path="ASSET"))
                machine = platform.machine().lower()
                if machine not in ("arm64", "aarch64", "x86_64", "amd64"):
                    raise RuntimeError(f"Unsupported fixture architecture: {machine}")
                system = platform.system()
                if system not in ("Darwin", "Linux"):
                    raise RuntimeError(f"Unsupported fixture platform: {system}")
                manifest = {"profile": "tractanda.bundle.v1", "version": "0.1.0-poc.17",
                            "platform": "macos" if system == "Darwin" else "linux",
                            "arch": "arm64" if machine in ("arm64", "aarch64") else "x86_64", "files": files}
                (source / "bundle-manifest.json").write_text(json.dumps(manifest))
                result = subprocess.run([str(self.binary), "stage-fixture", str(source), str(stages)],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, corruption == "none", result.stderr)
                self.assertEqual(list(stages.iterdir()), [], "Temporary protected stage was not cleaned")


def main():
    parser = argparse.ArgumentParser(
        description="Run private layout17 migration fault and integrity checks against an explicit fixture."
    )
    parser.add_argument("--fixture", required=True, type=Path,
                        help="private fixture root containing manifest.json and store/")
    parser.add_argument("--binary", type=Path,
                        help="prebuilt instrumented helper (required outside macOS)")
    args, unittest_args = parser.parse_known_args()
    global FIXTURE, PREBUILT_BINARY
    FIXTURE = args.fixture.expanduser().resolve()
    if not (FIXTURE / "manifest.json").is_file() or not (FIXTURE / "store").is_dir():
        parser.error(
            f"fixture is missing or incomplete at {FIXTURE}; create a private 16.2 fixture with "
            "produce_fixture.py --binary /path/to/tractanda-0.1.0-poc.16.2 --output PRIVATE_DIR"
        )
    if args.binary is not None:
        PREBUILT_BINARY = args.binary.expanduser().resolve()
        if not PREBUILT_BINARY.is_file() or not os.access(PREBUILT_BINARY, os.X_OK):
            parser.error(f"--binary must be an executable instrumented helper: {PREBUILT_BINARY}")
    elif platform.system() != "Darwin":
        parser.error(
            "automatic helper compilation is macOS-only; on Linux pass --binary PATH to an executable built "
            "with LAYOUT17_PRIVATE_FIXTURE and the configured Swift Crypto/SPM dependencies"
        )
    sys.argv = [sys.argv[0], *unittest_args]
    unittest.main()


if __name__ == "__main__":
    main()
