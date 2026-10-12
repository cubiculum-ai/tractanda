#!/usr/bin/env python3
"""Reproducible native Docling build with a guarded pinned-runtime patch."""

import argparse
import importlib.util
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--package", type=Path, default=ROOT / "Packages/TractandaDocuments")
    for name in ("scratch", "cache", "config", "security"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    paths = {
        name: getattr(args, name).resolve()
        for name in ("package", "scratch", "cache", "config", "security")
    }
    common = ["--disable-sandbox"]
    for name, path in paths.items():
        common.extend([f"--{name}-path", str(path)])

    checkout = paths["scratch"] / "checkouts/vmlx-swift"
    if not checkout.exists():
        subprocess.run(["swift", "package", *common, "resolve"], check=True)

    module_path = paths["package"] / "RuntimePatches/apply.py"
    spec = importlib.util.spec_from_file_location("docling_runtime_patch", module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    print(json.dumps(module.apply(checkout), sort_keys=True), flush=True)
    subprocess.run(
        [
            "swift", "build", *common, "--disable-automatic-resolution",
            "-c", "release", "-debug-info-format", "none",
            "--jobs", str(args.jobs), "--product", "tractanda-document-converter",
        ],
        check=True,
    )


if __name__ == "__main__":
    main()
