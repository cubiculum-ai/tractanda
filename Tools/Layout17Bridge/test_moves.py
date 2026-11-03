#!/usr/bin/env python3
"""Private fixture for the bridge's independently compiled POSIX primitive."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
HARNESS = r'''
#include "moves.h"
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc != 9) return 2;
    int a = open(argv[1], O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    int b = open(argv[3], O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (a < 0 || b < 0) return 3;
    int rc = atoi(argv[8]) ?
        layout17_move_directory(a, argv[2], b, argv[4], getuid(),
            strtoull(argv[5], 0, 10), strtoull(argv[6], 0, 10), atoi(argv[7])) :
        layout17_move_file(a, argv[2], b, argv[4], getuid(),
            strtoull(argv[5], 0, 10), strtoull(argv[6], 0, 10), atoi(argv[7]));
    if (rc) perror("layout17_move_file");
    close(a); close(b);
    return rc ? 1 : 0;
}
'''


class MoveTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="layout17-move-build-")
        build = Path(cls.temp.name)
        (build / "harness.c").write_text(HARNESS)
        cls.binary = build / "harness"
        subprocess.run(["cc", "-std=c11", "-D_DARWIN_C_SOURCE", "-D_GNU_SOURCE",
                        "-Wall", "-Wextra", "-Werror", "-I", str(HERE),
                        str(HERE / "moves.c"), str(build / "harness.c"),
                        "-o", str(cls.binary)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory(prefix="layout17-move-fixture-")
        self.addCleanup(self.tempdir.cleanup)
        self.root = Path(self.tempdir.name)
        self.old = self.root / "old"
        self.new = self.root / "new"
        self.old.mkdir()
        self.new.mkdir()
        self.payload = (b"preserve canonical bytes\x00" * 2048)
        (self.old / "revision").write_bytes(self.payload)
        metadata = (self.old / "revision").stat()
        self.pin = (str(metadata.st_dev), str(metadata.st_ino))

    def move(self, fault=0):
        return subprocess.run([str(self.binary), str(self.old), "revision", str(self.new),
                               "item.revision", *self.pin, str(fault), "0"], capture_output=True)

    def test_interrupted_link_resumes_without_changing_bytes(self):
        digest = hashlib.sha256(self.payload).digest()
        self.assertNotEqual(self.move(1).returncode, 0)
        self.assertTrue((self.old / "revision").samefile(self.new / "item.revision"))
        self.assertEqual(self.move().returncode, 0)
        self.assertFalse((self.old / "revision").exists())
        self.assertEqual(hashlib.sha256((self.new / "item.revision").read_bytes()).digest(), digest)
        self.assertEqual(self.move().returncode, 0)

    def test_collision_and_symlink_are_not_overwritten(self):
        target = self.new / "item.revision"
        target.write_bytes(b"unrelated")
        self.assertNotEqual(self.move().returncode, 0)
        self.assertEqual(target.read_bytes(), b"unrelated")
        target.unlink()
        target.symlink_to(self.old / "revision")
        self.assertNotEqual(self.move().returncode, 0)
        self.assertTrue(target.is_symlink())
        self.assertEqual((self.old / "revision").read_bytes(), self.payload)

    def test_interrupted_unlink_is_resynchronized(self):
        self.assertNotEqual(self.move(2).returncode, 0)
        self.assertFalse((self.old / "revision").exists())
        self.assertEqual(self.move().returncode, 0)
        self.assertEqual((self.new / "item.revision").read_bytes(), self.payload)

    def test_unrelated_hard_link_refused(self):
        os.link(self.old / "revision", self.root / "unrelated-link")
        self.assertNotEqual(self.move().returncode, 0)
        self.assertFalse((self.new / "item.revision").exists())

    def test_replaced_source_does_not_match_pin(self):
        source = self.old / "revision"
        source.rename(self.old / "original")
        source.write_bytes(b"replacement")
        self.assertNotEqual(self.move().returncode, 0)
        self.assertEqual(source.read_bytes(), b"replacement")
        self.assertEqual((self.old / "original").read_bytes(), self.payload)
        self.assertFalse((self.new / "item.revision").exists())

    def test_directory_rename_interruption_and_collision(self):
        staging = self.old / ".staging"
        staging.mkdir()
        (staging / "pending").write_bytes(self.payload)
        meta = staging.stat()
        args = [str(self.binary), str(self.old), ".staging", str(self.new), "staging",
                str(meta.st_dev), str(meta.st_ino)]
        occupied = self.new / "staging"
        occupied.mkdir()
        self.assertNotEqual(subprocess.run(args + ["0", "1"], capture_output=True).returncode, 0)
        self.assertTrue(staging.is_dir())
        occupied.rmdir()
        self.assertNotEqual(subprocess.run(args + ["1", "1"], capture_output=True).returncode, 0)
        self.assertEqual(subprocess.run(args + ["0", "1"], capture_output=True).returncode, 0)
        self.assertEqual((occupied / "pending").read_bytes(), self.payload)

    def test_item_revision_flattening_retains_arrival_minute_and_metadata(self):
        minute = self.root / "items/2026/11/03/10/52"
        item = "00000000-0000-1000-8000-000000000001"
        revision = "00000000-0000-1000-8000-000000000002"
        original = minute / item / (revision + ".tractanda")
        original.parent.mkdir(parents=True)
        original.write_bytes(self.payload)
        original.chmod(0o400)
        meta = original.stat()
        target = item + "." + revision + ".tractanda"
        args = [str(self.binary), str(original.parent), original.name, str(minute), target,
                str(meta.st_dev), str(meta.st_ino), "0", "0"]
        self.assertEqual(subprocess.run(args, capture_output=True).returncode, 0)
        flattened = minute / target
        self.assertEqual(flattened.read_bytes(), self.payload)
        self.assertEqual(flattened.stat().st_ino, meta.st_ino)
        self.assertEqual(flattened.stat().st_mode & 0o777, 0o400)
        self.assertFalse(original.exists())


if __name__ == "__main__":
    unittest.main()
