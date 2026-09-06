#!/usr/bin/env bash
# test-issue117-check-publication.sh
#
# Issue #117, claim 4. The v2.6.0 release notes say "28 of 56 image references
# resolve with `docker manifest inspect`". That check ran in create-release,
# right after docker/login-action had authenticated the job to ghcr.io, so the
# number is what the publisher could see. For a reader the number was 0 of 56:
# the GHCR packages are private and Docker Hub had received nothing because its
# token had expired. The run was green.
#
# scripts/release/check-publication.sh is the check that would have been red.
# This suite pins the four answers it has to keep apart - published, private,
# missing, unknown - and, above all, that it never reports success for a
# release nobody can pull.
#
# Entirely offline: the registry answers come from a stub sibling of a
# sandboxed copy of the script, picked up by the same
# `source "${SCRIPT_DIR}/registry-probe.sh"` line production uses.
#
# Usage: bash experiments/test-issue117-check-publication.sh

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
REGISTRY_PROBE_STATE=""
REGISTRY_PROBE_DETAIL=""
registry_probe_pull() {
  printf '%s\n' "$1" >>"$STUB_LOG"
  case "$1" in
    ghcr.io/*) REGISTRY_PROBE_STATE="${STUB_GHCR_STATE:-$STUB_STATE}" ;;
    *) REGISTRY_PROBE_STATE="${STUB_DOCKERHUB_STATE:-$STUB_STATE}" ;;
  esac
  REGISTRY_PROBE_DETAIL="stub answered ${REGISTRY_PROBE_STATE} for $1"
}
STUB

OUT="$WORK/out"
STUB_LOG="$WORK/probed"
SUMMARY="$WORK/summary.md"

# run GHCR_STATE DOCKERHUB_STATE [EXTRA_ENV...] - run the check, capture
# everything, leave the exit status in $STATUS.
run() {
  local ghcr_state="$1" dockerhub_state="$2"
  shift 2
  : >"$STUB_LOG"
  : >"$SUMMARY"
  env -i \
    PATH="$PATH" HOME="$HOME" \
    VERSION="2.6.0" \
    GHCR_IMAGE="ghcr.io/link-foundation/box" \
    DOCKERHUB_IMAGE="konard/box" \
    STUB_STATE="published" \
    STUB_GHCR_STATE="$ghcr_state" \
    STUB_DOCKERHUB_STATE="$dockerhub_state" \
    STUB_LOG="$STUB_LOG" \
    GITHUB_STEP_SUMMARY="$SUMMARY" \
    "$@" \
    bash "$WORK/scripts/release/check-publication.sh" >"$OUT" 2>&1
  STATUS=$?
}

echo "== Part 1: a release nobody can pull is not a success =="

# The exact shape of v2.6.0.
run private missing
if [ "$STATUS" -eq 1 ]; then
  pass "the v2.6.0 shape (GHCR private, Docker Hub empty) fails the run"
else
  fail "the v2.6.0 shape exits $STATUS; this is the green run of issue #117"
  sed 's/^/      /' "$OUT" >&2
fi

if grep -q '::error title=Release v2.6.0 is published to a private package' "$OUT"; then
  pass "the annotation names the actual cause: a private package"
else
  fail "the annotation does not name the private package"
fi

# The two ways of reaching nobody have different fixes. Calling a private
# package "missing" sends an operator looking for a build failure that did not
# happen.
run missing missing
if [ "$STATUS" -eq 1 ] && grep -q 'published nothing to the registry of record' "$OUT" \
  && ! grep -q 'private package' "$OUT"; then
  pass "nothing pushed at all is reported as nothing pushed, not as a visibility problem"
else
  fail "an unpushed release is not distinguished from a private one"
fi

# "I could not look" is not "it is not there", and it is not a pass either:
# an unknown state leaves the pullable count at zero, which is a failure.
run unknown unknown
if [ "$STATUS" -eq 1 ]; then
  pass "a registry that would not answer does not count as a successful publication"
else
  fail "an unanswered probe is treated as a published image"
fi

echo ""
echo "== Part 2: a reachable release passes, and a lagging mirror is a warning =="

run published published
if [ "$STATUS" -eq 0 ] && grep -q 'is reachable' "$OUT"; then
  pass "a fully published release passes"
else
  fail "a fully published release does not pass (exit $STATUS)"
  sed 's/^/      /' "$OUT" >&2
fi

# Issue #115, RC-18: a broken mirror credential must not fail a release that
# was published. GHCR is the registry of record; Docker Hub lagging is a
# warning, and issue #115's own fix depends on it staying one.
run published missing
if [ "$STATUS" -eq 0 ] && grep -q '::warning title=Docker Hub mirror is empty' "$OUT" \
  && ! grep -q '::error' "$OUT"; then
  pass "an empty Docker Hub mirror warns while GHCR carries the release"
else
  fail "an empty mirror fails a release that GHCR published (exit $STATUS)"
  sed 's/^/      /' "$OUT" >&2
fi

# ...but a repository that has decided Docker Hub is not optional can say so.
run published missing DOCKERHUB_REQUIRED=1
if [ "$STATUS" -eq 1 ] && grep -q '::error title=Docker Hub mirror is empty' "$OUT"; then
  pass "DOCKERHUB_REQUIRED=1 turns the mirror warning into a failure"
else
  fail "DOCKERHUB_REQUIRED=1 does not make the mirror mandatory (exit $STATUS)"
fi

echo ""
echo "== Part 3: it checks what it says it checks =="

run published published
PROBED="$(wc -l <"$STUB_LOG")"
if [ "$PROBED" -eq 8 ]; then
  pass "both registries are probed for all four sampled images"
else
  fail "expected 8 probes, got $PROBED"
  sed 's/^/      /' "$STUB_LOG" >&2
fi

missing=""
for reference in \
  "ghcr.io/link-foundation/box:2.6.0" \
  "ghcr.io/link-foundation/box-essentials:2.6.0" \
  "ghcr.io/link-foundation/box-js:2.6.0" \
  "ghcr.io/link-foundation/box-dind:2.6.0" \
  "konard/box:2.6.0" \
  "konard/box-dind:2.6.0"; do
  grep -qxF "$reference" "$STUB_LOG" || missing="${missing} ${reference}"
done
if [ -z "$missing" ]; then
  pass "the sample spans both image families and the dind layering"
else
  fail "the sample misses:${missing}"
fi

run published published CHECK_SUFFIXES="-python"
if [ "$(wc -l <"$STUB_LOG")" -eq 4 ]; then
  pass "CHECK_SUFFIXES narrows the sample (and always keeps the base image)"
else
  fail "CHECK_SUFFIXES does not control the sample"
  sed 's/^/      /' "$STUB_LOG" >&2
fi

run private missing
if grep -q '| `ghcr.io/link-foundation/box:2.6.0` | private |' "$SUMMARY"; then
  pass "the step summary records the state of each reference"
else
  fail "the step summary does not record per-reference state"
  sed 's/^/      /' "$SUMMARY" >&2
fi

echo ""
echo "== Part 4: misuse is refused, not guessed at =="

for var in VERSION GHCR_IMAGE DOCKERHUB_IMAGE; do
  out="$(env -i PATH="$PATH" HOME="$HOME" \
    VERSION="2.6.0" GHCR_IMAGE="ghcr.io/link-foundation/box" \
    DOCKERHUB_IMAGE="konard/box" STUB_STATE="published" STUB_LOG="$STUB_LOG" \
    "$var=" bash "$WORK/scripts/release/check-publication.sh" 2>&1)"
  status=$?
  if [ "$status" -eq 2 ] && printf '%s' "$out" | grep -q '::error'; then
    pass "a missing $var exits 2 with an annotation, distinct from a failed check"
  else
    fail "a missing $var exits $status"
  fi
done

echo ""
echo "== Part 5: the check holds no credential (issue #117, claim 4) =="

# The root cause was not the probing method, it was who was asking. A
# credential anywhere in this script would restore the defect.
# Matched as code, not as prose: the script explains in words why it holds no
# credential, and a pattern that cannot tell an explanation from an assignment
# would fail on its own documentation.
CREDENTIAL_USE='(^|[;&|(] *)docker +login|[$]\{?(GITHUB_TOKEN|DOCKERHUB_TOKEN|DOCKERHUB_PASSWORD)|REGISTRY_PROBE_(USERNAME|PASSWORD)='
if ! grep -qE "$CREDENTIAL_USE" scripts/release/check-publication.sh; then
  pass "check-publication.sh reads no registry credential of any kind"
else
  fail "check-publication.sh can authenticate; it would measure the publisher's access again"
  grep -nE "$CREDENTIAL_USE" scripts/release/check-publication.sh | sed 's/^/      /' >&2
fi

# And the workflow must not hand it one either - the step that calls it is the
# step that used to sit downstream of a docker/login-action.
STEP_ENV="$(awk '/- name: Verify the release is reachable without credentials/ {instep=1}
                 instep && /^      - name:/ && !/Verify the release is reachable/ {exit}
                 instep {print}' .github/workflows/release.yml)"
if [ -n "$STEP_ENV" ] && ! printf '%s' "$STEP_ENV" | grep -qE 'TOKEN|PASSWORD|secrets\.'; then
  pass "the workflow step passes no secret to the publication check"
else
  fail "the workflow step passes a secret to the publication check, or the step is missing"
  printf '%s\n' "$STEP_ENV" | sed 's/^/      /' >&2
fi

echo ""
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
