#!/usr/bin/env python3
"""Small, offline tests for validate-docling-model.py."""

import hashlib
import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("validate-docling-model.py")
SPEC = importlib.util.spec_from_file_location("docling_model_validator", SCRIPT)
validator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validator)


class DoclingModelValidatorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "model"
        self.root.mkdir()
        self.manifest = {"revision": validator.PINNED_REVISION, "files": []}
        for name in sorted(validator.PINNED_FILES):
            data = ("fixture:" + name).encode()
            (self.root / name).write_bytes(data)
            self.manifest["files"].append({"file": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})

    def tearDown(self):
        self.temp.cleanup()

    def test_valid_directory_produces_compact_file_proof(self):
        proof = validator.validate_model_directory(self.root, manifest=self.manifest)
        self.assertEqual(proof["status"], "verified")
        self.assertEqual(proof["revision"], validator.PINNED_REVISION)
        self.assertEqual(proof["fileCount"], 14)
        self.assertEqual({row["file"] for row in proof["files"]}, validator.PINNED_FILES)
        self.assertTrue(all(row["status"] == "verified" for row in proof["files"]))

    def test_length_and_hash_mismatches_fail(self):
        path = self.root / self.manifest["files"][0]["file"]
        path.write_bytes(b"different-length")
        with self.assertRaisesRegex(validator.ValidationError, "length mismatch"):
            validator.validate_model_directory(self.root, manifest=self.manifest)
        entry = self.manifest["files"][0]
        data = ("fixture:" + entry["file"]).encode()
        path.write_bytes(b"X" * len(data))
        with self.assertRaisesRegex(validator.ValidationError, "SHA-256 mismatch"):
            validator.validate_model_directory(self.root, manifest=self.manifest)

    def test_manifest_shape_revision_paths_and_duplicates_fail(self):
        malformed = dict(self.manifest, extra=True)
        with self.assertRaisesRegex(validator.ValidationError, "exactly"):
            validator.validate_model_directory(self.root, manifest=malformed)
        malformed = json.loads(json.dumps(self.manifest))
        malformed["revision"] = "mutable-main"
        with self.assertRaisesRegex(validator.ValidationError, "pinned revision"):
            validator.validate_model_directory(self.root, manifest=malformed)
        malformed = json.loads(json.dumps(self.manifest))
        malformed["files"][0]["file"] = "../escape"
        with self.assertRaisesRegex(validator.ValidationError, "unsafe file path"):
            validator.validate_model_directory(self.root, manifest=malformed)
        malformed = json.loads(json.dumps(self.manifest))
        malformed["files"][0]["file"] = malformed["files"][1]["file"]
        with self.assertRaisesRegex(validator.ValidationError, "duplicate path"):
            validator.validate_model_directory(self.root, manifest=malformed)
        with self.assertRaisesRegex(validator.ValidationError, "duplicate JSON member"):
            validator._load_manifest_json('{"revision":"first","revision":"second"}')

    def test_symlinks_missing_and_extra_entries_fail(self):
        name = self.manifest["files"][0]["file"]
        path = self.root / name
        data = path.read_bytes()
        path.unlink()
        outside = Path(self.temp.name) / "outside"
        outside.write_bytes(data)
        path.symlink_to(outside)
        with self.assertRaisesRegex(validator.ValidationError, "cannot safely open"):
            validator.validate_model_directory(self.root, manifest=self.manifest)
        path.unlink()
        path.write_bytes(data)
        (self.root / "extra.txt").write_text("not packaged")
        with self.assertRaisesRegex(validator.ValidationError, "will not be packaged"):
            validator.validate_model_directory(self.root, manifest=self.manifest)
        (self.root / "extra.txt").unlink()
        (self.root / name).unlink()
        with self.assertRaisesRegex(validator.ValidationError, "missing pinned files"):
            validator.validate_model_directory(self.root, manifest=self.manifest)

    def test_changed_read_fails(self):
        original_read = validator.os.read
        target_name = self.manifest["files"][0]["file"]
        target_fd = None
        changed_once = False
        real_open = validator.os.open

        def track_open(path, flags, *args, **kwargs):
            nonlocal target_fd
            fd = real_open(path, flags, *args, **kwargs)
            if path == target_name:
                target_fd = fd
            return fd

        def changed_read(fd, size):
            nonlocal changed_once
            if fd == target_fd:
                actual = original_read(fd, size)
                if actual and not changed_once:
                    changed_once = True
                    return b"changed-content"
                return actual
            return original_read(fd, size)

        with mock.patch.object(validator.os, "open", side_effect=track_open), mock.patch.object(validator.os, "read", side_effect=changed_read):
            with self.assertRaisesRegex(validator.ValidationError, "changed while being read|SHA-256 mismatch"):
                validator.validate_model_directory(self.root, manifest=self.manifest)

    def test_fifo_open_is_nonblocking_in_bounded_subprocess(self):
        name = self.manifest["files"][0]["file"]
        (self.root / name).unlink()
        os.mkfifo(self.root / name)
        manifest_path = Path(self.temp.name) / "fixture-manifest.json"
        manifest_path.write_text(json.dumps(self.manifest))
        child = """
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("validator", sys.argv[1])
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)
manifest = json.loads(open(sys.argv[3]).read())
try:
    validator.validate_model_directory(sys.argv[2], manifest=manifest)
except validator.ValidationError as exc:
    print(exc)
    sys.exit(0)
sys.exit(3)
"""
        result = subprocess.run(
            [sys.executable, "-c", child, str(SCRIPT), str(self.root), str(manifest_path)],
            capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("is not a regular file", result.stdout)

    def _track_file_descriptor(self, name):
        target_fd = None
        real_open = validator.os.open

        def track_open(path, flags, *args, **kwargs):
            nonlocal target_fd
            fd = real_open(path, flags, *args, **kwargs)
            if path == name:
                target_fd = fd
            return fd

        return lambda: target_fd, track_open

    def test_growing_file_read_stops_at_one_sentinel_byte(self):
        entry = self.manifest["files"][0]
        get_target_fd, track_open = self._track_file_descriptor(entry["file"])
        original_read = validator.os.read
        reads = 0

        def growing_read(fd, size):
            nonlocal reads
            if fd == get_target_fd():
                reads += 1
                if reads == 2:
                    return b"x"
                if reads > 2:
                    return b""
            return original_read(fd, size)

        with mock.patch.object(validator.os, "open", side_effect=track_open), mock.patch.object(validator.os, "read", side_effect=growing_read):
            with self.assertRaisesRegex(validator.ValidationError, "exceeds declared length"):
                validator.validate_model_directory(self.root, manifest=self.manifest)
        self.assertEqual(reads, 2)

    def test_read_and_fstat_errors_are_validation_errors(self):
        entry = self.manifest["files"][0]
        get_target_fd, track_open = self._track_file_descriptor(entry["file"])
        original_read = validator.os.read

        def failed_read(fd, size):
            if fd == get_target_fd():
                raise OSError("simulated read failure")
            return original_read(fd, size)

        with mock.patch.object(validator.os, "open", side_effect=track_open), mock.patch.object(validator.os, "read", side_effect=failed_read):
            with self.assertRaisesRegex(validator.ValidationError, "cannot read/stat .*simulated read failure"):
                validator.validate_model_directory(self.root, manifest=self.manifest)

        get_target_fd, track_open = self._track_file_descriptor(entry["file"])
        original_fstat = validator.os.fstat

        def failed_fstat(fd):
            if fd == get_target_fd():
                raise OSError("simulated fstat failure")
            return original_fstat(fd)

        with mock.patch.object(validator.os, "open", side_effect=track_open), mock.patch.object(validator.os, "fstat", side_effect=failed_fstat):
            with self.assertRaisesRegex(validator.ValidationError, "cannot stat opened .*simulated fstat failure"):
                validator.validate_model_directory(self.root, manifest=self.manifest)

    def test_cli_serializes_validation_errors_as_json(self):
        stderr = io.StringIO()
        with mock.patch.object(validator, "validate_model_directory", side_effect=validator.ValidationError("simulated I/O failure")), contextlib.redirect_stderr(stderr):
            code = validator.main([str(self.root)])
        self.assertEqual(code, 2)
        self.assertEqual(json.loads(stderr.getvalue()), {"status": "error", "error": "simulated I/O failure"})


if __name__ == "__main__":
    unittest.main()
