#!/bin/sh
# Invoked by linux-test-entrypoint.sh after it has dropped privileges.
set -eu

results=${TRACTANDA_TEST_RESULTS:?linux test result directory is required}
case "$results" in /results/*) ;; *) echo "Result directory must be below /results." >&2; exit 2 ;; esac
[ "$(id -u)" -ne 0 ] || { echo "Linux checks must not run as root." >&2; exit 2; }
: "${TRACTANDA_UUID_NODE:?explicit host hardware node is required}"
python3 -c 'import os, re; value = os.environ["TRACTANDA_UUID_NODE"]; assert re.fullmatch(r"[0-9a-f]{2}(:[0-9a-f]{2}){5}", value, re.I) and not (int(value[:2], 16) & 3)' || {
  echo "TRACTANDA_UUID_NODE must be a globally administered unicast MAC." >&2; exit 2;
}
export TRACTANDA_UUID_NODE
export CLANG_MODULE_CACHE_PATH=/build/module-cache
mkdir -p "$results"

run() {
  name=$1
  shift
  if "$@" > "$results/$name" 2>&1; then
    printf 'passed %s\n' "$name" >> "$results/check-status.txt"
  else
    status=$?
    printf 'failed(%s) %s\n' "$status" "$name" >> "$results/check-status.txt"
    failed=1
  fi
}

id > "$results/test-identity.txt"
swift --version > "$results/swift-version.txt"
python3 --version > "$results/python-version.txt"
dpkg-query -W python3 libsqlite3-0 > "$results/package-versions.txt"
failed=0
run swift-tests.log swift test --jobs 4 --scratch-path /build --cache-path /build/cache --config-path /build/config --security-path /build/security --disable-sandbox
run client-tests.log swift test --jobs 4 --package-path Packages/TractandaClient --scratch-path /build/client --cache-path /build/cache --config-path /build/config --security-path /build/security --disable-sandbox
run ipc.json python3 scripts/verify-ipc.py /build/debug/tractanda --import-from "$results/mac" --export "$results/linux" --append-note
run mcp.json python3 scripts/verify-mcp.py /build/debug/tractanda /build/debug/tractanda-mcp
run shared-daemon.json python3 scripts/verify-shared-daemon.py /build/debug/tractanda /build/debug/tractanda-mcp /build/debug/tractanda-tui
run learning.json python3 scripts/verify-learning.py /build/debug/tractanda --import-from "$results/learning-mac" --export "$results/learning-linux"
run tui.json python3 scripts/verify-tui.py /build/debug/tractanda /build/debug/tractanda-tui
run uuid-v1.log python3 scripts/verify-uuid-v1.py /build/debug/tractanda --output "$results/uuid-v1.json"
run kanban.json python3 scripts/verify-kanban.py /build/debug/tractanda --import-from "$results/kanban-mac" --export "$results/kanban-linux"
run category-hierarchy.json python3 scripts/verify-category-hierarchy.py /build/debug/tractanda --tui /build/debug/tractanda-tui --import-from "$results/categories-mac" --export "$results/categories-linux" --append-revision

python3 -c '
import json, os, re, sys
from pathlib import Path
root = Path(sys.argv[1])
counts = {}
for name in ("swift-tests.log", "client-tests.log"):
    text = (root / name).read_text()
    xctest = [int(value) for value in re.findall(r"Test Suite '\''All tests'\'' (?:passed|failed).*?\n\s+Executed (\d+) tests", text, re.S)]
    testing = [int(value) for value in re.findall(r"Test run with (\d+) tests", text)]
    counts[name] = {"xctestAll": xctest, "xctestAllTotal": sum(xctest), "swiftTesting": testing, "swiftTestingTotal": sum(testing)}
status_lines = (root / "check-status.txt").read_text()
status = "failed" if "failed(" in status_lines else "passed"
summary = {"status": status, "uid": os.geteuid(), "uuidNode": os.environ["TRACTANDA_UUID_NODE"], "suiteTotals": counts, "checkStatus": status_lines.splitlines(), "checks": ["package", "client", "native IPC", "MCP", "shared daemon wire", "learning", "TUI", "UUID v1 host-node override", "Kanban round-trip", "category hierarchy round-trip"]}
(root / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=2))
' "$results"
exit "$failed"
