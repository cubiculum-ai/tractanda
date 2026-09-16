#!/bin/sh
# Portable core/client verification. Real-account/service-manager tests are separate.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/module-cache"
mkdir -p work/verification
sh scripts/check-style.sh
python3 scripts/test-release-pipeline.py
python3 scripts/test-notarize-macos.py
python3 scripts/test-release-status.py
run_tests() (
    log=$1; scratch=$2; shift 2
    result=0
    swift test --scratch-path "$scratch" --cache-path .build/cache --config-path .build/config \
        --security-path .build/security --disable-sandbox "$@" > "$log" 2>&1 || result=$?
    cat "$log"
    python3 - "$log" <<'PY'
import re,sys
from pathlib import Path
text=Path(sys.argv[1]).read_text()
if re.search(r"Test (?:Suite|Case) [^\n]*failed|\berror:|No tests found",text):
    raise SystemExit('Test output contains a failure.')
if not re.search(r'Executed [1-9][0-9]* tests|Test run with [1-9][0-9]* tests',text):
    raise SystemExit('No completed nonempty test run was recorded.')
PY
    test "$result" -eq 0
)
run_tests work/verification/swift-tests.log .build
run_tests work/verification/client-tests.log .build/client-tests --package-path Packages/TractandaClient
binary_dir=$(swift build --show-bin-path --scratch-path .build --cache-path .build/cache \
    --config-path .build/config --security-path .build/security --disable-sandbox)
python3 scripts/verify-ipc.py "$binary_dir/tractanda"
python3 scripts/verify-samples.py "$binary_dir/tractanda"
python3 scripts/verify-agent-access-plan.py --binary "$binary_dir/tractanda" \
    --report work/verification/agent-access-plan.json
python3 scripts/verify-kanban.py "$binary_dir/tractanda"
python3 scripts/verify-learning.py "$binary_dir/tractanda"
python3 scripts/verify-mcp.py "$binary_dir/tractanda" "$binary_dir/tractanda-mcp"
python3 scripts/verify-shared-daemon.py "$binary_dir/tractanda" "$binary_dir/tractanda-mcp" "$binary_dir/tractanda-tui"
python3 scripts/verify-tui.py "$binary_dir/tractanda" "$binary_dir/tractanda-tui"
