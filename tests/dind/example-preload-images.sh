#!/usr/bin/env bash
set -euo pipefail

# Issue #94: the nested daemon starts with an empty image store, so the first
# `docker run <image>` inside the container re-downloads an image the host
# already has. This example proves the DIND_PRELOAD_TARBALL / DIND_PRELOAD_IMAGES
# entrypoint hook seeds the nested daemon at startup so no re-download is needed.
#
# The fixture image is built fully offline with `docker import` (no registry
# pull), saved to a tarball on the host, mounted into the dind container, and
# expected to be present in the *inner* daemon as soon as it is ready.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/dind/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_docker

fixture_image="preload-fixture-${DIND_EXAMPLE_ID}:issue94"
file_container="${DIND_EXAMPLE_ID}-preload-file"
dir_container="${DIND_EXAMPLE_ID}-preload-dir"

tarball_dir="$(mktemp -d)"
register_temp_dir "$tarball_dir"
register_image "$fixture_image"

log "building an offline fixture image with docker import (no registry pull)"
rootfs_dir="$(mktemp -d)"
register_temp_dir "$rootfs_dir"
# Keep the rootfs tar out of $tarball_dir so the directory-form preload below
# only ever sees a real image tarball (image.tar), not this raw filesystem tar.
echo "issue-94 preload fixture" > "$rootfs_dir/marker.txt"
tar -C "$rootfs_dir" -cf "$rootfs_dir/rootfs.tar" marker.txt
docker import "$rootfs_dir/rootfs.tar" "$fixture_image" >/dev/null

log "saving the fixture image to a tarball the way a host would seed it"
docker save "$fixture_image" -o "$tarball_dir/image.tar"

# The inner daemon loads the tarball as the box user, whose uid differs from the
# host creator of this temp dir. Make the mounted bind readable for everyone so
# the load is not blocked by host-side permissions.
chmod -R a+rX "$tarball_dir"

assert_inner_has_image() {
  local container="$1"
  if ! docker exec "$container" docker image inspect "$fixture_image" >/dev/null 2>&1; then
    docker exec "$container" docker images >&2 || true
    fail "expected ${fixture_image} to be preloaded in the inner daemon of ${container}"
  fi
}

# --- DIND_PRELOAD_TARBALL pointing at a single tarball file ---
log "starting ${DIND_IMAGE} with DIND_PRELOAD_TARBALL=/preload/image.tar"
run_dind_container "$file_container" \
  -e DIND_PRELOAD_TARBALL=/preload/image.tar \
  -v "$tarball_dir:/preload:ro"
wait_for_inner_docker "$file_container"
assert_inner_has_image "$file_container"
log "single-tarball preload made ${fixture_image} available without a pull"

# --- DIND_PRELOAD_TARBALL pointing at a directory of *.tar files, plus the
#     DIND_PRELOAD_IMAGES skip-when-present branch (no network pull happens
#     because the tarball already seeded the image). ---
log "starting ${DIND_IMAGE} with DIND_PRELOAD_TARBALL=/preload (directory form)"
run_dind_container "$dir_container" \
  -e DIND_PRELOAD_TARBALL=/preload \
  -e "DIND_PRELOAD_IMAGES=$fixture_image" \
  -v "$tarball_dir:/preload:ro"
wait_for_inner_docker "$dir_container"
assert_inner_has_image "$dir_container"

if ! docker logs "$dir_container" 2>&1 | grep -q "preload image already present, skipping pull"; then
  docker logs "$dir_container" >&2 || true
  fail "expected DIND_PRELOAD_IMAGES to skip the pull for an already-loaded image"
fi
log "directory preload loaded the tarball and DIND_PRELOAD_IMAGES skipped the redundant pull"

log "preload example passed"
