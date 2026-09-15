#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
exec "$base/bin/tractanda-setup" install --bundle "$base" "$@"
