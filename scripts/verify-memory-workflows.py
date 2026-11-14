#!/usr/bin/env python3
"""Exercise memory import and portable workflows on one disposable personal daemon."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid

from jmap_client import DiscoveryContext

RESERVE = 10 * 1024**3
CAP = 64 * 1024**2


def capacity(root):
    space = os.statvfs(root)
    actual = 0
    for path in root.rglob("*"):
        try:
            if path.is_file():
                actual += path.stat().st_size
        except FileNotFoundError:
            # The disposable daemon may retire one of its own temporary files.
            continue
    if actual > CAP or space.f_bavail * space.f_frsize < RESERVE + CAP:
        raise RuntimeError("Synthetic fixture requires a 10 GiB reserve and 64 MiB fixture cap")
    return actual


def progress(number, message):
    print(f"[{number}/7] {message}", file=sys.stderr, flush=True)


def private_json(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        json.dump(value, output, ensure_ascii=False, sort_keys=True)


def read_exact(connection, count):
    data = bytearray()
    while len(data) < count:
        chunk = connection.recv(count - len(data))
        if not chunk:
            raise RuntimeError("Daemon closed an incomplete frame")
        data.extend(chunk)
    return bytes(data)


def exchange(path, envelope):
    payload = json.dumps(envelope, ensure_ascii=False).encode("utf-8")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.connect(str(path))
        connection.sendall(struct.pack("!I", len(payload)) + payload)
        size = struct.unpack("!I", read_exact(connection, 4))[0]
        if not 0 < size <= 8 * 1024 * 1024:
            raise RuntimeError("Daemon returned an invalid frame size")
        return json.loads(read_exact(connection, size))


class Client:
    def __init__(self, path):
        self.context = DiscoveryContext(lambda request: exchange(path, request))

    def call(self, method, arguments=None):
        result = self.context.request([[method, arguments or {}, "fixture"]])
        responses = result.get("methodResponses", [])
        if len(responses) != 1 or responses[0][0] != method:
            raise RuntimeError(f"Synthetic native call failed: {method}: {responses}")
        return responses[0][1]

    def create(self, subject):
        operation = "memory-fixture-" + str(uuid.uuid4())
        receipt = self.call("TractandaItem/commit", {
            "action": "create", "classID": "Item", "changes": {"subject": text(subject)},
            "unset": [], "operationID": operation,
        })
        if receipt["operationId"] != operation:
            raise RuntimeError("Synthetic commit receipt differs from the request")
        return receipt


def text(value):
    return {"type": "text", "value": value}


def run_cli(binary, root, *arguments):
    capacity(root)
    result = subprocess.run([binary, *map(str, arguments)], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"Synthetic CLI failed ({arguments[0]}): {result.stderr.strip()}")
    capacity(root)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"Synthetic CLI did not return JSON ({arguments[0]})") from error


def dispositions(report, expected, label):
    outcomes = report.get("outcomes", [])
    if len(outcomes) != 3 or any(entry.get("disposition") != expected for entry in outcomes):
        raise RuntimeError(f"{label} did not return three {expected} outcomes: {outcomes}")
    return {entry["sourceID"]: entry for entry in outcomes}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def verify(binary, parent):
    with tempfile.TemporaryDirectory(prefix="tm-", dir=parent) as temporary, \
            tempfile.TemporaryDirectory(prefix="tms-", dir="/tmp") as socket_temporary:
        root = Path(temporary).resolve()
        sock = Path(socket_temporary).resolve() / "s"
        if len(os.fsencode(str(sock))) >= 104:
            raise RuntimeError("Physical Unix socket path exceeds the portable path bound")
        capacity(root)
        store = root / "store"
        source = root / "source"
        source.mkdir(mode=0o700)
        originals = {
            "a.md": b"---\r\ntype: fact\r\ntitle: Alpha\r\nstale_after: 2030-01-01T00:00:00Z\r\n---\r\nAlpha [to beta](b.md).\r\n",
            "b.md": b"---\ntype: fact\ntitle: Beta\n---\nBeta [to alpha](a.md).\n",
            "c.md": b"---\ntype: fact\ntitle: Gamma\n---\nGamma [to alpha](a.md).\n",
        }
        for name, data in originals.items():
            (source / name).write_bytes(data)
        progress(1, "Initializing disposable personal store")
        run_cli(binary, root, "init", store)
        with tempfile.TemporaryFile() as daemon_log:
            daemon = subprocess.Popen([binary, "daemon", str(store), str(sock), "--no-http"],
                                      stdout=subprocess.DEVNULL, stderr=daemon_log)
            try:
                while not sock.exists():
                    if daemon.poll() is not None:
                        daemon_log.seek(0)
                        raise RuntimeError("Disposable daemon exited during startup: " + daemon_log.read().decode(errors="replace"))
                    capacity(root)
                    time.sleep(0.1)
                client = Client(sock)
                info = client.call("TractandaStore/info")
                if info.get("ownerUID") != os.geteuid():
                    raise RuntimeError("Disposable server owner differs from the invoking account")
                prefix = ["--no-start", "--socket", str(sock)]
                plan = root / "plan.json"
                progress(2, "Previewing selected OKF files")
                preview = run_cli(binary, root, "import", "preview", "--adapter", "okf", "--source", source,
                                  "--namespace", "synthetic-memory", "--out", plan, "--json")
                if preview.get("records") != 3:
                    raise RuntimeError("Preview did not select the three synthetic files")
                inspection = run_cli(binary, root, *prefix, "import", "inspect", plan, "--json")
                dispositions(inspection, "create", "Inspection")
                progress(3, "Applying and verifying cyclic imported links")
                applied = run_cli(binary, root, *prefix, "import", "apply", plan, "--journal", root / "j1", "--json")
                records = dispositions(applied, "create", "Import")
                for source_id, target in [("a", "b"), ("b", "a"), ("c", "a")]:
                    item = client.call("TractandaItem/get", {"ids": [records[source_id]["itemID"]]})["list"][0]
                    if item["fields"]["importState"]["value"] != "complete":
                        raise RuntimeError(f"Synthetic import {source_id} remains incomplete")
                    links = item["fields"]["importLinks"]["value"]
                    if not any(link["value"].get("target", {}).get("value", {}).get("itemID") == records[target]["itemID"]
                               and link["value"]["resolution"]["value"] == "resolved" for link in links):
                        raise RuntimeError(f"Synthetic cyclic link {source_id} -> {target} was not resolved")
                for name, data in originals.items():
                    if (source / name).read_bytes() != data:
                        raise RuntimeError("Import changed a selected source file")
                progress(4, "Reapplying the same plan without duplicate Items")
                repeated = run_cli(binary, root, *prefix, "import", "apply", plan, "--journal", root / "j2", "--json")
                repeated_records = dispositions(repeated, "unchanged", "Repeated import")
                if any(repeated_records[key]["itemID"] != value["itemID"] for key, value in records.items()):
                    raise RuntimeError("Repeated import changed a source identity")
                progress(5, "Exporting current Items and comparing exact originals")
                export = root / "export"
                exported = run_cli(binary, root, *prefix, "export-memory", "--namespace", "synthetic-memory", "--out", export, "--json")
                if len(exported.get("outcomes", [])) != 3:
                    raise RuntimeError("Export report did not cover all Items")
                manifest = json.loads((export / "manifest.json").read_text(encoding="utf-8"))
                entries = {entry["sourceID"]: entry for entry in manifest["entries"]}
                if set(entries) != {"a", "b", "c"}:
                    raise RuntimeError("Export manifest differs from source selection")
                for source_id, entry in entries.items():
                    original = originals[entry["originalSourcePath"]]
                    original_path = export / entry["nativeDirectory"] / (entry["originalAttachmentID"] + ".original")
                    if original_path.read_bytes() != original or digest(original) != entry["originalSHA256"]:
                        raise RuntimeError(f"Exported original bytes differ for {source_id}")
                    if not (export / entry["nativeDirectory"] / "revision.json").is_file() or not (export / entry["readablePath"]).is_file():
                        raise RuntimeError("Export omitted a native revision or readable projection")
                if any((source / name).read_bytes() != data for name, data in originals.items()):
                    raise RuntimeError("Repeat import or export changed a selected source file")
                progress(6, "Writing explicit profile, memory and checkpoint Items")
                profile = client.create("Synthetic global collaborator")
                checkpoint = client.create("Synthetic checkpoint")
                binding = root / "binding.json"
                private_json(binding, {"storeID": manifest["storeID"], "profileItemID": profile["itemId"],
                                       "checkpointItemID": checkpoint["itemId"]})
                note_fields = root / "note-fields.json"
                checkpoint_fields = root / "checkpoint-fields.json"
                private_json(note_fields, {"subject": text("Synthetic durable memory"), "body": text("Remembered fact")})
                private_json(checkpoint_fields, {"body": text("Continue from synthetic Git reference")})
                memory = run_cli(binary, root, *prefix, "memory", "remember", "--binding", binding,
                                 "--fields", note_fields, "--journal", root / "jm", "--json")
                saved_checkpoint = run_cli(binary, root, *prefix, "memory", "checkpoint", "--binding", binding,
                                           "--expected-revision", checkpoint["revisionId"], "--fields", checkpoint_fields,
                                           "--journal", root / "jc", "--json")
                if saved_checkpoint["itemId"] != checkpoint["itemId"]:
                    raise RuntimeError("Checkpoint write changed its target")
                item = client.call("TractandaItem/get", {"ids": [memory["itemId"]]})["list"][0]
                if item["fields"]["collaborator"]["value"]["itemID"] != profile["itemId"]:
                    raise RuntimeError("Memory does not reference the selected collaborator")
                progress(7, "Recalling from a fresh CLI client")
                recall = run_cli(binary, root, *prefix, "memory", "recall", "--binding", binding,
                                 "--limit", "1", "--json")
                if (recall["profile"]["id"] != profile["itemId"]
                        or recall["checkpoint"]["id"] != checkpoint["itemId"]
                        or recall["checkpoint"]["revisionId"] != saved_checkpoint["revisionId"]
                        or recall["checkpoint"]["fields"]["body"]["value"] != "Continue from synthetic Git reference"
                        or not recall["truncated"]):
                    raise RuntimeError("Fresh recall did not preserve profile, checkpoint or truncation")
                return {"passed": True, "fixtureOnly": True, "sourceCount": 3, "cyclicLinksVerified": 3,
                        "unchangedOnRepeat": 3, "exactOriginalsVerified": 3, "freshClientRecall": True,
                        "truncationReported": True, "fixtureBytes": capacity(root), "fixtureCapBytes": CAP,
                        "reserveBytes": RESERVE, "modelRun": False, "replicationVerified": False}
            finally:
                if daemon.poll() is None:
                    daemon.send_signal(signal.SIGTERM)
                daemon.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary")
    parser.add_argument("--scratch-parent", default=os.environ.get("TRACTANDA_TEST_FIXTURE_ROOT") or tempfile.gettempdir())
    parser.add_argument("--report")
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, lambda signum, frame: (_ for _ in ()).throw(KeyboardInterrupt()))
    result = verify(str(Path(args.binary).resolve()), str(Path(args.scratch_parent).resolve()))
    encoded = json.dumps(result, sort_keys=True)
    if args.report:
        fd = os.open(args.report, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            output.write(encoded + "\n")
    print(encoded)


if __name__ == "__main__":
    main()
