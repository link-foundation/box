#!/usr/bin/env bash
# image-tags.sh - the tag list one release writes, computed once.
#
# Why this exists (issue #119b). The tags of a release used to be computed
# independently by every job that needed them: the amd64 build asked
# docker/metadata-action, the arm64 build asked it again in a different job, and
# the manifest job hard-coded the two names it knew about. Two of those three
# answers can disagree.
#
#   * `type=raw,value={{date 'YYYYMMDD'}}` is evaluated when the step runs. The
#     full box takes over an hour to build, so a release started at 23:40 UTC
#     gives the amd64 job one date and the arm64 job the next one, and the
#     manifest that combines them cannot be built from either.
#   * The manifest job only ever knew about `latest` and the version, so the
#     date and commit tags were left as whatever the single-architecture job had
#     pushed. Measured anonymously on 2026-09-08:
#
#       ghcr.io/link-foundation/box:2.7.0     linux/amd64 linux/arm64
#       ghcr.io/link-foundation/box:20260907  linux/amd64
#       ghcr.io/link-foundation/box:fd4742b   linux/amd64
#
# One job computes this list and hands it to the others, so "which tags does
# this release write?" has exactly one answer per run - and every one of them
# reaches the manifest step, which is the only step allowed to write a tag a
# user pulls.
#
# Usage:
#   VERSION=2.7.0 bash scripts/release/image-tags.sh [--image IMAGE] [--suffix SUFFIX]
#
#   --image IMAGE   print full references (IMAGE:TAG) instead of bare tags
#   --suffix SUFFIX append SUFFIX to every tag, e.g. -amd64
#
# Environment variables:
#   VERSION          Version being released, no leading "v" (required unless
#                    IMAGE_TAGS is set)
#   IMAGE_TAGS       Use this tag list verbatim instead of computing one. This
#                    is how one job hands its answer to the next: the amd64
#                    build computes the list, and the arm64 build and the
#                    manifest job are handed it, so all three name the same tags.
#   IMAGE_TAGS_DATE  Override the date tag (default: today, UTC)
#   IMAGE_TAGS_SHA   Override the commit tag (default: GITHUB_SHA, 7 characters)
#   GITHUB_SHA       Commit being released, as Actions sets it
#
# Output: one tag (or reference) per line, in the order the release publishes
# them - latest, version, date, commit.
#
# Exit codes: 0 = tags printed, 2 = called wrong.

set -euo pipefail

IMAGE=""
SUFFIX=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --image)
      IMAGE="${2:-}"
      shift 2
      ;;
    --suffix)
      SUFFIX="${2:-}"
      shift 2
      ;;
    *)
      echo "::error title=image-tags.sh::Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ -n "${IMAGE_TAGS:-}" ]; then
  # Handed a list: print it in the shape this caller asked for and compute
  # nothing. Recomputing would re-read the clock, which is the whole defect.
  read -r -a TAGS <<<"$(printf '%s' "$IMAGE_TAGS" | tr '\n' ' ')"
else
  if [ -z "${VERSION:-}" ]; then
    echo "::error title=image-tags.sh::VERSION is required (or hand me a list in IMAGE_TAGS)" >&2
    exit 2
  fi

  case "$VERSION" in
    *[[:space:]]* | */* | :*)
      echo "::error title=image-tags.sh::VERSION is not a tag: '${VERSION}'" >&2
      exit 2
      ;;
  esac

  DATE="${IMAGE_TAGS_DATE:-$(date -u +%Y%m%d)}"

  # Seven characters of the commit, which is what docker/metadata-action's
  # `type=sha,prefix=` wrote before this script existed - ghcr.io/…/box:fd4742b
  # - so the tag a release publishes keeps the name readers already know.
  SHA="${IMAGE_TAGS_SHA:-}"
  if [ -z "$SHA" ] && [ -n "${GITHUB_SHA:-}" ]; then
    SHA="${GITHUB_SHA:0:7}"
  fi
  if [ -z "$SHA" ] && git rev-parse --git-dir >/dev/null 2>&1; then
    SHA="$(git rev-parse --short=7 HEAD 2>/dev/null || true)"
  fi

  TAGS=(latest "$VERSION" "$DATE")
  if [ -n "$SHA" ]; then
    TAGS+=("$SHA")
  else
    # Not an error: the commit tag is a convenience, and a caller with no commit
    # to name still needs the three tags that identify the release.
    echo "::warning title=image-tags.sh::No commit to tag (GITHUB_SHA unset and not a git checkout); publishing ${TAGS[*]} only." >&2
  fi
fi

for tag in "${TAGS[@]}"; do
  if [ -n "$IMAGE" ]; then
    printf '%s:%s%s\n' "$IMAGE" "$tag" "$SUFFIX"
  else
    printf '%s%s\n' "$tag" "$SUFFIX"
  fi
done
