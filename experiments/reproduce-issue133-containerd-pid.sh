#!/usr/bin/env bash
# Reproduce the exact incident in issue #133: dockerd's own PID is gone in the
# resumed container, but the PID recorded in containerd.pid belongs to another
# live process, so managed containerd refuses to start.
# Usage: DIND_IMAGE=<box-dind image> bash experiments/reproduce-issue133-containerd-pid.sh
set -euo pipefail

: "${DIND_IMAGE:?set DIND_IMAGE to a box-dind image}"
id="issue133-$$"
trap 'docker rm -f "$id-a" "$id-b" >/dev/null 2>&1 || true; docker rmi -f "$id-snapshot" >/dev/null 2>&1 || true' EXIT

docker run -d --privileged --name "$id-a" -e DIND_HOST_PASSTHROUGH=off "$DIND_IMAGE" sleep infinity >/dev/null
for _ in $(seq 60); do
  docker exec "$id-a" docker info >/dev/null 2>&1 && break
  sleep 1
done
docker exec -u root "$id-a" bash -c 'echo 999999 >/var/run/docker.pid; echo 1 >/var/run/docker/containerd/containerd.pid'
docker commit "$id-a" "$id-snapshot" >/dev/null
docker rm -f "$id-a" >/dev/null
docker run -d --privileged --name "$id-b" -e DIND_HOST_PASSTHROUGH=off -e DIND_STORAGE_DRIVER=fuse-overlayfs \
  "$id-snapshot" sleep infinity >/dev/null
for _ in $(seq 30); do
  if docker exec "$id-b" docker info >/dev/null 2>&1; then
    docker logs "$id-b" 2>&1 | grep 'Removed stale' || true
    echo "RESULT: nested dockerd started"
    exit 0
  fi
  sleep 1
done
docker exec "$id-b" grep -m1 'failed to start containerd' /var/log/dockerd.log || true
echo "RESULT: nested dockerd did not start"
exit 1
