#!/usr/bin/env bash
# check-publication.sh - After a release has been published, ask the registries
# what a reader can actually pull, and fail the run when the answer is nothing -
# or when it is less than the release built.
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
# Why it also counts architectures (issue #119c). v2.7.0 passed this check and
# was still broken: konard/box:latest resolved, and served linux/amd64 alone,
# because a single-architecture job had written it. "Does it resolve?" is not
# the question a user asks - `docker pull` on an arm64 machine fails with "no
# matching manifest for linux/arm64" against a tag this script called
# published. So every checked reference is now asked which platforms it
# carries, and a tag that carries fewer than the release built fails the run.
#
# And because the expected set is a constant, it cannot notice a platform the
# project once shipped and no longer does. PREVIOUS_VERSION adds the other
# comparison: a tag that was multi-arch in the previous release and is
# single-arch now is a regression, whatever the constant says.
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
#   CHECK_TAGS         Space-separated tags to check (default: "$VERSION latest")
#   EXPECTED_PLATFORMS Platforms every checked reference must carry
#                      (default: linux/amd64 linux/arm64; empty disables the
#                      coverage gate)
#   PREVIOUS_VERSION   Compare coverage against this version and fail when a
#                      reference lost an architecture (default: no comparison)
#   DOCKERHUB_REQUIRED 1 = a mirror with nothing published fails too (default 0)
#   BOX_VERBOSE=1      Trace every command
#
# Exit codes:
#   0  the primary registry serves this version anonymously, on every platform
#   1  it does not: the release is not reachable, or not by everyone it was
#      built for
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

# `latest` is checked alongside the version because it is the tag that broke:
# every reference of v2.7.0 was fine at :2.7.0 and amd64-only at :latest, and a
# check that only looks at the version tag would have passed that release
# twice.
read -r -a TAGS <<<"${CHECK_TAGS:-${VERSION} latest}"

EXPECTED_PLATFORMS="${EXPECTED_PLATFORMS-linux/amd64 linux/arm64}"
PREVIOUS_VERSION="${PREVIOUS_VERSION:-}"
DOCKERHUB_REQUIRED="${DOCKERHUB_REQUIRED:-0}"

SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

GHCR_PULLABLE=0
GHCR_TOTAL=0
GHCR_PRIVATE=0
DOCKERHUB_PULLABLE=0
DOCKERHUB_TOTAL=0
GHCR_INCOMPLETE=()
DOCKERHUB_INCOMPLETE=()
UNMEASURED=()
REGRESSIONS=()

{
  echo "### Anonymous publication check for v${VERSION}"
  echo
  echo "| Reference | State | Platforms | Detail |"
  echo "|-----------|-------|-----------|--------|"
} >>"$SUMMARY"

# check REFERENCE KIND PREVIOUS_PLATFORMS - probe one reference and record it.
#
# registry_probe_platforms, not registry_probe_pull: an index declares its
# children, but a plain manifest declares no platform at all, and a plain
# manifest under an unsuffixed tag is exactly what a single-architecture job
# leaves behind. Answering that case costs one extra request for the config
# blob, which is why the sample stays small.
check() {
  local reference="$1" kind="$2" previous="${3:-}"
  local platforms missing lost

  registry_probe_platforms "$reference"
  platforms="$REGISTRY_PROBE_PLATFORMS"

  printf '%-60s %-10s %-24s %s\n' "$reference" "$REGISTRY_PROBE_STATE" \
    "${platforms:--}" "$REGISTRY_PROBE_DETAIL"
  printf '| `%s` | %s | %s | %s |\n' "$reference" "$REGISTRY_PROBE_STATE" \
    "${platforms:-—}" "$REGISTRY_PROBE_DETAIL" >>"$SUMMARY"

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

  [ "$REGISTRY_PROBE_STATE" = "published" ] || return 0

  # An empty platform list from a published reference means the registry would
  # not say - not that the image carries nothing. Reporting "single-arch" for
  # "I could not look" is the false claim of issue #117 pointed the other way,
  # so it is a warning and never a failure.
  if [ -z "$platforms" ]; then
    UNMEASURED+=("${reference} (${REGISTRY_PROBE_DETAIL})")
    return 0
  fi

  if [ -n "$EXPECTED_PLATFORMS" ]; then
    missing="$(registry_probe_missing_platforms "$EXPECTED_PLATFORMS" "$platforms")"
    if [ -n "$missing" ]; then
      if [ "$kind" = "ghcr" ]; then
        GHCR_INCOMPLETE+=("${reference} carries [${platforms}], missing ${missing}")
      else
        DOCKERHUB_INCOMPLETE+=("${reference} carries [${platforms}], missing ${missing}")
      fi
    fi
  fi

  if [ -n "$previous" ]; then
    lost="$(registry_probe_missing_platforms "$previous" "$platforms")"
    if [ -n "$lost" ]; then
      REGRESSIONS+=("${reference} carries [${platforms}] where v${PREVIOUS_VERSION} carried [${previous}]: lost ${lost}")
    fi
  fi
}

# previous_platforms IMAGE - what IMAGE:PREVIOUS_VERSION serves, or "".
#
# Only a published previous reference is a baseline. A private, missing or
# unanswered one says nothing about whether this release lost an architecture,
# and comparing against it would invent a regression out of an old failure.
previous_platforms() {
  [ -n "$PREVIOUS_VERSION" ] || return 0
  registry_probe_platforms "${1}:${PREVIOUS_VERSION}"
  [ "$REGISTRY_PROBE_STATE" = "published" ] || return 0
  printf '%s' "$REGISTRY_PROBE_PLATFORMS"
}

echo "==> Checking v${VERSION} the way a reader does: no credentials, no docker login."
echo "==> Tags: ${TAGS[*]}; every reference must carry [${EXPECTED_PLATFORMS:-any platform}]."
[ -n "$PREVIOUS_VERSION" ] && echo "==> Comparing coverage against v${PREVIOUS_VERSION}."

for suffix in "${SUFFIXES[@]}"; do
  for kind in ghcr dockerhub; do
    if [ "$kind" = "ghcr" ]; then
      image="${GHCR_IMAGE}${suffix}"
    else
      image="${DOCKERHUB_IMAGE}${suffix}"
    fi
    baseline="$(previous_platforms "$image")"
    for tag in "${TAGS[@]}"; do
      check "${image}:${tag}" "$kind" "$baseline"
    done
  done
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

if [ "${#GHCR_INCOMPLETE[@]}" -gt 0 ]; then
  printf '%s\n' "${GHCR_INCOMPLETE[@]}" | sed 's/^/    /' >&2
  echo "::error title=Release v${VERSION} is single-architecture on the registry of record::${#GHCR_INCOMPLETE[@]} checked reference(s) resolve but do not carry ${EXPECTED_PLATFORMS}. Pulling them on a missing architecture fails with 'no matching manifest'. Either a build job wrote a tag the manifest step should own (issue #119b), or the manifest step did not run for it." >&2
  STATUS=1
fi

if [ "${#DOCKERHUB_INCOMPLETE[@]}" -gt 0 ]; then
  # An empty mirror is a lag; a mirror that answers with half the release is a
  # wrong answer, and it is served to users who never learn there was more.
  # That is why this fails even though DOCKERHUB_REQUIRED defaults to 0: the
  # default is about Docker Hub being *behind*, not about it being wrong.
  printf '%s\n' "${DOCKERHUB_INCOMPLETE[@]}" | sed 's/^/    /' >&2
  echo "::error title=The Docker Hub mirror of v${VERSION} is single-architecture::${#DOCKERHUB_INCOMPLETE[@]} mirrored reference(s) resolve but do not carry ${EXPECTED_PLATFORMS}. This is what konard/box:latest looked like after v2.7.0: it pulls, and on arm64 it fails. An absent mirror tag would be a warning; a wrong one is not." >&2
  STATUS=1
fi

if [ "${#REGRESSIONS[@]}" -gt 0 ]; then
  printf '%s\n' "${REGRESSIONS[@]}" | sed 's/^/    /' >&2
  echo "::error title=v${VERSION} dropped an architecture that v${PREVIOUS_VERSION} published::${#REGRESSIONS[@]} reference(s) carry fewer platforms than the previous release. A tag that used to be multi-arch and is not any more breaks every user who is already pulling it." >&2
  STATUS=1
fi

if [ "${#UNMEASURED[@]}" -gt 0 ]; then
  printf '%s\n' "${UNMEASURED[@]}" | sed 's/^/    /' >&2
  echo "::warning title=Platform coverage unknown for ${#UNMEASURED[@]} reference(s) of v${VERSION}::These references resolve anonymously, but the registry would not say which platforms they carry. That is not evidence of a single-architecture publication, so it does not fail the run." >&2
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
  echo "==> v${VERSION} is reachable: ${GHCR_PULLABLE} of ${GHCR_TOTAL} checked references pull anonymously from the registry of record, carrying ${EXPECTED_PLATFORMS:-whatever they carry}."
fi

exit "$STATUS"
