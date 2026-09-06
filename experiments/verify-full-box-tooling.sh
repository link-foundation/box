#!/usr/bin/env bash
# verify-full-box-tooling.sh
#
# Issue #115: scripts/ci/test-box.sh's `full` profile runs every per-language
# box's checks against the composed image, which added checks the old inline
# copies never ran - most notably Rocq. The full box COPYs ~/.opam from
# rocq-stage but not the opam binary from ~/.local/bin, so whether `rocq` is
# actually reachable there depends on the merged .bashrc alone. This probe
# answers that against a real image instead of by reading the Dockerfile.
#
# It needs a full-box image on the machine (tens of GB), so
# scripts/ci/run-experiments.sh skips it; run it by hand:
#
#   docker pull konard/box:latest
#   bash experiments/verify-full-box-tooling.sh konard/box:latest

set -uo pipefail

IMAGE="${1:-konard/box:latest}"
FAILED=0

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "::error::$IMAGE is not present locally; pull it first"
  exit 2
fi

probe() {
  printf '%-38s ' "$*"
  local out status
  out="$(docker run --rm "$IMAGE" "$@" 2>&1 | head -1)"
  status="${PIPESTATUS[0]}"
  if [ "$status" -eq 0 ]; then
    printf 'ok      %s\n' "$out"
  else
    printf 'FAILED  %s\n' "$out"
    FAILED=$((FAILED + 1))
  fi
}

echo "=== probing $IMAGE ==="
probe rocq --version
probe opam --version
probe dotnet --version
probe Rscript --version
probe expect -v
probe gh-setup-git-identity --version
probe glab-setup-git-identity --version
probe cat /home/box/.php-install-method

echo
if [ "$FAILED" -eq 0 ]; then
  echo "all probes succeeded"
else
  echo "$FAILED probe(s) failed - the full box advertises a tool it cannot run"
fi
exit "$FAILED"
