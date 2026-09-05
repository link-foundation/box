#!/bin/bash
# buildx-retry.sh - Re-run a failed `docker buildx build --push`, but only when
# retrying can plausibly help.
#
# Usage: ./buildx-retry.sh <docker buildx build args...>
#
# Every build job in release.yml carried its own copy of a three-attempt retry
# loop (10 identical blocks, ~26 lines each) written for the transient GHCR 403
# of issue #78. Two problems, both visible in run 33972074755 (issue #115):
#
#   1. No classifier. The Docker Hub token had expired, so all three attempts
#      failed identically — except each attempt is a *full buildx solve*, not
#      just a push, so the cost was minutes per job across ~44 jobs.
#   2. Ten copies. A fix had to be made ten times, and RC-8 in the issue-115
#      analysis notes the duplication is why RC-4 and RC-7 keep recurring.
#
# Environment:
#   MAX_RETRIES              attempts, default 3
#   INITIAL_DELAY            seconds before the 2nd attempt, default 10 (the
#                            original blocks used 10*attempt; kept)
#   DOCKER_PUSH_FORCE_RETRY  set to 1 to retry regardless of classification
#   BOX_VERBOSE              set to 1 to trace the commands, default off

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/release/docker-push-failure-classifier.sh
source "$SCRIPT_DIR/docker-push-failure-classifier.sh"

MAX_RETRIES="${MAX_RETRIES:-3}"
INITIAL_DELAY="${INITIAL_DELAY:-10}"
BOX_VERBOSE="${BOX_VERBOSE:-0}"

[ "$BOX_VERBOSE" = "1" ] && set -x || true

if [ $# -eq 0 ]; then
  echo "Usage: $0 <docker buildx build args...>" >&2
  exit 2
fi

echo "First push attempt failed, retrying with backoff..."

attempt=1
while [ "$attempt" -le "$MAX_RETRIES" ]; do
  echo "==> Retry attempt $attempt/$MAX_RETRIES..."

  # Capture while streaming: the output must be inspectable to be classified,
  # but a silent multi-minute build is not debuggable.
  if output="$(docker buildx build "$@" 2>&1 | tee /dev/stderr)"; then
    echo "==> Push succeeded on retry attempt $attempt"
    exit 0
  fi

  # A rebuild cannot rotate an expired credential. Stop now with a message
  # that names the actual problem.
  if is_non_retryable_push_failure "$output"; then
    echo "==> ERROR: permanent authentication error; not retrying"
    echo "::error title=Registry authentication failed::The buildx push failed with a permanent authentication error. See the job log for how to rotate the credential."
    docker_push_failure_guidance "$(printf '%s\n' "$@" | grep -m1 -A1 -- '--tag' | tail -n1 || echo 'the image')"
    exit 1
  fi

  if [ "$attempt" -lt "$MAX_RETRIES" ]; then
    delay=$((INITIAL_DELAY * attempt))
    echo "==> Retry failed, waiting ${delay}s before next attempt..."
    sleep "$delay"
  fi
  attempt=$((attempt + 1))
done

echo "==> All retry attempts failed"
exit 1
