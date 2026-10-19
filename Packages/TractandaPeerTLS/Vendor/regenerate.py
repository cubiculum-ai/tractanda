#!/usr/bin/env python3
"""Regenerate from exact public Git objects, or verify tracked sources without network/builds."""
import argparse
import difflib
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
REVISION = "15e0b9e495786807272dd4891fa4bac76aa43034"
BORING = "8eb25be6fa18d475291122887a7bccd3762ff236"
TREES = ("Sources/CNIOBoringSSL/", "Sources/CNIOBoringSSLShims/", "Sources/NIOSSL/")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream-checkout", type=Path)
    args = parser.parse_args()
    manifest_path = ROOT / "Vendor/manifest.json"
    if args.upstream_checkout is None:
        manifest = json.loads(manifest_path.read_text())
        assert manifest["revision"] == REVISION and manifest["boringSSLRevision"] == BORING
        for name, item in manifest["files"].items():
            if digest((ROOT / name).read_bytes()) != item["vendoredSHA256"]:
                raise RuntimeError("vendored source differs: " + name)
        for tree in TREES:
            actual = {str(p.relative_to(ROOT)) for p in (ROOT / tree).rglob("*") if p.is_file()}
            expected = {name for name in manifest["files"] if name.startswith(tree)}
            if actual != expected:
                raise RuntimeError("vendor tree inventory differs: " + tree)
        if digest((ROOT / "Vendor/niossl-psk.patch").read_bytes()) != manifest["patchSHA256"]:
            raise RuntimeError("vendor patch differs")
        print(json.dumps({"status": "verified", "revision": REVISION, "files": len(manifest["files"])}))
        return
    source = args.upstream_checkout.resolve()
    def git(*arguments):
        return subprocess.check_output(["git", "-C", str(source), *arguments])
    if git("rev-parse", REVISION + "^{commit}").decode().strip() != REVISION:
        raise RuntimeError("upstream revision unavailable")
    spec = importlib.util.spec_from_file_location("vendor_patch", ROOT / "Vendor/patches.py")
    patches = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(patches)
    names = git("ls-tree", "-r", "--name-only", REVISION).decode().splitlines()
    selected = [name for name in names if name.startswith(TREES) or name in ("LICENSE.txt", "NOTICE.txt")]
    records = {}
    differences = []
    for name in selected:
        original = git("show", REVISION + ":" + name)
        result = patches.patch(name, original)
        output = ROOT / name
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(result)
        records[name] = {"upstreamSHA256": digest(original), "vendoredSHA256": digest(result)}
        if result != original:
            differences.extend(difflib.unified_diff(original.decode().splitlines(True), result.decode().splitlines(True),
                                                   fromfile="a/" + name, tofile="b/" + name))
    if BORING not in (ROOT / "Sources/CNIOBoringSSL/hash.txt").read_text():
        raise RuntimeError("bundled BoringSSL pin differs")
    patch = "".join(differences).encode()
    (ROOT / "Vendor/niossl-psk.patch").write_bytes(patch)
    manifest = {"profile": "tractanda.peer-tls-vendor.v1", "repository": "https://github.com/apple/swift-nio-ssl.git",
                "revision": REVISION, "boringSSLRevision": BORING, "patchSHA256": digest(patch), "files": records}
    manifest_path.write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
    print(json.dumps({"status": "regenerated", "revision": REVISION, "files": len(records)}))


if __name__ == "__main__":
    main()
