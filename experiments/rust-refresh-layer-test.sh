#!/usr/bin/env bash
# Reproduces the root cause behind issue #112's "2.2 GB ~/.rustup" and proves
# the fix used by ubuntu/24.04/full-box/refresh-rust.sh.
#
# The full image used to pick up its Rust with `COPY --from=rust-stage`, which
# bakes whatever `stable` the (possibly cached) rust image was built with. The
# obvious repair — COPY, then `rustup update` and delete the stale toolchain —
# does not shrink anything: the bytes are already committed in the COPY layer
# and the delete only writes a whiteout on top, so the image carries *both*
# toolchains. Binding the stage and copying inside a single RUN keeps the copy
# and the prune in one layer, so only the kept bytes are ever committed.
#
# This test measures both variants with a stand-in payload (no 700 MB rustup
# download) and asserts the size relationship.
#
# Usage: bash experiments/rust-refresh-layer-test.sh
set -euo pipefail

CTX="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/layer-whiteout"
PAYLOAD_MB="${PAYLOAD_MB:-128}"
BASE_IMAGE="${BASE_IMAGE:-ubuntu:24.04}"
export DOCKER_BUILDKIT=1

cleanup() {
  docker image rm -f whiteout-stage whiteout-copy-then-delete whiteout-single-layer >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

# The sizes are measured against the base image, and BuildKit keeps its build
# cache outside the image store, so building FROM the base does not leave it
# there. Pull it explicitly or `docker image inspect` fails on a clean runner.
docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 || docker pull -q "$BASE_IMAGE" >/dev/null

echo "==> Building the stand-in 'rust image' (a kept toolchain + a stale one, ${PAYLOAD_MB} MB each)"
docker build -q -t whiteout-stage \
  --build-arg PAYLOAD_MB="$PAYLOAD_MB" -f "$CTX/Dockerfile.stage" "$CTX" >/dev/null

echo "==> Variant A: COPY --from, then delete the stale toolchain in a later layer"
docker build -q -t whiteout-copy-then-delete -f "$CTX/Dockerfile.copy-then-delete" "$CTX" >/dev/null

echo "==> Variant B: RUN --mount=type=bind,from=... — copy and prune in one layer"
docker build -q -t whiteout-single-layer -f "$CTX/Dockerfile.single-layer" "$CTX" >/dev/null

size() { docker image inspect -f '{{.Size}}' "$1"; }
mb() { echo "$(( $1 / 1024 / 1024 ))"; }

base=$(size "$BASE_IMAGE")
a=$(size whiteout-copy-then-delete)
b=$(size whiteout-single-layer)

a_added=$(( a - base ))
b_added=$(( b - base ))

echo
echo "  base ${BASE_IMAGE}                  : $(mb "$base") MB"
echo "  A: COPY --from + later rm -rf    : $(mb "$a") MB  (+$(mb "$a_added") MB)"
echo "  B: RUN --mount + prune in-layer  : $(mb "$b") MB  (+$(mb "$b_added") MB)"
echo

failed=0

# A must carry both payloads: the whiteout hides the stale toolchain but the
# bytes stay in the image. Allow slack for compression/metadata.
if [ "$a_added" -gt $(( PAYLOAD_MB * 3 / 2 * 1024 * 1024 )) ]; then
  echo "PASS: deleting after COPY --from does not reclaim the bytes (image grew by ~2x the payload)"
else
  echo "FAIL: expected variant A to carry both payloads, it only added $(mb "$a_added") MB"
  failed=1
fi

if [ "$b_added" -lt $(( PAYLOAD_MB * 3 / 2 * 1024 * 1024 )) ]; then
  echo "PASS: copying and pruning inside one RUN commits only the kept payload"
else
  echo "FAIL: expected variant B to carry one payload, it added $(mb "$b_added") MB"
  failed=1
fi

if [ "$b" -lt "$a" ]; then
  echo "PASS: the single-layer variant is smaller ($(mb $(( a - b ))) MB saved)"
else
  echo "FAIL: the single-layer variant is not smaller"
  failed=1
fi

# Both variants must still expose the kept toolchain — a smaller image that
# lost the payload would be no fix at all.
for image in whiteout-copy-then-delete whiteout-single-layer; do
  if docker run --rm "$image" test -f /opt/toolchains/keep/payload.bin; then
    echo "PASS: $image keeps the current toolchain"
  else
    echo "FAIL: $image lost the current toolchain"
    failed=1
  fi
  if docker run --rm "$image" test -e /opt/toolchains/stale; then
    echo "FAIL: $image still exposes the stale toolchain"
    failed=1
  else
    echo "PASS: $image no longer exposes the stale toolchain"
  fi
done

exit "$failed"
