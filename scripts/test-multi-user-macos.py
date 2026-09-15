#!/usr/bin/env python3
"""Run macOS ACL/MCP tests under five existing OS identities without changing accounts.

The default principals are existing non-login system users used only as identities
for disposable test processes. --accounts accepts a service/alice/bob/agent/outsider
mapping instead. A dry run prints the exact plan; --execute requires sudo in Terminal.
No users, groups, home directories or account settings are created or changed.
"""
import argparse
import grp
import hashlib
import json
import os
from pathlib import Path
import platform
import pwd
import shutil
import subprocess
import tempfile

DEFAULT_ACCOUNTS = {"service": "_www", "alice": "daemon", "bob": "_sshd",
                    "agent": "_spotlight", "outsider": "_mdnsresponder"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--mcp-binary", type=Path)
    parser.add_argument("--accounts", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--execute", action="store_true")
    options = parser.parse_args()
    assert platform.system() == "Darwin", "This runner is macOS-only"
    names = json.loads(options.accounts.read_text()) if options.accounts else DEFAULT_ACCOUNTS
    assert set(names) == set(DEFAULT_ACCOUNTS) and len(set(names.values())) == 5
    accounts = {role: pwd.getpwnam(name) for role, name in names.items()}
    assert len({entry.pw_uid for entry in accounts.values()}) == 5
    assert all(entry.pw_uid > 0 for entry in accounts.values()), "Root is not a test principal"
    for entry in accounts.values():
        grp.getgrgid(entry.pw_gid)
    sources = {"tractanda": options.binary.resolve(strict=True)}
    for name in ["verify-multi-user.py", "verify-ipc.py"]:
        sources[name] = Path(__file__).with_name(name).resolve()
    if options.mcp_binary:
        sources["tractanda-mcp"] = options.mcp_binary.resolve(strict=True)
        sources["verify-mcp.py"] = Path(__file__).with_name("verify-mcp.py").resolve()
    output = options.output.resolve()
    plan = {"platform": "macOS", "accounts": names,
            "uids": {role: entry.pw_uid for role, entry in accounts.items()},
            "modifiesOSAccounts": False,
            "store": "Disposable temporary store. No project data, account settings or home directories are modified.",
            "inputs": {name: {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                       for name, path in sources.items()}, "output": str(output)}
    if not options.execute:
        print(json.dumps(plan, indent=2))
        return
    assert os.geteuid() == 0, "Use sudo in Terminal to launch the distinct-UID test processes"
    assert not output.exists(), "Use a new output file for each run"
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="trac-acl-run-", dir="/private/tmp") as directory:
        staging = Path(directory)
        os.chmod(staging, 0o755)
        for name, source in sources.items():
            target = staging / name
            shutil.copyfile(source, target)
            os.chmod(target, 0o755 if name in ["tractanda", "tractanda-mcp"] else 0o644)
            assert hashlib.sha256(target.read_bytes()).hexdigest() == plan["inputs"][name]["sha256"]
        account_file = staging / "accounts.json"
        account_file.write_text(json.dumps(names))
        os.chmod(account_file, 0o644)
        command = ["/usr/bin/python3", "-I", str(staging / "verify-multi-user.py"), str(staging / "tractanda"),
                   "--accounts", str(account_file), "--output", str(output)]
        if options.mcp_binary:
            command += ["--mcp-binary", str(staging / "tractanda-mcp")]
        with output.with_suffix(".log").open("w") as log:
            result = subprocess.run(command, stdout=log, stderr=log, cwd=staging,
                env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": "/private/tmp", "LANG": "en_US.UTF-8"},
                umask=0o022)
        if result.returncode:
            output.write_text(json.dumps({"status": "failed", "plan": plan, "log": str(output.with_suffix(".log"))}, indent=2)+"\n")
            raise RuntimeError("macOS account fixture failed; see its log")
    result = json.loads(output.read_text())
    result.update(accountProvisioning="none-existing-os-identities", inputs=plan["inputs"])
    output.write_text(json.dumps(result, indent=2)+"\n")
    print(json.dumps({"status": result["status"], "checks": len(result["checks"]), "output": str(output)}, indent=2))


if __name__ == "__main__":
    main()
