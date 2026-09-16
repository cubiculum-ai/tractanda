#!/usr/bin/env python3
"""Load shipped templates/examples into disposable stores and rebuild from files."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


PROJECT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("wire", PROJECT / "scripts/verify-ipc.py")
wire = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(wire)
RETIRED = {"NoteItem", "TodoItem", "PendencyItem", "ActionItem", "SavedViewItem"}


def snapshot(client):
    records, position = {}, 0
    while True:
        page = client.call("TractandaItem/query", {"position": position, "limit": 64})
        for start in range(0, len(page["ids"]), 8):
            result = client.call("TractandaItem/get", {"ids": page["ids"][start:start + 8]})
            assert not result["notFound"] and not result.get("remainingIDs")
            assert not result.get("oversizedIDs")
            records.update({wire.item_id(item): item for item in result["list"]})
        position += len(page["ids"])
        if position == page["total"]:
            break
        assert page["ids"] and position < page["total"]
    views = {}
    for item_id, item in records.items():
        if "viewDefinition" in item["fields"]:
            views[item_id] = client.call("TractandaItem/query", {
                "viewID": item_id, "at": "2026-09-16T12:00:00Z", "timeZone": "Europe/Vienna",
            })["ids"]
    return records, views


def verify(binary):
    with tempfile.TemporaryDirectory(prefix="tractanda-samples-", dir="/tmp") as temporary:
        root = Path(temporary)
        store, socket = root / "store", root / "socket"
        # This is the same core fixture used by the documented `tractanda seed` command.
        seeded = json.loads(subprocess.check_output([binary, "seed", str(store)]))
        assert len(seeded) == 8
        with wire.server(binary, store, socket) as client:
            template = json.loads((PROJECT / "templates/starter-categories.json").read_text())
            installed = client.call("TractandaCategory/installTemplate", {
                "template": template, "timeZone": "Europe/Vienna",
            })["items"]
            assert len(installed) == len(template["entries"])
            assert client.call("TractandaCategory/installTemplate", {
                "template": template, "timeZone": "Europe/Vienna",
            })["items"] == installed
            for name in ("create-note.json", "query-and-get.json"):
                envelope = json.loads((PROJECT / "examples" / name).read_text())
                result = wire.wire(socket, envelope)
                assert "code" not in result, result
                assert all(call[0] != "error" for call in result["methodResponses"]), result
                if name == "create-note.json":
                    created = result["methodResponses"][0][1]
                    assert created["revision"]["fields"]["classID"] == wire.text("Item")
                    replay = wire.wire(socket, envelope)["methodResponses"][0][1]
                    assert replay["replayed"] and replay["revision"] == created["revision"]
            command = [sys.executable, str(PROJECT / "examples/create-project.py"),
                       str(socket), "Example project", "--binary", binary,
                       "--project-root", installed["what"], "--status-root", installed["status"]]
            project = json.loads(subprocess.check_output(command))
            assert json.loads(subprocess.check_output(command)) == project
            project_items = client.call("TractandaItem/query", {
                "categoryPath": [project["projectID"], project["statusRootID"]],
            })
            assert project_items["total"] == 1
            before = snapshot(client)
            types = client.call("TractandaStore/describe", {"topic": "types"})["types"]
            concrete = {item["classID"] for item in types if not item["abstract"]}
            assert "Item" in concrete and concrete.isdisjoint(RETIRED)
            for record in before[0].values():
                fields = record["fields"]
                assert fields["classID"]["value"] in concrete, fields["classID"]
                for key in ("activity", "activityNotes"):
                    for entry in fields.get(key, {}).get("value", []):
                        assert entry["value"]["at"]["type"] == "date", (key, entry)
            for item_id in installed.values():
                assert before[0][item_id]["fields"]["classID"] == wire.text("Item")
            for key in ("status.attention", "status.ready", "status.doing", "status.review",
                        "status.planned", "status.done"):
                assert before[0][installed[key]]["fields"]["categoryOrder"]["type"] == "integer"
            canonical = wire.manifest(store)
        # Rebuild the disposable index from exactly the sample canonical files.
        shutil.rmtree(store / "index")
        with wire.server(binary, store, socket) as client:
            assert snapshot(client) == before
            assert wire.manifest(store) == canonical
        return {"status": "passed", "sampleItems": len(before[0]), "savedViews": len(before[1]),
                "templateItems": len(installed), "examplesReplayed": True,
                "canonicalOnlyRebuild": True, "retiredClassIDs": []}


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: verify-samples.py /path/to/tractanda")
    print(json.dumps(verify(str(Path(sys.argv[1]).resolve())), indent=2))
