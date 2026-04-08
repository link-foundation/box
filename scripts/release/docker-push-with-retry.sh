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

  while [ "$attempt" -le "$MAX_RETRIES" ]; do
    echo "==> Pushing $tag (attempt $attempt/$MAX_RETRIES)..."
    if docker push "$tag" 2>&1; then
      echo "==> Successfully pushed $tag"
      return 0
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
