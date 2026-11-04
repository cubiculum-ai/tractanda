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
              "revision-temp", "revision-published", "revision-retired", "move-completed",
              "move-cleared", "completion-marker", "journal-complete", "pending-removed")


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
            raise RuntimeError("Pass --binary PATH to the instrumented SwiftPM helper built with LAYOUT17_PRIVATE_FIXTURE.")
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
            old_bytes = (FIXTURE / "store" / old).read_bytes()
            self.assertEqual(hashlib.sha256(old_bytes).hexdigest(), record["sha256"])
            old_revision = subprocess.run([str(self.binary), "record-fixture", "legacy", str(FIXTURE / "store" / old)],
                                          capture_output=True, text=True, check=True)
            new_revision = subprocess.run([str(self.binary), "record-fixture", "message", str(store / new)],
                                          capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(old_revision.stdout), json.loads(new_revision.stdout))
            self.assertEqual(oct((store / new).stat().st_mode & 0o777), record["mode"])
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
        self.assertEqual(requirement["minimumReaderLevel"], 20)
        self.assertIn("tractanda.physical-layout.flat-items.v1", requirement["capabilities"])
        self.assertIn("tractanda.message-items.v1", requirement["capabilities"])
        self.assertEqual(marker["recordEncoding"], "message-v1")
        self.assertEqual(requirement["storeID"], self.manifest["storeIDs"]["store"]["storeID"])

    def check_file(self, path, expected):
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), expected["sha256"])
        self.assertEqual(path.stat().st_size, expected["size"])
        self.assertEqual(oct(path.stat().st_mode & 0o777), expected["mode"])

    def descriptor_key(self, value, parent):
        path = parent / "descriptor-input.json"
        path.write_text(json.dumps(value))
        result = subprocess.run([str(self.binary), "descriptor-fixture", str(path)],
                                capture_output=True, text=True, check=True)
        path.unlink()
        return result.stdout.strip()

    def make_pending_reviews(self, store, parent, disposition="pending"):
        """Synthetic peer metadata, using a genuine 16.2 record and real descriptor-key encoding."""
        record = self.manifest["records"][0]
        accepted_raw = (store / record["path"]).read_bytes()
        headers, body = accepted_raw.split(b"\r\n\r\n", 1)
        revision = json.loads(body)
        fields = revision["fields"]
        item_id, revision_id = fields["itemID"]["value"], fields["revisionID"]["value"]
        parents = [entry["value"] for entry in fields.get("revisionAncestry", {}).get("value", {}).get("parents", {}).get("value", [])]
        accepted = {"kind": "revision", "id": revision_id, "itemID": item_id,
                    "byteCount": len(accepted_raw), "sha256": hashlib.sha256(accepted_raw).hexdigest(),
                    "parentRevisionIDs": parents}
        accepted_key = self.descriptor_key(accepted, parent)
        source_replica = self.manifest["storeIDs"]["replica"]["replicaID"]
        accepted_review = {"reviewID": "00000000-0000-1000-8000-000000000006", "descriptor": accepted,
            "sourceReplicaID": source_replica, "currentFrontier": [], "baseRevisionIDs": parents,
            "reason": "fixture accepted review", "disposition": "accepted"}

        new_item = "00000000-0000-1000-8000-000000000007"
        new_revision = "00000000-0000-1000-8000-000000000008"
        stage_id = "00000000-0000-1000-8000-000000000009"
        fields["itemID"]["value"] = new_item
        fields["revisionID"]["value"] = new_revision
        fields["operationID"]["value"] = "layout17-synthetic-pending-revision"
        fields["requestIdentity"]["value"] = "layout17-synthetic-pending-request"
        changed_headers = headers.replace(item_id.encode(), new_item.encode()).replace(revision_id.encode(), new_revision.encode())
        staged_raw = changed_headers + b"\r\n\r\n" + json.dumps(revision, sort_keys=True, indent=2).encode() + b"\n"
        descriptor = {"kind": "revision", "id": new_revision, "itemID": new_item,
                      "byteCount": len(staged_raw), "sha256": hashlib.sha256(staged_raw).hexdigest(),
                      "parentRevisionIDs": parents}
        stage_key = self.descriptor_key(descriptor, parent)
        review = {"reviewID": "00000000-0000-1000-8000-00000000000a", "descriptor": descriptor,
            "sourceReplicaID": source_replica, "currentFrontier": [], "baseRevisionIDs": parents,
            "reason": "fixture retained review", "disposition": disposition}
        stages, reviews = store / ".personal-sync/stages", store / ".personal-sync/reviews"
        stages.mkdir(parents=True, mode=0o700, exist_ok=True)
        reviews.mkdir(parents=True, mode=0o700, exist_ok=True)
        (store / ".personal-sync").chmod(0o700)
        for path, value in ((stages / (stage_key + ".json"), {"descriptor": descriptor, "stageID": stage_id}),
                            (reviews / (stage_key + ".json"), review),
                            (reviews / (accepted_key + ".json"), accepted_review)):
            path.write_text(json.dumps(value, sort_keys=True))
            path.chmod(0o400)
        stage = store / "attachments/.staging" / (stage_id + ".stage")
        stage.write_bytes(staged_raw); stage.chmod(0o600)
        original = parent / "old-staged.tractanda"
        original.write_bytes(staged_raw)
        return {"stageID": stage_id, "revisionID": new_revision, "itemID": new_item,
                "oldStageKey": stage_key, "acceptedKey": accepted_key,
                "pendingReviewID": review["reviewID"], "acceptedReviewID": accepted_review["reviewID"],
                "pendingReview": review, "acceptedReview": accepted_review,
                "disposition": disposition, "oldStage": original, "acceptedPath": record["path"]}

    def check_pending_reviews(self, store, fixture, parent):
        stages = store / ".personal-sync/stages"
        bindings = [json.loads(p.read_text()) for p in stages.glob("*.json")]
        stage = next(value for value in bindings if value["stageID"] == fixture["stageID"])
        descriptor = stage["descriptor"]
        new_key = self.descriptor_key(descriptor, parent)
        self.assertNotEqual(new_key, fixture["oldStageKey"])
        self.assertTrue((stages / (new_key + ".json")).is_file())
        self.assertFalse((stages / (fixture["oldStageKey"] + ".json")).exists())
        stage_file = store / "attachments/staging" / (fixture["stageID"] + ".stage")
        self.assertEqual(hashlib.sha256(stage_file.read_bytes()).hexdigest(), descriptor["sha256"])
        old = subprocess.run([str(self.binary), "record-fixture", "legacy", str(fixture["oldStage"])],
                             capture_output=True, text=True, check=True)
        new = subprocess.run([str(self.binary), "record-fixture", "message", str(stage_file)],
                             capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(old.stdout), json.loads(new.stdout))
        self.assertFalse(any(fixture["itemID"] in path.name for path in (store / "items").rglob("*.tractanda")),
                         "A staged, unaccepted revision must never be promoted into canonical items")
        reviews = [json.loads(p.read_text()) for p in (store / ".personal-sync/reviews").glob("*.json")]
        pending = next(value for value in reviews if value["reviewID"] == fixture["pendingReviewID"])
        accepted = next(value for value in reviews if value["reviewID"] == fixture["acceptedReviewID"])
        self.assertEqual(pending["descriptor"], descriptor)
        self.assertEqual(pending["disposition"], fixture["disposition"])
        self.assertEqual(accepted["disposition"], "accepted")
        for actual, original in ((pending, fixture["pendingReview"]), (accepted, fixture["acceptedReview"])):
            for field in ("reviewID", "sourceReplicaID", "currentFrontier", "baseRevisionIDs", "reason", "disposition"):
                self.assertEqual(actual[field], original[field])
        self.assertFalse((store / ".personal-sync/reviews" / (fixture["acceptedKey"] + ".json")).exists())
        accepted_key = self.descriptor_key(accepted["descriptor"], parent)
        self.assertTrue((store / ".personal-sync/reviews" / (accepted_key + ".json")).is_file())

    def test_pending_review_rekey_and_resume_boundaries(self):
        cuts = ("stage-intent", "private-metadata-temp", "stage-binding-published", "review-published",
                "review-retired", "stage-temp", "stage-data-published", "stage-binding-retired", "stage-cleared",
                "review-intent", "review-cleared", "revision-retired", "move-cleared")
        for disposition in ("pending", "rejected"):
            for cut in cuts:
                with self.subTest(disposition=disposition, cut=cut), tempfile.TemporaryDirectory(prefix="layout17-review-", dir=TEMP_ROOT) as temp:
                    root = Path(temp); store, journal = root / "store", root / "journal"
                    shutil.copytree(FIXTURE / "store", store); journal.mkdir(mode=0o700)
                    fixture = self.make_pending_reviews(store, root, disposition)
                    failed = subprocess.run([str(self.binary), str(store), str(journal)],
                        env=dict(os.environ, LAYOUT17_TEST_FAULT=cut), capture_output=True, text=True)
                    self.assertEqual(failed.returncode, 90, failed.stderr)
                    if cut == "stage-data-published":
                        self.assertFalse((store / ".personal-sync/reviews" / (fixture["oldStageKey"] + ".json")).exists())
                        data = (store / "attachments/.staging" / (fixture["stageID"] + ".stage")).read_bytes()
                        matching = [json.loads(p.read_text()) for p in (store / ".personal-sync/stages").glob("*.json")]
                        self.assertTrue(any(row["stageID"] == fixture["stageID"] and
                                            row["descriptor"]["sha256"] == hashlib.sha256(data).hexdigest()
                                            for row in matching), "New stage binding must precede byte replacement")
                    if cut == "revision-retired" and not (store / fixture["acceptedPath"]).exists():
                        self.assertFalse((store / ".personal-sync/reviews" / (fixture["acceptedKey"] + ".json")).exists())
                    resumed = subprocess.run([str(self.binary), str(store), str(journal)], capture_output=True, text=True)
                    self.assertEqual(resumed.returncode, 0, resumed.stderr)
                    self.check_content(store)
                    self.check_pending_reviews(store, fixture, root)

    def test_incomplete_revision_stage_refuses_before_mutation(self):
        with tempfile.TemporaryDirectory(prefix="layout17-incomplete-", dir=TEMP_ROOT) as temp:
            root = Path(temp); store, journal = root / "store", root / "journal"
            shutil.copytree(FIXTURE / "store", store); journal.mkdir(mode=0o700)
            fixture = self.make_pending_reviews(store, root)
            stage = store / "attachments/.staging" / (fixture["stageID"] + ".stage")
            stage.write_bytes(stage.read_bytes()[:23])
            failed = subprocess.run([str(self.binary), str(store), str(journal)], capture_output=True, text=True)
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn(fixture["revisionID"], failed.stderr)
            self.assertIn(fixture["stageID"], failed.stderr)
            self.assertEqual(stage.stat().st_size, 23)
            self.assertFalse((store / "canonical-layout.pending.json").exists())
            self.assertEqual(list(journal.iterdir()), [])

    def test_partial_personal_original_stage_and_binding_are_preserved(self):
        with tempfile.TemporaryDirectory(prefix="layout17-original-stage-", dir=TEMP_ROOT) as temp:
            root = Path(temp); store, journal = root / "store", root / "journal"
            shutil.copytree(FIXTURE / "store", store); journal.mkdir(mode=0o700)
            checkpoint = self.manifest["partialUpload"]["checkpointFiles"][0]["path"]
            attachment = json.loads((store / checkpoint).read_text())["descriptor"]
            descriptor = {"kind": "original", "id": attachment["attachmentID"],
                "byteCount": attachment["byteCount"], "sha256": attachment["sha256"],
                "parentRevisionIDs": [], "attachment": attachment}
            descriptor_file = root / "peer-descriptor.json"
            descriptor_file.write_text(json.dumps(descriptor))
            key = subprocess.run([str(self.binary), "peer-descriptor-fixture", str(descriptor_file)],
                                 capture_output=True, text=True, check=True).stdout.strip()
            stage_id = "00000000-0000-1000-8000-00000000000c"
            stages = store / ".personal-sync/stages"
            stages.mkdir(parents=True, mode=0o700, exist_ok=True); stages.parent.chmod(0o700)
            binding = stages / (key + ".json")
            binding.write_text(json.dumps({"stageID": stage_id, "descriptor": descriptor}, sort_keys=True))
            binding.chmod(0o400); binding_bytes = binding.read_bytes()
            staged = store / "attachments/.staging" / (stage_id + ".stage")
            prefix = (FIXTURE / "fixture-partial-upload.bin").read_bytes()[:23]
            staged.write_bytes(prefix); staged.chmod(0o600)
            result = subprocess.run([str(self.binary), str(store), str(journal)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(binding.read_bytes(), binding_bytes)
            self.assertEqual((store / "attachments/staging" / (stage_id + ".stage")).read_bytes(), prefix)
            self.check_content(store)

    def test_distinct_legacy_stage_spellings_that_normalize_to_one_key_refuse(self):
        with tempfile.TemporaryDirectory(prefix="layout17-collision-", dir=TEMP_ROOT) as temp:
            root = Path(temp); store, journal = root / "store", root / "journal"
            shutil.copytree(FIXTURE / "store", store); journal.mkdir(mode=0o700)
            fixture = self.make_pending_reviews(store, root)
            old_file = store / "attachments/.staging" / (fixture["stageID"] + ".stage")
            headers, body = old_file.read_bytes().split(b"\r\n\r\n", 1)
            alternative = headers + b"\r\n\r\n" + json.dumps(json.loads(body), sort_keys=True, separators=(",", ":")).encode() + b"\n"
            binding = json.loads((store / ".personal-sync/stages" / (fixture["oldStageKey"] + ".json")).read_text())
            binding["stageID"] = "00000000-0000-1000-8000-00000000000b"
            binding["descriptor"]["byteCount"] = len(alternative)
            binding["descriptor"]["sha256"] = hashlib.sha256(alternative).hexdigest()
            other_key = self.descriptor_key(binding["descriptor"], root)
            other_binding = store / ".personal-sync/stages" / (other_key + ".json")
            other_binding.write_text(json.dumps(binding, sort_keys=True)); other_binding.chmod(0o400)
            other_stage = store / "attachments/.staging" / (binding["stageID"] + ".stage")
            other_stage.write_bytes(alternative); other_stage.chmod(0o600)
            failed = subprocess.run([str(self.binary), str(store), str(journal)], capture_output=True, text=True)
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn(fixture["stageID"], failed.stderr)
            self.assertIn(binding["stageID"], failed.stderr)
            self.assertEqual(old_file.read_bytes(), fixture["oldStage"].read_bytes())
            self.assertEqual(other_stage.read_bytes(), alternative)
            self.assertFalse((store / "canonical-layout.pending.json").exists())
            self.assertEqual(list(journal.iterdir()), [])

    def test_converted_review_limit_refuses_before_mutation(self):
        with tempfile.TemporaryDirectory(prefix="layout17-review-limit-", dir=TEMP_ROOT) as temp:
            root = Path(temp); store, journal = root / "store", root / "journal"
            shutil.copytree(FIXTURE / "store", store); journal.mkdir(mode=0o700)
            fixture = self.make_pending_reviews(store, root)
            path = store / ".personal-sync/reviews" / (fixture["oldStageKey"] + ".json")
            value = json.loads(path.read_text()); value["reason"] = ""
            base = len(json.dumps(value, sort_keys=True).encode())
            value["reason"] = "x" * (128 * 1024 - base - 1)
            path.chmod(0o600); path.write_text(json.dumps(value, sort_keys=True)); path.chmod(0o400)
            self.assertLessEqual(path.stat().st_size, 128 * 1024)
            failed = subprocess.run([str(self.binary), str(store), str(journal)], capture_output=True, text=True)
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("Converted review", failed.stderr)
            self.assertFalse((store / "canonical-layout.pending.json").exists())
            self.assertEqual(list(journal.iterdir()), [])

    def test_semantically_malformed_complete_stages_refuse_before_mutation(self):
        invalid = {"categoryOrder": {"type": "text", "value": "not an integer"},
                   "viewDefinition": {"type": "text", "value": "not a view"},
                   "attachments": {"type": "list", "value": [{"type": "text", "value": "not a descriptor"}]}}
        for field, value in invalid.items():
            with self.subTest(field=field), tempfile.TemporaryDirectory(prefix="layout17-invalid-stage-", dir=TEMP_ROOT) as temp:
                root = Path(temp); store, journal = root / "store", root / "journal"
                shutil.copytree(FIXTURE / "store", store); journal.mkdir(mode=0o700)
                fixture = self.make_pending_reviews(store, root)
                stage = store / "attachments/.staging" / (fixture["stageID"] + ".stage")
                headers, body = stage.read_bytes().split(b"\r\n\r\n", 1)
                revision = json.loads(body); revision["fields"][field] = value
                writes = revision["fields"]["revisionAncestry"]["value"]["writtenFields"]["value"]
                writes.append({"type": "text", "value": field}); writes.sort(key=lambda entry: entry["value"])
                raw = headers + b"\r\n\r\n" + json.dumps(revision, sort_keys=True, indent=2).encode() + b"\n"
                stage.write_bytes(raw)
                stages = store / ".personal-sync/stages"; reviews = store / ".personal-sync/reviews"
                old_binding = stages / (fixture["oldStageKey"] + ".json")
                binding = json.loads(old_binding.read_text())
                binding["descriptor"]["byteCount"] = len(raw)
                binding["descriptor"]["sha256"] = hashlib.sha256(raw).hexdigest()
                key = self.descriptor_key(binding["descriptor"], root)
                old_binding.unlink(); target = stages / (key + ".json")
                target.write_text(json.dumps(binding, sort_keys=True)); target.chmod(0o400)
                old_review = reviews / (fixture["oldStageKey"] + ".json")
                review = json.loads(old_review.read_text()); review["descriptor"] = binding["descriptor"]
                old_review.unlink(); target_review = reviews / (key + ".json")
                target_review.write_text(json.dumps(review, sort_keys=True)); target_review.chmod(0o400)
                failed = subprocess.run([str(self.binary), str(store), str(journal)], capture_output=True, text=True)
                self.assertNotEqual(failed.returncode, 0)
                self.assertIn(fixture["revisionID"], failed.stderr)
                self.assertIn(fixture["stageID"], failed.stderr)
                self.assertFalse((store / "canonical-layout.pending.json").exists())
                self.assertEqual(list(journal.iterdir()), [])

    def test_private_mode_and_external_hardlink_are_preserved_safely(self):
        with tempfile.TemporaryDirectory(prefix="layout17-hardlink-", dir=TEMP_ROOT) as temp:
            root = Path(temp); store, journal = root / "store", root / "journal"
            shutil.copytree(FIXTURE / "store", store); journal.mkdir(mode=0o700)
            old = Path(self.manifest["records"][0]["path"])
            source = store / old
            original = source.read_bytes()
            source.chmod(0o600)
            old_stat = source.stat()
            backup = root / "external-hardlink"
            os.link(source, backup)
            result = subprocess.run([str(self.binary), str(store), str(journal)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            target = store / old.parent.parent / (old.parent.name + "." + old.name)
            self.assertEqual(backup.read_bytes(), original)
            self.assertEqual(backup.stat().st_ino, old_stat.st_ino)
            self.assertNotEqual(target.stat().st_ino, old_stat.st_ino)
            self.assertEqual(target.stat().st_uid, old_stat.st_uid)
            self.assertEqual(target.stat().st_gid, old_stat.st_gid)
            self.assertEqual(target.stat().st_mode & 0o7777, 0o600)
            legacy = subprocess.run([str(self.binary), "record-fixture", "legacy", str(backup)],
                                    capture_output=True, text=True, check=True)
            message = subprocess.run([str(self.binary), "record-fixture", "message", str(target)],
                                     capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(legacy.stdout), json.loads(message.stdout))
            self.assertFalse(source.exists())

    def test_legacy_format_one_uuidv4_item_converts_without_invented_ancestry(self):
        with tempfile.TemporaryDirectory(prefix="layout17-v4-", dir=TEMP_ROOT) as temp:
            root = Path(temp); store, journal = root / "store", root / "journal"
            shutil.copytree(FIXTURE / "store", store); journal.mkdir(mode=0o700)
            row = self.manifest["records"][0]
            original = (store / row["path"]).read_bytes()
            headers, body = original.split(b"\r\n\r\n", 1)
            value = json.loads(body)
            old_item, old_revision = value["fields"]["itemID"]["value"], value["fields"]["revisionID"]["value"]
            item = "00000000-0000-4000-8000-000000000001"
            revision = "00000000-0000-4000-8000-000000000002"
            value["formatVersion"] = 1
            value["fields"].pop("revisionAncestry", None)
            value["fields"].pop("supersedes", None)
            value["fields"]["itemID"]["value"] = item
            value["fields"]["revisionID"]["value"] = revision
            value["fields"]["operationID"]["value"] = "legacy-v4-fixture"
            value["fields"]["requestIdentity"]["value"] = "legacy-v4-retry"
            headers = headers.replace(old_item.encode(), item.encode()).replace(old_revision.encode(), revision.encode())
            headers = headers.replace(b"X-Tractanda-Format-Version: 2", b"X-Tractanda-Format-Version: 1")
            old_bytes = headers + b"\r\n\r\n" + json.dumps(value, sort_keys=True, indent=2).encode() + b"\n"
            minute = (store / row["path"]).parent.parent
            legacy = minute / item / (revision + ".tractanda")
            legacy.parent.mkdir(mode=0o700)
            legacy.write_bytes(old_bytes); legacy.chmod(0o400)
            original_copy = root / "legacy-v4.tractanda"; original_copy.write_bytes(old_bytes)
            result = subprocess.run([str(self.binary), str(store), str(journal)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            converted = minute / (item + "." + revision + ".tractanda")
            old_decoded = subprocess.run([str(self.binary), "record-fixture", "legacy", str(original_copy)],
                                         capture_output=True, text=True, check=True)
            new_decoded = subprocess.run([str(self.binary), "record-fixture", "message", str(converted)],
                                         capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(old_decoded.stdout), json.loads(new_decoded.stdout))
            message = json.loads(new_decoded.stdout)
            self.assertEqual(message["formatVersion"], 1)
            self.assertNotIn("revisionAncestry", message["fields"])
            self.assertEqual(message["fields"]["itemID"]["value"], item)
            self.assertEqual(message["fields"]["revisionID"]["value"], revision)

    def test_duplicate_canonical_revision_placements_refuse_before_mutation(self):
        with tempfile.TemporaryDirectory(prefix="layout17-duplicate-", dir=TEMP_ROOT) as temp:
            root = Path(temp); store, journal = root / "store", root / "journal"
            shutil.copytree(FIXTURE / "store", store); journal.mkdir(mode=0o700)
            old = store / self.manifest["records"][0]["path"]
            minute = old.parent.parent
            other_minute = minute.parent / ("57" if minute.name != "57" else "58")
            destination = other_minute / old.parent.name / old.name
            destination.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
            other_minute.chmod(0o700)
            os.link(old, destination)
            result = subprocess.run([str(self.binary), str(store), str(journal)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Duplicate canonical revision", result.stderr)
            self.assertTrue(old.samefile(destination))
            self.assertFalse((store / "canonical-layout.pending.json").exists())
            self.assertEqual(list(journal.iterdir()), [])

    def test_changed_hardlinked_source_refuses_retirement_on_resume(self):
        with tempfile.TemporaryDirectory(prefix="layout17-hardlink-change-", dir=TEMP_ROOT) as temp:
            root = Path(temp); store, journal = root / "store", root / "journal"
            shutil.copytree(FIXTURE / "store", store); journal.mkdir(mode=0o700)
            backups = {}
            for index, row in enumerate(self.manifest["records"]):
                old = Path(row["path"])
                source = store / old
                source.chmod(0o600)
                backup = root / ("external-hardlink-" + str(index))
                os.link(source, backup)
                backups[str(old)] = backup
            failed = subprocess.run([str(self.binary), str(store), str(journal)],
                env=dict(os.environ, LAYOUT17_TEST_FAULT="revision-published"), capture_output=True, text=True)
            self.assertEqual(failed.returncode, 90, failed.stderr)
            state = json.loads(next(journal.glob("layout17-*.json")).read_text())
            relative = "/".join(state["move"]["source"])
            source = store / relative
            backup = backups[relative]
            backup.write_bytes(b"concurrent mutation")
            resumed = subprocess.run([str(self.binary), str(store), str(journal)], capture_output=True, text=True)
            self.assertNotEqual(resumed.returncode, 0)
            self.assertTrue(source.samefile(backup))
            self.assertEqual(backup.read_bytes(), b"concurrent mutation")
            self.assertTrue((store / "canonical-layout.pending.json").is_file())

    def test_completed_store_repeat_accepts_valid_lf_hand_edit_without_rewrite(self):
        with tempfile.TemporaryDirectory(prefix="layout17-completed-edit-", dir=TEMP_ROOT) as temp:
            root = Path(temp); store, journal = root / "store", root / "journal"
            shutil.copytree(FIXTURE / "store", store); journal.mkdir(mode=0o700)
            result = subprocess.run([str(self.binary), str(store), str(journal)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            old = Path(self.manifest["records"][0]["path"])
            target = store / old.parent.parent / (old.parent.name + "." + old.name)
            header, body = target.read_bytes().split(b"\r\n\r\n", 1)
            edited = header.replace(b"\r\n", b"\n") + b"\n\n" + body
            target.chmod(0o600); target.write_bytes(edited); target.chmod(0o400)
            parsed = subprocess.run([str(self.binary), "record-fixture", "message", str(target)],
                                    capture_output=True, text=True)
            self.assertEqual(parsed.returncode, 0, parsed.stderr)
            shutil.rmtree(journal)  # The one-time journal is not canonical state.
            repeated = subprocess.run([str(self.binary), str(store), str(journal)], capture_output=True, text=True)
            self.assertEqual(repeated.returncode, 0, repeated.stderr)
            self.assertEqual(target.read_bytes(), edited)

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

    def test_private_cluster_intent_requires_explicit_test_only_owner_hook(self):
        if os.geteuid() == 0:
            self.skipTest("Root-run fixture cannot distinguish test-user and root custody")
        with tempfile.TemporaryDirectory(prefix="layout17-intent-", dir=TEMP_ROOT) as temp:
            root = Path(temp); store, journal, intents = root / "store", root / "journal", root / "intents"
            shutil.copytree(FIXTURE / "store", store); journal.mkdir(mode=0o700); intents.mkdir(mode=0o700)
            ids = self.manifest["storeIDs"]
            config = {"profile": "tractanda.personal-membership.v1", "storeID": ids["store"]["storeID"],
                      "configurationID": "00000000-0000-1000-8000-000000000003",
                      "members": [{"replicaID": ids["replica"]["replicaID"], "hostname": "first.example"},
                                  {"replicaID": "00000000-0000-1000-8000-000000000004", "hostname": "second.example"}]}
            membership = store / ".personal-membership.json"
            membership.write_text(json.dumps(config)); membership.chmod(0o600)
            reader = store / "canonical-reader.json"
            intent = {"profile": "tractanda.layout17-prepare.v1", "mode": "administrator-coordinated",
                "instance": "fixture", "storePath": str(store), "storeID": ids["store"]["storeID"],
                "replicaID": ids["replica"]["replicaID"], "oldManifestSHA256": "a" * 64,
                "newManifestSHA256": "b" * 64, "membershipDigest": hashlib.sha256(membership.read_bytes()).hexdigest(),
                "readerRequirementSHA256": hashlib.sha256(reader.read_bytes()).hexdigest(),
                "acknowledgedAllMembersUpgradedBeforeStart": True}
            intent_path = intents / "fixture.json"
            intent_path.write_text(json.dumps(intent)); intent_path.chmod(0o600)
            command = [str(self.binary), str(store), str(journal), "--intent", str(intent_path)]
            refused = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(refused.returncode, 0)
            self.assertFalse((store / "canonical-layout.pending.json").exists())
            resumed = subprocess.run(command, env=dict(os.environ, LAYOUT17_TEST_INTENT_OWNER="self"),
                                     capture_output=True, text=True)
            self.assertEqual(resumed.returncode, 0, resumed.stderr)
            self.check_content(store)

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
    else:
        parser.error(
            "pass --binary PATH to an executable built with LAYOUT17_PRIVATE_FIXTURE and the configured SwiftPM dependencies"
        )
    sys.argv = [sys.argv[0], *unittest_args]
    unittest.main()


if __name__ == "__main__":
    main()
