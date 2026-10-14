#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/dind/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_docker

running_container="${DIND_EXAMPLE_ID}-running"
snapshot_image="${DIND_EXAMPLE_ID}-snapshot"
resumed_container="${DIND_EXAMPLE_ID}-resumed"

register_image "$snapshot_image"

log "starting a box with a running nested dockerd"
run_dind_container "$running_container" -e DIND_HOST_PASSTHROUGH=off
wait_for_inner_docker "$running_container"

# The snapshot keeps the old daemon's pid files because /var/run is part of the
# container's writable layer (issue #133).
docker exec -u root "$running_container" \
  test -s /var/run/docker.pid -a -s /var/run/docker/containerd/containerd.pid \
  || fail "expected the running daemon to write both pid files"

# Whether an old PID is reused in the next container depends on start order.
# Point both files at PID 1, which is always alive and is never a daemon, so the
# failure from the incident reproduces on every run.
docker exec -u root "$running_container" /bin/bash -c '
  echo 1 >/var/run/docker.pid
  echo 1 >/var/run/docker/containerd/containerd.pid
'

log "committing the box while dockerd is running"
docker commit "$running_container" "$snapshot_image" >/dev/null
docker rm -f "$running_container" >/dev/null

log "resuming from the snapshot"
run_container_from_image "$resumed_container" "$snapshot_image" -e DIND_HOST_PASSTHROUGH=off
wait_for_inner_docker "$resumed_container"
assert_box_exec_user "$resumed_container"

for pid_file in /var/run/docker.pid /var/run/docker/containerd/containerd.pid; do
  if ! wait_for_logs "$resumed_container" "Removed stale ${pid_file}" 5; then
    docker logs "$resumed_container" >&2 || true
    fail "expected the entrypoint to report removing ${pid_file}"
  fi
done

log "nested dockerd starts after resuming from a docker commit snapshot"
