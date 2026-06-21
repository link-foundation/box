#!/usr/bin/env bash
set -euo pipefail

# Docker-outside-of-Docker (DooD) example (issue #110, findings #1 and #4).
#
# Instead of a nested dockerd, the in-container Docker CLI talks to the HOST
# daemon through its mounted socket. Selected by two run flags only:
#   * -e DIND_SKIP_DAEMON=1           -> do not start a nested daemon
#   * -v /var/run/docker.sock:/var/run/docker.sock   -> the host socket as the
#                                                       real runtime
# plus --group-add <host-docker-gid> so the box user can read that socket.
#
# Proof that DooD is active: from inside the container `docker ps` lists the
# very container the test is running in, because that container lives on the
# *host* daemon. A nested daemon could never see it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/dind/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_docker

HOST_SOCK=/var/run/docker.sock
if [ ! -S "$HOST_SOCK" ]; then
  fail "host Docker socket ${HOST_SOCK} not found; DooD example needs the host socket"
fi

# Owning GID of the host socket — what the box user must join via --group-add.
sock_gid="$(stat -c '%g' "$HOST_SOCK")"
log "host socket ${HOST_SOCK} is owned by GID ${sock_gid}"

container="${DIND_EXAMPLE_ID}-dood"

# DooD needs no nested daemon, so no --privileged: drop the default runtime flag.
log "starting ${DIND_IMAGE} as ${container} in DooD mode (DIND_SKIP_DAEMON=1)"
DIND_RUNTIME_FLAG="" run_dind_container "$container" \
  -e DIND_SKIP_DAEMON=1 \
  -v "${HOST_SOCK}:/var/run/docker.sock" \
  --group-add "$sock_gid"

# The entrypoint should announce DooD rather than starting a nested daemon.
if ! wait_for_logs "$container" "Docker-outside-of-Docker"; then
  docker logs "$container" >&2 || true
  fail "entrypoint did not announce Docker-outside-of-Docker mode"
fi

# docker exec must still land as box (unchanged user-facing default).
assert_box_exec_user "$container"

# No nested dockerd should be running in DooD mode.
if docker exec "$container" pgrep -x dockerd >/dev/null 2>&1; then
  fail "a nested dockerd is running, but DooD mode should not start one"
fi

# The box user can read the mounted host socket (the --group-add worked) and the
# CLI reaches the host daemon.
docker exec "$container" docker info >/dev/null \
  || fail "box cannot reach the host daemon through the mounted socket"

# Decisive DooD proof: the in-container docker sees this very container (a host
# container). A nested, isolated daemon could not.
if ! docker exec "$container" docker ps --format '{{.Names}}' | grep -qx "$container"; then
  docker exec "$container" docker ps >&2 || true
  fail "in-container docker ps does not list ${container}; not talking to the host daemon"
fi

log "DooD mode active: box reaches the host daemon and sees host containers"
