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

# The entrypoint loads images *after* dockerd reports ready, so waiting only for
# the inner daemon (wait_for_inner_docker) can race the asynchronous load. Wait
# for the entrypoint's completion marker before asserting on the seeded images.
wait_for_preload_complete() {
  local container="$1"
  local limit="${2:-$DIND_WAIT_SECONDS}"
  local i=0

  while [ "$i" -lt "$limit" ]; do
    if docker logs "$container" 2>&1 | grep -q "image preload/passthrough complete"; then
      log "image preload/passthrough completed in ${container} after ${i}s"
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done

  docker logs "$container" >&2 || true
  fail "image preload/passthrough did not complete in ${container} within ${limit}s"
}

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
wait_for_preload_complete "$file_container"
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
wait_for_preload_complete "$dir_container"
assert_inner_has_image "$dir_container"

if ! docker logs "$dir_container" 2>&1 | grep -q "preload image already present, skipping pull"; then
  docker logs "$dir_container" >&2 || true
  fail "expected DIND_PRELOAD_IMAGES to skip the pull for an already-loaded image"
fi
log "directory preload loaded the tarball and DIND_PRELOAD_IMAGES skipped the redundant pull"

# --- Host-image passthrough (issue #94 follow-up) ---------------------------
# Passthrough copies images already present on a *host* daemon into the nested
# daemon at startup, reading the host socket from a non-default path so the inner
# daemon stays isolated. To keep this test fully self-contained and bounded (no
# copying of whatever images the CI runner happens to have), we stand up a
# throwaway "host" daemon inside a second dind-box and expose its socket on a
# runner bind mount, then point consumers at it.
host_daemon_container="${DIND_EXAMPLE_ID}-passthrough-host"
all_container="${DIND_EXAMPLE_ID}-passthrough-all"
public_container="${DIND_EXAMPLE_ID}-passthrough-public"

host_sock_dir="$(mktemp -d)"
register_temp_dir "$host_sock_dir"
# Both the host daemon (root) and the consumer's box user reach this socket
# across the bind mount; make the directory traversable for everyone.
chmod 0777 "$host_sock_dir"

log "starting a throwaway host daemon (second dind-box) to passthrough from"
run_dind_container "$host_daemon_container" \
  -e DIND_SKIP_DAEMON=1 \
  -v "$host_sock_dir:/sockets"
# Bring up a dedicated dockerd inside the host box, listening on the shared
# socket path. vfs keeps it independent of the outer storage driver.
docker exec -d "$host_daemon_container" \
  sudo -n /usr/bin/dockerd \
    --host=unix:///sockets/docker.sock \
    --data-root=/var/lib/docker \
    --storage-driver=vfs

host_docker="docker exec $host_daemon_container docker -H unix:///sockets/docker.sock"
i=0
until $host_docker info >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -ge "${DIND_WAIT_SECONDS:-60}" ]; then
    docker exec "$host_daemon_container" tail -n 80 /var/log/dockerd.log >&2 2>/dev/null || true
    fail "throwaway host daemon did not become ready within ${DIND_WAIT_SECONDS:-60}s"
  fi
  sleep 1
done
log "throwaway host daemon is ready"

# Seed the host daemon with the offline fixture image. Built via docker import,
# it has no RepoDigest, which is exactly the "locally built" case the default
# public mode must refuse to pass through.
docker exec -i "$host_daemon_container" \
  docker -H unix:///sockets/docker.sock load < "$tarball_dir/image.tar"

# all mode: every tagged host image is copied, including this local fixture.
log "starting consumer with DIND_HOST_PASSTHROUGH=all"
run_dind_container "$all_container" \
  -e DIND_HOST_PASSTHROUGH=all \
  -e DIND_HOST_DOCKER_SOCK=/host-sock/docker.sock \
  -v "$host_sock_dir:/host-sock:ro"
wait_for_inner_docker "$all_container"
wait_for_preload_complete "$all_container"
assert_inner_has_image "$all_container"
log "all-mode passthrough copied the host fixture into the inner daemon (no pull)"

# public mode (the default): the fixture has no RepoDigest, so it must be
# skipped — passthrough never copies locally built / private images by default.
log "starting consumer with DIND_HOST_PASSTHROUGH=public (default security mode)"
run_dind_container "$public_container" \
  -e DIND_HOST_PASSTHROUGH=public \
  -e DIND_HOST_DOCKER_SOCK=/host-sock/docker.sock \
  -v "$host_sock_dir:/host-sock:ro"
wait_for_inner_docker "$public_container"
wait_for_preload_complete "$public_container"

if docker exec "$public_container" docker image inspect "$fixture_image" >/dev/null 2>&1; then
  docker logs "$public_container" >&2 || true
  fail "public mode must NOT pass through the local fixture image (no RepoDigest)"
fi
if ! docker logs "$public_container" 2>&1 | grep -q "host-image passthrough (mode=public)"; then
  docker logs "$public_container" >&2 || true
  fail "expected the consumer to run host-image passthrough in public mode"
fi
log "public-mode passthrough correctly skipped the local fixture (security filter held)"

log "preload example passed"
