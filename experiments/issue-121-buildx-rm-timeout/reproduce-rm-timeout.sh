#!/usr/bin/env bash
#
# Reproduce: `docker buildx rm` gives the whole removal the 20 seconds that
# `--timeout` documents for *loading builder status*, so a BuildKit state
# volume the daemon needs longer than that to delete turns a successful CI job
# into one carrying "ERROR: failed to remove one or more builders" - and leaks
# the volume, because the builder is dropped from buildx's store anyway.
#
# That is the warning annotation on run 34293699247's `full / docker-build-push`
# job (issue #121), which succeeded, pushed and published:
#
#   [command]/usr/bin/docker buildx rm builder-1e6b2f9a-...
#   failed to remove builder-1e6b2f9a-...: failed to remove node builder-...0:
#     Delete "http://%2Fvar%2Frun%2Fdocker.sock/v1.48/volumes/
#     buildx_buildkit_builder-...0_state": context deadline exceeded
#   ERROR: failed to remove one or more builders
#   ##[warning]ERROR: failed to remove one or more builders
#
# 20.05s elapsed between the command and the error, and the runner had buildx
# v0.36.1.
#
# Run:  bash experiments/issue-121-buildx-rm-timeout/reproduce-rm-timeout.sh
#       BUILDX_VERSION=v0.35.0 bash .../reproduce-rm-timeout.sh   # passes
#
# Exit 0 means the defect reproduced and the upstream reports still stand -
# docker/buildx#4067 and docker/setup-buildx-action#615, which carry a reduced
# form of this script; exit 1 means it did not. This is a demonstration of somebody else's code, not
# an assertion about this repository, which is why it sits in a subdirectory:
# scripts/ci/run-experiments.sh discovers experiments/*.sh at depth 1 only. It
# needs docker, python3 and network access to fetch the buildx release, none of
# which the offline suites may assume.
#
# The slow daemon is simulated rather than waited for: stall-docker-volume-
# delete.py forwards the Docker socket byte for byte and holds back only
# `DELETE /<api>/volumes/...`. Filling a state volume until its deletion really
# takes 20s would need tens of GB and a lot of patience; what matters is that
# the delete has not answered yet, which is exactly what the proxy produces.

set -euo pipefail

BUILDX_VERSION="${BUILDX_VERSION:-v0.36.1}"
DELAY_SECONDS="${DELAY_SECONDS:-25}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
SUFFIX="$$"
CONTEXT="issue121-stalled-${SUFFIX}"
BUILDER="issue121-rmtimeout-${SUFFIX}"
PROXY_PID=""

# Every line ends in `|| true`: this runs as an EXIT trap under `set -e`, where
# one failing command would abort the trap and replace the script's exit status
# with its own - and most of these are expected to fail, since they clean up
# after whichever half of the run happened.
cleanup() {
  [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null || true
  # The point of the bug: after a timed-out removal the volume outlives the
  # builder entry, so nothing but this line will ever collect it.
  docker volume rm "buildx_buildkit_${BUILDER}0_state" >/dev/null 2>&1 || true
  docker rm -f "buildx_buildkit_${BUILDER}0" >/dev/null 2>&1 || true
  "$BUILDX" rm "$BUILDER" >/dev/null 2>&1 || true
  docker context rm -f "$CONTEXT" >/dev/null 2>&1 || true
  rm -rf "$WORK"
  return 0
}
trap cleanup EXIT

command -v docker >/dev/null || {
  echo "docker is required" >&2
  exit 2
}

BUILDX="${WORK}/buildx"
url="https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-$(dpkg --print-architecture 2>/dev/null || echo amd64)"
echo "==> Fetching buildx ${BUILDX_VERSION}"
curl -sfL -o "$BUILDX" "$url" || {
  echo "could not download $url" >&2
  exit 2
}
chmod +x "$BUILDX"
"$BUILDX" version

echo "==> Starting the stalling Docker socket proxy (${DELAY_SECONDS}s on DELETE /volumes/)"
LISTEN_SOCK="${WORK}/docker.sock" DELAY_SECONDS="$DELAY_SECONDS" \
  python3 "${HERE}/stall-docker-volume-delete.py" >"${WORK}/proxy.log" 2>&1 &
PROXY_PID=$!
for _ in $(seq 1 50); do
  [ -S "${WORK}/docker.sock" ] && break
  sleep 0.1
done
[ -S "${WORK}/docker.sock" ] || {
  echo "proxy did not come up:" >&2
  cat "${WORK}/proxy.log" >&2
  exit 2
}

echo "==> Creating a builder whose node talks to the daemon through the proxy"
docker context create "$CONTEXT" --docker "host=unix://${WORK}/docker.sock" >/dev/null
"$BUILDX" create --name "$BUILDER" --driver docker-container "$CONTEXT" >/dev/null
"$BUILDX" inspect --bootstrap "$BUILDER" >/dev/null 2>&1

echo "==> docker buildx rm ${BUILDER}"
started="$(date +%s)"
set +e
output="$("$BUILDX" rm "$BUILDER" 2>&1)"
status=$?
set -e
elapsed=$(($(date +%s) - started))
echo "$output"
echo "==> exit ${status} after ${elapsed}s (the daemon answers after ${DELAY_SECONDS}s)"

volume_leaked=no
docker volume inspect "buildx_buildkit_${BUILDER}0_state" >/dev/null 2>&1 && volume_leaked=yes
builder_gone=no
"$BUILDX" inspect "$BUILDER" >/dev/null 2>&1 || builder_gone=yes

if [ "$status" -ne 0 ] && printf '%s' "$output" | grep -q "context deadline exceeded"; then
  echo
  echo "REPRODUCED: buildx ${BUILDX_VERSION} aborted the removal after its status"
  echo "  timeout, although the delete was still in flight and succeeds ${DELAY_SECONDS}s in."
  echo "  state volume left behind: ${volume_leaked}"
  echo "  builder entry dropped from the store anyway: ${builder_gone}"
  exit 0
fi

echo
echo "NOT REPRODUCED: buildx ${BUILDX_VERSION} waited for the removal (exit ${status})."
echo "  This is the pre-v0.36.0 behaviour; the upstream report can be closed"
echo "  against this version."
exit 1
