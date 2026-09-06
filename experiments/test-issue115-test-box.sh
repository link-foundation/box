#!/usr/bin/env bash
# test-issue115-test-box.sh
#
# Issue #115: four hand-maintained copies of the box acceptance checks lived in
# .github/workflows/release.yml, and they had drifted. The release smoke test on
# the *pushed* image ran 22 of the 29 checks the pre-merge full-box test ran, so
# the artifact users pull was verified less thoroughly than the candidate it was
# built from - and nothing reported it, which is precisely the false negative
# this issue is about. The full box also shipped Rocq that no job ever ran.
#
# scripts/ci/test-box.sh replaced all four. That is only an improvement if the
# one remaining copy really runs a superset of what each copy ran, so this suite
# drives it against a fake `docker` on PATH that records every invocation, and
# then asserts the workflow calls it in every place the copies used to live.
#
# Usage: bash experiments/test-issue115-test-box.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

SCRIPT="scripts/ci/test-box.sh"
WORKFLOW=".github/workflows/release.yml"
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
DOCKER_LOG="$TMP/docker.log"

# A fake docker. It records every invocation and answers the two commands whose
# *output* the script reads:
#   rustup toolchain list -> one line, so the one-toolchain assertion passes
#   node --version        -> $FAKE_NODE, so the freshness comparison can be
#                            driven both ways
# $TMP/fail-match makes any invocation whose argument list contains that string
# exit 1, to prove a failing check is not swallowed.
cat >"$BIN/docker" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
match="$(cat "$FAKE_STATE/fail-match" 2>/dev/null || true)"
if [ -n "$match" ] && [[ "$*" == *"$match"* ]]; then
  echo "fake docker: forced failure on: $*" >&2
  exit 1
fi
case "$*" in
  *"rustup toolchain list"*) echo "stable-x86_64-unknown-linux-gnu (default)" ;;
  *"node --version"*)        echo "${FAKE_NODE:-v24.9.0}" ;;
  *"rustup check"*)          echo "stable-x86_64-unknown-linux-gnu - Up to date : 1.90.0" ;;
esac
exit 0
FAKE
chmod +x "$BIN/docker"

# run ENV... -- ARGS...
# Everything before `--` is a NAME=VALUE override for this run; everything after
# it is an argument to the script under test.
run() {
  : >"$DOCKER_LOG"
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
      ${overrides[@]+"${overrides[@]}"} \
      bash "$SCRIPT" "$@" 2>&1
  )"
  STATUS=$?
}

: >"$TMP/fail-match"

echo "=== Part 1: the script exists and rejects bad input ==="

if [ -x "$SCRIPT" ]; then
  pass "$SCRIPT is executable"
else
  fail "$SCRIPT is executable"
fi

if bash -n "$SCRIPT" 2>/dev/null; then
  pass "the script parses"
else
  fail "the script parses"
fi

run --
if [ "$STATUS" -eq 2 ] && [[ "$OUT" == *"::error"*"usage"* ]]; then
  pass "no arguments exits 2 with an ::error annotation"
else
  fail "no arguments exits 2 with an ::error annotation (status=$STATUS, out=$OUT)"
fi

run -- js
if [ "$STATUS" -eq 2 ]; then
  pass "a profile without an image exits 2"
else
  fail "a profile without an image exits 2 (status=$STATUS)"
fi

run BOX_CHECK_FRESHNESS=0 -- kobol box-kobol
if [ "$STATUS" -eq 1 ] && [[ "$OUT" == *"unknown language: kobol"* ]]; then
  pass "an unknown profile fails loudly instead of passing vacuously"
else
  fail "an unknown profile fails loudly (status=$STATUS, out=$OUT)"
fi

echo
echo "=== Part 2: the full box runs every per-language box's checks ==="

# The per-language commands, recorded from the language profile itself, must all
# reappear in the full profile. This is the assertion that keeps the composed
# image from skipping a language the standalone image checks.
# Both sides are compared with the image name replaced, so that a check reads
# the same whichever box ran it - and with the docker flags kept, so that an
# offline check in one box and an online check for the same tool in the other
# read as different checks (issue #115: `lean --version` passes on a Lean-less
# image if the network is up).
normalize_invocation() {
  sed -E 's/^run //; s/ (box-[A-Za-z0-9._-]+) / <image> /; s/-e [^ ]+ //'
}

run BOX_CHECK_FRESHNESS=0 -- full box-test
FULL_LOG="$(normalize_invocation <"$DOCKER_LOG")"

for language in python go rust java kotlin ruby php perl swift lean rocq \
  cpp assembly dotnet r; do
  run BOX_CHECK_FRESHNESS=0 -- "$language" "box-$language"
  if [ "$STATUS" -ne 0 ]; then
    fail "the $language profile succeeds against the fake docker (out=$OUT)"
    continue
  fi
  missing=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    cmd="$(printf '%s\n' "$line" | normalize_invocation)"
    grep -Fqx -- "$cmd" <<<"$FULL_LOG" || missing="$missing\n    $cmd"
  done <"$DOCKER_LOG"
  if [ -z "$missing" ]; then
    pass "every $language check also runs in the full box"
  else
    fail "the full box does not run these $language checks:$(printf "%b" "$missing")"
  fi
done

echo
echo "=== Part 3: the full box keeps the checks that used to be release-only ==="

run BOX_CHECK_FRESHNESS=0 -- full box-test
for expected in \
  "node --version" "bun --version" "deno --version" \
  "gh --version" "glab --version" \
  "gh-setup-git-identity --version" "glab-setup-git-identity --version" \
  "expect -v" "Rscript --version" "dotnet --version" \
  "cat /home/box/.php-install-method" \
  "assert_single_runtime_versions"; do
  if grep -Fq -- "$expected" "$DOCKER_LOG"; then
    pass "full box runs: $expected"
  else
    fail "full box runs: $expected"
  fi
done

# Rocq ships in the full box (ubuntu/24.04/full-box/Dockerfile COPYs
# .opam from rocq-stage) but no job had ever run it before issue #115.
if grep -Fq "rocq --version" "$DOCKER_LOG"; then
  pass "full box runs the Rocq check that was missing entirely"
else
  fail "full box runs the Rocq check that was missing entirely"
fi

if grep -Fq "common.sh:/tmp/common.sh:ro" "$DOCKER_LOG"; then
  pass "full box mounts the working tree's common.sh for the invariant check"
else
  fail "full box mounts the working tree's common.sh for the invariant check"
fi

echo
echo "=== Part 4: a failing check is not swallowed ==="

echo "glab-setup-git-identity" >"$TMP/fail-match"
run BOX_CHECK_FRESHNESS=0 -- full box-test
if [ "$STATUS" -ne 0 ]; then
  pass "a failing tool check fails the run"
else
  fail "a failing tool check fails the run (status=$STATUS)"
fi
: >"$TMP/fail-match"

echo
echo "=== Part 5: freshness assertions (issue #112) ==="

# NODE_VERSION short-circuits resolve_node_lts_major in ubuntu/24.04/common.sh,
# so these two cases need no network.
run NODE_VERSION=24 FAKE_NODE=v24.9.0 -- full box-test
if [ "$STATUS" -eq 0 ]; then
  pass "a full box shipping the expected Node major passes"
else
  fail "a full box shipping the expected Node major passes (out=$OUT)"
fi

run NODE_VERSION=24 FAKE_NODE=v20.11.0 -- full box-test
if [ "$STATUS" -ne 0 ] && [[ "$OUT" == *"expected Node 24"* ]]; then
  pass "a full box shipping a stale Node major fails"
else
  fail "a full box shipping a stale Node major fails (status=$STATUS, out=$OUT)"
fi

run BOX_CHECK_FRESHNESS=0 -- full box-test
if [[ "$OUT" == *"::warning"*"BOX_CHECK_FRESHNESS=0"* ]]; then
  pass "skipping the freshness assertions is announced, not silent"
else
  fail "skipping the freshness assertions is announced, not silent"
fi

echo
echo "=== Part 6: verbose mode is opt-in ==="

run BOX_CHECK_FRESHNESS=0 -- essentials box-essentials
if [[ "$OUT" != *"[test-box]"* ]]; then
  pass "tracing is off by default"
else
  fail "tracing is off by default"
fi

run BOX_CHECK_FRESHNESS=0 BOX_VERBOSE=1 -- essentials box-essentials
if [[ "$OUT" == *"[test-box] docker run --rm box-essentials gh --version"* ]]; then
  pass "BOX_VERBOSE=1 traces each docker invocation"
else
  fail "BOX_VERBOSE=1 traces each docker invocation (out=$OUT)"
fi

echo
echo "=== Part 7: the workflow uses the script everywhere the copies were ==="

if ! grep -qE '^\s*docker run --rm (box-test|"\$\{IMAGE\}")' "$WORKFLOW"; then
  pass "no inline full-box test commands survive in the workflow"
else
  fail "inline full-box test commands survive in the workflow:
$(grep -nE '^\s*docker run --rm (box-test|"\$\{IMAGE\}")' "$WORKFLOW")"
fi

CALLS="$(grep -c 'scripts/ci/test-box.sh' "$WORKFLOW")"
if [ "$CALLS" -eq 5 ]; then
  pass "all five test steps call the shared script"
else
  fail "all five test steps call the shared script (found $CALLS)"
fi

# The pre-merge test and the released-image smoke test must ask for the same
# profile; a different profile would reintroduce the 22-of-29 subset.
FULL_PROFILE_CALLS="$(grep -c 'scripts/ci/test-box.sh full ' "$WORKFLOW")"
if [ "$FULL_PROFILE_CALLS" -eq 2 ]; then
  pass "the pre-merge full-box test and the release smoke test run the same profile"
else
  fail "the pre-merge full-box test and the release smoke test run the same profile (found $FULL_PROFILE_CALLS)"
fi

if ! grep -rq 'BOX_CHECK_FRESHNESS' .github/workflows/; then
  pass "no workflow disables the freshness assertions"
else
  fail "a workflow disables the freshness assertions:
$(grep -rn 'BOX_CHECK_FRESHNESS' .github/workflows/)"
fi

# Anti-drift: the language matrix is the source of truth for which boxes exist,
# so check_language must handle every entry in it.
MATRIX_LINE="$(grep -m1 '^        language: \[' "$WORKFLOW")"
MATRIX_LANGS="$(printf '%s\n' "$MATRIX_LINE" | sed 's/.*\[//; s/\].*//; s/,//g')"
UNHANDLED=""
for language in $MATRIX_LANGS; do
  run BOX_CHECK_FRESHNESS=0 -- "$language" "box-$language"
  [ "$STATUS" -eq 0 ] || UNHANDLED="$UNHANDLED $language"
done
if [ -z "$UNHANDLED" ]; then
  pass "every language in the build matrix has checks ($MATRIX_LANGS)"
else
  fail "these matrix languages have no checks:$UNHANDLED"
fi

echo
echo "=== Summary ==="
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
