#!/bin/sh
set -eu

# Deliberately refuses a host run. The caller must run this as root in a fresh disposable Linux container.
if [ "${TRACTANDA_PAM_BROKER_CONTAINER_TEST:-}" != 1 ] || [ "$(id -u)" != 0 ]; then
    echo "set TRACTANDA_PAM_BROKER_CONTAINER_TEST=1 and run as root in a disposable Linux container" >&2
    exit 77
fi
case "$(uname -s)" in Linux) ;; *) echo "Linux only" >&2; exit 69 ;; esac

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime=$(mktemp -d /run/tractanda-auth-broker.XXXXXX)
chmod 0711 "$runtime"
service=tractanda_broker_service
target=tractanda_broker_target
password=tractanda-broker-synthetic-only
helper_pid=
fake_dir="$runtime/fake"

cleanup() {
    [ -z "$helper_pid" ] || kill "$helper_pid" 2>/dev/null || true
    [ -z "$helper_pid" ] || wait "$helper_pid" 2>/dev/null || true
    userdel "$target" 2>/dev/null || true
    userdel "$service" 2>/dev/null || true
    rmdir "$fake_dir" 2>/dev/null || true
    rmdir "$runtime" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

useradd --no-create-home --shell /usr/sbin/nologin "$service"
useradd --no-create-home --shell /usr/sbin/nologin "$target"
printf '%s:%s\n%s:%s\n' "$service" "$password" "$target" "$password" | chpasswd

cd "$root"
cc -std=c17 -Wall -Wextra -Werror -I Sources/CTractandaPlatform/include \
    Sources/TractandaAuthHelper/main.c Sources/CTractandaPlatform/Platform.c \
    -lpam -luuid -lpthread -o "$runtime/tractanda-auth-helper"
cc -std=c17 -Wall -Wextra -Werror -I Sources/CTractandaPlatform/include \
    Tests/Fixtures/PAMBrokerClientFixture.c Sources/CTractandaPlatform/Platform.c \
    -lpam -luuid -lpthread -o "$runtime/client"
echo "PAM broker fixture: compiled helper and client"
socket="$runtime/auth.sock"
"$runtime/tractanda-auth-helper" --socket "$socket" --allowed-user "$service" &
helper_pid=$!
for attempt in $(seq 1 50); do [ -S "$socket" ] && break; sleep 0.1; done
[ -S "$socket" ]
[ "$(stat -c '%a:%U' "$socket")" = "600:$service" ]
echo "PAM broker fixture: private socket ownership verified"
target_uid=$(id -u "$target")

printf '%s\n' "$password" | runuser -u "$service" -- "$runtime/client" "$socket" "$target" "$target_uid" 1
echo "PAM broker fixture: other-user password accepted"
printf '%s\n' wrong-synthetic-password | runuser -u "$service" -- "$runtime/client" "$socket" "$target" "$target_uid" 0
echo "PAM broker fixture: wrong password denied"

if runuser -u "$target" -- python3 - "$socket" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX)
try:
    s.connect(sys.argv[1])
except PermissionError:
    raise SystemExit(1)
raise SystemExit(0)
PY
then
    echo "unauthorized peer unexpectedly connected" >&2
    exit 1
fi
echo "PAM broker fixture: unauthorized peer denied"

runuser -u "$service" -- python3 - "$socket" <<'PY'
import socket, struct, sys
path = sys.argv[1]
for payload in (struct.pack('!I', 4227), struct.pack('!I', 3) + b'x\0\0'):
    s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(path); s.sendall(payload)
    reply = s.recv(8); s.close()
    assert len(reply) == 8 and struct.unpack('!II', reply)[0] != 1
s = socket.socket(socket.AF_UNIX); s.settimeout(12); s.connect(path); s.sendall(struct.pack('!I', 3))
reply = s.recv(8)
assert reply == b'' or (len(reply) == 8 and struct.unpack('!II', reply)[0] != 1)
s.close()
PY
echo "PAM broker fixture: malformed and stalled frames denied"

mkdir "$fake_dir"
chown "$service" "$fake_dir"
chmod 0700 "$fake_dir"
fake="$fake_dir/fake.sock"
runuser -u "$service" -- python3 - "$fake" <<'PY' &
import os, socket, sys
path = sys.argv[1]
s = socket.socket(socket.AF_UNIX); s.bind(path); s.listen(1)
c, _ = s.accept(); c.close(); s.close()
PY
fake_pid=$!
for attempt in $(seq 1 50); do [ -S "$fake" ] && break; sleep 0.1; done
printf '%s\n' "$password" | runuser -u "$service" -- "$runtime/client" "$fake" "$target" "$target_uid" -1
wait "$fake_pid"
echo "PAM broker fixture: non-root fake broker denied"

chage -E 0 "$target"
printf '%s\n' "$password" | runuser -u "$service" -- "$runtime/client" "$socket" "$target" "$target_uid" 0
echo "PAM broker Linux fixture passed: valid, denied, expired, peer, framing, timeout, and root-peer checks"
