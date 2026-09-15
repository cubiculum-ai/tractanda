#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
mkdir -p work/runtime work/linux-build
run_dir=$(mktemp -d "$project_dir/work/runtime/browser-login-linux-XXXXXXXX")
image_ref=tractanda-test:swift6.4-snapshot-20260908-bookworm
container build --file containers/test/Containerfile --tag "$image_ref" containers/test
container image inspect "$image_ref" > "$run_dir/image.json"
container run --rm --name "tractanda-build-$(basename "$run_dir")" --cpus 4 --memory 4G \
  --uid "$(id -u)" --gid "$(id -g)" \
  --mount "type=bind,source=$project_dir,target=/workspace,readonly" \
  --mount "type=bind,source=$project_dir/work/linux-build,target=/build" \
  --workdir /workspace "$image_ref" /usr/bin/env CLANG_MODULE_CACHE_PATH=/build/module-cache \
  swift test --scratch-path /build --cache-path /build/cache --config-path /build/config \
  --security-path /build/security --disable-sandbox > "$run_dir/swift-test.log" 2>&1
container run --rm --name "tractanda-login-$(basename "$run_dir")" --cpus 4 --memory 4G \
  --env TRACTANDA_DISPOSABLE_CONTAINER=1 \
  --mount "type=bind,source=$project_dir,target=/workspace,readonly" \
  --mount "type=bind,source=$project_dir/work/linux-build,target=/build,readonly" \
  --mount "type=bind,source=$run_dir,target=/results" \
  --workdir /workspace "$image_ref" python3 scripts/verify-browser-login.py /build/debug/tractanda \
  --output /results/browser-login.json
printf 'Browser login Linux evidence: %s\n' "$run_dir"
