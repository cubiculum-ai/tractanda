#!/usr/bin/env python3
"""Drive category learning in real PTYs against disposable native stores, including lost replies."""
import argparse
import importlib.util
import json
import platform
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("tui", Path(__file__).with_name("verify-tui.py"))
tui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tui)
wire, ESC = tui.wire, tui.ESC
F10 = ESC + b"[21~"


def create(client, subject, category=None, label=None):
    fields = {"subject": wire.text(subject), "body": wire.text("A note: café 文 👩🏽‍💻"),
              "foreign.metadata": wire.text("preserve")}
    if label:
        fields["categoryOverrides"] = {"type": "object", "value": {category: wire.text(label)}}
    return client.commit(wire.intent("create", "seed-" + subject, class_id="Item", changes=fields))["revision"]


def seed(client, candidates=1):
    category = client.commit(wire.intent("create", "category", class_id="Item", changes={
        "subject": wire.text("Club café 文"), "foreign.category": wire.text("preserve"),
        "selection": {"type": "object", "value": {"language": wire.text("tractanda.spotlight.v0"),
                                                     "expression": wire.text('itemID == ""')}},
    }))["revision"]
    identity = wire.item_id(category)
    for words, label in [("chess tournament players", "include"), ("chess board players", "include"),
                         ("garden vegetables soil", "exclude"), ("garden soil flowers", "exclude")]:
        create(client, words, identity, label)
    items = [create(client, f"chess tournament board {index}") for index in range(candidates)]
    return category, items


def learning(client, name, category, **arguments):
    return client.call("TractandaLearning/" + name, {"categoryID": category, **arguments})


def open_learning(ui):
    ui.send(ESC + b"l"); ui.wait("Choose learning category")
    ui.send(b"\r"); ui.wait("Learning · Club café 文")


def filter_item(ui, identity):
    ui.send("f"); ui.wait("Filter learning items")
    ui.send(b"\x15"); ui.paste(f'itemID == "{identity}"'); ui.send(b"\x13")
    ui.wait("Learning filter applied.", absent="Filter learning items")


def set_threshold(ui, value):
    ui.send("o"); ui.wait("Mode (off / suggestions)")
    ui.send(b"\t\x15"); ui.paste(value); ui.send(b"\x13")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("native_binary", type=Path)
    parser.add_argument("tui_binary", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    native, binary = str(args.native_binary.resolve()), str(args.tui_binary.resolve())
    checks, snapshots = [], []
    with tempfile.TemporaryDirectory(prefix="trac-learn-ui-", dir="/tmp") as directory:
        root = Path(directory)
        with wire.server(native, root / "store", root / "s") as client:
            category, candidates = seed(client, candidates=40)
            category_id, item_id = wire.item_id(category), wire.item_id(candidates[0])
            with tui.terminal(binary, root / "s", root / "recovery/pending.json") as ui:
                ui.wait("All items")
                before = wire.manifest(root / "store")
                open_learning(ui)
                ui.wait("untrained")
                assert "2 positive" in ui.screen and "2 negative" in ui.screen
                assert learning(client, "status", category_id).get("modelID") is None
                ui.send("t"); ui.wait("Training complete.")
                ui.wait("1–32 of 40")
                ui.send("]"); ui.wait("33–40 of 40")
                ui.send("["); ui.wait("1–32 of 40")
                assert wire.manifest(root / "store") == before
                checks.append("Explicit training and bounded forward/backward suggestion pages leave canonical files unchanged")

                filter_item(ui, item_id)
                for width, height in [(48, 12), (80, 25), (132, 40), (30, 8), (132, 40)]:
                    ui.resize(width, height)
                    if width < 48:
                        ui.wait("Enlarge terminal"); ui.send("a"); ui.read(0.1)
                    else:
                        ui.wait("Learning · Club")
                        assert "chess tournament board 0" in ui.screen
                        snapshots.append({"name": "suggestion-review", "columns": width,
                                          "rows": height, "screen": ui.screen})
                ui.send(F10); ui.wait("Command menu")
                ui.send(ESC + b"[C" + ESC + b"[C"); ui.wait("─View─")
                ui.send(F10); ui.wait("Learning · Club", absent="Command menu")
                ui.send(b"\r"); ui.wait("Item / immutable revision")
                assert "café 文" in ui.screen
                ui.send(ESC); ui.wait("Learning · Club", absent="Item / immutable revision")
                assert client.get(item_id) == candidates[0]
                checks.append("Unicode suggestions, item reading, menus and small/wide resizes preserve selection without feedback writes")

                ui.send("d"); ui.wait("Dismissed:")
                assert learning(client, "status", category_id)["negativeExamples"] == 2
                assert "categoryOverrides" not in client.get(item_id)["fields"]
                ui.send("e"); ui.wait("Teach from items")
                ui.send("n"); ui.wait("Rejected:")
                assert learning(client, "status", category_id)["negativeExamples"] == 3
                ui.send("c"); ui.wait("Feedback cleared;")
                assert learning(client, "status", category_id)["negativeExamples"] == 2
                ui.send("a"); ui.wait("Accepted:")
                assert client.get(item_id)["fields"]["categoryOverrides"]["value"][category_id] == wire.text("include")
                ui.send("x"); ui.wait("Excluded:")
                ui.send("c"); ui.wait("Feedback cleared;")
                assert client.get(item_id)["fields"]["categoryOverrides"]["value"][category_id] == wire.text("exclude")
                assert client.get(item_id)["fields"]["foreign.metadata"] == wire.text("preserve")
                checks.append("Dismissal, rejection, clearing feedback, assignment and exclusion follow native semantics and preserve unrelated metadata")

                set_threshold(ui, "NaN"); ui.wait("invalidLearningSettings")
                assert client.get(category_id) == category
                ui.send(b"\x15"); ui.paste("0.2"); ui.send(b"\x13"); ui.wait("Learning settings saved.")
                saved_category = client.get(category_id)
                assert saved_category["fields"]["learningSettings"]["value"]["threshold"]["value"] == 0.2
                assert saved_category["fields"]["foreign.category"] == wire.text("preserve")
                ui.send("t"); ui.wait("Training complete.")
                before_reset = wire.manifest(root / "store")
                model = learning(client, "status", category_id).get("modelID")
                ui.send("u"); ui.wait("Type reset"); ui.send(ESC); ui.wait("Draft canceled")
                assert learning(client, "status", category_id).get("modelID") == model
                ui.send("u"); ui.wait("Type reset"); ui.paste("reset"); ui.send(b"\x13"); ui.wait("Model reset.")
                assert learning(client, "status", category_id).get("modelID") is None
                assert wire.manifest(root / "store") == before_reset
                checks.append("Settings validate before writing; reset confirmation affects only the derived model and preserves assignments and settings")

                # A displayed suggestion must be reviewed again if its revision has changed.
                # Restore this chess example to positive after testing exclusion; otherwise the
                # intentionally contradictory training can suppress the similar candidates.
                ui.send("a"); ui.wait("Accepted:")
                other_id = wire.item_id(candidates[1])
                ui.send("s"); ui.wait("Suggestions")
                filter_item(ui, other_id)
                ui.send("t"); ui.wait("Training complete.")
                ui.wait("chess tournament board 1")
                current = client.get(other_id)
                external = client.commit(wire.intent("revise", "concurrent", item=other_id,
                    base=wire.revision_id(current), changes={"body": wire.text("Edited elsewhere")}))["revision"]
                ui.send("a"); ui.wait("stateChanged")
                assert client.get(other_id) == external
                assert "chess tournament board 1" not in ui.screen
                ui.send("r"); ui.wait("Learning refreshed.")
                ui.send("a"); ui.wait("Accepted:")
                assert client.get(other_id)["fields"]["body"] == wire.text("Edited elsewhere")
                ui.send(ESC); ui.wait("Learning closed.")
                ui.close()
                checks.append("Concurrent item edits invalidate the review page; refresh and renewed acceptance use the current revision")

        for method in ["feedback", "settings"]:
            case = root / method
            with wire.server(native, case / "store", case / "s") as client:
                category, items = seed(client)
                category_id, item_id = wire.item_id(category), wire.item_id(items[0])
                recovery = case / "recovery/pending.json"
                proxy = tui.LostResponseProxy(case / "proxy", case / "s", drop_method="TractandaLearning/" + method)
                try:
                    with tui.terminal(binary, proxy.path, recovery) as ui:
                        ui.wait("All items"); open_learning(ui)
                        if method == "feedback":
                            ui.send("t"); ui.wait("Training complete."); ui.send("a")
                        else:
                            set_threshold(ui, "0.25")
                        ui.wait("Unconfirmed learning edit")
                        frozen = json.loads(recovery.read_text())["request"]
                        assert "learning" in frozen
                        manifest = wire.manifest(case / "store")
                        ui.send("d"); ui.read(0.1)
                        assert wire.manifest(case / "store") == manifest
                        ui.close()
                    learning(client, "reset", category_id)
                    with tui.terminal(binary, proxy.path, recovery) as ui:
                        ui.wait("Recovered unconfirmed learning edit")
                        assert json.loads(recovery.read_text())["request"] == frozen
                        assert wire.manifest(case / "store") == manifest
                        ui.send("r"); ui.wait("Recovered learning edit.")
                        assert not recovery.exists()
                        assert wire.manifest(case / "store") == manifest
                        target = item_id if method == "feedback" else category_id
                        assert len(client.call("TractandaItem/history", {"itemID": target})["list"]) == 2
                        ui.send(ESC); ui.wait("Learning closed."); ui.close()
                    checks.append(f"Lost {method} response survives terminal restart and model reset; exact retry publishes no duplicate revision")
                finally:
                    proxy.close()
    result = {"status": "passed", "platform": platform.platform(), "checks": checks, "snapshots": snapshots}
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k != "snapshots"}, ensure_ascii=False))


if __name__ == "__main__":
    main()
