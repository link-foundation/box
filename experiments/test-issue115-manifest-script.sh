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
# Usage: bash experiments/test-issue115-manifest-script.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

SCRIPT="scripts/release/create-multiarch-manifest.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BIN="$TMP/bin"
mkdir -p "$BIN"

# A fake docker. It appends every argument list to $DOCKER_LOG and decides its
# exit status from two files written by the caller:
#   $TMP/fail-pushes   how many `manifest push` calls must fail (counted down)
#   $TMP/fail-output   what a failing call prints (chooses transient vs permanent)
cat > "$BIN/docker" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
if [ "$2" = "push" ]; then
  remaining="$(cat "$FAKE_STATE/fail-pushes" 2>/dev/null || echo 0)"
  if [ "$remaining" -gt 0 ]; then
    echo $((remaining - 1)) > "$FAKE_STATE/fail-pushes"
    # Order matters: `2>/dev/null >&2` would point stdout at /dev/null and
    # swallow the message the script classifies on.
    cat "$FAKE_STATE/fail-output" >&2
    exit 1
  fi
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
  echo "$fail_pushes" > "$TMP/fail-pushes"
  printf '%s\n' "$fail_output" > "$TMP/fail-output"
  : > "$DOCKER_LOG"

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

pushes() { grep -c 'manifest push' "$DOCKER_LOG" || true; }
creates() { grep -c 'manifest create' "$DOCKER_LOG" || true; }

TRANSIENT='received unexpected HTTP status: 502 Bad Gateway'
PERMANENT='denied: requested access to the resource is denied'

echo "== Part 1: the happy path publishes every tag for every architecture =="

: > "$TMP/summary.md"
run 0 "" -- ghcr.io/link-foundation/box-js latest 2.5.0

if [ "$STATUS" -eq 0 ]; then
  pass "publishing two tags exits 0"
else
  fail "publishing two tags exits 0 (got $STATUS)"
  echo "$OUT" | sed 's/^/      /' >&2
fi

if [ "$(pushes)" -eq 2 ] && [ "$(creates)" -eq 2 ]; then
  pass "one create and one push per tag"
else
  fail "one create and one push per tag (creates=$(creates) pushes=$(pushes))"
fi

if grep -qx 'manifest create ghcr.io/link-foundation/box-js:latest --amend ghcr.io/link-foundation/box-js:latest-amd64 --amend ghcr.io/link-foundation/box-js:latest-arm64' "$DOCKER_LOG"; then
  pass "each architecture tag is amended into the list"
else
  fail "each architecture tag is amended into the list"
  sed 's/^/      /' "$DOCKER_LOG" >&2
fi

# --amend is what makes a retry possible at all: the local manifest store
# survives a failed attempt, so a plain `create` would fail with "already
# exists" on the second attempt and turn a transient error into a permanent one.
if ! grep -q 'manifest create' "$DOCKER_LOG" || grep 'manifest create' "$DOCKER_LOG" | grep -qv -- '--amend'; then
  fail "every create uses --amend"
else
  pass "every create uses --amend"
fi

echo ""
echo "== Part 2: MANIFEST_ARCHES selects the architectures =="

run 0 "" MANIFEST_ARCHES='amd64 arm64 riscv64' -- ghcr.io/example/box latest

if grep -q -- '--amend ghcr.io/example/box:latest-riscv64' "$DOCKER_LOG"; then
  pass "a third architecture is amended when MANIFEST_ARCHES asks for it"
else
  fail "a third architecture is amended when MANIFEST_ARCHES asks for it"
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

if [ "$(pushes)" -eq 3 ]; then
  pass "the third attempt is the one that succeeds"
else
  fail "the third attempt is the one that succeeds (pushes=$(pushes))"
fi

if [ "$(creates)" -eq 3 ]; then
  pass "create is re-run before every retry, so the amend list is rebuilt"
else
  fail "create is re-run before every retry (creates=$(creates))"
fi

echo ""
echo "== Part 4: permanent failures are not retried =="

run 99 "$PERMANENT" -- ghcr.io/example/box latest

if [ "$(pushes)" -eq 1 ]; then
  pass "an auth failure costs exactly one attempt"
else
  fail "an auth failure costs exactly one attempt (pushes=$(pushes))"
fi

case "$OUT" in
  *"REGISTRY AUTHENTICATION FAILURE"*) pass "the auth failure prints actionable guidance" ;;
  *) fail "the auth failure prints actionable guidance" ; echo "$OUT" | sed 's/^/      /' >&2 ;;
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

if [ "$(pushes)" -eq 3 ]; then
  pass "MAX_RETRIES attempts are made before giving up"
else
  fail "MAX_RETRIES attempts are made before giving up (pushes=$(pushes))"
fi

: > "$TMP/summary.md"
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

if [ "$(pushes)" -eq 0 ]; then
  pass "misuse pushes nothing"
else
  fail "misuse pushes nothing (pushes=$(pushes))"
fi

echo ""
echo "== Part 7: every release.yml manifest step calls this script =="

# If any copy of the old inline pair survives, the defects above survive with
# it in that one job - which is exactly how ten copies drifted apart before.
#
# Comment lines are excluded: a comment that names `docker manifest inspect` -
# create-release has one, explaining why the publication check logs in to GHCR
# (issue #115) - is documentation, not a tenth divergent copy. Matching them
# would make this assertion fail for a reason it does not mean, and an
# assertion that cries wolf is the failure mode this suite exists to prevent.
LEFTOVER="$(grep -n 'docker manifest' .github/workflows/release.yml \
  | grep -v '^[0-9]*: *#' || true)"
if [ -z "$LEFTOVER" ]; then
  pass "no inline 'docker manifest' invocation remains in release.yml"
else
  fail "no inline 'docker manifest' invocation remains in release.yml"
  printf '%s\n' "$LEFTOVER" | sed 's/^/      /' >&2
fi

CALLS="$(grep -c 'create-multiarch-manifest.sh' .github/workflows/release.yml || true)"
if [ "$CALLS" -eq 10 ]; then
  pass "all ten manifest steps (five jobs x two registries) call the script"
else
  fail "all ten manifest steps call the script (found $CALLS)"
fi

echo ""
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
