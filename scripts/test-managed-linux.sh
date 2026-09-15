#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
mkdir -p work/runtime work/linux-build
run_dir=$(mktemp -d "$project_dir/work/runtime/managed-linux-XXXXXXXX")
image_ref=tractanda-service-test:swift6.4-snapshot-20260908-bookworm
container_name="tractanda-$(basename "$run_dir")"
container build --file containers/service-test/Containerfile --tag "$image_ref" containers/service-test \
  > "$run_dir/image-build.log" 2>&1
container image inspect "$image_ref" > "$run_dir/image.json"
container run --rm --name "$container_name-build" --cpus 4 --memory 4G \
  --uid "$(id -u)" --gid "$(id -g)" \
  --mount "type=bind,source=$project_dir,target=/workspace,readonly" \
  --mount "type=bind,source=$project_dir/work/linux-build,target=/build" \
  --workdir /workspace "$image_ref" /usr/bin/env CLANG_MODULE_CACHE_PATH=/build/module-cache \
  swift test --scratch-path /build --cache-path /build/cache --config-path /build/config \
  --security-path /build/security --disable-sandbox > "$run_dir/swift-test.log" 2>&1
cleanup() {
  container stop "$container_name" > /dev/null 2>&1 || true
  container delete "$container_name" > /dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# PID 1 and the user manager are real systemd. Root/CAP_SYS_ADMIN remain confined to this test VM.
# Neither source nor build artifacts are writable from this service fixture.
container run --detach --name "$container_name" --cpus 4 --memory 4G \
  --cap-add CAP_SYS_ADMIN --env container=other \
  --mount "type=bind,source=$project_dir,target=/workspace,readonly" \
  --mount "type=bind,source=$project_dir/work/linux-build,target=/build,readonly" \
  --mount "type=bind,source=$run_dir,target=/results" \
  "$image_ref" /bin/sh -c 'set -e; useradd --create-home --uid 1201 tractest; exec /lib/systemd/systemd --system --unit=multi-user.target --log-target=console' \
  > "$run_dir/container.log"
container exec "$container_name" /bin/sh -c '
  set -e
  attempt=0
  until loginctl enable-linger tractest; do
    attempt=$((attempt + 1))
    test "$attempt" -lt 20
    sleep 1
  done
  systemctl start user@1201.service
  systemctl show user@1201.service --property=ActiveState,SubState
' > "$run_dir/systemd.log" 2>&1
container exec "$container_name" /bin/sh -c '
  runuser -u tractest -- env XDG_RUNTIME_DIR=/run/user/1201 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1201/bus \
    python3 /workspace/scripts/verify-managed-service.py /build/debug/tractanda /build/debug/tractanda-tui \
    /build/debug/tractanda-mcp --output /tmp/managed.json
  result=$?
  if test -f /tmp/managed.json; then cp /tmp/managed.json /results/managed.json; fi
  exit "$result"
' > "$run_dir/managed.log" 2>&1
printf 'Managed Debian evidence: %s\n' "$run_dir"
