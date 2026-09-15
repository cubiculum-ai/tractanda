#!/usr/bin/env python3
"""Real OS peers, current-history authorization, private learning, and read-only archives.

Account provisioning runs ONLY as root inside an explicitly marked disposable Linux
container. For macOS use --accounts with an administrator-prepared JSON mapping of
existing service/alice/bob/agent/outsider account names; no host accounts are created.
All application data goes in a disposable temporary directory. Neither mode changes
permissions on existing application stores. Linux-only group/mount/ACL probes are
excluded from the macOS account fixture and reported separately.
"""
import argparse
import contextlib
import errno
import grp
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import pwd
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
wire_spec = importlib.util.spec_from_file_location("ipc_fixture", Path(__file__).with_name("verify-ipc.py"))
wire_module = importlib.util.module_from_spec(wire_spec)
wire_spec.loader.exec_module(wire_module)


def tagged(kind, value):
    return {"type": kind, "value": value}


def text(value):
    return tagged("text", value)


def obj(value):
    return tagged("object", value)


def number(value):
    return tagged("integer", value)


def identity(revision, key="itemID"):
    return revision["fields"][key]["value"]


def provision():
    assert platform.system() == "Linux" and os.environ.get("TRACTANDA_DISPOSABLE_CONTAINER") == "1", "Provisioning is restricted to the marked Linux test container"
    names = {key: "trac_test_" + key for key in ["service", "alice", "bob", "agent", "outsider"]}
    for offset, name in enumerate(names.values()):
        subprocess.run(["groupadd", "--gid", str(27110 + offset), name], check=True)
        subprocess.run(["useradd", "--uid", str(27110 + offset), "--gid", name, "--no-create-home", "--shell", "/usr/sbin/nologin", name], check=True)
    for group in ["trac_test_team", "trac_test_readers", "trac_test_writers"]:
        subprocess.run(["groupadd", group], check=True)
    for key in ["alice", "bob", "agent"]:
        subprocess.run(["usermod", "--append", "--groups", "trac_test_team", names[key]], check=True)
    subprocess.run(["usermod", "--append", "--groups", "trac_test_readers,trac_test_writers", names["bob"]], check=True)
    return names


class Fixture:
    def __init__(self, binary, names, root, linux):
        self.binary = str(Path(binary).resolve())
        self.names = names
        self.root = root
        self.store = root / "store"
        self.socket = root / "s"
        self.linux = linux
        self.team = "trac_test_team" if linux else pwd.getpwnam(names["alice"]).pw_gid
        if isinstance(self.team, int):
            self.team = grp.getgrgid(self.team).gr_name
        self.checks = []
        self.process = None

    def run(self, key, command, **kwargs):
        account = pwd.getpwnam(self.names[key])
        environment = {**os.environ, "TRACTANDA_SERVER_USER": self.names["service"]}
        return subprocess.run(command, user=account.pw_uid, group=account.pw_gid,
            extra_groups=os.getgrouplist(account.pw_name, account.pw_gid), env=environment,
            text=True, capture_output=True, timeout=40, **kwargs)

    def call(self, key, method, args=None, error=None):
        request = {"using": [wire_module.CAPABILITY], "methodCalls": [[method, args or {}, "test"]]}
        result = self.run(key, [sys.executable, __file__, "--wire", str(self.socket)], input=json.dumps(request))
        assert result.returncode == 0, (key, result.stderr)
        envelope = json.loads(result.stdout)
        if "code" in envelope:
            assert error == envelope["code"], envelope
            return envelope
        name, value, _ = envelope["methodResponses"][0]
        if error:
            assert name == "error" and value["type"] == error, (error, envelope)
        else:
            assert name == method, envelope
        return value

    def get(self, key, item):
        return self.call(key, "TractandaItem/get", {"ids": [identity(item)]})

    def commit(self, key, fields=None, base=None, action=None, class_id=None, operation=None, error=None):
        request = wire_module.intent(action or ("revise" if base else "create"), operation or str(uuid.uuid4()),
            item=identity(base) if base else None, base=identity(base, "revisionID") if base else None,
            class_id=class_id or ("NoteItem" if base is None else None), changes=fields)
        return self.call(key, "TractandaItem/commit", request, error=error)

    def permissions(self, mode=0o600, acl=None, owner=None, group=None):
        return obj({"profile": text("tractanda.permissions.posix.v1"), "owner": text(owner or self.names["alice"]),
            "group": text(group or self.team), "mode": number(mode), "acl": obj(acl or {})})

    def configure(self):
        # Only Bob is admitted through a supplementary group in the Linux fixture.
        admitted = ["alice", "agent"] if self.linux else ["alice", "bob", "agent"]
        config = obj({"profile": text("tractanda.access.v1"),
            "users": tagged("list", [text(self.names[key]) for key in admitted]),
            "groups": tagged("list", [text(self.team)] if self.linux else []),
            "userAliases": obj({"former_alice": text(self.names["alice"]), "older_alice": text(self.names["alice"])})})
        self.config = config
        path = self.root / "config.json"
        path.write_text(json.dumps(config))
        completed = self.run("service", [self.binary, "configure-access", str(self.store), str(path), "configure"])
        assert completed.returncode == 0, completed.stderr
        self.configuration_item = json.loads(completed.stdout)["revision"]

    @contextlib.contextmanager
    def server(self):
        account = pwd.getpwnam(self.names["service"])
        with tempfile.TemporaryFile() as log:
            process = subprocess.Popen([self.binary, "serve", str(self.store), str(self.socket)],
                user=account.pw_uid, group=account.pw_gid, extra_groups=[], stdout=subprocess.DEVNULL, stderr=log)
            self.process = process
            try:
                deadline = time.monotonic() + 20
                while True:
                    if process.poll() is not None or time.monotonic() > deadline:
                        log.seek(0)
                        raise AssertionError(log.read().decode())
                    if self.socket.exists():
                        ready = self.run("service", [self.binary, "info", str(self.socket)])
                        if ready.returncode == 0:
                            assert json.loads(ready.stdout)["ownerUID"] == account.pw_uid
                            break
                    time.sleep(0.03)
                yield
            finally:
                process.terminate()
                try:
                    process.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                self.process = None
                if process.returncode != 0 or self.socket.exists():
                    log.seek(0)
                    raise AssertionError("Native shutdown failed (%s): %s" % (process.returncode, log.read().decode()))

    def initial_checks(self):
        for key in ["alice", "bob", "agent"]:
            assert self.call(key, "TractandaStore/info")["accessScope"] == "user:" + self.names[key]
        self.call("outsider", "Core/echo", error="forbidden")
        cli = self.run("bob", [self.binary, "info", str(self.socket)])
        assert cli.returncode == 0, cli.stderr
        wrong = self.run("bob", ["env", "TRACTANDA_SERVER_USER=" + self.names["alice"], self.binary, "info", str(self.socket)])
        assert wrong.returncode != 0 and "forbidden" in wrong.stderr, wrong
        self.checks.append("kernel peer identities, admission, agent account, CLI daemon identity pinning")

        private = self.commit("alice", {"subject": text("Private secret chess"), "mobilePhone": text("private-mobile")}, class_id="NaturalPersonItem")["revision"]
        acl = {"mask": number(6), "owningGroup": number(0), "users": obj({self.names["bob"]: number(6), self.names["agent"]: number(4)})}
        first = self.commit("alice", {"subject": text("Shared chess"), "permissions": self.permissions(0o660, acl, "former_alice")})["revision"]
        assert self.get("bob", private)["notFound"] == [identity(private)]
        assert self.call("bob", "TractandaItem/query", {"text": "secret"})["total"] == 0
        assert self.get("agent", first)["list"]
        self.commit("agent", {"body": text("unauthorized edit")}, base=first, error="forbidden")
        second = self.commit("bob", {"body": text("Bob edited this")}, base=first, operation="bob-edit")["revision"]
        self.commit("bob", {"permissions": self.permissions(0o666)}, base=second, error="forbidden")
        self.call("bob", "TractandaStore/rebuild", error="forbidden")
        self.commit("bob", {"accessConfiguration": self.config}, class_id="AccessConfigurationItem", error="forbidden")
        assert self.get("bob", self.configuration_item)["notFound"]
        copied = self.commit("bob", base=second, action="copy")["revision"]
        assert copied["fields"]["permissions"]["value"]["owner"] == text(self.names["bob"])
        assert self.get("alice", copied)["notFound"]
        assert self.call("bob", "TractandaItem/history", {"itemID": identity(copied)})["total"] == 1
        self.checks.append("ACL read/edit, owner-only sharing, private copy, private FTS/counts, admin-only configuration")

        role = self.commit("alice", {"phone": text("office-phone"), "permissions": self.permissions(0o660, acl),
            "holdings": tagged("list", [obj({"key": text("term"), "start": tagged("date", "2020-01-01T00:00:00Z"),
                "holder": tagged("reference", {"itemID": identity(private)})})])}, class_id="RoleItem")["revision"]
        official = self.call("bob", "TractandaItem/resolve", {"itemID": identity(role), "path": "phone"})
        assert official["value"] == text("office-phone"), official
        denied = self.call("bob", "TractandaItem/resolve", {"itemID": identity(role), "path": "holder.mobilePhone"})
        assert denied["status"] == "accessDenied", denied
        self.checks.append("public role fields and denied private holder traversal")

        category = self.commit("alice", {"subject": text("Chess category"), "permissions": self.permissions(0o660, acl),
            "selection": obj({"language": text("tractanda.spotlight.v0"), "expression": text('subject == "never matches"')})})["revision"]
        category_id = identity(category)
        before_state = self.call("bob", "TractandaStore/info")["state"]
        overlay = self.commit("alice", {"target": tagged("reference", {"itemID": identity(second)}),
            "personalOverrides": obj({category_id: text("include")})}, class_id="PersonalStateItem")["revision"]
        assert self.call("bob", "TractandaStore/info")["state"] == before_state
        assert identity(second) in self.call("alice", "TractandaItem/query", {"categoryPath": [category_id]})["ids"]
        assert identity(second) not in self.call("bob", "TractandaItem/query", {"categoryPath": [category_id]})["ids"]
        assert self.get("bob", overlay)["notFound"]
        for subject, label in [("chess tournament board", "include"), ("garden vegetables soil", "exclude"), ("garden flowers soil", "exclude")]:
            self.commit("alice", {"subject": text(subject), "categoryOverrides": obj({category_id: text(label)})})
        alice_model = self.call("alice", "TractandaLearning/train", {"categoryID": category_id})
        assert alice_model["positiveExamples"] == 2 and alice_model["negativeExamples"] == 2 and alice_model.get("modelID"), alice_model
        bob_model = self.call("bob", "TractandaLearning/status", {"categoryID": category_id})
        assert bob_model["positiveExamples"] == 0 and bob_model["negativeExamples"] == 0, bob_model
        self.call("bob", "TractandaLearning/reset", {"categoryID": category_id})
        assert self.call("alice", "TractandaLearning/status", {"categoryID": category_id})["modelID"] == alice_model["modelID"]
        self.checks.append("personal category overlays, hidden private state changes, per-user learning and reset")

        shared_examples = []
        for subject, label in [("chess tournament board", "include"), ("chess players board", "include"), ("garden flowers soil", "exclude"), ("garden vegetables soil", "exclude")]:
            shared_examples.append(self.commit("alice", {"subject": text(subject), "permissions": self.permissions(0o660, acl),
                "categoryOverrides": obj({category_id: text(label)})})["revision"])
        learned = self.call("bob", "TractandaLearning/train", {"categoryID": category_id})
        assert learned["status"] == "ready" and learned.get("modelID"), learned
        self.commit("alice", {"permissions": self.permissions()}, base=shared_examples[0])
        unavailable = self.call("bob", "TractandaLearning/suggest", {"categoryID": category_id})
        assert unavailable["list"] == [] and unavailable["learning"]["status"] == "insufficientEvidence", unavailable
        self.checks.append("revoked training source invalidates cached model before returning suggestions")

        if self.linux:
            subprocess.run(["gpasswd", "--delete", self.names["bob"], self.team], check=True, stdout=subprocess.DEVNULL)
            self.call("bob", "Core/echo", error="forbidden")
            subprocess.run(["usermod", "--append", "--groups", self.team, self.names["bob"]], check=True)
            self.call("bob", "TractandaStore/info")
            self.checks.append("supplementary group revocation and restoration without daemon restart")
        self.first, self.second, self.acl = first, second, acl

    def recovery_checks(self):
        assert self.get("bob", self.first)["list"]
        assert self.call("bob", "TractandaItem/history", {"itemID": identity(self.first)})["total"] == 2
        revoked = self.commit("alice", {"permissions": self.permissions()}, base=self.second)["revision"]
        assert self.get("bob", revoked)["notFound"]
        self.call("bob", "TractandaRevision/get", {"itemID": identity(self.first), "revisionID": identity(self.first, "revisionID")}, error="forbidden")
        self.call("bob", "TractandaItem/history", {"itemID": identity(self.first)}, error="forbidden")
        self.commit("bob", {"body": text("Bob edited this")}, base=self.first, operation="bob-edit", error="forbidden")
        latest = self.commit("alice", {"permissions": self.permissions(0o660, self.acl)}, base=revoked)["revision"]
        retry = self.commit("bob", {"body": text("Bob edited this")}, base=self.first, operation="bob-edit")
        assert retry["replayed"] and retry["revision"] == self.second
        self.call("service", "TractandaStore/rebuild")
        assert self.call("bob", "TractandaItem/history", {"itemID": identity(latest)})["total"] == 4
        self.checks.append("canonical-only recovery, preserved aliases and receipts, current policy gates all history and retries")

    def kernel_acl_checks(self):
        path = self.root / "acl-oracle"
        path.write_text("fixture")
        alice = pwd.getpwnam(self.names["alice"])
        os.chown(path, alice.pw_uid, grp.getgrnam(self.team).gr_gid)
        # Verify the split-group edge against an actual O_RDWR open.
        subprocess.run(["setfacl", "--set", "u::rw-,g::---,g:trac_test_readers:r--,g:trac_test_writers:-w-,m::rw-,o::rw-", str(path)], check=True)
        def opens(flags):
            return self.run("bob", [sys.executable, "-c", "import os,sys; os.close(os.open(sys.argv[1], int(sys.argv[2])))", str(path), str(flags)]).returncode == 0
        assert opens(os.O_RDONLY) and opens(os.O_WRONLY) and not opens(os.O_RDWR)
        subprocess.run(["setfacl", "--modify", "u:" + self.names["bob"] + ":---", str(path)], check=True)
        assert not opens(os.O_RDONLY)
        self.checks.append("independent kernel POSIX ACL oracle: split group rights and named-user precedence")

    def mcp_checks(self, adapter):
        spec = importlib.util.spec_from_file_location("mcp_fixture", Path(__file__).with_name("verify-mcp.py"))
        mcp = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mcp)
        fixture_spec = importlib.util.spec_from_file_location("category_fixture", Path(__file__).with_name("category-board-fixture.py"))
        category_fixture = importlib.util.module_from_spec(fixture_spec)
        fixture_spec.loader.exec_module(category_fixture)
        mapping = category_fixture.create_fixture(lambda request: self.call("alice", "TractandaItem/commit", request))
        board_id = mapping["viewItemID"]
        card_id, private_id = [mapping["itemIDs"][key] for key in ["TEST-1", "TEST-2"]]
        board = self.call("alice", "TractandaItem/get", {"ids": [board_id]})["list"][0]
        card = self.call("alice", "TractandaItem/get", {"ids": [card_id]})["list"][0]
        read_acl = {"mask": number(4), "owningGroup": number(0), "users": obj({self.names["agent"]: number(4)})}
        write_acl = {"mask": number(6), "owningGroup": number(0), "users": obj({self.names["agent"]: number(6)})}
        for category_id in [mapping["projectID"], mapping["statusID"], mapping["groupID"], *mapping["columns"].values()]:
            category = self.call("alice", "TractandaItem/get", {"ids": [category_id]})["list"][0]
            self.commit("alice", {"permissions": self.permissions(0o640, read_acl)}, base=category)
        board = self.commit("alice", {"permissions": self.permissions(0o640, read_acl)}, base=board)["revision"]
        card = self.commit("alice", {"permissions": self.permissions(0o660, write_acl)}, base=card)["revision"]

        def peer(role, service_name=None):
            account = pwd.getpwnam(self.names[role])
            return mcp.MCPClient(adapter, self.socket, user=account.pw_uid, group=account.pw_gid,
                extra_groups=os.getgrouplist(account.pw_name, account.pw_gid),
                env={**os.environ, "TRACTANDA_SERVER_USER": service_name or self.names["service"]})

        with peer("agent") as client:
            client.initialize(client_name=self.names["service"])
            assert client.tool("tractanda_info")["accessScope"] == "user:" + self.names["agent"]
            client.tool("tractanda_info", {"actor": self.names["alice"]}, error="invalidArguments")
            assert client.tool("tractanda_query", {"viewID": board_id})["ids"] == [card_id]
            assert client.tool("tractanda_get", {"ids": [private_id]})["notFound"] == [private_id]
            client.resource("tractanda://items/" + private_id, error=-32002)
            client.tool("tractanda_commit", wire_module.intent("revise", "agent-board-denied", board_id,
                identity(board, "revisionID"), changes={"subject": text("not allowed")}), error="forbidden")
            edit = wire_module.intent("revise", "agent-card-edit", card_id, identity(card, "revisionID"),
                changes={"categoryOverrides": obj({**card["fields"]["categoryOverrides"]["value"], mapping["columns"]["ready"]: text("exclude"), mapping["columns"]["done"]: text("include")}), "workingNotes": text("Completed by the separate OS agent through MCP.")})
            changed = client.tool("tractanda_commit", edit)["revision"]
            assert changed["fields"]["actor"] == text("user:" + self.names["agent"])
            assert client.tool("tractanda_commit", edit)["replayed"]
            human = self.run("alice", [self.binary, "kanban", str(self.socket), board_id])
            assert human.returncode == 0, human.stderr
            human = json.loads(human.stdout)
            assert len(human["tasks"]) == 2
            visible = next(task for task in human["tasks"] if task["id"] == card_id)
            assert visible["categoryIDs"] == [mapping["columns"]["done"]] and visible["revisionID"] == identity(changed, "revisionID")
            assert self.call("alice", "TractandaItem/get", {"ids": [board_id]})["list"] == [board]
            self.commit("alice", {"permissions": self.permissions()}, base=changed)
            assert client.tool("tractanda_get", {"ids": [card_id]})["notFound"] == [card_id]
            assert client.tool("tractanda_query", {"viewID": board_id})["total"] == 0
            client.tool("tractanda_history", {"itemID": card_id}, error="forbidden")
            client.tool("tractanda_revision", {"itemID": card_id, "revisionID": identity(card, "revisionID")}, error="forbidden")
            client.resource("tractanda://items/" + card_id + "/revisions/" + identity(card, "revisionID"), error=-32002)
            client.tool("tractanda_commit", edit, error="forbidden")
        with peer("outsider") as client:
            client.initialize()
            client.tool("tractanda_info", error="forbidden")
            client.tool("tractanda_get", {"ids": [card_id]}, error="forbidden")
        with peer("agent", self.names["alice"]) as client:
            client.initialize()
            client.tool("tractanda_info", error="forbidden")
        self.checks.append("MCP under a distinct agent UID: permission-filtered board, guarded card edit visible to human CLI, immutable board, private-item/board-write denial, current-history/resource/retry revocation, outsider and server UID checks")

    def transfer_checks(self):
        original = self.store
        hashes = {str(p.relative_to(original / "items")): hashlib.sha256(p.read_bytes()).hexdigest() for p in (original / "items").rglob("*.tractanda")}
        # Simulate another deployment with the same Unix names and different numeric UIDs.
        # No Tractanda process is running; these are container-only fixture accounts.
        for name in self.names.values():
            account = pwd.getpwnam(name)
            subprocess.run(["usermod", "--uid", str(account.pw_uid + 1000), name], check=True, capture_output=True)
        self.store = self.root / "restored"
        self.store.mkdir(mode=0o700)
        shutil.copytree(original / "items", self.store / "items")
        service = pwd.getpwnam(self.names["service"])
        for path in [self.store, *self.store.rglob("*")]:
            os.chown(path, service.pw_uid, service.pw_gid)
        os.chown(self.socket.parent, service.pw_uid, service.pw_gid)
        with self.server():
            current = self.get("alice", self.first)["list"][0]
            assert self.call("bob", "TractandaItem/history", {"itemID": identity(current)})["total"] == 4
            retry = self.commit("bob", {"body": text("Bob edited this")}, base=self.first, operation="bob-edit")
            assert retry["replayed"] and retry["revision"] == self.second
            edited = self.commit("alice", {"body": text("Edited after UID mapping")}, base=current)["revision"]
            assert edited["fields"]["actor"] == text("user:" + self.names["alice"])
        assert all(hashlib.sha256((self.store / "items" / path).read_bytes()).hexdigest() == digest for path, digest in hashes.items())
        self.checks.append("canonical-only transfer to remapped OS UIDs, multiple aliases, preserved bytes, retry identity and new write")


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "--wire":
        print(json.dumps(wire_module.wire(Path(sys.argv[2]), json.load(sys.stdin))))
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary")
    parser.add_argument("--provision-disposable-linux", action="store_true")
    parser.add_argument("--accounts", type=Path)
    parser.add_argument("--mcp-binary", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    assert os.geteuid() == 0, "Fixture setup and real account subprocesses require administrator privileges"
    assert args.provision_disposable_linux != bool(args.accounts), "Choose disposable Linux provisioning or existing accounts"
    names = provision() if args.provision_disposable_linux else json.loads(args.accounts.read_text())
    assert set(names) == {"service", "alice", "bob", "agent", "outsider"} and len(set(names.values())) == 5
    assert len({pwd.getpwnam(name).pw_uid for name in names.values()}) == 5
    with tempfile.TemporaryDirectory(prefix="trac-multi-") as temporary:
        root = Path(temporary)
        os.chmod(root, 0o755)
        fixture = Fixture(args.binary, names, root, args.provision_disposable_linux)
        service = pwd.getpwnam(names["service"])
        fixture.store.mkdir(mode=0o700)
        os.chown(fixture.store, service.pw_uid, service.pw_gid)
        # The socket needs a service-writable parent, but other accounts cannot replace it.
        runtime = root / "runtime"
        runtime.mkdir(mode=0o755)
        os.chown(runtime, service.pw_uid, service.pw_gid)
        fixture.socket = runtime / "s"
        fixture.configure()
        with fixture.server():
            fixture.initial_checks()
            if args.mcp_binary:
                fixture.mcp_checks(str(args.mcp_binary.resolve()))
        shutil.rmtree(fixture.store / "index")
        archive = None
        if args.provision_disposable_linux:
            # Relocate this disposable fixture's existing date subtree to simulate a sealed year.
            # IDs and complete file bytes remain unchanged; recovery does not depend on path dates.
            year = next((fixture.store / "items").iterdir())
            archive = fixture.store / "items" / "2000"
            year.rename(archive)
            hashes = {str(p.relative_to(archive)): hashlib.sha256(p.read_bytes()).hexdigest() for p in archive.rglob("*.tractanda")}
            subprocess.run(["mount", "--bind", str(archive), str(archive)], check=True)
            subprocess.run(["mount", "-o", "remount,bind,ro", str(archive)], check=True)
            try:
                (archive / "must-not-write").touch()
                raise AssertionError("Archive was not read-only")
            except OSError as error:
                assert error.errno == errno.EROFS, error
        try:
            with fixture.server():
                fixture.recovery_checks()
            if archive:
                after = {str(p.relative_to(archive)): hashlib.sha256(p.read_bytes()).hexdigest() for p in archive.rglob("*.tractanda")}
                assert hashes == after
                fixture.checks.append("physically read-only archive, unchanged file hashes, new permission revisions in current date tree")
                fixture.kernel_acl_checks()
        finally:
            if archive:
                subprocess.run(["umount", str(archive)], check=True)
        if args.provision_disposable_linux:
            fixture.transfer_checks()
        result = {"platform": platform.platform(), "python": platform.python_version(), "accounts": names,
            "uids": {key: pwd.getpwnam(name).pw_uid for key, name in names.items()},
            "checks": fixture.checks, "status": "passed", "readOnlyArchiveTested": bool(archive),
            "mcpTested": bool(args.mcp_binary)}
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
