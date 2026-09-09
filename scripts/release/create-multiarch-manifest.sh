#!/usr/bin/env bash
# create-multiarch-manifest.sh - Publish the multi-arch manifest for a tag.
#
# Combines the per-architecture tags a build job pushed (IMAGE:TAG-amd64,
# IMAGE:TAG-arm64) into the plain IMAGE:TAG a user pulls, and then checks that
# the thing it just published carries the architectures it was asked for.
#
# Why this exists (issue #115). Ten steps across five jobs carried a
# byte-for-byte copy of the same `docker manifest create --amend` /
# `docker manifest push` pair, differing only in the image name. Ten copies
# means ten places to fix a defect, and two of them were already wrong in the
# same way:
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
# Why it no longer uses `docker manifest` (issue #119). On Docker Hub the
# sources are not what this script assumed. mirror-to-dockerhub.sh copies with
# `docker buildx imagetools create`, which always wraps its result in an OCI
# index - even for one platform - so docker.io/<ns>/box:2.7.0-amd64 is an index
# where ghcr.io/link-foundation/box:2.7.0-amd64 is a plain manifest. And
# `docker manifest create` refuses an index source. Release run 34056619231:
#
#   docker.io/***/box:2.7.0-amd64 is a manifest list
#   ==> ***/box:2.7.0: attempt 1 failed; retrying in 10s
#
# Three attempts, 40 seconds, one warning, and konard/box:2.7.0 left carrying
# whatever the amd64 job had written. `docker buildx imagetools create` accepts
# both shapes - it is the same tool the mirror already uses - so that is what
# publishes the manifest now. Retrying a deterministically wrong input is not a
# retry policy, it is a delay.
#
# Why it reads the result back (issue #119c). `imagetools create` will happily
# write an index with a single child, and that index resolves: on 2026-09-08
# konard/box:latest answered HTTP 200 and served linux/amd64 alone, where 2.4.0
# serves both. A tag that resolves with half the architectures the release built
# is a failed publication, so the read-back - not the exit status of the command
# that wrote it - decides whether this script succeeded.
#
# Usage:
#   bash scripts/release/create-multiarch-manifest.sh IMAGE TAG [TAG...]
#
#   IMAGE  Repository without a tag, e.g. ghcr.io/link-foundation/box-js
#   TAG    Manifest tag to publish, e.g. latest or 2.5.0. For each TAG the
#          script combines IMAGE:TAG-<arch> for every architecture.
#
# Environment variables:
#   MANIFEST_ARCHES     Space-separated arch suffixes (default: "amd64 arm64")
#   MANIFEST_PLATFORMS  Platforms the result must carry
#                       (default: linux/<arch> for every MANIFEST_ARCHES entry)
#   MANIFEST_VERIFY     1 = read the published manifest back (default)
#   MANIFEST_REQUIRED   1 = a failure fails the job (default), 0 = warn only
#   MAX_RETRIES         Attempts per tag (default: 3)
#   INITIAL_DELAY       Seconds before the first retry, linear backoff (default: 10)
#   BOX_VERBOSE=1       Trace every command this script runs
#
# Exit code 0 = every tag published with full coverage, or MANIFEST_REQUIRED=0
# and only warnings.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/release/docker-push-failure-classifier.sh
source "$SCRIPT_DIR/docker-push-failure-classifier.sh"
# The manifest parsers, shared with the anonymous publication check so that the
# publishing job and the post-release gate answer "which architectures?" the
# same way. Sourcing runs nothing.
# shellcheck source=scripts/release/registry-probe.sh
source "$SCRIPT_DIR/registry-probe.sh"

MANIFEST_ARCHES="${MANIFEST_ARCHES:-amd64 arm64}"
MANIFEST_REQUIRED="${MANIFEST_REQUIRED:-1}"
MANIFEST_VERIFY="${MANIFEST_VERIFY:-1}"
MAX_RETRIES="${MAX_RETRIES:-3}"
INITIAL_DELAY="${INITIAL_DELAY:-10}"

# The architectures are named as platforms for the read-back, because that is
# what a manifest declares. An explicit MANIFEST_PLATFORMS covers the case where
# an arch suffix and its platform are not the same word.
if [ -z "${MANIFEST_PLATFORMS:-}" ]; then
  MANIFEST_PLATFORMS=""
  for _arch in $MANIFEST_ARCHES; do
    MANIFEST_PLATFORMS="${MANIFEST_PLATFORMS}linux/${_arch} "
  done
  MANIFEST_PLATFORMS="${MANIFEST_PLATFORMS% }"
fi

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

# verify_tag TARGET - does the manifest that is now published carry the
# architectures this script was asked to publish?
#
# Reads the registry rather than trusting the exit status of the command that
# wrote it: `imagetools create` reports success for an index with one child, and
# an index with one child is exactly what the broken releases published.
#
# An unreadable manifest is not a failure here. The publishing job holds a
# credential, so it is the wrong place to adjudicate reachability; the anonymous
# check-publication.sh run after the release is the gate that cannot be fooled,
# and it re-asks this same question with no credentials at all.
verify_tag() {
  local target="$1" raw platforms missing

  [ "$MANIFEST_VERIFY" = "1" ] || return 0

  if ! raw="$(docker buildx imagetools inspect --raw "$target" 2>&1)"; then
    warn "Multi-arch manifest not verified" \
      "Published ${target} but could not read it back: $(printf '%s' "$raw" | tr '\n' ' ' | cut -c1-200). check-publication.sh re-checks this anonymously after the release."
    return 0
  fi

  platforms="$(registry_probe_manifest_platforms "$raw")"
  missing="$(registry_probe_missing_platforms "$MANIFEST_PLATFORMS" "$platforms")"

  if [ -n "$missing" ]; then
    echo "==> ${target}: published, and carries [${platforms:-nothing but a single-platform manifest}]; missing ${missing}" >&2
    MISSING_DETAIL="${target} carries [${platforms:-a single platform, undeclared}] and is missing ${missing}"
    return 1
  fi

  echo "==> ${target}: verified [${platforms}]"
  return 0
}

# publish_tag TAG - combine the per-architecture tags into TAG, with backoff.
# Returns 0 when TAG is published and carries every expected platform.
publish_tag() {
  local tag="$1"
  local target="${IMAGE}:${tag}"
  local sources=() arch attempt delay output

  for arch in $MANIFEST_ARCHES; do
    sources+=("${IMAGE}:${tag}-${arch}")
  done

  for attempt in $(seq 1 "$MAX_RETRIES"); do
    echo "==> Publishing ${target} (attempt ${attempt}/${MAX_RETRIES})"
    # imagetools create is idempotent by construction - it writes the tag from
    # its sources every time - so no --amend equivalent is needed, and unlike
    # `docker manifest create` it accepts a source that is itself an index.
    if output="$(docker buildx imagetools create --tag "$target" "${sources[@]}" 2>&1)"; then
      printf '%s\n' "$output"
      echo "==> Published ${target}"
      # A verification failure is not retried: the sources are what they are,
      # and writing the same index again produces the same index.
      verify_tag "$target"
      return $?
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
MISSING_DETAIL=""
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
if [ -n "${MISSING_DETAIL:-}" ]; then
  MESSAGE="Multi-arch manifest(s) do not carry ${MANIFEST_PLATFORMS}: ${MISSING_DETAIL}. A tag that resolves with half the architectures the release built is not published - an arm64 user pulling it gets 'no matching manifest for linux/arm64' (issue #119)."
fi

if [ "$MANIFEST_REQUIRED" = "1" ]; then
  echo "::error title=Multi-arch manifest failed::${MESSAGE}"
  exit 1
fi

warn "Multi-arch manifest failed" "$MESSAGE"
exit 0
