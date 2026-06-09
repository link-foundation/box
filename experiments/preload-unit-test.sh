#!/usr/bin/env bash
# Isolated unit test for the issue #94 preload + host-passthrough hooks in
# dind-entrypoint.sh.
#
# Building the full box-dind image requires overlay-backed nested Docker; this
# sandbox only has the vfs storage driver, which exhausts disk. So instead we
# source the real entrypoint (via DIND_ENTRYPOINT_SOURCE_ONLY=1, which returns
# before the startup/handoff flow) to get its functions verbatim, and drive
# them with a mock `docker` that records every call and simulates both the
# inner daemon and a mounted host daemon (`docker -H unix://<sock> ...`).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="$SCRIPT_DIR/../ubuntu/24.04/dind/dind-entrypoint.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- Mock docker on PATH; records calls and simulates inner + host state ---
mkdir -p "$WORK/bin"
cat > "$WORK/bin/docker" <<'MOCK'
#!/usr/bin/env bash
# Host-daemon calls look like: docker -H unix://<sock> <subcommand> ...
host=0
if [ "${1:-}" = "-H" ]; then host=1; shift 2; fi
echo "${host}|$*" >> "$DOCKER_CALLS"
case "$1" in
  version) [ "$host" = "1" ] && { [ "${HOST_DOCKER_OK:-1}" = "1" ] && exit 0 || exit 1; }; exit 0 ;;
  info) [ "${DOCKER_INFO_OK:-1}" = "1" ] && exit 0 || exit 1 ;;
  image)
    # image inspect <ref> [--format ...]
    ref="$3"
    if [ "$host" = "1" ]; then
      # Emit the RepoDigests recorded for this host image, if any.
      grep "^${ref}|" "$HOST_DIGESTS" 2>/dev/null | head -n1 | cut -d'|' -f2-
      grep "^${ref}|" "$HOST_DIGESTS" >/dev/null 2>&1 && exit 0 || exit 0
    fi
    grep -qxF "$ref" "$DOCKER_PRESENT" 2>/dev/null && exit 0 || exit 1 ;;
  images)
    # host: list refs from the fixture file
    [ "$host" = "1" ] && cat "$HOST_IMAGES" 2>/dev/null
    exit 0 ;;
  load)
    cat >/dev/null 2>&1 || true   # drain the piped tar stream like real `docker load`
    echo "loaded" >> "$DOCKER_LOADED"; exit 0 ;;
  save)
    # `docker -H .. save <ref>` streams a tarball; mark it saved.
    echo "$2" >> "$DOCKER_SAVED"; echo "fake-tar-stream"; exit 0 ;;
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
export DOCKER_SAVED="$WORK/saved.log"
export HOST_IMAGES="$WORK/host-images.log"
export HOST_DIGESTS="$WORK/host-digests.log"

# --- Source the real entrypoint for its functions only ---
# shellcheck disable=SC1090
DIND_ENTRYPOINT_SOURCE_ONLY=1 . "$ENTRYPOINT"

pass=0; fail=0
reset_state() {
  : > "$DOCKER_CALLS"; : > "$DOCKER_LOADED"; : > "$DOCKER_PULLED"
  : > "$DOCKER_PRESENT"; : > "$DOCKER_SAVED"; : > "$HOST_IMAGES"; : > "$HOST_DIGESTS"
}
check() { # check <description> <condition-cmd...>
  desc="$1"; shift
  if "$@"; then echo "  PASS: $desc"; pass=$((pass+1)); else echo "  FAIL: $desc"; fail=$((fail+1)); fi
}

# Defaults the entrypoint expects (it ran `VAR="${VAR:-default}"` at source time,
# but we re-assert here so each case is explicit/hermetic).
HOST_SOCK="$WORK/host-docker.sock"

# Create a real AF_UNIX socket file so the entrypoint's `[ -S ... ]` guard
# passes. The mock `docker version` never actually connects, so binding and
# leaving the inode behind is enough.
make_sock() {
  rm -f "$1"
  python3 - "$1" <<'PY'
import socket, sys
socket.socket(socket.AF_UNIX).bind(sys.argv[1])
PY
}

echo "== Case 1: single tarball file is loaded =="
reset_state
touch "$WORK/image.tar"
DIND_HOST_PASSTHROUGH=off DIND_PRELOAD_TARBALL="$WORK/image.tar" DIND_PRELOAD_IMAGES="" \
  DOCKER_INFO_OK=1 preload_into_daemon
check "docker load called for the tarball" grep -q "load -i $WORK/image.tar" "$DOCKER_CALLS"

echo "== Case 2: directory loads every *.tar inside =="
reset_state
mkdir -p "$WORK/dir"
touch "$WORK/dir/a.tar" "$WORK/dir/b.tar" "$WORK/dir/ignore.txt"
DIND_HOST_PASSTHROUGH=off DIND_PRELOAD_TARBALL="$WORK/dir" DIND_PRELOAD_IMAGES="" \
  DOCKER_INFO_OK=1 preload_into_daemon
check "a.tar loaded" grep -q "load -i $WORK/dir/a.tar" "$DOCKER_CALLS"
check "b.tar loaded" grep -q "load -i $WORK/dir/b.tar" "$DOCKER_CALLS"
check "ignore.txt not loaded" bash -c '! grep -q "ignore.txt" "$DOCKER_CALLS"'

echo "== Case 3: DIND_PRELOAD_IMAGES pulls a missing image =="
reset_state
DIND_HOST_PASSTHROUGH=off DIND_PRELOAD_TARBALL="" DIND_PRELOAD_IMAGES="alpine:3.20" \
  DOCKER_INFO_OK=1 preload_into_daemon
check "missing image was pulled" grep -qx "alpine:3.20" "$DOCKER_PULLED"

echo "== Case 4: DIND_PRELOAD_IMAGES skips an already-present image =="
reset_state
echo "alpine:3.20" > "$DOCKER_PRESENT"
DIND_HOST_PASSTHROUGH=off DIND_PRELOAD_TARBALL="" DIND_PRELOAD_IMAGES="alpine:3.20" \
  DOCKER_INFO_OK=1 preload_into_daemon
check "present image was NOT pulled" bash -c '! test -s "$DOCKER_PULLED"'

echo "== Case 5: nothing happens when daemon is not ready =="
reset_state
touch "$WORK/image.tar"
DIND_HOST_PASSTHROUGH=off DIND_PRELOAD_TARBALL="$WORK/image.tar" DIND_PRELOAD_IMAGES="alpine:3.20" \
  DOCKER_INFO_OK=0 preload_into_daemon
check "no load attempted when daemon down" bash -c '! grep -q "load -i" "$DOCKER_CALLS"'
check "no pull attempted when daemon down" bash -c '! test -s "$DOCKER_PULLED"'

echo "== Case 6: no-op when nothing is configured and passthrough is off =="
reset_state
DIND_HOST_PASSTHROUGH=off DIND_PRELOAD_TARBALL="" DIND_PRELOAD_IMAGES="" \
  DOCKER_INFO_OK=1 preload_into_daemon
check "no docker calls at all" bash -c '! test -s "$DOCKER_CALLS"'

echo "== Case 7: missing tarball path warns, no load =="
reset_state
DIND_HOST_PASSTHROUGH=off DIND_PRELOAD_TARBALL="$WORK/does-not-exist.tar" DIND_PRELOAD_IMAGES="" \
  DOCKER_INFO_OK=1 preload_into_daemon 2>"$WORK/err.log"
check "no load for missing path" bash -c '! grep -q "load -i" "$DOCKER_CALLS"'
check "warning emitted for missing path" grep -q "does not exist" "$WORK/err.log"

echo "== Case 8: passthrough is a quiet no-op when no host socket is mounted =="
reset_state
DIND_HOST_PASSTHROUGH=public DIND_HOST_DOCKER_SOCK="$WORK/absent.sock" \
  DIND_PRELOAD_TARBALL="" DIND_PRELOAD_IMAGES="" DOCKER_INFO_OK=1 \
  preload_into_daemon 2>"$WORK/err.log"
check "no host save attempted without a socket" bash -c '! test -s "$DOCKER_SAVED"'
check "no warning emitted when socket simply absent" bash -c '! test -s "$WORK/err.log"'

echo "== Case 9: public mode copies a Docker Hub image, skips a local one =="
reset_state
# A hub image (has a docker.io RepoDigest) and a locally-built one (no digest):
printf '%s\n%s\n' "alpine:3.20" "myapp:latest" > "$HOST_IMAGES"
echo "alpine:3.20|alpine@sha256:deadbeef " > "$HOST_DIGESTS"   # myapp has no digest line
# host_docker_available requires [ -S sock ]; emulate by pointing at a real sock.
make_sock "$HOST_SOCK"
DIND_HOST_PASSTHROUGH=public DIND_HOST_DOCKER_SOCK="$HOST_SOCK" \
  DIND_PRELOAD_TARBALL="" DIND_PRELOAD_IMAGES="" DOCKER_INFO_OK=1 HOST_DOCKER_OK=1 \
  preload_into_daemon
check "public mode saved the hub image" grep -qx "alpine:3.20" "$DOCKER_SAVED"
check "public mode loaded the hub image" grep -q "load" "$DOCKER_CALLS"
check "public mode did NOT save the local image" bash -c '! grep -qx "myapp:latest" "$DOCKER_SAVED"'
rm -f "$HOST_SOCK"

echo "== Case 10: all mode copies every host image including local =="
reset_state
printf '%s\n%s\n' "alpine:3.20" "myapp:latest" > "$HOST_IMAGES"
echo "alpine:3.20|alpine@sha256:deadbeef " > "$HOST_DIGESTS"
make_sock "$HOST_SOCK"
DIND_HOST_PASSTHROUGH=all DIND_HOST_DOCKER_SOCK="$HOST_SOCK" \
  DIND_PRELOAD_TARBALL="" DIND_PRELOAD_IMAGES="" DOCKER_INFO_OK=1 HOST_DOCKER_OK=1 \
  preload_into_daemon
check "all mode saved the hub image" grep -qx "alpine:3.20" "$DOCKER_SAVED"
check "all mode saved the local image too" grep -qx "myapp:latest" "$DOCKER_SAVED"
rm -f "$HOST_SOCK"

echo "== Case 11: passthrough skips images already present in the inner daemon =="
reset_state
printf '%s\n' "alpine:3.20" > "$HOST_IMAGES"
echo "alpine:3.20|alpine@sha256:deadbeef " > "$HOST_DIGESTS"
echo "alpine:3.20" > "$DOCKER_PRESENT"   # already in the inner daemon
make_sock "$HOST_SOCK"
DIND_HOST_PASSTHROUGH=public DIND_HOST_DOCKER_SOCK="$HOST_SOCK" \
  DIND_PRELOAD_TARBALL="" DIND_PRELOAD_IMAGES="" DOCKER_INFO_OK=1 HOST_DOCKER_OK=1 \
  preload_into_daemon
check "present image was NOT re-saved from host" bash -c '! test -s "$DOCKER_SAVED"'
rm -f "$HOST_SOCK"

echo "== Case 12: off mode never touches the host even with a socket =="
reset_state
printf '%s\n' "alpine:3.20" > "$HOST_IMAGES"
echo "alpine:3.20|alpine@sha256:deadbeef " > "$HOST_DIGESTS"
make_sock "$HOST_SOCK"
DIND_HOST_PASSTHROUGH=off DIND_HOST_DOCKER_SOCK="$HOST_SOCK" \
  DIND_PRELOAD_TARBALL="" DIND_PRELOAD_IMAGES="" DOCKER_INFO_OK=1 HOST_DOCKER_OK=1 \
  preload_into_daemon
check "off mode made no docker calls" bash -c '! test -s "$DOCKER_CALLS"'
rm -f "$HOST_SOCK"

echo "== Case 13: registry classification helpers =="
reset_state
# These call the sourced functions in the current shell (command substitution
# and `eval` keep them in scope, unlike a `bash -c` subshell).
# shellcheck disable=SC2034  # consumed by registry_is_public, sourced above
DIND_HOST_PASSTHROUGH_REGISTRIES="docker.io ghcr.io"
check "bare name -> docker.io"      test "$(image_registry alpine)" = "docker.io"
check "user/repo -> docker.io"      test "$(image_registry library/alpine)" = "docker.io"
check "ghcr.io host detected"       test "$(image_registry ghcr.io/o/i)" = "ghcr.io"
check "private registry host kept"  test "$(image_registry registry.example.com:5000/i)" = "registry.example.com:5000"
check "docker.io is public"         eval 'registry_is_public docker.io'
check "private host not public"     eval '! registry_is_public registry.example.com:5000'

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
