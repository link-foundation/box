#!/usr/bin/env bash
# mirror-to-dockerhub.sh
#
# Copy an image that is already published on GHCR to one or more Docker Hub
# tags, without rebuilding it.
#
# Why this exists (issue #115, root cause RC-3)
# --------------------------------------------
# Until now every build job pushed GHCR and Docker Hub tags in the *same*
# `docker buildx build --push` invocation. That coupling has three consequences,
# all of which were observed on run 33972074755 of the main branch:
#
#   1. One expired DOCKERHUB_TOKEN failed the whole push, so the GHCR tags were
#      never written either - even though GITHUB_TOKEN was perfectly valid.
#   2. The failing push aborted the run before `cache-to: type=gha` exported,
#      so the next run had no cache and rebuilt everything from scratch.
#   3. `continue-on-error` on the Docker Hub *login* (issue #82) suggested the
#      pipeline degrades gracefully to "GHCR only". It did not: the push step
#      itself was never guarded, so the tolerance was cosmetic.
#
# Splitting the push means GHCR is the registry of record - it is written with
# GITHUB_TOKEN, which Actions mints per run and cannot expire - and Docker Hub
# is a mirror. `docker buildx imagetools create` copies the manifest (and, for a
# multi-arch index, every child manifest) between registries server-side where
# possible, so mirroring costs a fraction of a rebuild.
#
# Failure policy
# --------------
# By default a mirror failure is a loud warning, not a job failure: the release
# is already published on GHCR and holding it back helps nobody. Set
# MIRROR_REQUIRED=1 to make Docker Hub a hard requirement instead. Permanent
# authentication failures are never retried (see docker-push-failure-classifier.sh).
#
# Usage:
#   bash scripts/release/mirror-to-dockerhub.sh <source-ref> <target-ref> [<target-ref>...]
#
# Environment:
#   MIRROR_REQUIRED  1 = exit non-zero when the mirror fails (default 0)
#   MAX_RETRIES      attempts for transient failures (default 3)
#   INITIAL_DELAY    seconds; the delay is INITIAL_DELAY * attempt (default 10)
#   BOX_VERBOSE      1 = trace every command (default 0, off)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/release/docker-push-failure-classifier.sh
source "$SCRIPT_DIR/docker-push-failure-classifier.sh"

MIRROR_REQUIRED="${MIRROR_REQUIRED:-0}"
MAX_RETRIES="${MAX_RETRIES:-3}"
INITIAL_DELAY="${INITIAL_DELAY:-10}"

if [ "${BOX_VERBOSE:-0}" = "1" ]; then
  set -x
fi

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <source-ref> <target-ref> [<target-ref>...]" >&2
  exit 2
fi

SOURCE="$1"
shift
TARGETS=("$@")

# Emit a warning that is visible both in the raw log and in the run summary.
warn() {
  local title="$1" message="$2"
  echo "::warning title=${title}::${message}"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '> [!WARNING]\n> **%s** — %s\n\n' "$title" "$message" >> "$GITHUB_STEP_SUMMARY"
  fi
}

TAG_ARGS=()
for target in "${TARGETS[@]}"; do
  TAG_ARGS+=(--tag "$target")
done

echo "==> Mirroring $SOURCE to Docker Hub"
printf '    -> %s\n' "${TARGETS[@]}"

output=""
for attempt in $(seq 1 "$MAX_RETRIES"); do
  echo "==> Mirror attempt $attempt of $MAX_RETRIES"
  if output="$(docker buildx imagetools create "${TAG_ARGS[@]}" "$SOURCE" 2>&1 | tee /dev/stderr)"; then
    echo "==> Mirrored $SOURCE to ${#TARGETS[@]} Docker Hub tag(s)"
    exit 0
  fi

  if is_non_retryable_push_failure "$output"; then
    echo "==> Docker Hub rejected the mirror with a permanent authentication error; not retrying"
    docker_push_failure_guidance "${TARGETS[0]}"
    break
  fi

  if [ "$attempt" -lt "$MAX_RETRIES" ]; then
    delay=$((INITIAL_DELAY * attempt))
    echo "==> Mirror failed; retrying in ${delay}s"
    sleep "$delay"
  fi
done

MESSAGE="Could not mirror ${SOURCE} to Docker Hub (${TARGETS[*]}). The image IS published on GHCR and is usable from there; only the Docker Hub copy is missing. The most likely cause is an expired or revoked DOCKERHUB_TOKEN - see docs/case-studies/issue-82/CASE-STUDY.md for the rotation runbook."

if [ "$MIRROR_REQUIRED" = "1" ]; then
  echo "::error title=Docker Hub mirror failed::${MESSAGE}"
  exit 1
fi

warn "Docker Hub mirror failed" "$MESSAGE"
exit 0
