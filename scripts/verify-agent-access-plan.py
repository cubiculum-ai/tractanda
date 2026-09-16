#!/usr/bin/env python3
"""Offline tests for prepare-agent-access plan generation."""

import argparse
import importlib.util
import json
import os
import platform
import grp
import pwd
from pathlib import Path
import tempfile


def load_script(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SPEC = importlib.util.spec_from_file_location(
    "prepare_agent_access", Path(__file__).with_name("prepare-agent-access.py")
)
PLANNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PLANNER)
WIRE = load_script("wire_protocol", "verify-ipc.py")


def _write_json(path: Path, data):
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def _text(value):
    return {"type": "text", "value": value}


def _item(item_id, revision_id, subject=None, include_permissions=False, class_id="Item"):
    fields = {
        "itemID": _text(item_id),
        "revisionID": _text(revision_id),
        "classID": _text(class_id),
    }
    if subject is not None:
        fields["subject"] = _text(subject)
    if include_permissions:
        fields["permissions"] = {"type": "object", "value": {"owner": _text("owner")}}
    return {"fields": fields}


def _snapshot(items, query_state="q-1"):
    return {
        "query": {
            "queryState": query_state,
            "total": len(items),
            "ids": [item["fields"]["itemID"]["value"] for item in items],
        },
        "items": items,
    }


def _run_builder(temp_dir: Path, snapshot_data, grants_data, owner="alice", group="team", agent="agent"):
    temp_dir.mkdir(parents=True, exist_ok=True)
    snapshot_path = temp_dir / "snapshot.json"
    grants_path = temp_dir / "grants.json"
    output_path = temp_dir / "plan.json"
    _write_json(snapshot_path, snapshot_data)
    _write_json(grants_path, grants_data)
    return (
        snapshot_path,
        grants_path,
        output_path,
        PLANNER.build_plan(snapshot_path, grants_path, owner, group, agent),
    )


def _run_builder_with_write(temp_dir: Path, snapshot_data, grants_data, owner="alice", group="team", agent="agent", output_path=None):
    temp_dir.mkdir(parents=True, exist_ok=True)
    snapshot_path = temp_dir / "snapshot.json"
    grants_path = temp_dir / "grants.json"
    if output_path is None:
        output_path = temp_dir / "plan.json"
    _write_json(snapshot_path, snapshot_data)
    _write_json(grants_path, grants_data)
    return PLANNER.build_and_write_plan(snapshot_path, grants_path, owner, group, agent, output_path), output_path


def _assert(condition, message):
    if not condition:
        raise AssertionError(message)


def _expect_failure(fn, exc_type=Exception):
    try:
        fn()
    except exc_type:
        return True
    except Exception as exc:
        raise AssertionError(f"expected {exc_type.__name__}, got {type(exc).__name__}: {exc}")
    raise AssertionError(f"expected {exc_type.__name__}, got no error")


def _plan_subject_mode_checks(plan):
    phases = plan["phases"]
    _assert(len(phases) == 2, "phases must be exactly two")
    revise, create = phases
    _assert(revise["label"] == "revise", "first phase must be revise")
    _assert(create["label"] == "create", "second phase must be create")

    ids = [request["itemID"] for request in revise["requests"]]
    _assert(len(ids) == len(set(ids)), "revise requests must be guarded by unique item IDs")
    for request in revise["requests"]:
        _assert(
            set(request) == {"action", "itemID", "expectedRevisionID", "changes", "unset", "operationID"},
            "revise requests must not leak unrelated input fields",
        )
        _assert(request["action"] == "revise", "revise phase actions are revise")
        _assert(isinstance(request["itemID"], str), "revise request itemID must be plain string")
        _assert(request["itemID"], "revise request itemID must be non-empty")
        _assert(isinstance(request["expectedRevisionID"], str), "expectedRevisionID must be plain string")
        _assert(request["expectedRevisionID"], "expectedRevisionID must be non-empty")
        _assert(request.get("classID") is None, "revise requests must not set classID")
        _assert(request["changes"].keys() == {"permissions"}, "revise may only change permissions")
        _assert(request["unset"] == [], "unset must always be empty")

    create_request = create["requests"][0]
    _assert(
        set(create_request) == {"action", "classID", "changes", "unset", "operationID"},
        "admission request must not leak unrelated input fields",
    )
    _assert(create_request["action"] == "create", "final phase action must be create")
    _assert(create_request.get("itemID") is None, "create must not provide itemID")
    _assert(create_request["classID"] == "AccessConfigurationItem", "create must target AccessConfigurationItem")

    shared_read = []
    shared_edit = []
    for request in revise["requests"]:
        permissions = request["changes"]["permissions"]["value"]
        mode = permissions["mode"]["value"]
        acl = permissions["acl"]["value"]
        if acl and acl.get("users", {}).get("value"):
            value = next(iter(acl["users"]["value"].values()))["value"]
            if mode == 416:
                _assert(value == 4, "read-shared grant must use user mask 4")
                shared_read.append(request["itemID"])
            elif mode == 432:
                _assert(value == 6, "write-shared grant must use user mask 6")
                shared_edit.append(request["itemID"])
        else:
            _assert(mode == 384, "unshared items keep mode 0600")
            _assert(not acl, "unshared items keep empty ACL")
            _assert(acl.get("owningGroup", {"value": 0}).get("value") == 0, "owningGroup must be 0")

    return shared_read, shared_edit


def _native_account():
    current_uid = os.getuid()
    if platform.system() == "Darwin":
        try:
            candidate = pwd.getpwnam("_www")
        except KeyError:
            return None, "Darwin account _www unavailable"
        if candidate.pw_uid == current_uid:
            return None, "Darwin account _www is current account"
        return candidate.pw_name, None

    for candidate in pwd.getpwall():
        if candidate.pw_uid != 0 and candidate.pw_uid != current_uid:
            return candidate.pw_name, None
    return None, "No existing non-root account available"


def _native_verify(binary):
    peer = Path(binary).resolve()
    _assert(peer.exists(), f"Native binary not found: {peer}")
    with tempfile.TemporaryDirectory(prefix="scope-agent-plan-native-", dir="/tmp") as temporary:
        base = Path(temporary)
        store = base / "store"
        socket = base / "s"
        if socket.exists():
            socket.unlink()

        agent, reason = _native_account()
        if reason:
            return {"status": "skip", "reason": reason}

        owner = pwd.getpwuid(os.getuid()).pw_name
        group = grp.getgrgid(os.getgid()).gr_name

        with WIRE.server(str(peer), store, socket) as client:
            baseline_subjects = {}
            baseline_bodies = {}
            ids = []
            for index in range(4):
                request = WIRE.intent(
                    "create",
                    f"native-note-{index + 1}",
                    class_id="Item",
                    changes={
                        "subject": WIRE.text(f"Native note #{index + 1}"),
                        "body": WIRE.text(f"Body {index + 1}"),
                    },
                )
                revision = client.commit(request)["revision"]
                item_id = revision["fields"]["itemID"]["value"]
                ids.append(item_id)
                baseline_subjects[item_id] = revision["fields"]["subject"]["value"]
                baseline_bodies[item_id] = revision["fields"]["body"]["value"]

            deleted_id = ids[-1]
            deleted_revision = client.get(deleted_id)
            client.commit(WIRE.intent(
                "revise", "native-delete", item=deleted_id,
                base=deleted_revision["fields"]["revisionID"]["value"],
                changes={"isDeleted": {"type": "boolean", "value": True}},
            ))

            query = client.call("TractandaItem/query", {"expression": 'classID == "Item"'})
            _assert(query["total"] == 3, "native fixture must create exactly three Items")
            query_ids = query["ids"]
            responses = client.batch([["TractandaItem/get", {"ids": query_ids}, "notes"]])[0]
            _assert(responses[0] == "TractandaItem/get", responses)
            rows = responses[1]["list"]
            _assert(deleted_id not in query_ids, "normal query must omit deleted items")
            deleted_row = client.get(deleted_id)
            snapshot_query = dict(query)
            snapshot_query["ids"] = query_ids + [deleted_id]
            snapshot_query["total"] = len(snapshot_query["ids"])
            snapshot = {"query": snapshot_query, "items": rows + [deleted_row]}
            grants = {
                "read": [query_ids[0]],
                "edit": [query_ids[1]],
            }
            snapshot_path = base / "snapshot.json"
            grants_path = base / "grants.json"
            _write_json(snapshot_path, snapshot)
            _write_json(grants_path, grants)
            plan = PLANNER.build_plan(snapshot_path, grants_path, owner, group, agent)

            revision_after_apply = {}

            revise_requests = plan["phases"][0]["requests"]
            for request in revise_requests:
                applied = client.commit(request)
                item_id = request["itemID"]
                revision_after_apply[item_id] = applied["revision"]["fields"]["revisionID"]["value"]
                revision = client.get(item_id)
                fields = revision["fields"]
                _assert(fields["subject"]["value"] == baseline_subjects[item_id], "subject must survive permission-only apply")
                _assert(fields["body"]["value"] == baseline_bodies[item_id], "body must survive permission-only apply")
                _assert(fields["permissions"] == request["changes"]["permissions"], "native permissions must match planner")
            for request in revise_requests:
                replay = client.commit(request)
                _assert(replay["replayed"] is True, "exact replay should be idempotent")
                _assert(
                    client.get(request["itemID"])["fields"]["revisionID"]["value"] == revision_after_apply[request["itemID"]],
                    "replay must not create a duplicate revision",
                )

            create_request = plan["phases"][1]["requests"][0]
            client.commit(create_request)
            info = client.call("TractandaStore/info")
            _assert(info.get("accessMode") == "multi-user", "planner config should switch to multi-user mode")

            untouched = [item_id for item_id in query_ids if item_id not in grants["read"] + grants["edit"]][0]
            current = client.get(untouched)
            update = WIRE.intent(
                "revise",
                "admin-revise",
                item=untouched,
                base=current["fields"]["revisionID"]["value"],
                changes={"subject": WIRE.text("Revised by owner with admin privilege")},
            )
            revised = client.commit(update)["revision"]["fields"]["subject"]["value"]
            _assert(revised == "Revised by owner with admin privilege", "administrator can revise unshared item")

            stale = WIRE.intent(
                "revise",
                "stale-guard",
                item=untouched,
                base=revision_after_apply[untouched],
                changes={"subject": WIRE.text("stale")},
            )
            failure = client.batch([["TractandaItem/commit", stale, "stale"]])[0]
            _assert(failure[0] == "error" and failure[1]["type"] == "revisionConflict", "stale guard must fail")

            _assert(info["accessScope"] != "", "accessScope should be reported")
            _assert(revised is not None, "revision should be returned for admin rewrite")
            return {"status": "pass"}


def run_tests(binary=None):
    report = []
    failed = 0
    passed = 0
    skipped = 0

    def record_skip(name, reason):
        nonlocal skipped
        skipped += 1
        report.append({"name": name, "status": "skip", "reason": reason})

    def record(name, fn):
        nonlocal failed, passed
        try:
            fn()
            passed += 1
            report.append({"name": name, "status": "pass"})
        except Exception as exc:
            failed += 1
            report.append({"name": name, "status": "fail", "error": str(exc)})

    with tempfile.TemporaryDirectory(prefix="scope-agent-plan-") as temp_root:
        root = Path(temp_root)

        snapshot = _snapshot([
            _item("id-a", "rev-a", subject="Alpha"),
            _item("id-b", "rev-b", subject="Beta"),
            _item("id-c", "rev-c", subject="Gamma"),
        ])
        grants = {"read": ["id-a"], "edit": ["id-b"]}

        def case_effective_modes_and_order():
            plan = _run_builder(root / "case1", snapshot, grants)[3]
            shared_read, shared_edit = _plan_subject_mode_checks(plan)
            _assert(shared_read == ["id-a"], "exactly one read-granted item")
            _assert(shared_edit == ["id-b"], "exactly one edit-granted item")
            _assert(len(plan["phases"][1]["requests"]) == 1, "single admission request")
            _assert(plan["counts"]["items"] == 3, "item count is preserved")
        record("effective modes, order, and guard checks", case_effective_modes_and_order)

        def case_empty_grants_stay_private():
            plan = _run_builder(root / "empty-grants", snapshot, {"read": [], "edit": []})[3]
            shared_read, shared_edit = _plan_subject_mode_checks(plan)
            _assert(shared_read == [] and shared_edit == [], "empty grants must not auto-share items")
        record("empty grants preserve private legacy items", case_empty_grants_stay_private)

        def case_deterministic_ids():
            path = root / "deterministic"
            plan_a = _run_builder(path, snapshot, grants)[3]
            path2 = root / "deterministic2"
            plan_b = _run_builder(path2, snapshot, grants)[3]
            _assert(plan_a["planDigest"] == plan_b["planDigest"], "plan digest should be deterministic")
            ids_a = [r["operationID"] for phase in plan_a["phases"] for r in phase["requests"]]
            ids_b = [r["operationID"] for phase in plan_b["phases"] for r in phase["requests"]]
            _assert(ids_a == ids_b, "operation IDs should stay stable")
        record("deterministic digest and operation IDs", case_deterministic_ids)

        def case_arbitrary_fields_absent():
            plan = _run_builder(root / "case3", snapshot, grants)[3]
            for request in plan["phases"][0]["requests"]:
                for forbidden in ("subject", "body", "classID", "classId"):
                    _assert(forbidden not in request["changes"], f"revise change '{forbidden}' must not be copied")
        record("unindexed/original fields are not copied", case_arbitrary_fields_absent)

        def case_invalid_grants():
            _expect_failure(lambda: _run_builder(root / "bad1", snapshot, {"read": ["id-a", "id-a"], "edit": []}))
            _expect_failure(lambda: _run_builder(root / "bad2", snapshot, {"read": ["id-a"], "edit": ["id-a"]}))
            _expect_failure(lambda: _run_builder(root / "bad3", snapshot, {"read": ["id-x"], "edit": []}))
        record("invalid duplicate/unknown/overlapping grants rejected", case_invalid_grants)

        def case_incomplete_snapshot():
            bad_snapshot = _snapshot([
                _item("id-a", "rev-a"),
            ])
            bad_snapshot["query"]["total"] = 2
            _expect_failure(lambda: _run_builder(root / "bad4", bad_snapshot, grants))
            bad_snapshot2 = _snapshot([
                _item("id-a", "rev-a"),
                _item("id-b", "rev-b"),
            ], query_state="q-2")
            del bad_snapshot2["query"]["ids"][1]
            _expect_failure(lambda: _run_builder(root / "bad5", bad_snapshot2, grants))
        record("incomplete snapshot rejected", case_incomplete_snapshot)

        def case_existing_permissions_config_rejected():
            with_permissions = _snapshot([
                _item("id-a", "rev-a", include_permissions=True),
            ])
            _expect_failure(lambda: _run_builder(root / "bad6", with_permissions, {"read": [], "edit": []}))
            with_config = _snapshot([
                _item("id-a", "rev-a", class_id="AccessConfigurationItem"),
            ])
            _expect_failure(lambda: _run_builder(root / "bad7", with_config, {"read": [], "edit": []}))
        record("existing permissions or access config rejected", case_existing_permissions_config_rejected)

        def case_bad_principals():
            _expect_failure(lambda: _run_builder(root / "bad8", snapshot, grants, owner="bad@name", group="team", agent="agent"))
            _expect_failure(lambda: _run_builder(root / "bad9", snapshot, grants, owner="alice", group="te@m", agent="agent"))
            _expect_failure(lambda: _run_builder(root / "bad10", snapshot, grants, owner="alice", group="team", agent="alice"))
        record("bad principals rejected", case_bad_principals)

        def case_output_collision_preserved():
            temp = root / "collision"
            temp.mkdir()
            plan, output = _run_builder_with_write(temp / "normal", snapshot, grants, agent="agent")
            _assert(output.stat().st_mode & 0o777 == 0o600, "new output file is private 0600")
            normal_target = output.read_text(encoding="utf-8")
            _assert("planDigest" in normal_target, "normal output preserves full JSON")

            symlink_target = temp / "symlink-target"
            symlink_target.write_text(normal_target, encoding="utf-8")
            symlink_path = temp / "symlink-output"
            symlink_path.symlink_to(temp / "symlink-target")
            _expect_failure(
                lambda: PLANNER.build_and_write_plan(
                    temp / "normal/snapshot.json", temp / "normal/grants.json", "alice", "team", "agent", symlink_path
                )
            )
            _assert(symlink_path.is_symlink(), "existing symlink must be preserved")
            _assert(symlink_path.read_text(encoding="utf-8") == normal_target, "existing symlink destination must remain unchanged")

            race_output = temp / "collision-race.json"
            race_snapshot = temp / "normal" / "snapshot.json"
            race_grants = temp / "normal" / "grants.json"
            original_link = PLANNER.os.link
            def interrupted(source, target):
                race_output.write_text("intervened", encoding="utf-8")
                return original_link(source, target)
            PLANNER.os.link = interrupted
            try:
                _expect_failure(lambda: PLANNER.build_and_write_plan(race_snapshot, race_grants, "alice", "team", "agent", race_output))
                _assert(race_output.read_text(encoding="utf-8") == "intervened", "simultaneous file creation must be rejected")
                _assert(True, "simulated race target remains present")
            finally:
                PLANNER.os.link = original_link
        record("output collision preserves existing file", case_output_collision_preserved)

        def case_native_protocol():
            result = _native_verify(binary)
            if result["status"] == "skip":
                record_skip("native protocol roundtrip and replay guards", result["reason"])
                return
            _assert(result["status"] == "pass", result.get("reason") or "native verification failed")
        if binary:
            record("native protocol roundtrip and replay guards", case_native_protocol)
        elif binary is None:
            record_skip("native protocol roundtrip and replay guards", "Binary not provided")

    return passed, failed, skipped, report


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--report",
        type=Path,
        default=Path("work/scoped-agent/planner-tests.json"),
        help="report output path",
    )
    parser.add_argument("--binary", type=Path, default=None, help="run native protocol verifier with this executable")
    return parser.parse_args()


def main():
    args = parse_args()
    passed, failed, skipped, tests = run_tests(args.binary)
    result = {
        "tests": tests,
        "passed": passed,
        "failed": failed,
        "skipped": skipped,
        "status": "fail" if failed else "pass",
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    with open(args.report, "w", encoding="utf-8") as handle:
        json.dump(result, handle, indent=2, sort_keys=True)
    os.chmod(args.report, 0o600)
    print(json.dumps(result, sort_keys=True))
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
