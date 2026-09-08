#!/usr/bin/env bash
# test-issue119-image-tags.sh
#
# Issue #119(b): "Only the manifest step should ever write an unsuffixed tag."
#
# For that to be possible the manifest step has to know every tag the release
# writes, and every job has to agree on what those tags are. Before
# scripts/release/image-tags.sh each job computed them for itself, and two of
# those computations were clock-dependent: docker/metadata-action evaluates
# `{{date 'YYYYMMDD'}}` when the step runs, and the full box takes over an hour
# to build. This suite pins the tag list and its determinism.
#
# What it asserts:
#   Part 1  the list, and its order
#   Part 2  references and per-architecture suffixes
#   Part 3  the same run gives the same answer, whatever the clock says, and
#           one job can hand its answer to the next
#   Part 4  the commit tag keeps the name docker/metadata-action gave it
#   Part 5  being called wrong is an error, not a surprising tag
#
# Usage: bash experiments/test-issue119-image-tags.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

SCRIPT="scripts/release/image-tags.sh"
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

# run - call the script with a pinned date and commit unless a test overrides
# them, capture stdout in $OUT, stderr in $ERR and the exit code in $CODE.
run() {
  OUT="$(VERSION="${VERSION:-2.7.0}" IMAGE_TAGS_DATE="${IMAGE_TAGS_DATE:-20260908}" \
    GITHUB_SHA="${GITHUB_SHA:-fd4742b9c8e7a6b5c4d3e2f1a0b9c8d7e6f5a4b3}" \
    bash "$SCRIPT" "$@" 2>"$TMP/err")"
  CODE=$?
  ERR="$(cat "$TMP/err")"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== Part 1: the tag list ==="

run
[ "$CODE" -eq 0 ] && pass "the tag list is produced" || fail "the tag list is produced" "exit $CODE" "$ERR"

EXPECTED="$(printf 'latest\n2.7.0\n20260908\nfd4742b')"
if [ "$OUT" = "$EXPECTED" ]; then
  pass "a release writes latest, the version, the date and the commit, in that order"
else
  fail "a release writes latest, the version, the date and the commit, in that order" \
    "expected: $(printf '%s' "$EXPECTED" | tr '\n' ' ')" \
    "got:      $(printf '%s' "$OUT" | tr '\n' ' ')"
fi

# The manifest step publishes what this prints, so an empty line would become
# `IMAGE:` and a stray space would become a tag no registry accepts.
if printf '%s\n' "$OUT" | grep -qx '[^[:space:]]*'; then
  if printf '%s\n' "$OUT" | grep -q '^[[:space:]]*$\|[[:space:]]'; then
    fail "every line is one tag and nothing else" "got: $(printf '%q' "$OUT")"
  else
    pass "every line is one tag and nothing else"
  fi
fi

echo
echo "=== Part 2: references and architectures ==="

run --image ghcr.io/link-foundation/box
if [ "$OUT" = "$(printf 'ghcr.io/link-foundation/box:latest\nghcr.io/link-foundation/box:2.7.0\nghcr.io/link-foundation/box:20260908\nghcr.io/link-foundation/box:fd4742b')" ]; then
  pass "--image turns the tags into references"
else
  fail "--image turns the tags into references" "got: $(printf '%s' "$OUT" | tr '\n' ' ')"
fi

run --image ghcr.io/link-foundation/box --suffix -amd64
if [ "$OUT" = "$(printf 'ghcr.io/link-foundation/box:latest-amd64\nghcr.io/link-foundation/box:2.7.0-amd64\nghcr.io/link-foundation/box:20260908-amd64\nghcr.io/link-foundation/box:fd4742b-amd64')" ]; then
  pass "--suffix names the per-architecture tags the build jobs push"
else
  fail "--suffix names the per-architecture tags the build jobs push" "got: $(printf '%s' "$OUT" | tr '\n' ' ')"
fi

# The suffix belongs to the tag, not to the repository: box:2.7.0-amd64, never
# box-amd64:2.7.0. create-multiarch-manifest.sh builds its sources the same way.
run --image ghcr.io/link-foundation/box --suffix -arm64
if ! printf '%s\n' "$OUT" | grep -q 'box-arm64' && printf '%s\n' "$OUT" | grep -qx 'ghcr.io/link-foundation/box:2.7.0-arm64'; then
  pass "the architecture suffixes the tag, not the repository"
else
  fail "the architecture suffixes the tag, not the repository" "got: $(printf '%s' "$OUT" | tr '\n' ' ')"
fi

echo
echo "=== Part 3: one release, one answer ==="

# The bug this prevents: a build that straddles midnight UTC. The amd64 job
# would tag 20260907-amd64 and the arm64 job 20260908-arm64, and no manifest
# could be built from that pair.
IMAGE_TAGS_DATE=20260907 run
BEFORE="$OUT"
IMAGE_TAGS_DATE=20260908 run
AFTER="$OUT"
if [ "$BEFORE" != "$AFTER" ]; then
  pass "the date tag does follow the date it is given"
else
  fail "the date tag does follow the date it is given" "both runs: $BEFORE"
fi

unset IMAGE_TAGS_DATE
run
FIRST="$OUT"
run
if [ "$FIRST" = "$OUT" ]; then
  pass "the same inputs give the same tags, so every job that asks gets one list"
else
  fail "the same inputs give the same tags, so every job that asks gets one list" \
    "first: $FIRST" "second: $OUT"
fi

if printf '%s\n' "$FIRST" | grep -qx "$(date -u +%Y%m%d)"; then
  pass "the date tag defaults to today in UTC"
else
  fail "the date tag defaults to today in UTC" "got: $(printf '%s' "$FIRST" | tr '\n' ' ')"
fi

# How the answer travels: the amd64 job computes the list, and the arm64 build
# and the manifest job are handed it. Being handed a list must not re-read the
# clock - a job that recomputes is the defect, whatever it is handed.
OUT="$(IMAGE_TAGS='latest 2.7.0 20260907 fd4742b' IMAGE_TAGS_DATE=20260908 \
  bash "$SCRIPT" --image ghcr.io/link-foundation/box --suffix -arm64 2>/dev/null)"
if [ "$OUT" = "$(printf 'ghcr.io/link-foundation/box:latest-arm64\nghcr.io/link-foundation/box:2.7.0-arm64\nghcr.io/link-foundation/box:20260907-arm64\nghcr.io/link-foundation/box:fd4742b-arm64')" ]; then
  pass "a handed-down list is used verbatim, so a later job cannot pick a different date"
else
  fail "a handed-down list is used verbatim, so a later job cannot pick a different date" \
    "got: $(printf '%s' "$OUT" | tr '\n' ' ')"
fi

# Actions job outputs are one line, so the list travels space-separated and
# comes back newline-separated. Both shapes have to mean the same thing.
SPACED="$(IMAGE_TAGS='latest 2.7.0' bash "$SCRIPT" 2>/dev/null)"
LINED="$(IMAGE_TAGS="$(printf 'latest\n2.7.0')" bash "$SCRIPT" 2>/dev/null)"
if [ "$SPACED" = "$LINED" ] && [ "$SPACED" = "$(printf 'latest\n2.7.0')" ]; then
  pass "the list survives the trip through a job output, spaces or newlines"
else
  fail "the list survives the trip through a job output, spaces or newlines" \
    "spaced: $(printf '%s' "$SPACED" | tr '\n' ' ')" "lined: $(printf '%s' "$LINED" | tr '\n' ' ')"
fi

# A handed-down list needs no version: the job that computed it had one.
OUT="$(VERSION='' IMAGE_TAGS='latest 2.7.0' bash "$SCRIPT" 2>"$TMP/err-handed")"
CODE=$?
if [ "$CODE" -eq 0 ] && [ -z "$(cat "$TMP/err-handed")" ]; then
  pass "a job that was handed the list does not need the version too"
else
  fail "a job that was handed the list does not need the version too" \
    "exit $CODE, stderr: $(cat "$TMP/err-handed")"
fi

echo
echo "=== Part 4: the commit tag ==="

# ghcr.io/link-foundation/box:fd4742b exists on the registry today, written by
# docker/metadata-action's `type=sha,prefix=`. Seven characters, no prefix.
GITHUB_SHA=fd4742b9c8e7a6b5c4d3e2f1a0b9c8d7e6f5a4b3 run
if printf '%s\n' "$OUT" | grep -qx 'fd4742b'; then
  pass "the commit tag is the first seven characters of the commit, as before"
else
  fail "the commit tag is the first seven characters of the commit, as before" \
    "got: $(printf '%s' "$OUT" | tr '\n' ' ')"
fi

if ! printf '%s\n' "$OUT" | grep -q 'sha-'; then
  pass "the commit tag carries no prefix, as before"
else
  fail "the commit tag carries no prefix, as before" "got: $(printf '%s' "$OUT" | tr '\n' ' ')"
fi

IMAGE_TAGS_SHA=abc1234 run
if printf '%s\n' "$OUT" | grep -qx 'abc1234' && ! printf '%s\n' "$OUT" | grep -qx 'fd4742b'; then
  pass "an explicit commit overrides the environment, so one job can hand its list to another"
else
  fail "an explicit commit overrides the environment, so one job can hand its list to another" \
    "got: $(printf '%s' "$OUT" | tr '\n' ' ')"
fi

# No commit to name: the release still has three tags, and the caller is told.
OUT="$(cd "$TMP" && VERSION=2.7.0 IMAGE_TAGS_DATE=20260908 GITHUB_SHA='' IMAGE_TAGS_SHA='' \
  bash "$OLDPWD/$SCRIPT" 2>"$TMP/err2")"
if [ "$OUT" = "$(printf 'latest\n2.7.0\n20260908')" ] && grep -q 'No commit to tag' "$TMP/err2"; then
  pass "with no commit to name, the other three tags are still published and the gap is announced"
else
  fail "with no commit to name, the other three tags are still published and the gap is announced" \
    "stdout: $(printf '%s' "$OUT" | tr '\n' ' ')" "stderr: $(cat "$TMP/err2")"
fi

echo
echo "=== Part 5: being called wrong ==="

OUT="$(VERSION='' bash "$SCRIPT" 2>"$TMP/err3")"
CODE=$?
if [ "$CODE" -eq 2 ] && grep -q 'VERSION is required' "$TMP/err3"; then
  pass "no version is an error, not a release tagged ':'"
else
  fail "no version is an error, not a release tagged ':'" "exit $CODE, stderr: $(cat "$TMP/err3")"
fi

OUT="$(VERSION='2.7.0 ' bash "$SCRIPT" 2>"$TMP/err4")"
CODE=$?
if [ "$CODE" -eq 2 ]; then
  pass "a version that is not a tag is rejected before anything is published"
else
  fail "a version that is not a tag is rejected before anything is published" \
    "exit $CODE, stdout: $(printf '%s' "$OUT" | tr '\n' ' ')"
fi

OUT="$(VERSION=2.7.0 bash "$SCRIPT" --plaform linux/amd64 2>"$TMP/err5")"
CODE=$?
if [ "$CODE" -eq 2 ] && grep -q 'Unknown argument' "$TMP/err5"; then
  pass "a mistyped flag is an error, not a silently different tag list"
else
  fail "a mistyped flag is an error, not a silently different tag list" "exit $CODE"
fi

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
