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
    echo "loaded" >> "$DOCKER_LOADED"
    if [ "${2:-}" = "-i" ]; then
      # Tarball load (`docker load -i file`): nothing is piped and the mock has
      # no way to know which refs the tarball carried, so just record the load.
      exit 0
    fi
    # Piped load (`docker -H .. save <ref> | docker load`): our mock `save`
    # encodes the ref as a "REF:<ref>" line, so the loaded image becomes present
    # in the inner daemon — mirroring real `docker load` so post-load
    # verification (issue #106) sees what was actually seeded.
    while IFS= read -r line; do
      case "$line" in REF:*) printf '%s\n' "${line#REF:}" >> "$DOCKER_PRESENT" ;; esac
    done
    exit 0 ;;
  save)
    # `docker -H .. save <ref>` streams a tarball; mark it saved and encode the
    # ref so the piped `docker load` can mark it present (see above).
    echo "$2" >> "$DOCKER_SAVED"; printf 'REF:%s\n' "$2"; exit 0 ;;
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
# Captured entrypoint stdout/stderr for the issue #106 verification cases.
# Exported so the `bash -c '! grep ...'` negative checks resolve the path inside
# their subshell (an unexported $WORK would silently miss the file).
export OUT_LOG="$WORK/out.log"
export ERR_LOG="$WORK/err.log"

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
  DOCKER_INFO_OK=1 preload_into_daemon 2>"$ERR_LOG"
check "no load for missing path" bash -c '! grep -q "load -i" "$DOCKER_CALLS"'
check "warning emitted for missing path" grep -q "does not exist" "$ERR_LOG"

echo "== Case 8: passthrough is a quiet no-op when no host socket is mounted =="
reset_state
DIND_HOST_PASSTHROUGH=public DIND_HOST_DOCKER_SOCK="$WORK/absent.sock" \
  DIND_PRELOAD_TARBALL="" DIND_PRELOAD_IMAGES="" DOCKER_INFO_OK=1 \
  preload_into_daemon 2>"$ERR_LOG"
check "no host save attempted without a socket" bash -c '! test -s "$DOCKER_SAVED"'
check "no warning emitted when socket simply absent" bash -c '! test -s "$ERR_LOG"'

echo "== Case 8b: explicit allowlist + absent socket warns about the missing mount (issue #102) =="
reset_state
# The operator named the images they expect passed through, but forgot the
# host-socket mount. That opt-in signal turns the otherwise-silent no-op into a
# single actionable warning.
DIND_HOST_PASSTHROUGH=public DIND_HOST_DOCKER_SOCK="$WORK/absent.sock" \
  DIND_HOST_PASSTHROUGH_IMAGES="hello-world" \
  DIND_PRELOAD_TARBALL="" DIND_PRELOAD_IMAGES="" DOCKER_INFO_OK=1 \
  preload_into_daemon 2>"$ERR_LOG"
check "no host save attempted without a socket" bash -c '! test -s "$DOCKER_SAVED"'
check "warning names DIND_HOST_PASSTHROUGH_IMAGES" grep -q "DIND_HOST_PASSTHROUGH_IMAGES is set" "$ERR_LOG"
check "warning suggests the -v mount remediation" grep -q -- "-v /var/run/docker.sock:" "$ERR_LOG"

echo "== Case 8c: present-but-unreachable socket still wins over the allowlist warning =="
reset_state
# When a socket file exists but is unreachable, the original (more specific)
# "not accessible" warning fires — even with an allowlist set — and the generic
# missing-mount hint does not.
touch "$WORK/dead.sock"
DIND_HOST_PASSTHROUGH=public DIND_HOST_DOCKER_SOCK="$WORK/dead.sock" \
  DIND_HOST_PASSTHROUGH_IMAGES="hello-world" \
  DIND_PRELOAD_TARBALL="" DIND_PRELOAD_IMAGES="" DOCKER_INFO_OK=1 HOST_DOCKER_OK=0 \
  preload_into_daemon 2>"$ERR_LOG"
check "unreachable-socket warning fires" grep -q "is not accessible; skipping passthrough" "$ERR_LOG"
check "missing-mount hint suppressed when a socket file exists" bash -c '! grep -q "DIND_HOST_PASSTHROUGH_IMAGES is set" "$ERR_LOG"'
rm -f "$WORK/dead.sock"

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

echo "== Case 14: DIND_HOST_PASSTHROUGH_IMAGES allowlist scopes passthrough to named repos =="
reset_state
# Three Docker Hub images, all with a public RepoDigest so the mode gate passes;
# the allowlist must narrow to only the two hive-mind repos.
printf '%s\n%s\n%s\n' "konard/hive-mind:latest" "konard/hive-mind-dind:latest" "alpine:3.20" > "$HOST_IMAGES"
{
  echo "konard/hive-mind:latest|konard/hive-mind@sha256:aaa "
  echo "konard/hive-mind-dind:latest|konard/hive-mind-dind@sha256:bbb "
  echo "alpine:3.20|alpine@sha256:ccc "
} > "$HOST_DIGESTS"
make_sock "$HOST_SOCK"
DIND_HOST_PASSTHROUGH=public DIND_HOST_DOCKER_SOCK="$HOST_SOCK" \
  DIND_HOST_PASSTHROUGH_IMAGES="konard/hive-mind konard/hive-mind-dind" \
  DIND_PRELOAD_TARBALL="" DIND_PRELOAD_IMAGES="" DOCKER_INFO_OK=1 HOST_DOCKER_OK=1 \
  preload_into_daemon
check "allowlisted hive-mind image saved"       grep -qx "konard/hive-mind:latest" "$DOCKER_SAVED"
check "allowlisted hive-mind-dind image saved"  grep -qx "konard/hive-mind-dind:latest" "$DOCKER_SAVED"
check "non-allowlisted alpine NOT saved"         bash -c '! grep -qx "alpine:3.20" "$DOCKER_SAVED"'
rm -f "$HOST_SOCK"

echo "== Case 15: allowlist composes with mode (public still drops a local image even if allowlisted) =="
reset_state
printf '%s\n%s\n' "konard/hive-mind:latest" "konard/hive-mind-dev:latest" > "$HOST_IMAGES"
# hive-mind has a public digest; hive-mind-dev is locally built (no digest line).
echo "konard/hive-mind:latest|konard/hive-mind@sha256:aaa " > "$HOST_DIGESTS"
make_sock "$HOST_SOCK"
DIND_HOST_PASSTHROUGH=public DIND_HOST_DOCKER_SOCK="$HOST_SOCK" \
  DIND_HOST_PASSTHROUGH_IMAGES="konard/hive-mind*" \
  DIND_PRELOAD_TARBALL="" DIND_PRELOAD_IMAGES="" DOCKER_INFO_OK=1 HOST_DOCKER_OK=1 \
  preload_into_daemon
check "allowlisted public image saved"          grep -qx "konard/hive-mind:latest" "$DOCKER_SAVED"
check "allowlisted local image dropped by mode"  bash -c '! grep -qx "konard/hive-mind-dev:latest" "$DOCKER_SAVED"'
rm -f "$HOST_SOCK"

echo "== Case 16: globs and docker.io-qualified / tagged patterns all match =="
reset_state
printf '%s\n%s\n' "konard/hive-mind:latest" "ghcr.io/owner/tool:v1" > "$HOST_IMAGES"
{
  echo "konard/hive-mind:latest|konard/hive-mind@sha256:aaa "
  echo "ghcr.io/owner/tool:v1|ghcr.io/owner/tool@sha256:ddd "
} > "$HOST_DIGESTS"
make_sock "$HOST_SOCK"
# A docker.io-qualified glob for the hub image and an exact tagged ghcr ref.
DIND_HOST_PASSTHROUGH=all DIND_HOST_DOCKER_SOCK="$HOST_SOCK" \
  DIND_HOST_PASSTHROUGH_IMAGES="docker.io/konard/hive-mind* ghcr.io/owner/tool:v1" \
  DIND_PRELOAD_TARBALL="" DIND_PRELOAD_IMAGES="" DOCKER_INFO_OK=1 HOST_DOCKER_OK=1 \
  preload_into_daemon
check "docker.io-qualified glob matched the hub image" grep -qx "konard/hive-mind:latest" "$DOCKER_SAVED"
check "exact tagged ghcr ref matched"                  grep -qx "ghcr.io/owner/tool:v1" "$DOCKER_SAVED"
rm -f "$HOST_SOCK"

echo "== Case 17: empty allowlist preserves prior behavior (all eligible images pass) =="
reset_state
printf '%s\n%s\n' "konard/hive-mind:latest" "alpine:3.20" > "$HOST_IMAGES"
{
  echo "konard/hive-mind:latest|konard/hive-mind@sha256:aaa "
  echo "alpine:3.20|alpine@sha256:ccc "
} > "$HOST_DIGESTS"
make_sock "$HOST_SOCK"
DIND_HOST_PASSTHROUGH=public DIND_HOST_DOCKER_SOCK="$HOST_SOCK" \
  DIND_HOST_PASSTHROUGH_IMAGES="" \
  DIND_PRELOAD_TARBALL="" DIND_PRELOAD_IMAGES="" DOCKER_INFO_OK=1 HOST_DOCKER_OK=1 \
  preload_into_daemon
check "empty allowlist still saves hive-mind" grep -qx "konard/hive-mind:latest" "$DOCKER_SAVED"
check "empty allowlist still saves alpine"    grep -qx "alpine:3.20" "$DOCKER_SAVED"
rm -f "$HOST_SOCK"

echo "== Case 19: concrete allowlisted image present after passthrough -> honest 'complete' (issue #106) =="
reset_state
# Host has the named image with a public RepoDigest; the socket is mounted, so
# passthrough copies it and the mock `load` marks it present in the inner daemon.
printf '%s\n' "konard/hive-mind-dind:2.0.6" > "$HOST_IMAGES"
echo "konard/hive-mind-dind:2.0.6|konard/hive-mind-dind@sha256:aaa " > "$HOST_DIGESTS"
make_sock "$HOST_SOCK"
DIND_HOST_PASSTHROUGH=public DIND_HOST_DOCKER_SOCK="$HOST_SOCK" \
  DIND_HOST_PASSTHROUGH_IMAGES="konard/hive-mind-dind:2.0.6" \
  DIND_PRELOAD_TARBALL="" DIND_PRELOAD_IMAGES="" DOCKER_INFO_OK=1 HOST_DOCKER_OK=1 \
  preload_into_daemon >"$OUT_LOG" 2>"$ERR_LOG"
check "seeded concrete image was saved from host" grep -qx "konard/hive-mind-dind:2.0.6" "$DOCKER_SAVED"
check "honest 'complete' marker printed"          grep -q "image preload/passthrough complete" "$OUT_LOG"
check "no verification warning when present"       bash -c '! grep -q "did NOT seed" "$ERR_LOG"'
check "no 'WITH WARNINGS' marker when present"     bash -c '! grep -q "finished WITH WARNINGS" "$OUT_LOG" "$ERR_LOG"'
rm -f "$HOST_SOCK"

echo "== Case 20: concrete allowlisted image absent -> loud warning, no false 'complete' (issue #106) =="
reset_state
# No host socket mounted, so nothing can be copied. The named concrete image is
# absent from the inner daemon: verification must catch it and suppress 'complete'.
DIND_HOST_PASSTHROUGH=public DIND_HOST_DOCKER_SOCK="$WORK/absent.sock" \
  DIND_HOST_PASSTHROUGH_IMAGES="konard/hive-mind-dind:2.0.6" \
  DIND_PRELOAD_TARBALL="" DIND_PRELOAD_IMAGES="" DOCKER_INFO_OK=1 \
  preload_into_daemon >"$OUT_LOG" 2>"$ERR_LOG"
check "verification warns it did NOT seed the image" grep -q "did NOT seed expected image(s) into the nested daemon: konard/hive-mind-dind:2.0.6" "$ERR_LOG"
check "warning points at the missing -v mount"        grep -q -- "-v /var/run/docker.sock:" "$ERR_LOG"
check "terminal marker is 'finished WITH WARNINGS'"   grep -q "image preload/passthrough finished WITH WARNINGS" "$ERR_LOG"
check "misleading 'complete' is NOT printed"          bash -c '! grep -q "image preload/passthrough complete" "$OUT_LOG" "$ERR_LOG"'

echo "== Case 21: glob / bare-repo allowlist entries never raise a false verification alarm (issue #106) =="
reset_state
# Neither a glob nor a bare repository is concrete, so verification must skip
# them (the host could hold any tag) and still report an honest 'complete'.
DIND_HOST_PASSTHROUGH=public DIND_HOST_DOCKER_SOCK="$WORK/absent.sock" \
  DIND_HOST_PASSTHROUGH_IMAGES="konard/hive-mind* konard/other" \
  DIND_PRELOAD_TARBALL="" DIND_PRELOAD_IMAGES="" DOCKER_INFO_OK=1 \
  preload_into_daemon >"$OUT_LOG" 2>"$ERR_LOG"
check "no verification warning for non-concrete entries" bash -c '! grep -q "did NOT seed" "$ERR_LOG"'
check "honest 'complete' still printed"                  grep -q "image preload/passthrough complete" "$OUT_LOG"

echo "== Case 22: ref_is_concrete classification (direct calls) =="
reset_state
check "explicit tag is concrete"        eval 'ref_is_concrete "konard/hive-mind-dind:2.0.6"'
check "explicit digest is concrete"     eval 'ref_is_concrete "konard/hive-mind-dind@sha256:abc"'
check "bare repo is NOT concrete"       eval '! ref_is_concrete "konard/hive-mind"'
check "glob is NOT concrete"            eval '! ref_is_concrete "konard/hive-mind*"'
check "registry port w/o tag NOT concrete" eval '! ref_is_concrete "registry.example.com:5000/repo"'
check "registry port WITH tag is concrete" eval 'ref_is_concrete "registry.example.com:5000/repo:v1"'

echo "== Case 18: image-matching helper normalization (direct calls) =="
reset_state
# Like Case 13, drive the sourced helper in the current shell via `eval` so the
# function stays in scope (a `bash -c` subshell would not have it). Each check
# sets DIND_HOST_PASSTHROUGH_IMAGES inline so the case is self-contained.
check "bare repo matches tagged hub ref" \
  eval 'DIND_HOST_PASSTHROUGH_IMAGES="konard/hive-mind" host_image_matches_images_filter "konard/hive-mind:latest"'
check "docker.io-qualified pattern matches hub ref" \
  eval 'DIND_HOST_PASSTHROUGH_IMAGES="docker.io/konard/hive-mind" host_image_matches_images_filter "konard/hive-mind:latest"'
check "glob matches hub ref" \
  eval 'DIND_HOST_PASSTHROUGH_IMAGES="konard/hive-mind*" host_image_matches_images_filter "konard/hive-mind-dind:latest"'
check "unrelated pattern does not match" \
  eval '! DIND_HOST_PASSTHROUGH_IMAGES="konard/other" host_image_matches_images_filter "konard/hive-mind:latest"'
check "empty allowlist matches anything" \
  eval 'DIND_HOST_PASSTHROUGH_IMAGES="" host_image_matches_images_filter "anything:latest"'
check "ghcr exact ref matches" \
  eval 'DIND_HOST_PASSTHROUGH_IMAGES="ghcr.io/owner/tool:v1" host_image_matches_images_filter "ghcr.io/owner/tool:v1"'

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
