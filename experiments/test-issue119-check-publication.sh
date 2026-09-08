#!/usr/bin/env bash
# test-issue119-check-publication.sh
#
# Issue #119(c): "nothing fails the release over it."
#
# v2.7.0 published konard/box:latest as an amd64-only image and konard/box-dind:2.7.0
# not at all, and the release run was green. The Docker Hub manifest step
# carried MANIFEST_REQUIRED: '0', so its three failed attempts were a warning;
# check-publication.sh asked whether the references resolved, and a
# single-architecture tag resolves. Measured anonymously on 2026-09-08:
#
#   konard/box:latest   published  linux/amd64               <- the regression
#   konard/box:2.4.0    published  linux/amd64 linux/arm64   <- the last good one
#
# The issue asks for two assertions, and this suite pins both:
#
#   "assert platform coverage, not just resolvability"
#   "treat 'a tag that was multi-arch in the previous release is single-arch
#    now' as a regression that fails the run"
#
# Offline: the registry answers come from a fixture table read by a stub
# sibling of a sandboxed copy of the script, picked up by the same
# `source "${SCRIPT_DIR}/registry-probe.sh"` line production uses. The stub
# sources the real probe first, so the platform comparison under test is the
# real registry_probe_missing_platforms and not a second implementation of it.
#
# Usage: bash experiments/test-issue119-check-publication.sh

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
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/scripts/release"
cp scripts/release/check-publication.sh "$WORK/scripts/release/"

cat >"$WORK/scripts/release/registry-probe.sh" <<'STUB'
#!/usr/bin/env bash
# Fixtures come from the environment, which run() sets; asserted here rather
# than expanded by the parent (issue #115 RC-1, scripts/ci/check-heredoc-vars.sh).
: "${STUB_FIXTURES:?must be passed in by the test}"
: "${STUB_LOG:?must be passed in by the test}"
: "${STUB_REAL_PROBE:?must be passed in by the test}"
# shellcheck source=/dev/null
source "$STUB_REAL_PROBE"

# One fixture per line: REFERENCE<TAB>STATE<TAB>PLATFORMS, first match wins,
# and a reference of "*" is the fallback. A "-" platform list means the
# registry did not say.
registry_probe_platforms() {
  local ref="$1" line
  printf '%s\n' "$ref" >>"$STUB_LOG"
  line="$(awk -F'\t' -v ref="$ref" '$1 == ref { print; exit }' "$STUB_FIXTURES")"
  [ -n "$line" ] || line="$(awk -F'\t' '$1 == "*" { print; exit }' "$STUB_FIXTURES")"
  REGISTRY_PROBE_STATE="$(printf '%s' "$line" | cut -f2)"
  REGISTRY_PROBE_PLATFORMS="$(printf '%s' "$line" | cut -f3)"
  [ "$REGISTRY_PROBE_PLATFORMS" = "-" ] && REGISTRY_PROBE_PLATFORMS=""
  REGISTRY_PROBE_DETAIL="fixture: ${REGISTRY_PROBE_STATE} [${REGISTRY_PROBE_PLATFORMS}]"
  return 0
}
registry_probe_pull() { registry_probe_platforms "$1"; }
STUB

OUT="$WORK/out"
STUB_LOG="$WORK/probed"
FIXTURES="$WORK/fixtures"
SUMMARY="$WORK/summary.md"

BOTH="linux/amd64 linux/arm64"

# run [EXTRA_ENV...] - run the check against the current fixture table.
run() {
  : >"$STUB_LOG"
  : >"$SUMMARY"
  env -i \
    PATH="$PATH" HOME="$HOME" \
    VERSION="2.7.0" \
    GHCR_IMAGE="ghcr.io/link-foundation/box" \
    DOCKERHUB_IMAGE="konard/box" \
    CHECK_SUFFIXES="-dind" \
    STUB_FIXTURES="$FIXTURES" \
    STUB_LOG="$STUB_LOG" \
    STUB_REAL_PROBE="$PWD/scripts/release/registry-probe.sh" \
    GITHUB_STEP_SUMMARY="$SUMMARY" \
    "$@" \
    bash "$WORK/scripts/release/check-publication.sh" >"$OUT" 2>&1
  STATUS=$?
}

# fixtures LINE... - write the table, tabs written by printf so the file is
# readable in the suite source.
fixtures() {
  : >"$FIXTURES"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" | sed 's/|/\t/g' >>"$FIXTURES"
  done
}

echo "== Part 1: a resolvable tag is not a published tag =="

fixtures "*|published|$BOTH"
run
if [ "$STATUS" -eq 0 ]; then
  pass "a release that carries both architectures everywhere passes"
else
  pass_out="$(cat "$OUT")"
  fail "a fully published release fails (exit $STATUS)"
  printf '%s\n' "$pass_out" | sed 's/^/      /' >&2
fi

# The exact shape of v2.7.0 on Docker Hub: latest resolves, and serves amd64.
fixtures \
  "konard/box:latest|published|linux/amd64" \
  "*|published|$BOTH"
run
if [ "$STATUS" -eq 1 ]; then
  pass "an amd64-only konard/box:latest fails the run, where v2.7.0 was green"
else
  fail "the v2.7.0 Docker Hub shape still exits $STATUS"
  sed 's/^/      /' "$OUT" >&2
fi

if grep -q '::error title=The Docker Hub mirror of v2.7.0 is single-architecture' "$OUT" \
  && grep -q 'missing linux/arm64' "$OUT"; then
  pass "the annotation names the missing architecture, not just the reference"
else
  fail "the annotation does not name the missing architecture"
  sed 's/^/      /' "$OUT" >&2
fi

# The same defect on the registry of record has its own annotation, because it
# has a different fix: on GHCR it means a build job wrote a tag the manifest
# step should own (issue #119b).
fixtures \
  "ghcr.io/link-foundation/box:latest|published|linux/amd64" \
  "*|published|$BOTH"
run
if [ "$STATUS" -eq 1 ] \
  && grep -q '::error title=Release v2.7.0 is single-architecture on the registry of record' "$OUT"; then
  pass "a single-architecture GHCR tag fails, and is reported as its own fault"
else
  fail "a single-architecture GHCR tag does not fail on its own terms (exit $STATUS)"
  sed 's/^/      /' "$OUT" >&2
fi

# An absent mirror tag is a lag and stays a warning (issue #115 RC-18); a
# mirror tag that answers with half the release is a wrong answer served to
# users. The two must not be collapsed, in either direction.
fixtures \
  "konard/box:latest|missing|-" \
  "konard/box:2.7.0|missing|-" \
  "konard/box-dind:latest|missing|-" \
  "konard/box-dind:2.7.0|missing|-" \
  "*|published|$BOTH"
run
if [ "$STATUS" -eq 0 ] && grep -q '::warning title=Docker Hub mirror is empty' "$OUT" \
  && ! grep -q '::error' "$OUT"; then
  pass "an empty Docker Hub mirror is still only a warning"
else
  fail "an empty mirror no longer degrades to a warning (exit $STATUS)"
  sed 's/^/      /' "$OUT" >&2
fi

echo
echo "== Part 2: 'I could not look' is not 'it is single-arch' =="

# registry_probe_platforms leaves the list empty when the config blob cannot be
# read. Failing on that would put issue #117's false claim back, pointed the
# other way: a rate limit would be reported as a broken release.
fixtures \
  "konard/box:latest|published|-" \
  "*|published|$BOTH"
run
if [ "$STATUS" -eq 0 ] && grep -q '::warning title=Platform coverage unknown' "$OUT"; then
  pass "a published reference with no measurable platforms warns instead of failing"
else
  fail "an unmeasurable reference is treated as a coverage failure (exit $STATUS)"
  sed 's/^/      /' "$OUT" >&2
fi

# ...and a private or missing reference is not asked about coverage at all: it
# has a state of its own, and the older annotations still own it.
fixtures "*|private|-"
run
if [ "$STATUS" -eq 1 ] && grep -q 'is published to a private package' "$OUT" \
  && ! grep -q 'single-architecture' "$OUT"; then
  pass "a private release is still reported as private, not as single-architecture"
else
  fail "a private release is misreported (exit $STATUS)"
  sed 's/^/      /' "$OUT" >&2
fi

echo
echo "== Part 3: losing an architecture is a regression, even if nobody expected it =="

# EXPECTED_PLATFORMS is a constant, so it cannot notice a platform the project
# used to ship and no longer does. This is the issue's second assertion.
fixtures \
  "konard/box:latest|published|linux/amd64 linux/arm64" \
  "konard/box:2.6.0|published|linux/amd64 linux/arm64 linux/riscv64" \
  "*|published|linux/amd64 linux/arm64"
run PREVIOUS_VERSION=2.6.0
if [ "$STATUS" -eq 1 ] && grep -q 'dropped an architecture that v2.6.0 published' "$OUT" \
  && grep -q 'lost linux/riscv64' "$OUT"; then
  pass "a tag that lost an architecture since the previous release fails the run"
else
  fail "a lost architecture does not fail the run (exit $STATUS)"
  sed 's/^/      /' "$OUT" >&2
fi

# The comparison needs a baseline that exists. v2.5.0 has no release at all and
# v2.6.0 is private on GHCR; comparing against either would invent a regression
# out of an old failure.
fixtures \
  "konard/box:2.6.0|missing|-" \
  "ghcr.io/link-foundation/box:2.6.0|private|-" \
  "*|published|$BOTH"
run PREVIOUS_VERSION=2.6.0
if [ "$STATUS" -eq 0 ] && ! grep -q 'dropped an architecture' "$OUT"; then
  pass "an unpublished previous release is not used as a baseline"
else
  fail "an unpublished previous release produces a false regression (exit $STATUS)"
  sed 's/^/      /' "$OUT" >&2
fi

# No PREVIOUS_VERSION, no comparison, and no probes for it either.
fixtures "*|published|$BOTH"
run
if ! grep -q ':2.6.0' "$STUB_LOG" && ! grep -q 'Comparing coverage' "$OUT"; then
  pass "without PREVIOUS_VERSION the previous release is never probed"
else
  fail "the previous release is probed without being asked for"
  sed 's/^/      /' "$STUB_LOG" >&2
fi

echo
echo "== Part 4: it checks the tag that broke, and reports what it found =="

fixtures "*|published|$BOTH"
run
for reference in \
  "ghcr.io/link-foundation/box:latest" \
  "konard/box:latest" \
  "ghcr.io/link-foundation/box-dind:2.7.0" \
  "konard/box-dind:2.7.0"; do
  if grep -qxF "$reference" "$STUB_LOG"; then
    pass "checked $reference"
  else
    fail "never checked $reference"
  fi
done

fixtures \
  "konard/box:latest|published|linux/amd64" \
  "*|published|$BOTH"
run
if grep -q '| `konard/box:latest` | published | linux/amd64 |' "$SUMMARY"; then
  pass "the step summary records the platforms, so the evidence outlives the run"
else
  fail "the step summary does not record platforms"
  sed 's/^/      /' "$SUMMARY" >&2
fi

# A repository that ships one architecture on purpose can say so, and the gate
# then has nothing to complain about. A gate with no off switch gets deleted.
fixtures \
  "konard/box:latest|published|linux/amd64" \
  "*|published|$BOTH"
run EXPECTED_PLATFORMS=""
if [ "$STATUS" -eq 0 ]; then
  pass "an empty EXPECTED_PLATFORMS disables the coverage gate deliberately"
else
  fail "the coverage gate cannot be turned off (exit $STATUS)"
  sed 's/^/      /' "$OUT" >&2
fi

echo
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
