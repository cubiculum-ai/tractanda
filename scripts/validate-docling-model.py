#!/usr/bin/env python3
"""Validate an operator-prepared, pinned Docling model directory offline."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path
from typing import Any


REPOSITORY = Path(__file__).resolve().parents[1]
MANIFEST_PATH = REPOSITORY / "Packages/TractandaDocuments/Sources/TractandaDocumentConverter/Resources/ModelAssets.json"
PINNED_REVISION = "a8b999991fe8c521a0cec749973414eaaf823731"
PINNED_FILES = frozenset({
    "README.md", "config.json", "preprocessor_config.json", "processor_config.json",
    "chat_template.jinja", "generation_config.json", "tokenizer.json", "tokenizer_config.json",
    "special_tokens_map.json", "added_tokens.json", "merges.txt", "vocab.json",
    "model.safetensors.index.json", "model.safetensors",
})
CHUNK_SIZE = 1024 * 1024


class ValidationError(ValueError):
    """The source manifest or prepared model directory violates its contract."""


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValidationError(f"source manifest contains duplicate JSON member: {key}")
        result[key] = value
    return result


def _load_manifest_json(source: str) -> Any:
    return json.loads(source, object_pairs_hook=_unique_object)


def _parse_manifest(raw: Any) -> tuple[str, list[dict[str, Any]]]:
    if not isinstance(raw, dict) or set(raw) != {"revision", "files"}:
        raise ValidationError("manifest must contain exactly 'revision' and 'files'")
    revision = raw["revision"]
    if not isinstance(revision, str) or revision != PINNED_REVISION:
        raise ValidationError(f"manifest revision must be pinned revision {PINNED_REVISION}")
    entries = raw["files"]
    if not isinstance(entries, list) or len(entries) != len(PINNED_FILES):
        raise ValidationError(f"manifest must contain exactly {len(PINNED_FILES)} file entries")
    names: set[str] = set()
    normalized = []
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict) or set(entry) != {"file", "bytes", "sha256"}:
            raise ValidationError(f"manifest entry {index} must contain exactly 'file', 'bytes', and 'sha256'")
        name, length, digest = entry["file"], entry["bytes"], entry["sha256"]
        if not isinstance(name, str) or name in ("", ".", "..") or "/" in name or "\\" in name:
            raise ValidationError(f"manifest entry {index} has an unsafe file path")
        if name not in PINNED_FILES:
            raise ValidationError(f"manifest contains unexpected pinned path: {name}")
        if name in names:
            raise ValidationError(f"manifest contains duplicate path: {name}")
        if type(length) is not int or length < 0:
            raise ValidationError(f"manifest entry {name} has an invalid byte length")
        if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
            raise ValidationError(f"manifest entry {name} has an invalid SHA-256")
        names.add(name)
        normalized.append(entry)
    if names != PINNED_FILES:
        missing = sorted(PINNED_FILES - names)
        raise ValidationError(f"manifest pinned path set differs; missing: {', '.join(missing)}")
    return revision, normalized


def _identity(st: os.stat_result) -> tuple[int, int, int, int, int, int]:
    return st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns, st.st_mode


def validate_model_directory(directory: Path | str, *, manifest: Any | None = None) -> dict[str, Any]:
    """Return compact verification proof; ``manifest`` injection is for tests only."""
    if not all(hasattr(os, flag) for flag in ("O_NOFOLLOW", "O_DIRECTORY", "O_NONBLOCK")):
        raise ValidationError("platform lacks required safe-open flags")
    if manifest is None:
        try:
            manifest = _load_manifest_json(MANIFEST_PATH.read_text(encoding="utf-8"))
        except ValidationError:
            raise
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise ValidationError(f"cannot read pinned source manifest: {exc}") from exc
    revision, entries = _parse_manifest(manifest)

    root = Path(directory)
    try:
        root_stat = root.lstat()
    except OSError as exc:
        raise ValidationError(f"cannot inspect model directory: {exc}") from exc
    if not stat.S_ISDIR(root_stat.st_mode):
        raise ValidationError("model directory must be a real directory, not a symlink")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    try:
        root_fd = os.open(root, flags)
    except OSError as exc:
        raise ValidationError(f"cannot safely open model directory: {exc}") from exc

    try:
        try:
            opened_root = os.fstat(root_fd)
        except OSError as exc:
            raise ValidationError(f"cannot stat opened model directory: {exc}") from exc
        if not stat.S_ISDIR(opened_root.st_mode) or (opened_root.st_dev, opened_root.st_ino) != (root_stat.st_dev, root_stat.st_ino):
            raise ValidationError("model directory changed while opening")

        try:
            names = set(os.listdir(root_fd))
        except OSError as exc:
            raise ValidationError(f"cannot list model directory: {exc}") from exc
        extras = sorted(names - PINNED_FILES)
        missing = sorted(PINNED_FILES - names)
        if extras:
            raise ValidationError("unexpected directory entries will not be packaged: " + ", ".join(extras))
        if missing:
            raise ValidationError("missing pinned files: " + ", ".join(missing))

        results = []
        for entry in entries:
            name = entry["file"]
            try:
                fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=root_fd)
            except OSError as exc:
                raise ValidationError(f"cannot safely open {name}: {exc}") from exc
            try:
                try:
                    before = os.fstat(fd)
                except OSError as exc:
                    raise ValidationError(f"cannot stat opened {name}: {exc}") from exc
                if not stat.S_ISREG(before.st_mode):
                    raise ValidationError(f"{name} is not a regular file")
                if before.st_size != entry["bytes"]:
                    raise ValidationError(f"{name} length mismatch: expected {entry['bytes']}, found {before.st_size}")
                hasher = hashlib.sha256()
                read_size = 0
                try:
                    while True:
                        # Consume no more than the declared size plus one sentinel byte.
                        request_size = min(CHUNK_SIZE, entry["bytes"] - read_size) if read_size < entry["bytes"] else 1
                        chunk = os.read(fd, request_size)
                        if not chunk:
                            break
                        if len(chunk) > entry["bytes"] - read_size:
                            raise ValidationError(f"{name} exceeds declared length while being read")
                        hasher.update(chunk)
                        read_size += len(chunk)
                    after = os.fstat(fd)
                except OSError as exc:
                    raise ValidationError(f"cannot read/stat {name}: {exc}") from exc
                if _identity(before) != _identity(after) or read_size != entry["bytes"]:
                    raise ValidationError(f"{name} changed while being read")
                actual_hash = hasher.hexdigest()
                if actual_hash != entry["sha256"]:
                    raise ValidationError(f"{name} SHA-256 mismatch")
                results.append({"file": name, "bytes": read_size, "sha256": actual_hash, "status": "verified"})
            finally:
                os.close(fd)
        return {"revision": revision, "files": results, "fileCount": len(results), "totalBytes": sum(x["bytes"] for x in results), "status": "verified"}
    finally:
        os.close(root_fd)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model_directory", type=Path, help="operator-prepared model snapshot directory")
    args = parser.parse_args(argv)
    try:
        proof = validate_model_directory(args.model_directory)
    except ValidationError as exc:
        print(json.dumps({"status": "error", "error": str(exc)}, separators=(",", ":")), file=sys.stderr)
        return 2
    print(json.dumps(proof, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
