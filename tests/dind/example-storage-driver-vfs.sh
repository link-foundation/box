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
