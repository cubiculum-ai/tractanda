#!/usr/bin/env python3
"""Disposable-Debian, real-peer semantic authorization regression.

Requires TRACTANDA_DISPOSABLE_CONTAINER=1 and runs only against accounts provisioned by
verify-multi-user.py. It never creates host accounts or opens a production store.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import pwd
import tempfile
import time


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


multi = load("semantic_peers_multi", "verify-multi-user.py")
semantic = load("semantic_peers_provider", "verify-semantic.py")
wire = multi.wire_module


def wait(call, predicate, timeout=25):
    deadline = time.monotonic() + timeout
    while True:
        value = call()
        if predicate(value): return value
        assert time.monotonic() < deadline, value
        time.sleep(.05)


def revision(value): return value["revision"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    assert platform.system() == "Linux" and os.environ.get("TRACTANDA_DISPOSABLE_CONTAINER") == "1", "Run only in the marked disposable Debian container."
    checks = []
    with tempfile.TemporaryDirectory(prefix="tractanda-semantic-peers-", dir="/tmp") as temp, semantic.Provider() as provider:
        # Make a hidden item strictly nearer than the readable one, deliberately.
        provider.vector_for = lambda text: [1, 0, 0] if text.startswith("query:") or "hidden semantic nearest" in text else [0, 1, 0]
        root = Path(temp); names = multi.provision(); fixture = multi.Fixture(args.binary, names, root, linux=True)
        # Match the real-peer fixture's service-owned store/socket directories.
        # The outer temporary directory stays root-owned and only permits traversal.
        root.chmod(0o755)
        service = pwd.getpwnam(names["service"])
        fixture.store.mkdir(mode=0o700)
        os.chown(fixture.store, service.pw_uid, service.pw_gid)
        runtime = root / "runtime"
        runtime.mkdir(mode=0o755)
        os.chown(runtime, service.pw_uid, service.pw_gid)
        fixture.socket = runtime / "s"
        fixture.configure()
        config = {"formatVersion": 2, "configurationID": "semantic-peer-config", "operationID": "semantic-peer-config-op",
            "endpoint": provider.endpoint, "model": "synthetic-contract-v1", "modelRevision": "sha256:peer-test",
            "dimensions": 3, "documentPrefix": "passage: ", "queryPrefix": "query: ", "chunkBytes": 384,
            "overlapBytes": 64, "pooling": "mean", "normalization": "l2", "inputEncoding": "item-text-utf8-v2"}
        with fixture.server():
            fixture.call("bob", "TractandaSemantic/configure", {"configuration": config}, error="forbidden")
            fixture.call("agent", "TractandaSemantic/reset", {"expectedConfigurationID": config["configurationID"], "operationID": "nope"}, error="forbidden")
            fixture.call("service", "TractandaSemantic/configure", {"configuration": config})
            private = revision(fixture.commit("alice", {"subject": wire.text("hidden semantic nearest"), "body": wire.text("needle " * 200)}))
            acl = {"mask": multi.number(4), "owningGroup": multi.number(0), "users": multi.obj({names["bob"]: multi.number(4), names["agent"]: multi.number(4)})}
            shared = revision(fixture.commit("alice", {"subject": wire.text("team semantic result"), "body": wire.text("needle available"), "permissions": fixture.permissions(0o640, acl)}))
            provider.gate.set()
            status = wait(lambda: fixture.call("bob", "TractandaSemantic/status"), lambda r: r["coverage"] == "complete")
            assert status["indexableItems"] == 1, status
            q = fixture.call("bob", "TractandaSemantic/search", {"text": "needle", "limit": 1})
            fixture.call("agent", "TractandaSemantic/results", {"queryID": q["queryID"]}, error="notFound")
            result = wait(lambda: fixture.call("bob", "TractandaSemantic/results", {"queryID": q["queryID"]}), lambda r: r["state"] != "pending")
            assert [row["itemID"] for row in result["results"]] == [wire.item_id(shared)], result
            assert wire.item_id(private) not in str(result)
            agent_query = fixture.call("agent", "TractandaSemantic/search", {"text": "needle", "limit": 1})
            agent_result = wait(lambda: fixture.call("agent", "TractandaSemantic/results", {"queryID": agent_query["queryID"]}), lambda r: r["state"] != "pending")
            assert [row["itemID"] for row in agent_result["results"]] == [wire.item_id(shared)], agent_result
            checks.append("OS-peer scoped query IDs, private-count isolation, and filtered Vec1 search prevent hidden nearest chunks from starving readable top-K")

            fts_before = fixture.call("bob", "TractandaItem/query", {"text": "team"})["ids"]
            revised = revision(fixture.commit("alice", {"privateFixtureField": wire.text("metadata only")}, base=shared))
            wait(lambda: fixture.call("bob", "TractandaSemantic/status"), lambda r: r["coverage"] == "complete")
            current = wait(lambda: fixture.call("bob", "TractandaSemantic/results", {"queryID": q["queryID"]}), lambda r: r["state"] == "ready")
            assert current["results"][0]["revisionID"] == wire.revision_id(revised), current
            assert fixture.call("bob", "TractandaItem/query", {"text": "team"})["ids"] == fts_before
            checks.append("Metadata-only revisions relabel current semantic references without changing FTS")

            revoked = revision(fixture.commit("alice", {"permissions": fixture.permissions()}, base=revised))
            after = fixture.call("bob", "TractandaSemantic/results", {"queryID": q["queryID"]})
            assert after["results"] == [], after
            assert fixture.call("agent", "TractandaSemantic/results", {"queryID": agent_query["queryID"]})["results"] == []
            assert fixture.call("bob", "TractandaItem/get", {"ids": [wire.item_id(revoked)]})["notFound"] == [wire.item_id(revoked)]
            checks.append("Current permission revocation removes an already-submitted query result immediately")

    report = {"status": "passed", "checks": checks, "binarySHA256": hashlib.sha256(args.binary.read_bytes()).hexdigest(), "disposable": True}
    args.output.parent.mkdir(parents=True, exist_ok=True); args.output.write_text(json.dumps(report, indent=2) + "\n"); print(json.dumps(report))


if __name__ == "__main__": main()
