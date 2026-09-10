#!/usr/bin/env bash
# test-issue123-log-capture-truncation.sh
#
# Issue #123: "Check for all false positives, false negatives, warnings and
# errors in CI/CD and fix them all."
#
# The false negative this suite pins is log content that is written and then
# destroyed. Four scripts captured a command's output while streaming it with
#
#   output="$(cmd 2>&1 | tee /dev/stderr)"
#
# and `/dev/stderr` is not file descriptor 2 - it is a symlink to
# /proc/self/fd/2, so `tee` *reopens* the file behind fd 2, with O_TRUNC. When
# fd 2 is a pipe, as it is inside a GitHub Actions step, nothing happens. When
# fd 2 is a regular file, everything the script wrote before that point is
# erased, and any reader tracking a byte offset in that file - which is exactly
# what scripts/ci/run-with-budget-warning.sh does while relaying a wrapped
# command's stderr - silently skips everything written after it as well.
#
# It was found by a redirect: the end-to-end part of
# test-issue123-log-command-injection.sh runs apply-changesets.sh with its
# output in a file, and the `git commit` lines it asserts on had become NUL
# bytes by the time `git-push-with-retry.sh` returned.
#
# What it asserts:
#   Part 1  the defect, minimally: `tee /dev/stderr` truncates a redirected log
#   Part 2  scripts/ci/capture-and-stream.sh does not, and keeps every property
#           the old form had - live streaming, the command's exit status, the
#           captured copy, no leftover temporary files
#   Part 3  no tracked script writes to /dev/stderr, /dev/fd/2 or
#           /proc/self/fd/2 through a tool that opens its operands
#   Part 4  end to end: git-push-with-retry.sh's own log survives its push,
#           and restoring the old form in a copy destroys it again
#
# Usage: bash experiments/test-issue123-log-capture-truncation.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

HELPER="scripts/ci/capture-and-stream.sh"

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
  return 0
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Bytes of a file, with NUL and newline made visible, so a hole is reportable.
readable() {
  od -c "$1" 2>/dev/null | head -n 20
}

# True when the file contains a NUL byte. Asked with `tr`, not `grep`, because
# a NUL cannot be put in a shell string: `$'\\x00'` is the empty string, and an
# empty pattern matches every file - an assertion that always passes.
has_nul() {
  ! LC_ALL=C tr -d '\000' <"$1" | cmp -s - "$1"
}

echo "=== Part 1: the defect - tee /dev/stderr truncates a redirected log ==="

cat >"$TMP/old-form.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "==> Pushing HEAD to origin/main (attempt 1/3)"
echo "a line on stderr that has to survive" >&2
output="$(printf 'To /tmp/remote.git\n' 2>&1 | tee /dev/stderr)"
echo "==> classified: ${#output} bytes"
EOF

bash "$TMP/old-form.sh" >"$TMP/old.log" 2>&1
OLD_STATUS=$?

if [ "$OLD_STATUS" -eq 0 ]; then
  pass "the old form runs and exits 0, so nothing reports the loss"
else
  fail "the old form runs and exits 0, so nothing reports the loss" "status $OLD_STATUS"
fi

if ! grep -q "attempt 1/3" "$TMP/old.log"; then
  pass "the old form destroyed the lines written before the tee"
else
  fail "the old form destroyed the lines written before the tee" "$(readable "$TMP/old.log")"
fi

if grep -q "To /tmp/remote.git" "$TMP/old.log"; then
  pass "what the tee itself wrote is present, which is why this looks fine"
else
  fail "what the tee itself wrote is present, which is why this looks fine" \
    "$(readable "$TMP/old.log")"
fi

# The truncation leaves the shell's own descriptor pointing past end of file,
# so the next write from the script lands at the old offset and the kernel
# fills the gap with NULs. That is what a reader sees: not a short log, a
# corrupt one.
if has_nul "$TMP/old.log"; then
  pass "and the shell's stale offset leaves a NUL hole in the middle of the log"
else
  fail "and the shell's stale offset leaves a NUL hole in the middle of the log" \
    "$(readable "$TMP/old.log")"
fi

# A pipe is what fd 2 is inside a GitHub Actions step, and there the same line
# is harmless - which is why this survived four scripts and several releases.
bash "$TMP/old-form.sh" 2>&1 | cat >"$TMP/old-piped.log"
if grep -q "attempt 1/3" "$TMP/old-piped.log" && grep -q "To /tmp/remote.git" "$TMP/old-piped.log"; then
  pass "with fd 2 on a pipe the old form loses nothing, so CI never showed it"
else
  fail "with fd 2 on a pipe the old form loses nothing, so CI never showed it" \
    "$(cat "$TMP/old-piped.log")"
fi

echo
echo "=== Part 2: capture-and-stream.sh keeps the log and the properties ==="

cat >"$TMP/new-form.sh" <<EOF
#!/bin/bash
set -euo pipefail
source "$PWD/$HELPER"
echo "==> Pushing HEAD to origin/main (attempt 1/3)"
echo "a line on stderr that has to survive" >&2
capture_and_stream printf 'To /tmp/remote.git\n'
echo "==> classified: \${#CAPTURED_OUTPUT} bytes"
EOF

bash "$TMP/new-form.sh" >"$TMP/new.log" 2>&1
NEW_STATUS=$?

if [ "$NEW_STATUS" -eq 0 ] \
  && grep -q "attempt 1/3" "$TMP/new.log" \
  && grep -q "a line on stderr that has to survive" "$TMP/new.log" \
  && grep -q "To /tmp/remote.git" "$TMP/new.log" \
  && grep -q "classified: 18 bytes" "$TMP/new.log"; then
  pass "every line survives, in order, and the output is still captured"
else
  fail "every line survives, in order, and the output is still captured" \
    "status $NEW_STATUS" "$(cat "$TMP/new.log")"
fi

if ! has_nul "$TMP/new.log"; then
  pass "no NUL hole: the caller's descriptor is never left behind"
else
  fail "no NUL hole: the caller's descriptor is never left behind" "$(readable "$TMP/new.log")"
fi

# shellcheck source=scripts/ci/capture-and-stream.sh
source "$PWD/$HELPER"

capture_and_stream bash -c 'echo out; echo err >&2; exit 7' 2>/dev/null
STATUS=$?
if [ "$STATUS" -eq 7 ]; then
  pass "the command's own exit status is returned, not the pipeline's"
else
  fail "the command's own exit status is returned, not the pipeline's" "got $STATUS"
fi

if [ "$CAPTURED_OUTPUT" = "$(printf 'out\nerr')" ]; then
  pass "stdout and stderr are merged into CAPTURED_OUTPUT, as the classifiers expect"
else
  fail "stdout and stderr are merged into CAPTURED_OUTPUT, as the classifiers expect" \
    "got [$CAPTURED_OUTPUT]"
fi

capture_and_stream true 2>/dev/null
if [ -z "$CAPTURED_OUTPUT" ]; then
  pass "a silent command captures nothing"
else
  fail "a silent command captures nothing" "got [$CAPTURED_OUTPUT]"
fi

if capture_and_stream 2>/dev/null; then
  fail "the helper refuses to run with no command"
else
  [ $? -eq 2 ] \
    && pass "the helper refuses to run with no command" \
    || fail "the helper refuses to run with no command" "wrong status"
fi

# Streaming, not buffering. A command that prints and then keeps running must
# have its first line visible in the caller's log before it exits, or a
# twenty-minute push is silent again.
(
  # shellcheck source=scripts/ci/capture-and-stream.sh
  source "$PWD/$HELPER"
  capture_and_stream bash -c 'echo first-line; sleep 5'
) >"$TMP/stream.log" 2>&1 &
STREAM_PID=$!
STREAMED=no
for _ in $(seq 1 40); do
  if grep -q "first-line" "$TMP/stream.log" 2>/dev/null; then
    STREAMED=yes
    break
  fi
  sleep 0.1
done
kill "$STREAM_PID" 2>/dev/null
wait "$STREAM_PID" 2>/dev/null

if [ "$STREAMED" = yes ]; then
  pass "output is streamed while the command is still running"
else
  fail "output is streamed while the command is still running" "$(cat "$TMP/stream.log")"
fi

BEFORE="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'capture-and-stream.*' 2>/dev/null | wc -l)"
capture_and_stream bash -c 'echo x; exit 3' >/dev/null 2>&1
AFTER="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'capture-and-stream.*' 2>/dev/null | wc -l)"
if [ "$BEFORE" -eq "$AFTER" ]; then
  pass "the temporary file is removed even when the command fails"
else
  fail "the temporary file is removed even when the command fails" "$BEFORE -> $AFTER"
fi

# The helper is sourced into scripts that run under `set -e`; a failing command
# must return to the caller rather than kill it.
cat >"$TMP/errexit.sh" <<EOF
#!/bin/bash
set -euo pipefail
source "$PWD/$HELPER"
if capture_and_stream bash -c 'exit 4'; then
  echo "unexpected success"
else
  echo "caller survived with status \$?"
fi
EOF
if bash "$TMP/errexit.sh" 2>/dev/null | grep -q "caller survived with status 4"; then
  pass "a failing command does not abort a caller running under set -e"
else
  fail "a failing command does not abort a caller running under set -e" \
    "$(bash "$TMP/errexit.sh" 2>&1)"
fi

echo
echo "=== Part 3: no tracked script reopens the caller's stderr ==="

# `tee`, `sponge` and shell redirection all open their operands; the point is
# that no tracked file names a path that resolves back to fd 2 as a *target*.
: >"$TMP/reopen-sites"
while IFS= read -r file; do
  case "$file" in
    experiments/* | dev/log/* | docs/*) continue ;;
  esac
  [ -f "$file" ] || continue
  grep -nE '(tee|sponge)[^|]*(/dev/stderr|/dev/fd/2|/proc/self/fd/2)' "$file" \
    | grep -v '^[0-9]*: *#' \
    | sed "s|^|$file:|" >>"$TMP/reopen-sites" || true
done < <(git ls-files 'scripts/*' '.github/*')

if [ ! -s "$TMP/reopen-sites" ]; then
  pass "no tracked script or workflow tees into a reopened stderr"
else
  fail "no tracked script or workflow tees into a reopened stderr" \
    "$(cat "$TMP/reopen-sites")"
fi

# The scan has to be able to see one. A checker that cannot fail is the defect
# this issue is about.
mkdir -p "$TMP/plant"
cat >"$TMP/plant/planted.sh" <<'EOF'
#!/bin/bash
output="$(some-command 2>&1 | tee /dev/stderr)"
EOF
if grep -nE '(tee|sponge)[^|]*(/dev/stderr|/dev/fd/2|/proc/self/fd/2)' "$TMP/plant/planted.sh" >/dev/null; then
  pass "the scan reports a reopened stderr when there is one"
else
  fail "the scan reports a reopened stderr when there is one"
fi

if git ls-files --error-unmatch "$HELPER" >/dev/null 2>&1; then
  pass "the helper is tracked at $HELPER"
else
  fail "the helper is tracked at $HELPER"
fi

# Every script that used the old form has to use the helper now, otherwise the
# capture was simply dropped and the classifier is reading an empty string.
MISSING=()
for script in scripts/release/git-push-with-retry.sh \
  scripts/release/docker-push-with-retry.sh \
  scripts/release/buildx-retry.sh \
  scripts/release/mirror-to-dockerhub.sh; do
  grep -q 'capture_and_stream' "$script" || MISSING+=("$script")
done
if [ "${#MISSING[@]}" -eq 0 ]; then
  pass "every script that captured while streaming uses the helper"
else
  fail "every script that captured while streaming uses the helper" "${MISSING[@]}"
fi

echo
echo "=== Part 4: git-push-with-retry.sh end to end, output in a file ==="

REPO_ROOT="$PWD"

make_repo() {
  local dir="$1"
  rm -rf "$dir"
  git init -q -b main "$dir"
  git -C "$dir" config user.name "test"
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config commit.gpgsign false
  echo "1.0.0" >"$dir/VERSION"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "fixture"
}

REPO="$TMP/repo"
make_repo "$REPO"
git init -q --bare "$TMP/remote.git"
git -C "$REPO" remote add origin "$TMP/remote.git"

(cd "$REPO" && bash "$REPO_ROOT/scripts/release/git-push-with-retry.sh" origin main 1.0.0) \
  >"$TMP/push.log" 2>&1
PUSH_STATUS=$?

if [ "$PUSH_STATUS" -eq 0 ]; then
  pass "the push succeeds against a local remote"
else
  fail "the push succeeds against a local remote" "status $PUSH_STATUS" "$(cat "$TMP/push.log")"
fi

if grep -q "Pushing HEAD to origin/main (attempt 1/3)" "$TMP/push.log" \
  && grep -q "Push succeeded" "$TMP/push.log"; then
  pass "the lines written before and after the push are both in the log"
else
  fail "the lines written before and after the push are both in the log" \
    "$(readable "$TMP/push.log")"
fi

if ! has_nul "$TMP/push.log"; then
  pass "the log has no hole where the push output was"
else
  fail "the log has no hole where the push output was" "$(readable "$TMP/push.log")"
fi

# The control: put the old form back in a copy and the same run loses the same
# lines. Without this, the three assertions above could pass on any change.
MUTANT_DIR="$TMP/mutant-scripts"
mkdir -p "$MUTANT_DIR/release" "$MUTANT_DIR/ci"
cp "$REPO_ROOT/scripts/release/"*.sh "$MUTANT_DIR/release/"
cp "$REPO_ROOT/scripts/ci/"*.sh "$MUTANT_DIR/ci/"
sed -i 's|if capture_and_stream git push "\$REMOTE" "HEAD:\$BRANCH"; then|if CAPTURED_OUTPUT="$(git push "$REMOTE" "HEAD:$BRANCH" 2>\&1 \| tee /dev/stderr)"; then|' \
  "$MUTANT_DIR/release/git-push-with-retry.sh"

if grep -q 'tee /dev/stderr' "$MUTANT_DIR/release/git-push-with-retry.sh"; then
  pass "the control restores the old form"
else
  fail "the control restores the old form" \
    "$(grep -n 'git push "\$REMOTE"' "$MUTANT_DIR/release/git-push-with-retry.sh")"
fi

MUTANT="$TMP/mutant"
make_repo "$MUTANT"
git init -q --bare "$TMP/mutant-remote.git"
git -C "$MUTANT" remote add origin "$TMP/mutant-remote.git"

(cd "$MUTANT" && bash "$MUTANT_DIR/release/git-push-with-retry.sh" origin main 1.0.0) \
  >"$TMP/mutant.log" 2>&1

if ! grep -q "Pushing HEAD to origin/main (attempt 1/3)" "$TMP/mutant.log"; then
  pass "with the old form back, the push destroys the log that preceded it"
else
  fail "with the old form back, the push destroys the log that preceded it" \
    "$(readable "$TMP/mutant.log")"
fi

echo
echo "================================================================"
echo "PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
