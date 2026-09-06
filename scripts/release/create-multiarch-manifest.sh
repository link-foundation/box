#!/usr/bin/env bash
# create-multiarch-manifest.sh - Publish the multi-arch manifest list for a tag.
#
# Combines the per-architecture tags a build job pushed (IMAGE:TAG-amd64,
# IMAGE:TAG-arm64) into the plain IMAGE:TAG manifest list that users pull.
#
# Why this exists (issue #115). Ten steps across five jobs in
# .github/workflows/release.yml carried a byte-for-byte copy of the same
# `docker manifest create --amend` / `docker manifest push` pair, differing only
# in the image name. Ten copies means ten places to fix a defect, and two of
# them were already wrong in the same way:
#
#   1. No retry. `docker manifest push` talks to a registry, so it fails the
#      way every other registry call in this workflow fails - and unlike every
#      other registry call in this workflow, it had no backoff. A single 502
#      failed a release whose images were already built and pushed.
#   2. A Docker Hub manifest failure failed the whole job even though the GHCR
#      manifest had already been published. That is the same coupling that made
#      an expired DOCKERHUB_TOKEN take down run 33972074755: the registry with
#      the weaker credential decides whether the release succeeds. Docker Hub
#      manifests now pass MANIFEST_REQUIRED=0 and degrade to a warning.
#
# Usage:
#   bash scripts/release/create-multiarch-manifest.sh IMAGE TAG [TAG...]
#
#   IMAGE  Repository without a tag, e.g. ghcr.io/link-foundation/box-js
#   TAG    Manifest tag to publish, e.g. latest or 2.5.0. For each TAG the
#          script amends IMAGE:TAG-<arch> for every architecture.
#
# Environment variables:
#   MANIFEST_ARCHES     Space-separated arch suffixes (default: "amd64 arm64")
#   MANIFEST_REQUIRED   1 = a failure fails the job (default), 0 = warn only
#   MAX_RETRIES         Attempts per tag (default: 3)
#   INITIAL_DELAY       Seconds before the first retry, linear backoff (default: 10)
#   BOX_VERBOSE=1       Trace every command this script runs
#
# Exit code 0 = every tag published, or MANIFEST_REQUIRED=0 and only warnings.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/release/docker-push-failure-classifier.sh
source "$SCRIPT_DIR/docker-push-failure-classifier.sh"

MANIFEST_ARCHES="${MANIFEST_ARCHES:-amd64 arm64}"
MANIFEST_REQUIRED="${MANIFEST_REQUIRED:-1}"
MAX_RETRIES="${MAX_RETRIES:-3}"
INITIAL_DELAY="${INITIAL_DELAY:-10}"

if [ "${BOX_VERBOSE:-0}" = "1" ]; then
  set -x
fi

if [ "$#" -lt 2 ]; then
  echo "::error title=create-multiarch-manifest.sh::Usage: create-multiarch-manifest.sh IMAGE TAG [TAG...]"
  exit 2
fi

IMAGE="$1"
shift
TAGS=("$@")

# warn TITLE MESSAGE - a GitHub annotation plus a job-summary note, so a
# degraded publish is visible without reading the log.
warn() {
  local title="$1" message="$2"
  echo "::warning title=${title}::${message}"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '> [!WARNING]\n> **%s** — %s\n\n' "$title" "$message" >>"$GITHUB_STEP_SUMMARY"
  fi
}

# publish_tag TAG - create and push one manifest list, with backoff.
# Returns 0 on success, 1 when every attempt failed.
publish_tag() {
  local tag="$1"
  local target="${IMAGE}:${tag}"
  local amend_args=() arch attempt delay output

  for arch in $MANIFEST_ARCHES; do
    amend_args+=(--amend "${IMAGE}:${tag}-${arch}")
  done

  for attempt in $(seq 1 "$MAX_RETRIES"); do
    echo "==> Publishing ${target} (attempt ${attempt}/${MAX_RETRIES})"
    # --amend makes `create` idempotent: the local manifest store survives a
    # failed attempt, so a plain `create` would report "already exists" on the
    # retry and turn a transient push failure into a permanent one.
    if output="$({ docker manifest create "$target" "${amend_args[@]}" \
      && docker manifest push "$target"; } 2>&1)"; then
      printf '%s\n' "$output"
      echo "==> Published ${target}"
      return 0
    fi
    printf '%s\n' "$output" >&2

    if is_non_retryable_push_failure "$output"; then
      echo "==> ${target}: permanent registry error, not retrying" >&2
      docker_push_failure_guidance "$target" >&2
      return 1
    fi

    if [ "$attempt" -lt "$MAX_RETRIES" ]; then
      delay=$((INITIAL_DELAY * attempt))
      echo "==> ${target}: attempt ${attempt} failed; retrying in ${delay}s" >&2
      sleep "$delay"
    fi
  done

  return 1
}

FAILED=()
for tag in "${TAGS[@]}"; do
  if ! publish_tag "$tag"; then
    FAILED+=("${IMAGE}:${tag}")
  fi
done

if [ "${#FAILED[@]}" -eq 0 ]; then
  echo "==> ${IMAGE}: multi-arch manifests published for ${TAGS[*]}"
  exit 0
fi

MESSAGE="Could not publish multi-arch manifest(s): ${FAILED[*]}. The per-architecture tags were pushed and remain pullable by their -${MANIFEST_ARCHES// /\/-} suffix; only the combined manifest list is missing."

if [ "$MANIFEST_REQUIRED" = "1" ]; then
  echo "::error title=Multi-arch manifest failed::${MESSAGE}"
  exit 1
fi

warn "Multi-arch manifest failed" "$MESSAGE"
exit 0
