#!/usr/bin/env python3
"""Disposable end-to-end verifier for the integrated native/HTTP/MCP daemon.

It never opens a real store, invokes password authentication, or registers a service.
"""
import argparse
import http.client
import json
import os
from pathlib import Path
import select
import socket
import struct
import subprocess
import tempfile
import time


CAPABILITY = "https://tractanda.ai/ns/local-prototype/2"


def exact(connection, count):
    result = bytearray()
    while len(result) < count:
        chunk = connection.recv(count - len(result))
        if not chunk:
            raise RuntimeError("native socket closed before a complete frame")
        result.extend(chunk)
    return bytes(result)


def native(socket_path, calls):
    request = json.dumps({"using": [CAPABILITY], "methodCalls": calls}).encode()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(10)
        connection.connect(str(socket_path))
        connection.sendall(struct.pack("!I", len(request)) + request)
        size = struct.unpack("!I", exact(connection, 4))[0]
        return json.loads(exact(connection, size))


def http_request(port, method, path, body=None, headers=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    connection.request(method, path, body=body, headers=headers or {})
    response = connection.getresponse()
    result = (response.status, dict(response.getheaders()), response.read())
    connection.close()
    return result


def response_value(value):
    calls = value.get("methodResponses", [])
    assert len(calls) == 1, value
    assert calls[0][0] != "error", value
    return calls[0][1]


def wait_line(process):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("daemon stopped before reporting endpoints")
        if select.select([process.stdout], [], [], 0.1)[0]:
            return process.stdout.readline()
    raise RuntimeError("daemon did not report endpoints")


def mcp_request(port, token, method, params, request_id, session=None):
    headers = {
        "Authorization": "Bearer " + token,
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    if session:
        headers["Mcp-Session-Id"] = session
    body = json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}).encode()
    return http_request(port, "POST", "/mcp", body, headers)


def stdio_request(process, value):
    process.stdin.write(json.dumps(value).encode() + b"\n")
    process.stdin.flush()
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if select.select([process.stdout], [], [], 0.1)[0]:
            line = process.stdout.readline()
            if line:
                return json.loads(line)
        if process.poll() is not None:
            raise RuntimeError("tractanda-mcp exited unexpectedly")
    raise RuntimeError("tractanda-mcp did not reply")


def expect_rejected(binary, arguments):
    result = subprocess.run([binary, "daemon", *arguments], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=10)
    assert result.returncode == 1, result.stderr


def header(headers, name):
    return next((value for key, value in headers.items() if key.lower() == name.lower()), None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tractanda", type=Path)
    parser.add_argument("tractanda_mcp", type=Path)
    parser.add_argument("tractanda_tui", type=Path)
    args = parser.parse_args()
    binaries = [str(value.resolve()) for value in (args.tractanda, args.tractanda_mcp, args.tractanda_tui)]
    assert all(Path(value).is_file() for value in binaries)
    checks = []
    with tempfile.TemporaryDirectory(prefix="tsd-", dir="/private/tmp" if Path("/private/tmp").is_dir() else "/tmp") as root:
        root = Path(root)
        store, socket_path = root / "store", root / "s"
        daemon = subprocess.Popen(
            [binaries[0], "daemon", str(store), str(socket_path), "--http-port", "0"],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            endpoints = json.loads(wait_line(daemon))
            assert endpoints["socketPath"] == str(socket_path)
            port = int(endpoints["httpURL"].rsplit(":", 1)[1])
            assert endpoints["mcpURL"] == endpoints["httpURL"] + "/mcp" and port > 0
            checks.append("generic daemon endpoint JSON and simultaneous Unix/HTTP listeners")

            info = response_value(native(socket_path, [["TractandaStore/info", {}, "native-info"]]))
            assert "ownerUID" in info
            session = response_value(native(socket_path, [["TractandaAuth/createSession", {}, "self"]]))
            token = session["token"]
            assert len(token) == 64 and all(character in "0123456789abcdef" for character in token)
            checks.append("kernel-peer native info and self-session issuance")

            status, _, body = http_request(port, "GET", "/manual")
            assert status == 200 and b"user guide" in body.lower()
            status, _, body = http_request(port, "GET", "/auth/session", headers={"Authorization": "Bearer " + token})
            assert status == 200 and json.loads(body)["isAuthenticated"] is True
            api_headers = {"Authorization": "Bearer " + token, "Content-Type": "application/json"}
            info_request = json.dumps({"using": [CAPABILITY], "methodCalls": [["TractandaStore/info", {}, "http-info"]]}).encode()
            status, _, body = http_request(port, "POST", "/api", info_request, api_headers)
            assert status == 200 and "ownerUID" in response_value(json.loads(body))
            write = {
                "action": "create", "operationID": "shared-daemon-wire-write", "classID": "NoteItem",
                "changes": {"subject": {"type": "text", "value": "shared daemon wire fixture"}}, "unset": [],
            }
            commit_request = json.dumps({"using": [CAPABILITY], "methodCalls": [["TractandaItem/commit", write, "write"]]}).encode()
            status, _, body = http_request(port, "POST", "/api", commit_request, api_headers)
            assert status == 200 and "revision" in response_value(json.loads(body))
            checks.append("manual, authenticated HTTP session, native read and guarded write")

            initialize = {
                "protocolVersion": "2025-11-25", "capabilities": {},
                "clientInfo": {"name": "shared daemon verifier", "version": "1"},
            }
            status, headers, body = mcp_request(port, token, "initialize", initialize, 1)
            mcp_session = header(headers, "mcp-session-id")
            assert status == 200 and mcp_session and json.loads(body)["result"]["protocolVersion"] == "2025-11-25"
            status, _, _ = http_request(
                port, "POST", "/mcp",
                json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}).encode(),
                {**api_headers, "Accept": "application/json", "Mcp-Session-Id": mcp_session})
            assert status in (200, 202)
            status, _, body = mcp_request(port, token, "tools/list", {}, 2, mcp_session)
            tools = {entry["name"] for entry in json.loads(body)["result"]["tools"]}
            assert status == 200 and "tractanda_info" in tools
            status, _, body = mcp_request(port, token, "tools/call", {"name": "tractanda_info", "arguments": {}}, 3, mcp_session)
            assert status == 200 and not json.loads(body)["result"].get("isError", False)
            checks.append("MCP initialize/initialized/tools list/current-user-scoped info")

            legacy = subprocess.Popen([binaries[1], str(socket_path)], stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                initial = stdio_request(legacy, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": initialize})
                assert initial["result"]["protocolVersion"] == "2025-11-25"
                legacy.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
                legacy.stdin.flush()
                tools = stdio_request(legacy, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
                assert "tractanda_info" in {entry["name"] for entry in tools["result"]["tools"]}
            finally:
                legacy.stdin.close()
                legacy.wait(timeout=10)
                assert legacy.returncode == 0
            old_client = subprocess.run([binaries[0], "info", str(socket_path)], stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, timeout=10)
            assert old_client.returncode == 0 and b"ownerUID" in old_client.stdout
            tui_help = subprocess.run([binaries[2], "--help"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
            assert tui_help.returncode == 0
            checks.append("existing stdio MCP, legacy socket CLI, and TUI executable")

            for malformed in (
                [str(store), str(socket_path), "--http-port", "1", "--http-port", "2"],
                [str(store), str(socket_path), "--no-http", "--http-port", "1"],
                [str(store), str(socket_path), "--http-port", "1", "--no-http"],
                [str(store), str(socket_path), "--http-port", "nope"],
                [str(store), str(socket_path), "--unknown"],
                [str(store), str(socket_path), "--view", "not-an-id", "--project-root", "also-not-an-id"],
                [str(store), str(socket_path), "--http-port"],
            ):
                expect_rejected(binaries[0], malformed)
            help_result = subprocess.run([binaries[0], "daemon", "--help"], stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE, timeout=10)
            assert help_result.returncode == 0 and b"tractanda daemon" in help_result.stdout
            checks.append("daemon parser duplicate, mixed HTTP, invalid, missing, board, and help cases")

            status, _, _ = http_request(port, "POST", "/auth/logout", headers={"Authorization": "Bearer " + token})
            assert status == 200
            status, _, _ = mcp_request(port, token, "tools/list", {}, 4, mcp_session)
            assert status == 401
            checks.append("logout revokes HTTP and MCP bearer access")
        finally:
            if daemon.poll() is None:
                daemon.terminate()
                daemon.wait(timeout=10)
            assert daemon.returncode == 0
            assert not socket_path.exists()
    print(json.dumps({"passed": True, "checks": len(checks), "details": checks}, indent=2))


if __name__ == "__main__":
    main()
