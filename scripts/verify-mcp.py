#!/usr/bin/env python3
"""Independent MCP stdio wire tests. Only disposable native stores; Python 3.9+."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import platform
import select
import shutil
import subprocess
import tempfile
import time
import uuid

spec = importlib.util.spec_from_file_location("native_wire", Path(__file__).with_name("verify-ipc.py"))
wire = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wire)


def tagged(kind, value):
    return {"type": kind, "value": value}


def obj(value):
    return tagged("object", value)


def comparable_info(value):
    """Exclude adapter-local diagnostics; compare state against a fresh native read."""
    return {key: item for key, item in value.items() if key != "connection"}


class MCPClient:
    """No SDK: newline JSON-RPC, bounded reads, separate process and real pipes."""
    def __init__(self, binary, socket, arguments=None, result_format="both", append_result_format=True,
                 **process_options):
        self.log = tempfile.TemporaryFile()
        arguments = [str(socket)] if arguments is None else arguments
        if result_format != "both" and append_result_format:
            arguments = [*arguments, "--result-format", result_format]
        self.result_format = result_format
        self.process = subprocess.Popen([str(binary), *arguments], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=self.log, bufsize=0, **process_options)
        self.buffer = bytearray()
        self.sequence = 0

    def send(self, value, fragmented=False):
        data = json.dumps(value, ensure_ascii=False).encode() + b"\n"
        while data:
            count = self.process.stdin.write(data[:7] if fragmented else data)
            assert count, "MCP input closed"
            data = data[count:]

    def receive(self, timeout=15):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            assert remaining > 0 and select.select([self.process.stdout], [], [], remaining)[0], "MCP response timed out"
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                self.log.seek(0)
                raise AssertionError("MCP closed stdout: " + self.log.read().decode())
            self.buffer.extend(chunk)
            assert len(self.buffer) <= 4 * 1024 * 1024, "Oversized MCP response"
        data, _, self.buffer = self.buffer.partition(b"\n")
        response = json.loads(data)
        assert response["jsonrpc"] == "2.0", response
        return response

    def request(self, method, parameters=None, fragmented=False, error=None):
        self.sequence += 1
        self.send({"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": parameters or {}}, fragmented)
        response = self.receive()
        assert response["id"] == self.sequence, response
        if error is not None:
            assert response.get("error", {}).get("code") == error, response
            return response["error"]
        assert "error" not in response, response
        return response["result"]

    def initialize(self, client_name="Tractanda independent fixture"):
        response = self.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": client_name, "version": "1.0"}}, fragmented=True)
        assert response["protocolVersion"] == "2025-11-25", response
        assert set(response["capabilities"]) == {"tools", "resources"}, response
        assert response["capabilities"]["resources"] == {} and response["capabilities"]["tools"] == {}, response
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return response

    def tool(self, name, arguments=None, error=None):
        result = self.request("tools/call", {"name": name, "arguments": arguments or {}})
        if self.result_format == "text":
            assert "structuredContent" not in result, result
            assert len(result["content"]) == 1, result
            structured = json.loads(result["content"][0]["text"])
        elif self.result_format == "structured":
            assert result["content"] == [], result
            structured = result["structuredContent"]
        else:
            structured = result["structuredContent"]
            assert json.loads(result["content"][0]["text"]) == structured, result
        if error:
            assert result["isError"] and structured["code"] == error, result
        else:
            assert not result.get("isError", False), result
        return structured

    def resource(self, uri, error=None):
        result = self.request("resources/read", {"uri": uri}, error=error)
        return result if error else result["contents"][0]

    def close(self):
        if not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
            assert self.process.returncode == 0, self.process.returncode
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise AssertionError("MCP did not exit on EOF")
        finally:
            self.process.stdout.close()
            self.log.close()

    def __enter__(self):
        return self

    def __exit__(self, kind, value, traceback):
        if kind:
            self.process.kill()
            self.process.wait()
            self.process.stdin.close()
            self.process.stdout.close()
            self.log.close()
        else:
            self.close()


def check_cli_options(adapter, socket, root):
    """Exercise mixed adapter/connection option order against the disposable service."""
    configuration = root / "connections.json"
    profile_configuration = {
        "version": 1, "defaultProfile": "fixture",
        "profiles": {"fixture": {"socketPath": str(socket)}},
    }
    configuration.write_text(json.dumps(profile_configuration))
    configuration.chmod(0o600)
    environment = dict(os.environ, TRACTANDA_CONFIG=str(configuration))
    permutations = [
        (["--socket", str(socket), "--no-start", "--result-format", "text"], "text"),
        (["--result-format", "structured", "--no-start", "--socket", str(socket)], "structured"),
        (["--profile", "fixture", "--no-start", "--result-format", "text"], "text"),
        (["--result-format", "structured", "--no-start", "--profile", "fixture"], "structured"),
    ]
    for arguments, result_format in permutations:
        with MCPClient(adapter, socket, arguments=arguments, result_format=result_format,
                       append_result_format=False, env=environment) as client:
            client.initialize("CLI permutation fixture")
            info = client.tool("tractanda_info")
            assert "ownerUID" in info
            if "--profile" in arguments:
                assert info["connection"]["profile"] == "fixture"
                assert info["connection"]["profileSource"] == "user"
                # The adapter captures its profile once; changing configuration while it is
                # serving must not silently retarget the store in the middle of a session.
                configuration.write_text(json.dumps({
                    "version": 1, "defaultProfile": "changed",
                    "profiles": {
                        "fixture": {"socketPath": str(root / "retired")},
                        "changed": {"socketPath": str(socket)},
                    },
                }))
                frozen = client.tool("tractanda_info")
                assert frozen["connection"]["profile"] == "fixture"
                assert frozen["connection"]["socketPath"] == str(socket)
                configuration.write_text(json.dumps(profile_configuration))
    for arguments in (["--socket", "--no-start"], ["--socket", str(socket), str(socket)]):
        process = subprocess.run([str(adapter), *arguments], input=b"", stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, env=environment, timeout=10)
        assert process.returncode == 1 and b"usage" in process.stderr, process.stderr


def exercise(binary, adapter, root, checks):
    store, socket = root / "store", root / "s"
    stale = root / "retired"
    with MCPClient(adapter, stale, arguments=["--socket", str(stale), "--no-start"]) as offline:
        offline.initialize("Offline diagnostics fixture")
        info = offline.tool("tractanda_info", error="connectionFailed")
        assert info["connection"]["status"] == "error"
        assert info["connection"]["socketPath"] == str(stale)
        assert "server" not in info
    checks.append("offline tractanda_info preserves the bound socket and adapter identity without claiming server facts")
    with wire.server(binary, store, socket) as native:
        check_cli_options(adapter, socket, root)
        checks.append("mixed socket/profile/no-start/result-format CLI permutations and missing/duplicate socket validation")
        with MCPClient(adapter, socket) as client:
            client.request("ping")
            client.request("tools/list", error=-32600)
            client.initialize()
            catalog = client.request("tools/list")["tools"]
            catalog_names = {tool["name"] for tool in catalog}
            assert len(catalog) == 22 and len(catalog_names) == 22
            assert {
                "tractanda_semantic_status", "tractanda_semantic_search", "tractanda_semantic_results",
                "tractanda_semantic_configure", "tractanda_semantic_rebuild", "tractanda_semantic_reset",
            } <= catalog_names
            for tool in catalog:
                assert tool["inputSchema"]["additionalProperties"] is False
                assert tool["annotations"]["openWorldHint"] is False
            client.request("tools/call", {"name": "unknown", "arguments": {}}, error=-32602)
            client.request("tools/list", {"cursor": "invalid"}, error=-32602)
            client.request("unknown-method", error=-32601)
            references = client.request("resources/list")["resources"]
            assert len(references) == 5
            for reference in references:
                assert len(client.resource(reference["uri"])["text"]) > 100
            assert len(client.request("resources/templates/list")["resourceTemplates"]) == 2
            client.resource("file:///etc/passwd", error=-32602)
            client.resource("tractanda://items/../../reference/items", error=-32602)
            checks.append("initialization, ping, discovery, schemas, help resources, unknown methods and URI boundaries")

            native_info = native.call("TractandaStore/info")
            info = client.tool("tractanda_info")
            assert comparable_info(info) == comparable_info(native_info)
            assert info["connection"]["status"] == "ready"
            assert info["connection"]["transport"] == "unix"
            assert info["connection"]["socketPath"] == str(socket)
            assert info["connection"]["profileSource"] == "explicitSocket"
            server_instance = info["server"]["instanceID"]
            adapter_instance = info["connection"]["adapter"]["instanceID"]
            assert {"tractanda.runtime-identity.v1", "tractanda.semantic-job-timing.v1"} <= set(info["features"])
            assert info["connection"]["referenceCompatibility"]["status"] == "satisfied"
            assert info["connection"]["referenceCompatibility"]["missingServerFeatures"] == []
            assert client.tool("tractanda_describe") == native.call("TractandaStore/describe")
            types = client.tool("tractanda_describe", {"topic": "types"})
            properties = client.tool("tractanda_describe", {"topic": "properties"})
            assert any(entry["classID"] == "NoteItem" for entry in types["types"]), types
            assert any(entry["name"] == "requestIdentity" for entry in properties["properties"]), properties
            client.tool("tractanda_info", {"actor": "administrator"}, error="invalidArguments")
            client.tool("tractanda_query", {"limit": 65}, error="invalidArguments")
            client.tool("tractanda_query", {"limit": True}, error="invalidArguments")
            client.tool("tractanda_get", {"ids": [str(uuid.uuid4())] * 65}, error="invalidArguments")
            client.tool("tractanda_query", {"expression": "NOT subject == 'x'"}, error="unsupportedQuery")
            request = wire.intent("create", "mcp-create", class_id="TodoItem", changes={
                "subject": wire.text("MCP task"), "body": wire.text("Line one\nLine two ☃"),
                "max": tagged("integer", 9223372036854775807), "min": tagged("integer", -9223372036854775808),
                "unknown.key": obj({"x": wire.text("preserved")})})
            first = client.tool("tractanda_commit", request)["revision"]
            assert first["fields"]["max"]["value"] == 9223372036854775807
            assert first["fields"]["min"]["value"] == -9223372036854775808
            item_id = wire.item_id(first)
            native_full = native.get(item_id)
            compact = native.call("TractandaItem/get", {
                "ids": [item_id], "projection": "content", "maxBytes": 524288})
            assert first == compact["list"][0]
            assert client.tool("tractanda_get", {"ids": [item_id]}) == compact
            full = client.tool("tractanda_get", {"ids": [item_id], "projection": "full", "maxBytes": 524288})
            assert full["list"] == [native_full]
            current_uri = "tractanda://items/" + item_id
            assert json.loads(client.resource(current_uri)["text"])["list"] == native.call(
                "TractandaItem/get", {"ids": [item_id], "projection": "content"})["list"]
            assert client.tool("tractanda_get", {"ids": [item_id], "projection": "full"})["list"] == [native_full]
            assert client.tool("tractanda_resolve", {"itemID": item_id, "segments": ["unknown.key", "x"]})["value"] == wire.text("preserved")
            query = {"expression": 'classID == "TodoItem"', "text": "MCP task", "categoryPath": [], "limit": 32,
                     "at": "2026-09-09T12:00:00Z", "timeZone": "UTC"}
            assert client.tool("tractanda_query", query) == native.call("TractandaItem/query", query)
            sorted_query = {"expression": 'classID == "TodoItem"', "sort": [
                {"property": "subject", "isAscending": True}], "limit": 32,
                "at": "2026-09-09T12:00:00Z", "timeZone": "UTC"}
            assert client.tool("tractanda_query", sorted_query) == native.call("TractandaItem/query", sorted_query)
            revise = wire.intent("retype", "mcp-retype", item_id, wire.revision_id(first), "PendencyItem",
                changes={"body": wire.text("Waiting for a person")}, unset=["min"])
            second = client.tool("tractanda_commit", revise)["revision"]
            assert wire.item_id(second) == item_id and second["fields"]["classID"] == wire.text("PendencyItem")
            assert "min" not in second["fields"] and second["fields"]["unknown.key"] == first["fields"]["unknown.key"]
            assert client.tool("tractanda_commit", revise)["replayed"] is True
            client.tool("tractanda_commit", dict(revise, operationID="stale"), error="revisionConflict")
            client.tool("tractanda_commit", dict(revise, changes={"body": wire.text("different intent")}), error="operationMismatch")
            assert client.tool("tractanda_history", {"itemID": item_id}) == native.call(
                "TractandaItem/history", {"itemID": item_id, "projection": "content", "position": 0, "limit": 32})
            assert client.tool("tractanda_history", {"itemID": item_id, "projection": "full"}) == native.call(
                "TractandaItem/history", {"itemID": item_id, "projection": "full", "position": 0, "limit": 32})
            assert client.tool("tractanda_revision", {"itemID": item_id, "revisionID": wire.revision_id(first)}) == native.call(
                "TractandaRevision/get", {"itemID": item_id, "revisionID": wire.revision_id(first), "projection": "content"})
            assert client.tool("tractanda_revision", {"itemID": item_id, "revisionID": wire.revision_id(first), "projection": "full"}) == native.call(
                "TractandaRevision/get", {"itemID": item_id, "revisionID": wire.revision_id(first), "projection": "full"})
            pinned = current_uri + "/revisions/" + wire.revision_id(first)
            assert json.loads(client.resource(pinned)["text"])["revision"] == native.call(
                "TractandaRevision/get", {"itemID": item_id, "revisionID": wire.revision_id(first), "projection": "content"})["revision"]
            copied = client.tool("tractanda_commit", wire.intent("copy", "mcp-copy", item_id, wire.revision_id(second)))["revision"]
            assert wire.item_id(copied) != item_id
            assert client.tool("tractanda_history", {"itemID": wire.item_id(copied)})["total"] == 1
            checks.append("native full/content equivalence for writes, history, revisions and resources; 64-bit values, arbitrary keys, path resolution, whole edits, retyping, copies, conflicts and idempotent retry")

            category = client.tool("tractanda_commit", wire.intent("create", "category", class_id="NoteItem", changes={
                "subject": wire.text("Chess category"), "selection": obj({"language": wire.text("tractanda.spotlight.v0"),
                    "expression": wire.text('subject == "not a sample"')})}))["revision"]
            category_id = wire.item_id(category)
            parent = client.tool("tractanda_commit", wire.intent("create", "category-parent", class_id="NoteItem", changes={
                "subject": wire.text("Chess parent"), "selection": obj({"language": wire.text("tractanda.spotlight.v0"),
                    "expression": wire.text('subject == "not a sample"')})}))["revision"]
            parent_id = wire.item_id(parent)
            category = client.tool("tractanda_commit", wire.intent(
                "revise", "category-parent-link", category_id, wire.revision_id(category),
                changes={"categoryParents": tagged("list", [tagged("reference", {"itemID": parent_id})])}
            ))["revision"]
            for index, (subject, label) in enumerate([("chess tournament players", "include"), ("chess players board", "include"),
                    ("garden vegetables soil", "exclude"), ("garden soil flowers", "exclude")]):
                client.tool("tractanda_commit", wire.intent("create", "example-" + str(index), class_id="NoteItem",
                    changes={"subject": wire.text(subject), "categoryOverrides": obj({category_id: wire.text(label)})}))
            candidate = client.tool("tractanda_commit", wire.intent("create", "candidate", class_id="NoteItem",
                changes={"subject": wire.text("chess tournament board")}))["revision"]
            candidate_id = wire.item_id(candidate)
            assert client.tool("tractanda_learning_status", {"categoryID": category_id})["status"] == "untrained"
            trained = client.tool("tractanda_learning_train", {"categoryID": category_id})
            assert trained["status"] == "ready" and trained["positiveExamples"] == trained["negativeExamples"] == 2
            suggestions = client.tool("tractanda_learning_suggest", {"categoryID": category_id})
            assert candidate_id in [entry["itemID"] for entry in suggestions["list"]]
            categories = client.tool("tractanda_learning_categories", {"itemID": candidate_id, "categoryIDs": [category_id]})
            assert categories["list"][0]["categoryID"] == category_id
            feedback = {"itemID": candidate_id, "categoryID": category_id, "expectedRevisionID": wire.revision_id(candidate),
                "operationID": "accept", "action": "accept", "modelID": trained["modelID"]}
            accepted = client.tool("tractanda_learning_feedback", feedback)["revision"]
            assert accepted == native.call("TractandaItem/get", {
                "ids": [candidate_id], "projection": "content"})["list"][0]
            assert client.tool("tractanda_get", {"ids": [candidate_id], "projection": "full"})["list"] == [native.get(candidate_id)]
            assert client.tool("tractanda_explain", {"itemID": candidate_id, "categoryID": category_id})["included"] is True
            explanation = client.tool("tractanda_explain", {"itemID": candidate_id, "categoryID": parent_id})
            assert explanation == native.call(
                "TractandaItem/explain", {"itemID": candidate_id, "categoryID": parent_id})
            assert explanation["inheritancePath"] == [parent_id, category_id]
            assert explanation["sourceReason"] == "manual include"
            assert client.tool("tractanda_learning_feedback", feedback)["replayed"]
            client.tool("tractanda_learning_feedback", dict(feedback, action="exclude"), error="operationMismatch")
            client.tool("tractanda_learning_suggest", {"categoryID": category_id, "ifInState": suggestions["learning"]["queryState"]}, error="stateMismatch")
            exclude = dict(feedback, expectedRevisionID=wire.revision_id(accepted), operationID="exclude", action="exclude")
            excluded = client.tool("tractanda_learning_feedback", exclude)["revision"]
            assert not client.tool("tractanda_explain", {"itemID": candidate_id, "categoryID": category_id})["included"]
            cleared = client.tool("tractanda_learning_feedback", dict(exclude, expectedRevisionID=wire.revision_id(excluded),
                operationID="clear-feedback", action="clear"))["revision"]
            assert cleared["fields"]["categoryOverrides"] == excluded["fields"]["categoryOverrides"]
            assert category_id not in cleared["fields"]["learningFeedback"]["value"]
            configured = client.tool("tractanda_learning_settings", {"categoryID": category_id,
                "expectedRevisionID": wire.revision_id(category), "operationID": "settings",
                "settings": obj({"profile": wire.text("tractanda.category-learning.v1"), "threshold": tagged("real", -0.2)})})
            assert configured["revision"]["fields"]["learningSettings"]["value"]["threshold"]["value"] == -0.2
            assert configured["revision"] == native.call("TractandaItem/get", {
                "ids": [category_id], "projection": "content"})["list"][0]
            assert client.tool("tractanda_get", {"ids": [category_id], "projection": "full"})["list"] == [native.get(category_id)]
            assert client.tool("tractanda_learning_train", {"categoryID": category_id})["status"] == "ready"
            assert client.tool("tractanda_learning_reset", {"categoryID": category_id})["status"] == "untrained"
            assert cleared == native.call("TractandaItem/get", {
                "ids": [candidate_id], "projection": "content"})["list"][0]
            assert client.tool("tractanda_get", {"ids": [candidate_id], "projection": "full"})["list"] == [native.get(candidate_id)]
            checks.append("training from actual assignments/exclusions, suggestions in both directions, feedback/retry, manual authority, settings and reset")

            section_view = client.tool("tractanda_commit", wire.intent("create", "section-view", class_id="SavedViewItem", changes={
                "viewDefinition": obj({"language": wire.text("tractanda.spotlight.v0"),
                    "text": wire.text("chess"), "presentation": obj({"profile": wire.text("tractanda.table.v0"),
                    "sections": tagged("list", [tagged("reference", {"itemID": category_id})])})})}))["revision"]
            view_id = wire.item_id(section_view)
            section_query = {"viewID": view_id, "sectionID": category_id, "limit": 32,
                "at": "2026-09-09T12:00:00Z", "timeZone": "UTC"}
            assert client.tool("tractanda_query", section_query) == native.call("TractandaItem/query", section_query)
            client.tool("tractanda_query", {"sectionID": category_id}, error="invalidArguments")
            client.tool("tractanda_query", {"viewID": view_id, "sort": []}, error="invalidArguments")
            checks.append("inline ItemSort property/isAscending and saved-view sectionID semantics")

            realistic = []
            for index in range(64):
                revision = native.commit(wire.intent("create", "bounded-" + str(index), class_id="NoteItem", changes={
                    "subject": wire.text("Bounded record %02d" % index),
                    "body": wire.text("Body %02d: " % index + "x" * 4500),
                    "rank": tagged("integer", 9223372036854775807 - index),
                    "userMetadata": obj({"requestIdentity": wire.text("user-owned nested value %02d" % index),
                        "rank": tagged("integer", index)})}))["revision"]
                realistic.append(wire.item_id(revision))
            native_full_batch = native.call("TractandaItem/get", {"ids": realistic, "projection": "full"})
            assert len(json.dumps(native_full_batch).encode()) > 512 * 1024
            default_transfer = client.tool("tractanda_get", {"ids": realistic})
            assert [record["fields"]["itemID"]["value"] for record in default_transfer["list"]] == realistic
            assert default_transfer["list"][0]["fields"]["userMetadata"]["value"]["requestIdentity"] == wire.text("user-owned nested value 00")
            continuation = []
            pending = realistic
            while pending:
                page = client.tool("tractanda_get", {"ids": pending, "projection": "summary", "maxBytes": 8192})
                continuation.extend(record["fields"]["itemID"]["value"] for record in page["list"])
                assert page["oversizedIDs"] == [], page
                assert page["remainingIDs"] != pending, page
                pending = page["remainingIDs"]
            assert continuation == realistic
            content_continuation = []
            pending = realistic
            while pending:
                page = client.tool("tractanda_get", {"ids": pending, "projection": "content", "maxBytes": 16384})
                content_continuation.extend(record["fields"]["itemID"]["value"] for record in page["list"])
                assert page["oversizedIDs"] == [], page
                pending = page["remainingIDs"]
            assert content_continuation == realistic
            property_continuation = []
            pending = realistic
            while pending:
                page = client.tool("tractanda_get", {"ids": pending,
                    "properties": ["subject", "rank", "userMetadata"], "maxBytes": 8192})
                property_continuation.extend(record["fields"]["itemID"]["value"] for record in page["list"])
                assert page["oversizedIDs"] == [], page
                pending = page["remainingIDs"]
            assert property_continuation == realistic
            full_bounded = client.tool("tractanda_get", {"ids": realistic, "projection": "full", "maxBytes": 8192})
            assert full_bounded["list"] == [] and full_bounded["remainingIDs"] == []
            assert full_bounded["oversizedIDs"] == realistic
            huge = native.commit(wire.intent("create", "huge-get", class_id="NoteItem", changes={
                "subject": wire.text("Huge but retrievable by property"), "body": wire.text("x" * 100000),
                "customInt": tagged("integer", 9223372036854775807)}))["revision"]
            huge_id = wire.item_id(huge)
            bounded = client.tool("tractanda_get", {"ids": [huge_id], "projection": "content", "maxBytes": 8192})
            assert bounded["list"] == [] and bounded["remainingIDs"] == [] and bounded["oversizedIDs"] == [huge_id]
            properties = client.tool("tractanda_get", {"ids": [huge_id], "properties": ["subject", "customInt"], "maxBytes": 8192})
            fields = properties["list"][0]["fields"]
            assert fields["customInt"]["value"] == 9223372036854775807 and "body" not in fields
            checks.append("64 body/metadata records whose native full result exceeds 512 KiB; default content transfer, summary/property/content continuation, oversized full records, nested requestIdentity metadata and Int64 retrieval")

            # Pipeline concurrent responses large enough to exercise output pipe backpressure.
            moderate = native.commit(wire.intent("create", "moderate", class_id="NoteItem", changes={"body": wire.text("x" * 70000)}))["revision"]
            for sequence in range(1000, 1008):
                client.send({"jsonrpc": "2.0", "id": sequence, "method": "tools/call", "params": {
                    "name": "tractanda_get", "arguments": {"ids": [wire.item_id(moderate)]}}})
            responses = [client.receive() for _ in range(8)]
            assert {response["id"] for response in responses} == set(range(1000, 1008))
            assert all(response["result"]["structuredContent"]["list"] == native.call(
                "TractandaItem/get", {"ids": [wire.item_id(moderate)], "projection": "content", "maxBytes": 524288})["list"] for response in responses)
            before = native.call("TractandaItem/query")["total"]
            too_large = wire.intent("create", "oversized-argument", class_id="NoteItem", changes={"body": wire.text("x" * (1024 * 1024))})
            client.tool("tractanda_commit", too_large, error="requestTooLarge")
            assert native.call("TractandaItem/query")["total"] == before
            normal_large = client.tool("tractanda_commit", wire.intent("create", "normal-large-result", class_id="NoteItem", changes={
                "subject": wire.text("Normal compact write"), "body": wire.text("x" * 300000)}))["revision"]
            assert normal_large == native.call("TractandaItem/get", {
                "ids": [wire.item_id(normal_large)], "projection": "content"})["list"][0]
            assert native.call("TractandaItem/query")["total"] == before + 1
            oversized_result = wire.intent("create", "oversized-result", class_id="NoteItem", changes={"subject": wire.text("Large result"), "body": wire.text("x" * 600000)})
            failure = client.tool("tractanda_commit", oversized_result, error="responseTooLarge")
            assert failure["operationID"] == "oversized-result"
            assert native.call("TractandaItem/query")["total"] == before + 2
            client.tool("tractanda_commit", oversized_result, error="responseTooLarge")
            assert native.call("TractandaItem/query")["total"] == before + 2
            checks.append("fragmented input, concurrent output under backpressure, request bounds, compact 300000-character write success and committed 600000-character oversized-result replay")
        # Process restart keeps native receipts; it does not depend on an adapter cache.
        with MCPClient(adapter, socket) as restarted:
            restarted.initialize()
            assert restarted.tool("tractanda_commit", revise)["replayed"]
            assert restarted.tool("tractanda_history", {"itemID": item_id})["total"] == 2
        # Oversized unframed input closes without dispatch or hanging.
        oversized = subprocess.Popen([str(adapter), str(socket)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        stdout, stderr = oversized.communicate(b"x" * (4 * 1024 * 1024 + 1), timeout=15)
        assert not stdout, stdout[:200]
        checks.append("adapter restart preserves retry receipts, clean EOF shutdown, oversized unterminated frame rejection")
        for result_format in ("text", "structured"):
            with MCPClient(adapter, socket, result_format=result_format) as formatted:
                formatted.initialize()
                catalog = formatted.request("tools/list")["tools"]
                assert all("outputSchema" not in tool for tool in catalog) == (result_format == "text")
                formatted_info = formatted.tool("tractanda_info")
                assert comparable_info(formatted_info) == comparable_info(native.call("TractandaStore/info"))
                assert formatted_info["connection"]["status"] == "ready"
                formatted.tool("tractanda_get", {}, error="invalidArguments")
        checks.append("both/text/structured result modes, outputSchema discovery and error contracts")
    shutil.rmtree(store / "index")
    with wire.server(binary, store, socket):
        with MCPClient(adapter, socket) as rebuilt:
            rebuilt.initialize()
            rebuilt_info = rebuilt.tool("tractanda_info")
            assert rebuilt_info["server"]["instanceID"] != server_instance
            assert rebuilt_info["connection"]["adapter"]["instanceID"] != adapter_instance
            assert rebuilt.tool("tractanda_commit", revise)["replayed"]
            assert rebuilt.tool("tractanda_history", {"itemID": item_id})["total"] == 2
    checks.append("native index loss and rebuild preserve MCP-visible history and durable retry identity")


def exercise_older_server(binary, adapter, root, checks):
    """Diagnose a real older native build without changing its installed store or executable."""
    store, socket = root / "older-store", root / "older-socket"
    with wire.server(binary, store, socket) as native:
        assert "features" not in native.call("TractandaStore/info"), "Fixture must predate feature declarations"
        with MCPClient(adapter, socket) as client:
            client.initialize()
            info = client.tool("tractanda_info")
            assessment = info["connection"]["referenceCompatibility"]
            assert info["connection"]["status"] == "ready"
            assert assessment["status"] == "unverified"
            assert "missingServerFeatures" not in assessment
            assert "features" not in info
            semantic = client.resource("tractanda://reference/semantic")["text"]
            assert "tractanda.semantic-job-timing.v1" in semantic
            assert "conditional" in semantic
    checks.append("new adapter with real older native binary reports unverified features and conditional references in-band")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary")
    parser.add_argument("adapter")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--older-server", type=Path, help="Optional native binary predating feature declarations")
    args = parser.parse_args()
    checks = []
    # macOS TMPDIR can itself exceed the Unix-domain socket path budget.
    with tempfile.TemporaryDirectory(prefix="trac-mcp-", dir="/tmp") as temporary:
        exercise(str(Path(args.binary).resolve()), str(Path(args.adapter).resolve()), Path(temporary), checks)
        if args.older_server:
            exercise_older_server(str(args.older_server.resolve()), str(Path(args.adapter).resolve()), Path(temporary), checks)
    result = {"status": "passed", "platform": platform.platform(), "python": platform.python_version(),
        "protocolVersion": "2025-11-25", "checks": checks}
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
