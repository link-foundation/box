#!/bin/bash
# assert-base-image.sh - Verify a base image really exists before a job builds
# FROM it.
#
# Usage: ./assert-base-image.sh <image-ref> [consumer-description]
#
# Why (issue #115, RC-4). The dind jobs gate on
#
#   needs.js-manifest.result == 'success' || needs.js-manifest.result == 'skipped'
#
# but a manifest job is skipped for two very different reasons: "this flavour
# was not rebuilt" (fine) and "the build it depends on failed" (fatal). The
# expression cannot tell them apart, so in run 33972074755 — where the Docker
# Hub token had expired and the js builds failed — all 28 dind matrix legs ran
# anyway and each failed 8.5 minutes later with
#
#   failed to resolve source metadata for docker.io/***/box-js:2.5.0-amd64: not found
#
# That is 28 red jobs blaming ubuntu/24.04/dind/Dockerfile for an expired
# secret. This check turns that into one honest line, before the build starts.
#
# Rather than trying to make the `if:` expression smarter (it has no way to
# know), assert the postcondition the gate was really standing in for: the
# image this job is about to consume was actually published.
#
# Exit 0 when the manifest resolves, 1 when it does not, 2 on usage error.

set -euo pipefail

BOX_VERBOSE="${BOX_VERBOSE:-0}"
[ "$BOX_VERBOSE" = "1" ] && set -x || true

if [ $# -lt 1 ]; then
  echo "Usage: $0 <image-ref> [consumer-description]" >&2
  exit 2
fi

IMAGE="$1"
CONSUMER="${2:-this job}"

echo "==> Verifying base image exists: $IMAGE"

# buildx imagetools speaks to the registry directly and reuses the credentials
# the login steps already established, so it works for both GHCR and Docker Hub
# and never has to pull the layers.
if output="$(docker buildx imagetools inspect "$IMAGE" 2>&1)"; then
  echo "==> Base image is present"
  [ "$BOX_VERBOSE" = "1" ] && printf '%s\n' "$output"
  exit 0
fi

printf '%s\n' "$output" >&2

cat >&2 <<MESSAGE

=== BASE IMAGE MISSING (build not attempted) ===

${CONSUMER} builds FROM ${IMAGE}, but that image is not present in the
registry, so the build could not have succeeded. It was not attempted.

This is almost always an *upstream* failure, not a defect in this job's
Dockerfile. Check, in order:

  1. The build job for the base flavour — did it fail to push?
  2. The manifest job for that flavour — a job that is "skipped" because the
     build it needed failed looks identical, in a workflow "if:" expression, to one
     skipped because the flavour simply was not rebuilt (issue #115, RC-4).
  3. The registry login steps — Docker Hub login is deliberately tolerant of
     failure, so an expired DOCKERHUB_TOKEN surfaces here first.

MESSAGE

echo "::error title=Base image missing::${IMAGE} was never published, so ${CONSUMER} cannot be built. Check the build and manifest jobs for that flavour; this is not a Dockerfile error."
exit 1
