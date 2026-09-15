#!/bin/sh
# The only root code in the disposable guest: create a same-UID/GID test
# identity, then delegate every build and verifier operation to that identity.
set -eu

: "${TRACTANDA_TEST_UID:?host UID is required}"
: "${TRACTANDA_TEST_GID:?host GID is required}"
: "${TRACTANDA_UUID_NODE:?explicit host hardware node is required}"
: "${TRACTANDA_TEST_RESULTS:?result directory is required}"
case "$TRACTANDA_TEST_UID:$TRACTANDA_TEST_GID" in
  *[!0-9:]* | :* | *:) echo "Test UID/GID must be numeric." >&2; exit 2 ;;
esac
[ "$(id -u)" -eq 0 ] || { echo "Guest entrypoint must start as root." >&2; exit 2; }

test_user=tractanda_test
test_home=/tmp/tractanda-test-home
if getent group "$TRACTANDA_TEST_GID" >/dev/null; then
  test_group=$(getent group "$TRACTANDA_TEST_GID" | cut -d: -f1)
else
  test_group=$test_user
  groupadd -g "$TRACTANDA_TEST_GID" "$test_group"
fi
if getent passwd "$TRACTANDA_TEST_UID" >/dev/null; then
  actual_user=$(getent passwd "$TRACTANDA_TEST_UID" | cut -d: -f1)
  [ "$actual_user" = "$test_user" ] || { echo "Guest UID already belongs to $actual_user." >&2; exit 2; }
else
  useradd -u "$TRACTANDA_TEST_UID" -g "$test_group" -m -d "$test_home" -s /bin/sh "$test_user"
fi
install -d -o "$TRACTANDA_TEST_UID" -g "$TRACTANDA_TEST_GID" "$test_home"
exec runuser -u "$test_user" -- env HOME="$test_home" \
  TRACTANDA_UUID_NODE="$TRACTANDA_UUID_NODE" TRACTANDA_TEST_RESULTS="$TRACTANDA_TEST_RESULTS" \
  /bin/sh /workspace/scripts/linux-check.sh
