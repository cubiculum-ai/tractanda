#!/usr/bin/env python3
"""Apply only the exact known local patch to the pinned runtime checkout."""

import argparse
import hashlib
import json
import stat
import subprocess
from pathlib import Path


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def apply(checkout):
    checkout = Path(checkout).resolve()
    root = Path(__file__).resolve().parent
    manifest = json.loads((root / "manifest.json").read_text())
    revision = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=checkout, text=True
    ).strip()
    if revision != manifest["runtimeBaseRevision"]:
        raise RuntimeError("Unsupported runtime revision")

    receipts = []
    for entry in manifest["patches"]:
        patch = root / entry["file"]
        source = checkout / entry["sourcePath"]
        if digest(patch) != entry["sha256"]:
            raise RuntimeError("Runtime patch artifact changed")
        actual = digest(source)
        mode = stat.S_IMODE(source.stat().st_mode)
        if actual == entry["afterSHA256"]:
            receipts.append({
                "identifier": entry["identifier"], "status": "already-applied",
                "sourceSHA256": actual, "mode": oct(mode),
            })
            continue
        if actual != entry["beforeSHA256"]:
            raise RuntimeError("Foreign runtime source changes; refusing overwrite")
        subprocess.run(["git", "apply", "--check", str(patch)], cwd=checkout, check=True)
        try:
            source.chmod(mode | stat.S_IWUSR)
            subprocess.run(["git", "apply", str(patch)], cwd=checkout, check=True)
        finally:
            source.chmod(mode)
        if digest(source) != entry["afterSHA256"]:
            raise RuntimeError("Patched runtime source hash differs")
        receipts.append({
            "identifier": entry["identifier"], "status": "applied",
            "sourceSHA256": digest(source), "mode": oct(mode),
        })
    return {
        "runtimeBaseRevision": revision,
        "converterIdentity": manifest["converterIdentity"],
        "manifestSHA256": digest(root / "manifest.json"),
        "patches": receipts,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("checkout", type=Path)
    args = parser.parse_args()
    print(json.dumps(apply(args.checkout), indent=2))
