#!/bin/bash
# docker-push-with-retry.sh - Push Docker images with retry logic for transient GHCR 403 errors
#
# Usage: ./docker-push-with-retry.sh <tag1> [tag2] [tag3] ...
#
# This script retries docker push for each tag up to MAX_RETRIES times with
# exponential backoff. This works around transient 403 Forbidden errors from
# GitHub Container Registry (ghcr.io) that occur during concurrent pushes,
# especially for first-time package creation.
#
# See: https://github.com/docker/build-push-action/issues/463
#      https://github.com/docker/build-push-action/issues/981
#      https://github.com/link-foundation/box/issues/78

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/release/docker-push-failure-classifier.sh
source "$SCRIPT_DIR/docker-push-failure-classifier.sh"

MAX_RETRIES="${MAX_RETRIES:-3}"
INITIAL_DELAY="${INITIAL_DELAY:-10}"

if [ $# -eq 0 ]; then
  echo "Usage: $0 <tag1> [tag2] [tag3] ..."
  exit 1
fi

push_with_retry() {
  local tag="$1"
  local attempt=1
  local delay="$INITIAL_DELAY"
  local output

  while [ "$attempt" -le "$MAX_RETRIES" ]; do
    echo "==> Pushing $tag (attempt $attempt/$MAX_RETRIES)..."
    # Capture while still streaming: the output has to be inspectable to be
    # classified, but a silent 20-minute push is not debuggable (issue #115).
    if output="$(docker push "$tag" 2>&1 | tee /dev/stderr)"; then
      echo "==> Successfully pushed $tag"
      return 0
    fi

    # An expired or missing credential does not heal on a backoff. Fail on the
    # first attempt with an actionable message rather than repeating it three
    # times (issue #115).
    if is_non_retryable_push_failure "$output"; then
      echo "==> ERROR: $tag failed with a permanent authentication error; not retrying"
      echo "::error title=Registry authentication failed::Pushing ${tag} failed with a permanent authentication error. See the job log for how to rotate the credential."
      docker_push_failure_guidance "$tag"
      return 1
    fi

    if [ "$attempt" -lt "$MAX_RETRIES" ]; then
      echo "==> Push failed for $tag, retrying in ${delay}s..."
      sleep "$delay"
      delay=$((delay * 2))
    fi
    attempt=$((attempt + 1))
  done

  echo "==> ERROR: Failed to push $tag after $MAX_RETRIES attempts"
  return 1
}

failed=0
for tag in "$@"; do
  if ! push_with_retry "$tag"; then
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  echo "==> Some pushes failed. See above for details."
  exit 1
fi

echo "==> All tags pushed successfully."
