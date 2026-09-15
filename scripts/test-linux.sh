#!/bin/sh
# Run the portable checks in Apple's container runtime. The guest sees only an
# audit-derived source snapshot plus disposable build/result directories.
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "${TRACTANDA_LINUX_EXPORT_ROOT+x}" = x ]; then
  export_root=$TRACTANDA_LINUX_EXPORT_ROOT
  mkdir -p "$export_root"
else
  export_root=$(mktemp -d "${TMPDIR:-/private/tmp}/tractanda-linux-XXXXXXXX")
fi
container_bin=${TRACTANDA_CONTAINER_BIN:-/usr/local/bin/container}
image_ref=tractanda-test:swift6.4-snapshot-20260908-bookworm
test_uid=${TRACTANDA_TEST_UID:-$(id -u)}
test_gid=${TRACTANDA_TEST_GID:-$(id -g)}
category_only=${TRACTANDA_LINUX_CATEGORY_ONLY:-0}

case "$test_uid:$test_gid" in
  *[!0-9:]* | :* | *:) echo "TRACTANDA_TEST_UID and TRACTANDA_TEST_GID must be numeric." >&2; exit 2 ;;
esac
[ "$test_uid" -ne 0 ] || { echo "Refusing to run Linux tests as host root." >&2; exit 2; }
[ -x "$container_bin" ] || { echo "Apple container runtime is unavailable: $container_bin" >&2; exit 2; }
[ -x "$project_dir/.build/debug/tractanda" ] || { echo "Build the host tractanda executable before exporting fixtures." >&2; exit 2; }

node=$("$project_dir/.build/debug/tractanda" uuid-node | python3 -c 'import json, re, sys; value = json.load(sys.stdin)["node"]; assert re.fullmatch(r"[0-9a-f]{2}(:[0-9a-f]{2}){5}", value, re.I) and not (int(value[:2], 16) & 3); print(value)') || {
  echo "Host uuid-node did not return a globally administered unicast MAC." >&2; exit 2;
}

mkdir -p "$export_root/build" "$export_root/results"
case_name="linux-final-$(date -u +%Y%m%dT%H%M%SZ)-$$"
case_dir="$export_root/results/$case_name"
mkdir "$case_dir"
audit="$case_dir/release-audit.json"
"$project_dir/scripts/audit-release.py" --output "$audit"

# Every attempt receives a fresh, manifest-derived source mount.  A caller may
# reuse only the surrounding export root (in particular its /build cache).
source_dir=$(mktemp -d "$export_root/source-$case_name-XXXXXXXX")
python3 -c '
import hashlib, json, shutil, sys
from pathlib import Path
root, audit, destination = map(Path, sys.argv[1:])
manifest = json.loads(audit.read_text())
if manifest["status"] != "passed": raise SystemExit("release audit did not pass")
for entry in manifest["manifest"]:
    rel = Path(entry["path"])
    if rel.is_absolute() or ".." in rel.parts: raise SystemExit(f"unsafe manifest path: {rel}")
    origin, target = root / rel, destination / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(origin, target)
    data = target.read_bytes()
    if len(data) != entry["bytes"] or hashlib.sha256(data).hexdigest() != entry["sha256"]:
        raise SystemExit(f"manifest mismatch: {rel}")
(destination / ".linux-release-manifest.json").write_text(json.dumps(manifest["manifest"], indent=2) + "\n")
' "$project_dir" "$audit" "$source_dir"

# Canonical-only disposable fixture exports; no live store is transferred.
"$project_dir/.build/debug/tractanda" uuid-node > "$case_dir/host-uuid-node.json"
if [ "$category_only" = 1 ]; then
  python3 "$project_dir/scripts/verify-category-hierarchy.py" "$project_dir/.build/debug/tractanda" --export "$case_dir/categories-mac" > "$case_dir/category-mac.log"
elif [ "$category_only" = 0 ]; then
  python3 "$project_dir/scripts/verify-ipc.py" "$project_dir/.build/debug/tractanda" --export "$case_dir/mac"
  python3 "$project_dir/scripts/verify-kanban.py" "$project_dir/.build/debug/tractanda" --export "$case_dir/kanban-mac"
  python3 "$project_dir/scripts/verify-learning.py" "$project_dir/.build/debug/tractanda" --export "$case_dir/learning-mac"
  python3 "$project_dir/scripts/verify-category-hierarchy.py" "$project_dir/.build/debug/tractanda" --export "$case_dir/categories-mac"
else
  echo "TRACTANDA_LINUX_CATEGORY_ONLY must be 0 or 1." >&2; exit 2
fi

if ! "$container_bin" image inspect "$image_ref" > "$case_dir/image.json"; then
  "$container_bin" build --file "$project_dir/containers/test/Containerfile" --tag "$image_ref" "$project_dir/containers/test"
  "$container_bin" image inspect "$image_ref" > "$case_dir/image.json"
fi
container_status=0
run_guest() {
  "$container_bin" run --rm --name "tractanda-test-$case_name" --cpus 4 --memory 4G \
    --mount "type=bind,source=$source_dir,target=/workspace,readonly" \
    --mount "type=bind,source=$export_root/build,target=/build" \
    --mount "type=bind,source=$export_root/results,target=/results" \
    --env "TRACTANDA_TEST_UID=$test_uid" --env "TRACTANDA_TEST_GID=$test_gid" \
    --env "TRACTANDA_UUID_NODE=$node" --env "TRACTANDA_TEST_RESULTS=/results/$case_name" \
    --workdir /workspace "$image_ref" "$@" > "$case_dir/container.log" 2>&1
}
if [ "$category_only" = 1 ]; then
  guest_command='set -eu
test_user=tractanda_test
test_home=/tmp/tractanda-test-home
if getent group "$TRACTANDA_TEST_GID" >/dev/null; then test_group=$(getent group "$TRACTANDA_TEST_GID" | cut -d: -f1); else test_group=$test_user; groupadd -g "$TRACTANDA_TEST_GID" "$test_group"; fi
if getent passwd "$TRACTANDA_TEST_UID" >/dev/null; then actual_user=$(getent passwd "$TRACTANDA_TEST_UID" | cut -d: -f1); [ "$actual_user" = "$test_user" ] || exit 2; else useradd -u "$TRACTANDA_TEST_UID" -g "$test_group" -m -d "$test_home" -s /bin/sh "$test_user"; fi
install -d -o "$TRACTANDA_TEST_UID" -g "$TRACTANDA_TEST_GID" "$test_home"
exec runuser -u "$test_user" -- env HOME="$test_home" TRACTANDA_UUID_NODE="$TRACTANDA_UUID_NODE" /bin/sh -c "cd /workspace && python3 scripts/verify-category-hierarchy.py /build/debug/tractanda --tui /build/debug/tractanda-tui --import-from \"$TRACTANDA_TEST_RESULTS/categories-mac\" --export \"$TRACTANDA_TEST_RESULTS/categories-linux\" --append-revision"'
  run_guest /bin/sh -c "$guest_command" || container_status=$?
else
  run_guest /bin/sh scripts/linux-test-entrypoint.sh || container_status=$?
fi

# Preserve the existing cross-platform canonical round-trip coverage.
if [ "$category_only" = 1 ]; then
  if [ -f "$case_dir/categories-linux/snapshot.json" ]; then
    python3 "$project_dir/scripts/verify-category-hierarchy.py" "$project_dir/.build/debug/tractanda" --import-from "$case_dir/categories-linux" --export "$case_dir/categories-returned-to-mac" > "$case_dir/category-returned-to-mac.log"
  else
    printf 'Category hierarchy round-trip was not exported by the guest; see container.log.\n' >&2
    container_status=1
  fi
else
  python3 "$project_dir/scripts/verify-ipc.py" "$project_dir/.build/debug/tractanda" --import-from "$case_dir/linux" --export "$case_dir/returned-to-mac"
  python3 "$project_dir/scripts/verify-kanban.py" "$project_dir/.build/debug/tractanda" --import-from "$case_dir/kanban-linux" --export "$case_dir/kanban-returned-to-mac"
  python3 "$project_dir/scripts/verify-learning.py" "$project_dir/.build/debug/tractanda" --import-from "$case_dir/learning-linux" --export "$case_dir/learning-returned-to-mac"
  if [ -f "$case_dir/categories-linux/snapshot.json" ]; then
    python3 "$project_dir/scripts/verify-category-hierarchy.py" "$project_dir/.build/debug/tractanda" --import-from "$case_dir/categories-linux" --export "$case_dir/categories-returned-to-mac"
  else
    printf 'Category hierarchy round-trip was not exported by the guest; see category-hierarchy.json.\n' >&2
    container_status=1
  fi
fi

printf 'Linux package/native/MCP/shared-daemon and round-trip evidence: %s\n' "$case_dir"
exit "$container_status"
