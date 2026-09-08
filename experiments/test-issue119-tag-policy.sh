#!/usr/bin/env bash
# test-issue119-tag-policy.sh
#
# Issue #119(b): "Only the manifest step should ever write an unsuffixed tag."
#
# The 2.7.0 release broke that rule in both directions. The full box's amd64 job
# pushed eight tags - its own four -amd64 ones and the four unsuffixed ones -
# and mirrored all eight to Docker Hub, so `konard/box:latest` was an amd64-only
# image written by a single-architecture job. The dind jobs pushed only suffixed
# tags and their manifest step wrote to GHCR alone, so `konard/box-dind:2.7.0`
# did not exist at all. Measured anonymously on 2026-09-08:
#
#   konard/box:latest             published  linux/amd64
#   konard/box:2.4.0              published  linux/amd64 linux/arm64
#   konard/box-dind:2.7.0         missing
#
# This suite reads the release workflows and asserts the rule directly: an
# architecture job names its architecture in every tag it writes, and the tags a
# user pulls are written by the manifest step, from the list one job computed.
#
# What it asserts:
#   Part 1  no architecture job writes a tag a user would pull
#   Part 2  the manifest step writes the unsuffixed tags, on both registries
#   Part 3  the tag list is computed once and handed down
#   Part 4  nothing re-reads the clock for a tag
#   Part 5  a job tests the image it published, not the one it did not
#
# Usage: bash experiments/test-issue119-tag-policy.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

PASS=0
FAIL=0

pass() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
  [ $# -gt 1 ] && printf '      %s\n' "${@:2}" >&2
}

# The workflows are resolved from the caller's `uses:` graph, not named: a grep
# over a file the jobs have left finds nothing and passes vacuously (issue #115).
WORKFLOWS="$(bash scripts/ci/list-release-workflows.sh)" || exit 1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Every line that names an image reference, tagged with the step it belongs to:
#   FILE:LINE<TAB>STEP NAME<TAB>TEXT
# Comments are skipped - the rule is about what a step writes, and a comment
# that quotes a broken reference is documentation of this very issue.
# shellcheck disable=SC2086 # deliberate word splitting: one path per awk arg
awk '
  /^[[:space:]]*- name:/ { step = $0; sub(/^[[:space:]]*- name:[[:space:]]*/, "", step) }
  /^[[:space:]]*#/ { next }
  /IMAGE_NAME[^:]*}}[^ ]*:/ { printf "%s:%d\t%s\t%s\n", FILENAME, FNR, step, $0 }
' $WORKFLOWS >"$TMP/refs"

if [ -s "$TMP/refs" ]; then
  pass "the release workflows still name images ($(wc -l <"$TMP/refs") references found)"
else
  fail "the release workflows still name images" "no reference matched - this suite would pass vacuously"
fi

# A step whose name mentions a manifest is the one step allowed to write a tag
# without an architecture in it.
grep -vi "$(printf '\t')[^$(printf '\t')]*manifest" "$TMP/refs" >"$TMP/arch-refs" || true
grep -i "$(printf '\t')[^$(printf '\t')]*manifest" "$TMP/refs" >"$TMP/manifest-refs" || true

echo
echo "=== Part 1: an architecture job writes architecture tags ==="

UNSUFFIXED=""
while IFS="$(printf '\t')" read -r where step text; do
  # Strip what surrounds the reference on the line: the shell redirection of a
  # step output, a line continuation, and the closing quote of an argument.
  ref="${text%% >> \"\$GITHUB_OUTPUT\"*}"
  ref="${ref% \\}"
  ref="${ref%\"}"
  case "$ref" in
    *-amd64 | *-arm64 | *-amd64-* | *-arm64-*) continue ;;
  esac
  UNSUFFIXED="${UNSUFFIXED}${where} (${step}): ${text#"${text%%[![:space:]]*}"}
"
done <"$TMP/arch-refs"

if [ -z "$UNSUFFIXED" ]; then
  pass "no step outside the manifest steps writes or reads an unsuffixed tag"
else
  fail "no step outside the manifest steps writes or reads an unsuffixed tag"
  printf '%s' "$UNSUFFIXED" | sed 's/^/      /' >&2
fi

# The specific regression the issue names: the full box's amd64 build pushing
# the tags a user pulls.
if ! grep -q 'steps.meta.outputs.tags' .github/workflows/release-full.yml; then
  pass "the full box build steps no longer push the unsuffixed metadata-action tag set"
else
  fail "the full box build steps no longer push the unsuffixed metadata-action tag set" \
    "$(grep -n 'steps.meta.outputs.tags' .github/workflows/release-full.yml)"
fi

echo
echo "=== Part 2: the manifest step writes the tags a user pulls ==="

if [ -s "$TMP/manifest-refs" ]; then
  pass "the manifest steps name images ($(wc -l <"$TMP/manifest-refs") references)"
else
  fail "the manifest steps name images" "none found - Part 1 would then be vacuous"
fi

# Both registries, every family: GHCR gets the manifest, Docker Hub gets a copy
# of it. Before issue #119a Docker Hub got its own assembly from the mirrored
# per-architecture tags, which could not work.
#
# Counted per file, because "five somewhere" would pass with one family
# publishing five manifests and four publishing none - which is close to what
# 2.7.0 actually did.
# shellcheck disable=SC2086 # deliberate word splitting: one path per awk arg
awk '
  /^[[:space:]]*- name:/ { step = tolower($0) }
  /create-multiarch-manifest.sh/ { ghcr[FILENAME] = 1 }
  step ~ /manifest/ && /mirror-to-dockerhub.sh/ { mirror[FILENAME] = 1 }
  END {
    for (f in ghcr) printf "%s\t%s\n", f, (f in mirror ? "mirrored" : "GHCR-ONLY")
  }
' $WORKFLOWS | sort >"$TMP/families"

FAMILIES="$(wc -l <"$TMP/families")"
if [ "$FAMILIES" -eq 5 ]; then
  pass "each of the five image families publishes its manifest on the registry of record"
else
  fail "each of the five image families publishes its manifest on the registry of record (found $FAMILIES)" \
    "$(cat "$TMP/families")"
fi

if ! grep -q 'GHCR-ONLY' "$TMP/families"; then
  pass "every family that publishes a manifest also mirrors it to Docker Hub"
else
  fail "every family that publishes a manifest also mirrors it to Docker Hub" \
    "$(grep 'GHCR-ONLY' "$TMP/families")"
fi

# konard/box-dind:2.7.0 was missing because the dind manifest step wrote to GHCR
# only. Its Docker Hub half is what this asserts exists.
if grep -A 8 'Mirror ${{ matrix.variant }} dind multi-arch manifests to Docker Hub' \
  .github/workflows/release-dind.yml | grep -q 'mirror-to-dockerhub.sh'; then
  pass "the dind manifests reach Docker Hub, which is why konard/box-dind:2.7.0 did not exist"
else
  fail "the dind manifests reach Docker Hub, which is why konard/box-dind:2.7.0 did not exist"
fi

echo
echo "=== Part 3: one list, computed once ==="

if grep -q 'tags: \${{ steps.tags.outputs.tags }}' .github/workflows/release-full.yml; then
  pass "the job that computes the tag list publishes it as a job output"
else
  fail "the job that computes the tag list publishes it as a job output"
fi

CONSUMERS="$(grep -c 'needs.docker-build-push.outputs.tags' .github/workflows/release-full.yml)"
if [ "$CONSUMERS" -ge 3 ]; then
  pass "the arm64 build and both manifest steps are handed that list ($CONSUMERS uses)"
else
  fail "the arm64 build and both manifest steps are handed that list (found $CONSUMERS uses)"
fi

# Exactly one step computes the list; everyone else is handed it. Two computing
# steps is the midnight-straddling bug reintroduced.
COMPUTERS="$(grep -B 6 'image-tags.sh' .github/workflows/release-full.yml | grep -c 'VERSION: \${{ steps.version.outputs.version }}')"
if [ "$COMPUTERS" -eq 1 ]; then
  pass "exactly one step computes the tag list from the version"
else
  fail "exactly one step computes the tag list from the version (found $COMPUTERS)"
fi

echo
echo "=== Part 4: no tag depends on when a step ran ==="

# shellcheck disable=SC2086
CLOCK="$(grep -n "date 'YYYYMMDD'" $WORKFLOWS | grep -v ': *#' || true)"
if [ -z "$CLOCK" ]; then
  pass "no metadata-action step reads the clock for a tag"
else
  fail "no metadata-action step reads the clock for a tag" "$CLOCK"
fi

# shellcheck disable=SC2086
STALE_META="$(grep -n 'type=raw,value=latest\|type=sha,prefix=' $WORKFLOWS || true)"
if [ -z "$STALE_META" ]; then
  pass "the release tag names come from image-tags.sh, not from four metadata-action lists"
else
  fail "the release tag names come from image-tags.sh, not from four metadata-action lists" "$STALE_META"
fi

echo
echo "=== Part 5: a job tests what it published ==="

if grep -q 'IMAGE: ${{ env.GHCR_REGISTRY }}/${{ env.GHCR_IMAGE_NAME }}:${{ steps.version.outputs.version }}-amd64' \
  .github/workflows/release-full.yml; then
  pass "the amd64 smoke test pulls the amd64 tag this job pushed"
else
  fail "the amd64 smoke test pulls the amd64 tag this job pushed" \
    "$(grep -n 'test-box.sh full' -B 3 .github/workflows/release-full.yml)"
fi

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
