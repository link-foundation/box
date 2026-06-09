#!/usr/bin/env bash
# Isolated unit test for the issue #94 preload hook in dind-entrypoint.sh.
#
# Building the full box-dind image requires overlay-backed nested Docker; this
# sandbox only has the vfs storage driver, which exhausts disk. So instead we
# extract the preload functions from the real entrypoint and drive them with a
# mock `docker` that records every call, asserting the load/pull/skip behavior.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="$SCRIPT_DIR/../ubuntu/24.04/dind/dind-entrypoint.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- Extract just the preload functions (lines 198..259) from the entrypoint ---
FUNCS="$WORK/funcs.sh"
sed -n '198,259p' "$ENTRYPOINT" > "$FUNCS"

# --- Mock docker on PATH; records calls and simulates state ---
mkdir -p "$WORK/bin"
cat > "$WORK/bin/docker" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >> "$DOCKER_CALLS"
case "$1" in
  info) [ "${DOCKER_INFO_OK:-1}" = "1" ] && exit 0 || exit 1 ;;
  image)
    # image inspect <ref>
    ref="$3"
    grep -qxF "$ref" "$DOCKER_PRESENT" 2>/dev/null && exit 0 || exit 1 ;;
  load)
    # docker load -i <file> -> mark a sentinel image present
    echo "loaded:$3" >> "$DOCKER_LOADED"; exit 0 ;;
  pull)
    echo "$2" >> "$DOCKER_PULLED"; echo "$2" >> "$DOCKER_PRESENT"; exit 0 ;;
  *) exit 0 ;;
esac
MOCK
chmod +x "$WORK/bin/docker"
export PATH="$WORK/bin:$PATH"

export DOCKER_CALLS="$WORK/calls.log"
export DOCKER_LOADED="$WORK/loaded.log"
export DOCKER_PULLED="$WORK/pulled.log"
export DOCKER_PRESENT="$WORK/present.log"

log()  { echo "[test] $*"; }
warn() { echo "[test] WARN: $*" >&2; }

# shellcheck disable=SC1090
source "$FUNCS"

pass=0; fail=0
reset_state() { : > "$DOCKER_CALLS"; : > "$DOCKER_LOADED"; : > "$DOCKER_PULLED"; : > "$DOCKER_PRESENT"; }
check() { # check <description> <condition-cmd...>
  desc="$1"; shift
  if "$@"; then echo "  PASS: $desc"; pass=$((pass+1)); else echo "  FAIL: $desc"; fail=$((fail+1)); fi
}

echo "== Case 1: single tarball file is loaded =="
reset_state
touch "$WORK/image.tar"
DIND_PRELOAD_TARBALL="$WORK/image.tar" DIND_PRELOAD_IMAGES="" DOCKER_INFO_OK=1 preload_into_daemon
check "docker load called for the tarball" grep -q "load -i $WORK/image.tar" "$DOCKER_CALLS"

echo "== Case 2: directory loads every *.tar inside =="
reset_state
mkdir -p "$WORK/dir"
touch "$WORK/dir/a.tar" "$WORK/dir/b.tar" "$WORK/dir/ignore.txt"
DIND_PRELOAD_TARBALL="$WORK/dir" DIND_PRELOAD_IMAGES="" DOCKER_INFO_OK=1 preload_into_daemon
check "a.tar loaded" grep -q "load -i $WORK/dir/a.tar" "$DOCKER_CALLS"
check "b.tar loaded" grep -q "load -i $WORK/dir/b.tar" "$DOCKER_CALLS"
check "ignore.txt not loaded" bash -c '! grep -q "ignore.txt" "$DOCKER_CALLS"'

echo "== Case 3: DIND_PRELOAD_IMAGES pulls a missing image =="
reset_state
DIND_PRELOAD_TARBALL="" DIND_PRELOAD_IMAGES="alpine:3.20" DOCKER_INFO_OK=1 preload_into_daemon
check "missing image was pulled" grep -qx "alpine:3.20" "$DOCKER_PULLED"

echo "== Case 4: DIND_PRELOAD_IMAGES skips an already-present image =="
reset_state
echo "alpine:3.20" > "$DOCKER_PRESENT"
DIND_PRELOAD_TARBALL="" DIND_PRELOAD_IMAGES="alpine:3.20" DOCKER_INFO_OK=1 preload_into_daemon
check "present image was NOT pulled" bash -c '! test -s "$DOCKER_PULLED"'

echo "== Case 5: nothing happens when daemon is not ready =="
reset_state
touch "$WORK/image.tar"
DIND_PRELOAD_TARBALL="$WORK/image.tar" DIND_PRELOAD_IMAGES="alpine:3.20" DOCKER_INFO_OK=0 preload_into_daemon
check "no load attempted when daemon down" bash -c '! grep -q "load -i" "$DOCKER_CALLS"'
check "no pull attempted when daemon down" bash -c '! test -s "$DOCKER_PULLED"'

echo "== Case 6: no-op when neither var is set (no docker info probe) =="
reset_state
DIND_PRELOAD_TARBALL="" DIND_PRELOAD_IMAGES="" DOCKER_INFO_OK=1 preload_into_daemon
check "no docker calls at all" bash -c '! test -s "$DOCKER_CALLS"'

echo "== Case 7: missing tarball path warns, no load =="
reset_state
DIND_PRELOAD_TARBALL="$WORK/does-not-exist.tar" DIND_PRELOAD_IMAGES="" DOCKER_INFO_OK=1 preload_into_daemon 2>"$WORK/err.log"
check "no load for missing path" bash -c '! grep -q "load -i" "$DOCKER_CALLS"'
check "warning emitted for missing path" grep -q "does not exist" "$WORK/err.log"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
