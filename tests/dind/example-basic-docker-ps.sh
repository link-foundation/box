#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/dind/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_docker

container="${DIND_EXAMPLE_ID}-basic"

log "starting ${DIND_IMAGE} as ${container}"
run_dind_container "$container"
wait_for_inner_docker "$container"
assert_box_exec_user "$container"

docker exec "$container" pgrep -x dockerd >/dev/null
docker exec "$container" docker ps >/dev/null

log "docker exec lands as box and inner docker ps works"
