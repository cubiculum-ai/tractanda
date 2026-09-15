#!/usr/bin/env python3
"""Build an offline, review-only plan for initial single-user to multi-user migration."""

from __future__ import annotations

import argparse
import hashlib
import errno
import json
import os
import re
import tempfile
from pathlib import Path
from typing import Any, Dict, Iterable, List


TEXT_FIELD = "text"
INTEGER_FIELD = "integer"
OBJECT_FIELD = "object"
LIST_FIELD = "list"

NAME_PATTERN = re.compile(r"^[A-Za-z0-9._$-]{1,128}$")


class PlanError(ValueError):
    pass


def tagged(value_type: str, value: Any) -> Dict[str, Any]:
    return {"type": value_type, "value": value}


def _to_text(value: Any) -> Dict[str, str]:
    return tagged(TEXT_FIELD, str(value))


def _to_int(value: Any) -> Dict[str, int]:
    return tagged(INTEGER_FIELD, int(value))


def _to_obj(value: Dict[str, Any]) -> Dict[str, Any]:
    return tagged(OBJECT_FIELD, value)


def _to_list(value: List[Any]) -> Dict[str, Any]:
    return tagged(LIST_FIELD, value)


def _read_json(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _ensure_principal(value: Any, label: str) -> str:
    if not isinstance(value, str):
        raise PlanError(f"{label} must be a string")
    if not NAME_PATTERN.fullmatch(value):
        raise PlanError(f"{label} must match ASCII principal rules: [A-Za-z0-9._$-], max 128 chars")
    return value


def _ensure_item_identity(fields: Dict[str, Any], key: str, index: int) -> str:
    if key not in fields:
        raise PlanError(f"item #{index} missing field {key}")
    value = fields[key]
    if not isinstance(value, dict):
        raise PlanError(f"{key} on item #{index} must be tagged object")
    if value.get("type") != TEXT_FIELD:
        raise PlanError(f"{key} on item #{index} must be text")
    raw = value.get("value")
    if not isinstance(raw, str) or not raw:
        raise PlanError(f"{key} on item #{index} must be non-empty text")
    return raw


def _normalise_grants(grants_value: Any, known_items: Iterable[str], key: str) -> List[str]:
    if key not in grants_value:
        return []
    ids = grants_value[key]
    if not isinstance(ids, list):
        raise PlanError(f"grants[{key}] must be a list")
    if not all(isinstance(i, str) and i for i in ids):
        raise PlanError(f"grants[{key}] must be non-empty string IDs")
    values = list(ids)
    if len(values) != len(set(values)):
        raise PlanError(f"grants[{key}] contains duplicates")
    unknown = [i for i in values if i not in known_items]
    if unknown:
        raise PlanError(f"grants[{key}] has unknown IDs: {unknown}")
    return values


def _validate_snapshot(snapshot: Dict[str, Any]) -> List[Dict[str, Any]]:
    if not isinstance(snapshot, dict):
        raise PlanError("snapshot must be an object")
    if "query" not in snapshot or "items" not in snapshot:
        raise PlanError("snapshot must contain query and items")
    query = snapshot["query"]
    items = snapshot["items"]
    if not isinstance(query, dict):
        raise PlanError("snapshot.query must be an object")
    if not isinstance(items, list):
        raise PlanError("snapshot.items must be a list")

    query_state = query.get("queryState")
    ids = query.get("ids")
    total = query.get("total")
    if not isinstance(query_state, str) or not query_state:
        raise PlanError("snapshot.query.queryState must be a non-empty string")
    if not isinstance(ids, list) or any(not isinstance(i, str) or not i for i in ids):
        raise PlanError("snapshot.query.ids must be a list of non-empty string IDs")
    if isinstance(total, bool) or not isinstance(total, int) or total < 0:
        raise PlanError("snapshot.query.total must be a non-negative integer")
    if len(ids) != total or total != len(items):
        raise PlanError("snapshot.query.total/ids/rows are inconsistent")

    seen: set[str] = set()
    normalized: List[Dict[str, Any]] = []
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            raise PlanError(f"item #{index} must be an object")
        fields = item.get("fields")
        if not isinstance(fields, dict):
            raise PlanError(f"item #{index} fields must be an object")

        item_id = _ensure_item_identity(fields, "itemID", index)
        revision_id = _ensure_item_identity(fields, "revisionID", index)
        class_id = _ensure_item_identity(fields, "classID", index)
        if class_id == "AccessConfigurationItem":
            raise PlanError(f"item {item_id} is already AccessConfigurationItem")
        if "permissions" in fields:
            raise PlanError(f"item {item_id} already has permissions")
        if item_id in seen:
            raise PlanError(f"duplicate itemID {item_id}")
        seen.add(item_id)

        subject = fields.get("subject")
        subject_value = None
        if subject is not None:
            if not isinstance(subject, dict) or subject.get("type") != TEXT_FIELD or not isinstance(subject.get("value"), str):
                raise PlanError(f"subject for item {item_id} must be tagged text")
            subject_value = subject["value"]

        normalized.append({
            "itemID": item_id,
            "revisionID": revision_id,
            "classID": class_id,
            "subject": subject_value,
        })

    expected_ids = set(ids)
    if expected_ids != seen:
        missing = sorted(expected_ids - seen)
        extra = sorted(seen - expected_ids)
        if missing:
            raise PlanError(f"snapshot rows are missing ids: {missing}")
        raise PlanError(f"snapshot rows include extra ids: {extra}")

    return normalized


def _build_permissions_for(item_id: str, read_ids: set[str], edit_ids: set[str], owner: str, group: str, agent: str):
    if item_id in read_ids:
        users = {agent: _to_int(4)}
        acl = _to_obj({"users": _to_obj(users), "groups": _to_obj({}), "mask": _to_int(4), "owningGroup": _to_int(0)})
        return _to_obj({
            "profile": _to_text("tractanda.permissions.posix.v1"),
            "owner": _to_text(owner),
            "group": _to_text(group),
            "mode": _to_int(416),
            "acl": acl,
        })
    if item_id in edit_ids:
        users = {agent: _to_int(6)}
        acl = _to_obj({"users": _to_obj(users), "groups": _to_obj({}), "mask": _to_int(6), "owningGroup": _to_int(0)})
        return _to_obj({
            "profile": _to_text("tractanda.permissions.posix.v1"),
            "owner": _to_text(owner),
            "group": _to_text(group),
            "mode": _to_int(432),
            "acl": acl,
        })
    return _to_obj({
        "profile": _to_text("tractanda.permissions.posix.v1"),
        "owner": _to_text(owner),
        "group": _to_text(group),
        "mode": _to_int(384),
        "acl": _to_obj({}),
    })


def _build_base_plan(snapshot: Dict[str, Any], read: List[str], edit: List[str], owner: str, group: str, agent: str) -> Dict[str, Any]:
    normalized_items = _validate_snapshot(snapshot)
    query_ids = list(snapshot["query"]["ids"])
    known_rows = {row["itemID"]: row["revisionID"] for row in normalized_items}

    read_set = set(read)
    edit_set = set(edit)
    unknown = sorted((set(read_set) | set(edit_set)) - set(query_ids))
    if unknown:
        raise PlanError(f"grants reference unknown item IDs: {unknown}")
    overlap = sorted(read_set & edit_set)
    if overlap:
        raise PlanError(f"grants are overlapping: {overlap}")

    phases: List[Dict[str, Any]] = [
        {"label": "revise", "requests": []},
        {"label": "create", "requests": []},
    ]

    # Build operation IDs after canonicalizing the request bodies so IDs are stable
    # and reproducible for the same inputs.
    placeholder_requests = []
    for item_id in query_ids:
        revision_id = known_rows[item_id]
        placeholder_requests.append({
            "action": "revise",
            "itemID": item_id,
            "expectedRevisionID": revision_id,
            "changes": {
            "permissions": _build_permissions_for(item_id, read_set, edit_set, owner, group, agent),
            },
            "unset": [],
        })

    admission = {
        "subject": _to_text("Store access configuration"),
        "accessConfiguration": _to_obj({
            "profile": _to_text("tractanda.access.v1"),
            "users": _to_list([_to_text(agent)]),
            "groups": _to_list([]),
            "userAliases": _to_obj({}),
            "groupAliases": _to_obj({}),
        }),
    }
    create_request = {
        "action": "create",
        "classID": "AccessConfigurationItem",
        "changes": admission,
        "unset": [],
    }

    seed = {
        "snapshotState": snapshot["query"]["queryState"],
        "headManifest": {
            "queryState": snapshot["query"]["queryState"],
            "total": snapshot["query"]["total"],
            "ids": query_ids,
        },
        "owner": owner,
        "group": group,
        "agent": agent,
        "grants": {"read": read, "edit": edit},
        "subjects": {row["itemID"]: row["subject"] for row in normalized_items},
        "counts": {"items": len(normalized_items), "read": len(read), "edit": len(edit)},
        "phases": [dict(label="revise", requests=placeholder_requests), dict(label="create", requests=[create_request])],
    }

    digest_payload = json.dumps(seed, sort_keys=True, separators=(",", ":"))
    digest = hashlib.sha256(digest_payload.encode("utf-8")).hexdigest()

    for request in seed["phases"][0]["requests"]:
        item_id = request["itemID"]
        request["operationID"] = hashlib.sha256(f"{digest}:{item_id}:revise".encode("utf-8")).hexdigest()
    seed["phases"][1]["requests"][0]["operationID"] = hashlib.sha256(f"{digest}:admission:create".encode("utf-8")).hexdigest()
    seed["planDigest"] = digest
    seed["headManifest"]["itemRevisions"] = {row["itemID"]: row["revisionID"] for row in normalized_items}
    seed["explicitNotes"] = [
        "grants are per-item; no automatic sharing from future project membership",
        "all history follows current permission",
        "admission last",
        "restart required for socket mode",
        "serverUser pins SERVICE owner, not agent",
        "host isolation separate",
        "stale snapshots are preflight candidates only and must not be blindly applied",
    ]
    return seed


def build_plan(snapshot_path: Path, grants_path: Path, owner: str, group: str, agent: str) -> Dict[str, Any]:
    owner = _ensure_principal(owner, "owner")
    group = _ensure_principal(group, "group")
    agent = _ensure_principal(agent, "agent")
    if owner == agent:
        raise PlanError("owner and agent must be distinct")

    snapshot = _read_json(snapshot_path)
    grants = _read_json(grants_path)
    if not isinstance(grants, dict):
        raise PlanError("grants must be an object")
    if set(grants.keys()) != {"read", "edit"}:
        raise PlanError("grants must contain only read and edit")

    normalized_items = _validate_snapshot(snapshot)
    item_ids = [row["itemID"] for row in normalized_items]
    read = _normalise_grants(grants, set(item_ids), "read")
    edit = _normalise_grants(grants, set(item_ids), "edit")

    if set(read).intersection(edit):
        raise PlanError("grants overlap between read and edit")

    return _build_base_plan(snapshot, read, edit, owner, group, agent)


def write_plan(plan: Dict[str, Any], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(plan, indent=2, sort_keys=True) + "\n"
    fd, temporary = tempfile.mkstemp(prefix=output.name + ".", suffix=".tmp", dir=str(output.parent))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(payload)
        try:
            os.link(temporary, str(output))
        except OSError as error:
            if error.errno == errno.EEXIST:
                raise PlanError(f"refusing to overwrite existing output file: {output}")
            raise
    finally:
        try:
            if os.path.exists(temporary):
                os.unlink(temporary)
        except OSError:
            pass


def build_and_write_plan(snapshot_path: Path, grants_path: Path, owner: str, group: str, agent: str, output: Path) -> Dict[str, Any]:
    plan = build_plan(snapshot_path, grants_path, owner, group, agent)
    write_plan(plan, output)
    return plan


def _parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", required=True, type=Path)
    parser.add_argument("--grants", required=True, type=Path)
    parser.add_argument("--owner", required=True, type=str)
    parser.add_argument("--group", required=True, type=str)
    parser.add_argument("--agent", required=True, type=str)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def main():
    args = _parse_args()
    plan = build_and_write_plan(args.snapshot, args.grants, args.owner, args.group, args.agent, args.output)
    print(json.dumps(plan, sort_keys=True))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
