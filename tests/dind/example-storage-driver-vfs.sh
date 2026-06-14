#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/dind/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_docker

container="${DIND_EXAMPLE_ID}-vfs"

log "starting ${DIND_IMAGE} with DIND_STORAGE_DRIVER=vfs"
run_dind_container "$container" -e DIND_STORAGE_DRIVER=vfs
wait_for_inner_docker "$container"

driver="$(docker exec "$container" docker info --format '{{.Driver}}' | tr -d '\r')"
if [ "$driver" != "vfs" ]; then
  fail "expected inner dockerd storage driver vfs, got ${driver}"
fi

log "inner dockerd is using the vfs storage driver"

# issue #104: landing on vfs must not be silent. The entrypoint (PID 1) emits a
# copy-on-write warning to stderr, which docker captures in the container logs.
log "verifying the vfs copy-on-write warning was emitted (issue #104)"
for needle in "'vfs' storage driver" "no space left on device" "DIND_STORAGE_DRIVER=fuse-overlayfs"; do
  if ! logs_contain "$container" "$needle"; then
    docker logs "$container" >&2 || true
    fail "expected the vfs warning to mention \"${needle}\", but it was absent from the container logs"
  fi
done

log "vfs copy-on-write warning is present in the container logs"
