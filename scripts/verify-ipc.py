#!/usr/bin/env python3
"""Independent wire client, recovery scenario, and canonical-file transfer check.

Requires Python 3.9+ and the built tractanda executable. No third-party packages.
Only disposable temporary stores and an explicitly supplied export directory are used.
"""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import tempfile
import time

CAPABILITY = "https://tractanda.ai/ns/local-prototype/3"


def text(value):
    return {"type": "text", "value": value}


def intent(action, operation, item=None, base=None, class_id=None, changes=None, unset=None):
    value = {"action": action, "operationID": operation, "changes": changes or {}, "unset": unset or []}
    for key, item_value in [("itemID", item), ("expectedRevisionID", base), ("classID", class_id)]:
        if item_value is not None:
            value[key] = item_value
    return value


def item_id(revision):
    return revision["fields"]["itemID"]["value"]


def revision_id(revision):
    return revision["fields"]["revisionID"]["value"]


def read_exact(connection, count):
    result = bytearray()
    while len(result) < count:
        chunk = connection.recv(count - len(result))
        if not chunk:
            raise RuntimeError("Socket closed before the frame completed")
        result.extend(chunk)
    return bytes(result)


def wire(path, envelope):
    data = json.dumps(envelope, ensure_ascii=False).encode()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(20)
        connection.connect(str(path))
        connection.sendall(struct.pack("!I", len(data)) + data)
        count = struct.unpack("!I", read_exact(connection, 4))[0]
        assert 0 < count <= 8 * 1024 * 1024
        return json.loads(read_exact(connection, count))


class Client:
    def __init__(self, path):
        self.path = path

    def batch(self, calls):
        result = wire(self.path, {"using": [CAPABILITY], "methodCalls": calls})
        assert "code" not in result, result
        return result["methodResponses"]

    def call(self, method, arguments=None):
        response = self.batch([[method, arguments or {}, "test"]])[0]
        assert response[0] == method, response
        return response[1]

    def get(self, identity):
        return self.call("TractandaItem/get", {"ids": [identity]})["list"][0]

    def commit(self, request):
        return self.call("TractandaItem/commit", request)


@contextlib.contextmanager
def server(binary, store, path):
    with tempfile.TemporaryFile() as log:
        process = subprocess.Popen([binary, "serve", str(store), str(path)], stdout=subprocess.DEVNULL, stderr=log)
        try:
            deadline = time.monotonic() + 10
            while not path.exists():
                if process.poll() is not None or time.monotonic() > deadline:
                    log.seek(0)
                    raise RuntimeError(log.read().decode())
                time.sleep(0.02)
            assert path.stat().st_mode & 0o777 == 0o600
            # Exercise the shipped Swift client as well as this independent wire client.
            info = json.loads(subprocess.check_output([binary, "info", str(path)]))
            assert info["ownerUID"] == os.geteuid()
            yield Client(path)
        finally:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                raise RuntimeError("Server did not stop after SIGTERM")
            if process.returncode != 0:
                log.seek(0)
                raise RuntimeError(f"Server exit {process.returncode}: {log.read().decode()}")
            assert not path.exists(), "Graceful shutdown must remove its socket"


def manifest(store):
    return {str(p.relative_to(store)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted((store / "items").rglob("*.tractanda"))}


def snapshot(client, fixture):
    queries = {
        "all": {},
        "persons": {"expression": 'kMDItemContentTypeTree == "PersonItem"'},
        "family_alice": {"categoryPath": [fixture[k] for k in ("persons", "family", "alice")]},
        "newsletter": {"text": "chess club"},
        "unicode": {"expression": 'subject ==[cd] "*frederic*"'},
    }
    if "view" in fixture:
        queries["savedFamily"] = {"viewID": fixture["view"]}
    result = {key: sorted(client.call("TractandaItem/query", args)["ids"]) for key, args in queries.items()}
    result["currentRevisions"] = {i: revision_id(client.get(i)) for i in result["all"]}
    result["rolePhone"] = client.call("TractandaItem/resolve", {"itemID": fixture["president"], "path": "phone"})
    result["holderPhone"] = client.call("TractandaItem/resolve", {
        "itemID": fixture["president"], "path": "holder.mobilePhone", "at": "2026-09-07T00:00:00Z"})
    return result


def exercise(client, fixture):
    view = client.commit(intent("create", "ipc-saved-view", class_id="Item", changes={
        "subject": text("Family and Alice"),
        "viewDefinition": {"type": "object", "value": {"language": text("tractanda.spotlight.v0"),
            "categoryPath": {"type": "list", "value": [{"type": "reference", "value": {"itemID": fixture[k]}}
                                                       for k in ("persons", "family", "alice")]}}}}))["revision"]
    fixture["view"] = item_id(view)
    assert client.call("TractandaItem/query", {"viewID": item_id(view)})["ids"] == [fixture["lunch"]]
    role = client.get(fixture["president"])
    bob = client.get(fixture["bob"])
    new_bob = client.commit(intent("revise", "ipc-bob-phone", item_id(bob), revision_id(bob),
                                  changes={"mobilePhone": text("private replacement")}))["revision"]
    assert revision_id(client.get(item_id(role))) == revision_id(role)
    request = intent("revise", "ipc-role-phone", item_id(role), revision_id(role),
                     changes={"phone": text("official replacement"), "body": text("Two fields in one commit")})
    committed = client.commit(request)["revision"]
    assert revision_id(client.get(item_id(bob))) == revision_id(new_bob)
    assert client.call("TractandaItem/history", {"itemID": item_id(role)})["total"] == 2
    assert client.commit(request)["replayed"] is True
    conflict = dict(request, operationID="ipc-conflicting-edit")
    failed = client.batch([["TractandaItem/commit", conflict, "conflict"]])[0]
    assert failed[0] == "error" and failed[1]["type"] == "revisionConflict", failed
    copied = client.commit(intent("copy", "ipc-copy", item_id(role), revision_id(committed)))["revision"]
    assert item_id(copied) != item_id(role)
    assert client.call("TractandaItem/history", {"itemID": item_id(copied)})["total"] == 1
    assert copied["fields"]["holdings"] == committed["fields"]["holdings"]
    todo = client.get(fixture["todo"])
    appointment = client.commit(intent("retype", "ipc-retype", item_id(todo), revision_id(todo), "AppointmentItem",
                                       {"subject": text("Meet with the president")}))["revision"]
    assert item_id(appointment) == item_id(todo)
    assert appointment["fields"]["classID"] == text("AppointmentItem")
    note = client.commit(intent("create", "ipc-unicode", class_id="Item", changes={
        "subject": text("Frédéric's notes"), "body": text("Quotes: \"hello\"; slash /; newline\n"),
        "custom.key": {"type": "integer", "value": 9223372036854775807}}))["revision"]
    assert note["fields"]["custom.key"]["value"] == 9223372036854775807
    responses = client.batch([
        ["TractandaItem/query", {"expression": 'classID == "Item" && subject == "Newsletter delivery issue"'}, "q"],
        ["TractandaItem/get", {"#ids": {"resultOf": "q", "name": "TractandaItem/query", "path": "/ids"}}, "g"],
    ])
    assert len(responses[1][1]["list"]) == 1
    # A truncated client frame must not terminate the listening service.
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.connect(str(client.path))
        connection.sendall(struct.pack("!I", 100) + b"{")
    assert client.call("Core/echo", {"alive": True}) == {"alive": True}
    return request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=str)
    parser.add_argument("--export", type=Path)
    parser.add_argument("--import-from", dest="source", type=Path)
    parser.add_argument("--append-note", action="store_true")
    args = parser.parse_args()
    binary = str(Path(args.binary).resolve())
    if args.export:
        assert not args.export.exists(), "Choose a new export directory; existing results are preserved"
    with tempfile.TemporaryDirectory(prefix="tractanda-", dir="/tmp") as temporary:
        base = Path(temporary)
        store = base / "store"
        path = base / "s.sock"
        if args.source:
            reference = json.loads((args.source / "report.json").read_text())
            store.mkdir(mode=0o700)
            shutil.copytree(args.source / "store" / "items", store / "items")
            assert manifest(store) == reference["manifest"]
            fixture, request = reference["fixture"], reference["replayRequest"]
        else:
            fixture = json.loads(subprocess.check_output([binary, "seed", str(store)]))
        with server(binary, store, path) as client:
            if args.source:
                assert snapshot(client, fixture) == reference["snapshot"], "Transfer changed current items or query/path results"
                assert manifest(store) == reference["manifest"], "Rebuild altered canonical files"
                assert client.commit(request)["replayed"] is True, "Preserve/map the original numeric UID when testing retry scope"
            else:
                request = exercise(client, fixture)
            if args.append_note:
                request = intent("create", "debian-transfer-note", class_id="Item", changes={"subject": text("Created on Debian"), "body": text("Return this immutable revision to the Mac.")})
                client.commit(request)
            before = snapshot(client, fixture)
            previous_state = client.call("TractandaStore/info")["state"]
            client.call("TractandaStore/rebuild")
            assert client.call("TractandaStore/info")["state"] != previous_state
            assert snapshot(client, fixture) == before
        canonical_before = manifest(store)
        shutil.rmtree(store / "index")
        with server(binary, store, path) as client:
            assert snapshot(client, fixture) == before
            assert client.commit(request)["replayed"] is True
            assert manifest(store) == canonical_before
            report = {"fixture": fixture, "replayRequest": request, "snapshot": before,
                      "manifest": canonical_before, "ownerUID": os.geteuid()}
        if args.export:
            args.export.mkdir(parents=True, mode=0o700)
            destination = args.export / "store"
            destination.mkdir(mode=0o700)
            shutil.copytree(store / "items", destination / "items")
            (args.export / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
        print(json.dumps({"passed": True, "canonicalRevisions": len(canonical_before),
                          "imported": bool(args.source), "ownerUID": os.geteuid()}))


if __name__ == "__main__":
    main()
