#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
mkdir -p work/portable-lsm/linux work/linux-build
container image inspect tractanda-test:swift6.4-snapshot-20260908-bookworm > work/portable-lsm/linux/image.json
container run --rm --name "tractanda-learning-$(date +%s)" --cpus 4 --memory 4G \
  --uid "$(id -u)" --gid "$(id -g)" \
  --mount "type=bind,source=$project_dir,target=/workspace,readonly" \
  --mount "type=bind,source=$project_dir/work/linux-build,target=/build" \
  --mount "type=bind,source=$project_dir/work/portable-lsm/linux,target=/results" \
  --workdir /workspace tractanda-test:swift6.4-snapshot-20260908-bookworm /bin/sh scripts/learning-linux-check.sh
