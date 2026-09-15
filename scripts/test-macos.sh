#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/module-cache"
sh scripts/check-style.sh
swift test --scratch-path .build --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
swift test --package-path Packages/TractandaClient --scratch-path .build/client-tests --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
python3 scripts/verify-ipc.py .build/debug/tractanda
python3 scripts/verify-kanban.py .build/debug/tractanda
python3 scripts/verify-learning.py .build/debug/tractanda
python3 scripts/verify-mcp.py .build/debug/tractanda .build/debug/tractanda-mcp
python3 scripts/verify-tui.py .build/debug/tractanda .build/debug/tractanda-tui
python3 scripts/verify-tui-views.py .build/debug/tractanda .build/debug/tractanda-tui
python3 scripts/verify-tui-breadcrumbs.py .build/debug/tractanda .build/debug/tractanda-tui
python3 scripts/verify-tui-mouse.py .build/debug/tractanda .build/debug/tractanda-tui
python3 scripts/verify-tui-learning.py .build/debug/tractanda .build/debug/tractanda-tui
python3 scripts/verify-tui-menus.py .build/debug/tractanda .build/debug/tractanda-tui
python3 scripts/verify-tui-keymap.py .build/debug/tractanda .build/debug/tractanda-tui
python3 scripts/verify-tui-groups.py .build/debug/tractanda .build/debug/tractanda-tui
python3 scripts/verify-category-hierarchy.py .build/debug/tractanda --tui .build/debug/tractanda-tui
