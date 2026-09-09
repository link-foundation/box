#!/usr/bin/env bash
# test-issue115-manifest-script.sh
#
# Issue #115: ten byte-identical `docker manifest create --amend` /
# `docker manifest push` pairs in .github/workflows/release.yml were replaced by
# scripts/release/create-multiarch-manifest.sh, which also fixes the two defects
# every copy carried:
#
#   1. no retry around a registry call, so one 502 failed a finished release;
#   2. a Docker Hub manifest failure failing a job whose GHCR manifest had
#      already been published (RC-3: GHCR is the registry of record, written
#      with the run's own GITHUB_TOKEN; Docker Hub is a mirror written with a
#      long-lived secret that can expire).
#
# Consolidation is only an improvement if the one remaining copy behaves as
# claimed, so this suite drives the script against a fake `docker` on PATH that
# records every invocation and can be told to fail in a chosen way.
#
# The pair the script itself runs changed in issue #119: `docker manifest create`
# refuses a source that is an index, which is exactly what the Docker Hub mirror
# writes, so the manifest is built with `docker buildx imagetools create` now.
# What this suite pins is unchanged - retries, the mirror not failing the job,
# one script for every manifest step - and the media-type behaviour itself is
# pinned by experiments/test-issue119-manifest-media-type.sh.
#
# Usage: bash experiments/test-issue115-manifest-script.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

SCRIPT="scripts/release/create-multiarch-manifest.sh"
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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BIN="$TMP/bin"
mkdir -p "$BIN"

# A fake docker. It appends every argument list to $DOCKER_LOG and decides its
# exit status from two files written by the caller:
#   $TMP/fail-pushes   how many `imagetools create` calls must fail (counted down)
#   $TMP/fail-output   what a failing call prints (chooses transient vs permanent)
#
# It also serves the manifest back: `imagetools inspect --raw` answers with an
# index built from the platforms of whatever sources the matching `create` was
# given, so the read-back the script does after publishing (issue #119) sees the
# truth rather than a canned success.
cat >"$BIN/docker" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"

if [ "$1 $2 $3" = "buildx imagetools create" ]; then
  shift 3
  remaining="$(cat "$FAKE_STATE/fail-pushes" 2>/dev/null || echo 0)"
  if [ "$remaining" -gt 0 ]; then
    echo $((remaining - 1)) > "$FAKE_STATE/fail-pushes"
    # Order matters: `2>/dev/null >&2` would point stdout at /dev/null and
    # swallow the message the script classifies on.
    cat "$FAKE_STATE/fail-output" >&2
    exit 1
  fi
  tag=""; platforms=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --tag|-t) tag="$2"; shift 2 ;;
      *) platforms="$platforms linux/${1##*-}"; shift ;;
    esac
  done
  printf '%s %s\n' "$tag" "${platforms# }" >> "$FAKE_STATE/manifests"
  exit 0
fi

if [ "$1 $2 $3" = "buildx imagetools inspect" ]; then
  ref="${*: -1}"
  line="$(grep "^${ref} " "$FAKE_STATE/manifests" 2>/dev/null | tail -1)" || true
  [ -n "$line" ] || { echo "${ref}: not found" >&2; exit 1; }
  children=""
  for platform in ${line#* }; do
    children="${children}{\"platform\":{\"architecture\":\"${platform#*/}\",\"os\":\"${platform%%/*}\"}},"
  done
  printf '{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[%s]}\n' "${children%,}"
  exit 0
fi

exit 0
FAKE
chmod +x "$BIN/docker"

# run FAIL_PUSHES FAIL_OUTPUT ENV... -- ARGS...
# Runs the script with the fake docker, no real sleeping, and a fresh log.
# Leaves the exit status in $STATUS, combined output in $OUT, the recorded
# docker invocations in $DOCKER_LOG.
DOCKER_LOG="$TMP/docker.log"
OUT=""
STATUS=0
run() {
  local fail_pushes="$1" fail_output="$2"
  shift 2
  echo "$fail_pushes" >"$TMP/fail-pushes"
  printf '%s\n' "$fail_output" >"$TMP/fail-output"
  : >"$DOCKER_LOG"
  : >"$TMP/manifests"

  # Everything before `--` is a NAME=VALUE override for this run; everything
  # after it is an argument to the script.
  local overrides=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    overrides+=("$1")
    shift
  done
  shift || true

  OUT="$(
    env \
      PATH="$BIN:$PATH" \
      DOCKER_LOG="$DOCKER_LOG" \
      FAKE_STATE="$TMP" \
      INITIAL_DELAY=0 \
      GITHUB_STEP_SUMMARY="$TMP/summary.md" \
      ${overrides[@]+"${overrides[@]}"} \
      bash "$SCRIPT" "$@" 2>&1
  )"
  STATUS=$?
}

creates() { grep -c 'imagetools create' "$DOCKER_LOG" || true; }

TRANSIENT='received unexpected HTTP status: 502 Bad Gateway'
PERMANENT='denied: requested access to the resource is denied'

echo "== Part 1: the happy path publishes every tag for every architecture =="

: >"$TMP/summary.md"
run 0 "" -- ghcr.io/link-foundation/box-js latest 2.5.0

if [ "$STATUS" -eq 0 ]; then
  pass "publishing two tags exits 0"
else
  fail "publishing two tags exits 0 (got $STATUS)"
  echo "$OUT" | sed 's/^/      /' >&2
fi

if [ "$(creates)" -eq 2 ]; then
  pass "one manifest write per tag"
else
  fail "one manifest write per tag (creates=$(creates))"
fi

if grep -qx 'buildx imagetools create --tag ghcr.io/link-foundation/box-js:latest ghcr.io/link-foundation/box-js:latest-amd64 ghcr.io/link-foundation/box-js:latest-arm64' "$DOCKER_LOG"; then
  pass "every architecture tag is a source of the published manifest"
else
  fail "every architecture tag is a source of the published manifest"
  sed 's/^/      /' "$DOCKER_LOG" >&2
fi

# imagetools create writes the tag from its sources on every call, so a retry
# needs no equivalent of `docker manifest create --amend`: there is no local
# manifest store left over from the failed attempt to collide with.
if [ "$(grep -c -- '--amend' "$DOCKER_LOG")" -eq 0 ]; then
  pass "no local manifest store to keep in sync between attempts"
else
  fail "no local manifest store to keep in sync between attempts"
  sed 's/^/      /' "$DOCKER_LOG" >&2
fi

echo ""
echo "== Part 2: MANIFEST_ARCHES selects the architectures =="

run 0 "" MANIFEST_ARCHES='amd64 arm64 riscv64' -- ghcr.io/example/box latest

if grep -q 'ghcr.io/example/box:latest-riscv64' "$DOCKER_LOG"; then
  pass "a third architecture is a source when MANIFEST_ARCHES asks for it"
else
  fail "a third architecture is a source when MANIFEST_ARCHES asks for it"
fi

if [ "$STATUS" -eq 0 ]; then
  pass "and the read-back expects linux/riscv64 too, so it still verifies"
else
  fail "and the read-back expects linux/riscv64 too (got $STATUS)"
  echo "$OUT" | sed 's/^/      /' >&2
fi

echo ""
echo "== Part 3: transient failures are retried (defect 1) =="

run 2 "$TRANSIENT" -- ghcr.io/example/box latest

if [ "$STATUS" -eq 0 ]; then
  pass "a tag that fails twice and then succeeds still exits 0"
else
  fail "a tag that fails twice and then succeeds still exits 0 (got $STATUS)"
  echo "$OUT" | sed 's/^/      /' >&2
fi

if [ "$(creates)" -eq 3 ]; then
  pass "the third attempt is the one that succeeds"
else
  fail "the third attempt is the one that succeeds (creates=$(creates))"
fi

echo ""
echo "== Part 4: permanent failures are not retried =="

run 99 "$PERMANENT" -- ghcr.io/example/box latest

if [ "$(creates)" -eq 1 ]; then
  pass "an auth failure costs exactly one attempt"
else
  fail "an auth failure costs exactly one attempt (creates=$(creates))"
fi

case "$OUT" in
  *"REGISTRY AUTHENTICATION FAILURE"*) pass "the auth failure prints actionable guidance" ;;
  *)
    fail "the auth failure prints actionable guidance"
    echo "$OUT" | sed 's/^/      /' >&2
    ;;
esac

echo ""
echo "== Part 5: the registry of record fails the job, the mirror does not (defect 2) =="

run 99 "$TRANSIENT" -- ghcr.io/example/box latest

if [ "$STATUS" -eq 1 ]; then
  pass "an exhausted required manifest exits 1"
else
  fail "an exhausted required manifest exits 1 (got $STATUS)"
fi

case "$OUT" in
  *"::error title=Multi-arch manifest failed::"*) pass "the failure is annotated as an error" ;;
  *) fail "the failure is annotated as an error" ;;
esac

if [ "$(creates)" -eq 3 ]; then
  pass "MAX_RETRIES attempts are made before giving up"
else
  fail "MAX_RETRIES attempts are made before giving up (creates=$(creates))"
fi

: >"$TMP/summary.md"
run 99 "$TRANSIENT" MANIFEST_REQUIRED=0 -- docker.io/example/box latest

if [ "$STATUS" -eq 0 ]; then
  pass "MANIFEST_REQUIRED=0 degrades the same failure to exit 0"
else
  fail "MANIFEST_REQUIRED=0 degrades the same failure to exit 0 (got $STATUS)"
  echo "$OUT" | sed 's/^/      /' >&2
fi

case "$OUT" in
  *"::warning title=Multi-arch manifest failed::"*) pass "the degraded failure is annotated as a warning" ;;
  *) fail "the degraded failure is annotated as a warning" ;;
esac

# A warning nobody reads is not a warning: it has to reach the job summary too.
if grep -q 'Multi-arch manifest failed' "$TMP/summary.md"; then
  pass "the warning also reaches \$GITHUB_STEP_SUMMARY"
else
  fail "the warning also reaches \$GITHUB_STEP_SUMMARY"
fi

echo ""
echo "== Part 6: misuse is rejected loudly =="

run 0 "" -- ghcr.io/example/box
if [ "$STATUS" -eq 2 ]; then
  pass "a missing tag argument exits 2"
else
  fail "a missing tag argument exits 2 (got $STATUS)"
fi

if [ "$(creates)" -eq 0 ]; then
  pass "misuse pushes nothing"
else
  fail "misuse pushes nothing (creates=$(creates))"
fi

echo ""
echo "== Part 7: every release manifest step calls this script =="

# The manifest jobs used to live in release.yml; the split by image family
# (issue #115, RC-8) moved them into release-<family>.yml. Resolve the files
# from the caller's `uses:` graph instead of naming one: a grep over a file the
# jobs have left finds zero inline copies and zero script calls, and "zero
# occurrences of the bug" reads exactly like "fixed". That vacuous pass is the
# false negative issue #115 exists to prevent.
# shellcheck disable=SC2086 # deliberate word splitting: one path per grep arg
WORKFLOWS="$(bash scripts/ci/list-release-workflows.sh)" || exit 1

# If any copy of the old inline pair survives, the defects above survive with
# it in that one job - which is exactly how ten copies drifted apart before.
#
# Comment lines are excluded: a comment that names `docker manifest inspect` -
# create-release has one, explaining why the publication check logs in to GHCR
# (issue #115) - is documentation, not a tenth divergent copy. Matching them
# would make this assertion fail for a reason it does not mean, and an
# assertion that cries wolf is the failure mode this suite exists to prevent.
LEFTOVER="$(grep -n 'docker manifest' $WORKFLOWS \
  | grep -v ':[0-9]*: *#' || true)"
if [ -z "$LEFTOVER" ]; then
  pass "no inline 'docker manifest' invocation remains in the release workflows"
else
  fail "no inline 'docker manifest' invocation remains in the release workflows"
  printf '%s\n' "$LEFTOVER" | sed 's/^/      /' >&2
fi

# One call per image family, on the registry of record only. Docker Hub used to
# get a second call that assembled its own manifest from the mirrored
# per-architecture tags; since issue #119a it is handed the finished GHCR index
# by mirror-to-dockerhub.sh, because those mirrored tags are indexes themselves
# and there was never anything to assemble.
CALLS="$(grep -h 'create-multiarch-manifest.sh' $WORKFLOWS | wc -l)"
if [ "$CALLS" -eq 5 ]; then
  pass "all five manifest steps (one per image family) call the script"
else
  fail "all five manifest steps call the script (found $CALLS)"
  grep -n 'create-multiarch-manifest.sh' $WORKFLOWS | sed 's/^/      /' >&2
fi

MIRRORED="$(grep -h 'mirror-to-dockerhub.sh' $WORKFLOWS | wc -l)"
if [ "$MIRRORED" -ge 5 ]; then
  pass "Docker Hub is served by the mirror, not by a second assembly ($MIRRORED call sites)"
else
  fail "Docker Hub is served by the mirror, not by a second assembly (found $MIRRORED call sites)"
fi

echo ""
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
