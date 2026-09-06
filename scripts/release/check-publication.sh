#!/usr/bin/env bash
# check-publication.sh - After a release has been published, ask the registries
# what a reader can actually pull, and fail the run when the answer is nothing.
#
# Why this exists (issue #117). The release notes for v2.6.0 say "28 of 56
# image references resolve with `docker manifest inspect`". They ran that check
# inside create-release, in the same job that had just authenticated to ghcr.io
# with docker/login-action - so the number describes what the *publisher* could
# see. Anonymously, which is the only view a reader has, the number was 0 of
# 56: both GHCR packages are private, and Docker Hub had received nothing
# because its token had expired. The run was green, the notes were confident,
# and the release was unreachable by everybody.
#
# A check that runs as the one party guaranteed to have access is not a check.
# This one holds no credential at all - it deliberately unsets the ambient ones
# - and it is the last word on whether a release happened.
#
# Where this sits relative to issue #115's principle #13 ("never gate the
# release on an image push"): the GitHub Release is still created first and is
# still never withheld, so an operator always gets the notes and the tag. This
# runs afterwards and turns the *run* red. The failure is a report about a
# release that already exists, not a veto over creating it.
#
# Usage:
#   VERSION=2.7.0 GHCR_IMAGE=ghcr.io/link-foundation/box \
#   DOCKERHUB_IMAGE=konard/box bash scripts/release/check-publication.sh
#
# Environment variables:
#   VERSION            Version that was just published, no leading "v" (required)
#   GHCR_IMAGE         Full GHCR image, registry/owner/name (required)
#   DOCKERHUB_IMAGE    Docker Hub image, namespace/name (required)
#   CHECK_SUFFIXES     Space-separated image suffixes to check
#                      (default: the three combo images plus -dind)
#   DOCKERHUB_REQUIRED 1 = a mirror with nothing published fails too (default 0)
#   BOX_VERBOSE=1      Trace every command
#
# Exit codes:
#   0  the primary registry serves this version anonymously
#   1  it does not: the release is not reachable by its readers
#   2  the script was called wrong

set -uo pipefail

if [ "${BOX_VERBOSE:-0}" = "1" ]; then
  set -x
fi

for var in VERSION GHCR_IMAGE DOCKERHUB_IMAGE; do
  if [ -z "${!var:-}" ]; then
    echo "::error title=check-publication.sh::${var} is required" >&2
    exit 2
  fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./registry-probe.sh
source "${SCRIPT_DIR}/registry-probe.sh"

# A sample, not the full 56. This runs after every image has been pushed, and
# its job is to answer one question - "did this release reach anyone?" - not to
# re-inventory the build. The four cover both image families and the dind
# layering, so a whole-registry failure cannot hide behind a lucky tag.
read -r -a SUFFIXES <<<"${CHECK_SUFFIXES:--essentials -js -dind}"
SUFFIXES=("" "${SUFFIXES[@]}")

DOCKERHUB_REQUIRED="${DOCKERHUB_REQUIRED:-0}"

SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

GHCR_PULLABLE=0
GHCR_TOTAL=0
GHCR_PRIVATE=0
DOCKERHUB_PULLABLE=0
DOCKERHUB_TOTAL=0

{
  echo "### Anonymous publication check for v${VERSION}"
  echo
  echo "| Reference | State | Detail |"
  echo "|-----------|-------|--------|"
} >>"$SUMMARY"

# check REFERENCE KIND - probe one reference and record it.
check() {
  local reference="$1" kind="$2"

  registry_probe_pull "$reference"
  printf '%-60s %-10s %s\n' "$reference" "$REGISTRY_PROBE_STATE" "$REGISTRY_PROBE_DETAIL"
  printf '| `%s` | %s | %s |\n' "$reference" "$REGISTRY_PROBE_STATE" "$REGISTRY_PROBE_DETAIL" >>"$SUMMARY"

  if [ "$kind" = "ghcr" ]; then
    GHCR_TOTAL=$((GHCR_TOTAL + 1))
    case "$REGISTRY_PROBE_STATE" in
      published) GHCR_PULLABLE=$((GHCR_PULLABLE + 1)) ;;
      private) GHCR_PRIVATE=$((GHCR_PRIVATE + 1)) ;;
    esac
  else
    DOCKERHUB_TOTAL=$((DOCKERHUB_TOTAL + 1))
    if [ "$REGISTRY_PROBE_STATE" = "published" ]; then
      DOCKERHUB_PULLABLE=$((DOCKERHUB_PULLABLE + 1))
    fi
  fi
}

echo "==> Checking v${VERSION} the way a reader does: no credentials, no docker login."
for suffix in "${SUFFIXES[@]}"; do
  check "${GHCR_IMAGE}${suffix}:${VERSION}" ghcr
  check "${DOCKERHUB_IMAGE}${suffix}:${VERSION}" dockerhub
done

echo
echo "==> GHCR (registry of record): ${GHCR_PULLABLE}/${GHCR_TOTAL} pullable anonymously."
echo "==> Docker Hub (mirror):       ${DOCKERHUB_PULLABLE}/${DOCKERHUB_TOTAL} pullable anonymously."

STATUS=0

if [ "$GHCR_PULLABLE" -eq 0 ]; then
  if [ "$GHCR_PRIVATE" -gt 0 ]; then
    # Distinguish the two ways of reaching nobody. They have different fixes,
    # and "missing" would send an operator to look for a build failure that
    # did not happen.
    echo "::error title=Release v${VERSION} is published to a private package::Every checked GHCR reference exists but is refused anonymously, so this release reaches nobody. Make the packages public: https://github.com/orgs/link-foundation/packages -> each box package -> Package settings -> Danger Zone -> Change visibility -> Public. See docs/RELEASING.md." >&2
  else
    echo "::error title=Release v${VERSION} published nothing to the registry of record::None of the checked ghcr.io references can be pulled anonymously. The GitHub Release exists but there is no image behind it." >&2
  fi
  STATUS=1
fi

if [ "$DOCKERHUB_PULLABLE" -eq 0 ] && [ "$DOCKERHUB_TOTAL" -gt 0 ]; then
  if [ "$DOCKERHUB_REQUIRED" = "1" ]; then
    echo "::error title=Docker Hub mirror is empty for v${VERSION}::DOCKERHUB_REQUIRED=1, and none of the checked Docker Hub references can be pulled. This is what the expired DOCKERHUB_TOKEN of run 33972074755 looked like from outside." >&2
    STATUS=1
  else
    # The mirror is allowed to lag; the release-time preflight is what stops a
    # run with a credential that cannot write at all, and it runs before any
    # image is built rather than after.
    echo "::warning title=Docker Hub mirror is empty for v${VERSION}::None of the checked Docker Hub references can be pulled anonymously. GHCR carries this release; re-run scripts/release/mirror-to-dockerhub.sh once the credential works." >&2
  fi
fi

if [ "$STATUS" -eq 0 ]; then
  echo "==> v${VERSION} is reachable: ${GHCR_PULLABLE} of ${GHCR_TOTAL} checked references pull anonymously from the registry of record."
fi

exit "$STATUS"
