#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
mkdir -p work/runtime
run_dir=$(mktemp -d "$project_dir/work/runtime/managed-macos-XXXXXXXX")
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/module-cache"
swift build --scratch-path .build --cache-path .build/cache --config-path .build/config \
  --security-path .build/security --disable-sandbox > "$run_dir/build.log" 2>&1
# Requires the calling account's GUI launchd domain; creates and removes only a uniquely named fixture job.
python3 scripts/verify-managed-service.py .build/debug/tractanda .build/debug/tractanda-tui \
  .build/debug/tractanda-mcp --output "$run_dir/managed.json" > "$run_dir/managed.log" 2>&1
printf 'Managed macOS evidence: %s\n' "$run_dir"
