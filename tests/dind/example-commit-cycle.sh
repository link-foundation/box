#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/dind/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_docker

setup_container="${DIND_EXAMPLE_ID}-setup"
leaky_image="${DIND_EXAMPLE_ID}-leaky"
clean_image="${DIND_EXAMPLE_ID}-clean"
leaky_container="${DIND_EXAMPLE_ID}-leaky-run"
clean_container="${DIND_EXAMPLE_ID}-clean-run"

register_image "$leaky_image"
register_image "$clean_image"

log "creating a setup container with DIND_SKIP_DAEMON=1"
run_dind_container "$setup_container" -e DIND_SKIP_DAEMON=1

if docker exec "$setup_container" docker info >/dev/null 2>&1; then
  fail "DIND_SKIP_DAEMON=1 should leave dockerd stopped in the setup container"
fi

docker commit "$setup_container" "$leaky_image" >/dev/null

if ! docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$leaky_image" | grep -qx 'DIND_SKIP_DAEMON=1'; then
  fail "expected docker commit to preserve DIND_SKIP_DAEMON=1 in the leaky image"
fi

log "confirming the committed leaky image still skips dockerd"
run_container_from_image "$leaky_container" "$leaky_image"
sleep 2
if docker exec "$leaky_container" docker info >/dev/null 2>&1; then
  fail "the leaky committed image unexpectedly started dockerd"
fi

log "creating a cleaned image with DIND_SKIP_DAEMON reset to 0"
docker commit --change 'ENV DIND_SKIP_DAEMON=0' "$setup_container" "$clean_image" >/dev/null

run_container_from_image "$clean_container" "$clean_image"
wait_for_inner_docker "$clean_container"
assert_box_exec_user "$clean_container"

log "commit cycle works when the setup-only daemon skip is reset"
