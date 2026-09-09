#!/usr/bin/env bash
# reproduce-issue121-git-init-hint.sh
#
# Every job of every workflow begins with actions/checkout, and actions/checkout
# begins with `git init`. On a runner whose git has no `init.defaultBranch`,
# that prints a thirteen-line advice block:
#
#   hint: Using 'master' as the name for the initial branch. This default branch
#   hint: name will change to "main" in Git 3.0. ...
#
# It is not an annotation, so nothing counted it, and it is not an error, so
# nothing acted on it - it is thirteen lines of "something may be wrong here"
# at the top of every job log, in jobs where nothing is wrong. Issue #121 asks
# for the warnings too.
#
# The fix cannot be a step: the first thing the first step of a job does is
# print this, so there is no step early enough to run `git config` before it.
# Configuration handed to git through the environment is read by that first
# process as well, which is what the js template does at workflow scope.
#
# This script measures both halves - the mechanism, locally and exactly, and
# the count, from the job logs downloaded for this pull request - and prints
# what the tree does about it today. It asserts nothing; it is the measurement
# behind experiments/test-issue121-git-init-hint.sh.
#
# Usage: bash experiments/reproduce-issue121-git-init-hint.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

HINT="hint: Using 'master' as the name for the initial branch"

echo "=== Part 1: the mechanism, in this git ($(git --version)) ==="
echo

# `git init` with no configured default. env -u is not enough on its own: the
# advice is suppressed by the *config*, so the fixture has to run without the
# repository's own environment too.
PLAIN="$(env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 \
  git init "$WORK/plain" 2>&1)"
PLAIN_HINTS="$(printf '%s\n' "$PLAIN" | grep -c '^hint:')"
printf '  plain `git init`                 %2d hint line(s), branch %s\n' \
  "$PLAIN_HINTS" "$(git -C "$WORK/plain" symbolic-ref --short HEAD 2>/dev/null || echo '?')"

CONFIGURED="$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=init.defaultBranch GIT_CONFIG_VALUE_0=main \
  git init "$WORK/configured" 2>&1)"
CONFIGURED_HINTS="$(printf '%s\n' "$CONFIGURED" | grep -c '^hint:')"
printf '  with GIT_CONFIG_* in the env     %2d hint line(s), branch %s\n' \
  "$CONFIGURED_HINTS" "$(git -C "$WORK/configured" symbolic-ref --short HEAD 2>/dev/null || echo '?')"

echo
echo '  The environment reaches the first git process of the job; a `git config`'
echo '  step cannot, because this is printed before any step of ours runs.'

echo
echo "=== Part 2: what the downloaded job logs actually carried ==="
echo

LOGS="$ROOT/dev/log/issues/121/pulls/122/ci-logs"
if [ -d "$LOGS" ]; then
  TOTAL=0
  FILES=0
  LINES=0
  for log in "$LOGS"/*.log.gz; do
    [ -e "$log" ] || continue
    n="$(zcat "$log" 2>/dev/null | grep -c "$HINT")"
    [ "$n" -gt 0 ] || continue
    # Count the advice lines as the runner's git printed them rather than
    # multiplying by what this machine's git prints: the block is 13 lines on
    # the runner's git and 10 on git 2.43, and the point is the log, not the
    # arithmetic.
    l="$(zcat "$log" 2>/dev/null | grep -c 'hint:')"
    FILES=$((FILES + 1))
    TOTAL=$((TOTAL + n))
    LINES=$((LINES + l))
    printf '  %-40s %2d checkout(s), %3d line(s)\n' "$(basename "$log")" "$n" "$l"
  done
  echo
  printf '  %d checkout(s) across %d downloaded run log(s), %d lines of advice.\n' \
    "$TOTAL" "$FILES" "$LINES"
else
  echo "  (no downloaded logs under dev/log/issues/121/pulls/122/ci-logs)"
fi

echo
echo "=== Part 3: what this tree declares ==="
echo

MISSING=0
CHECKOUTS=0
for wf in "$ROOT"/.github/workflows/*.yml; do
  uses="$(grep -cE 'uses:[[:space:]]*actions/checkout' "$wf")"
  [ "$uses" -gt 0 ] || continue
  CHECKOUTS=$((CHECKOUTS + uses))
  # Workflow scope only: an `env:` at column 0. A job- or step-level one would
  # have to be repeated for every job, and the next job added would not have it.
  if awk '/^env:/{inblock=1; next} /^[^ \t]/{inblock=0} inblock && /GIT_CONFIG_KEY_0:[[:space:]]*init.defaultBranch/{found=1} END{exit !found}' "$wf"; then
    printf '  OK      %-28s %d checkout(s)\n' "$(basename "$wf")" "$uses"
  else
    printf '  MISSING %-28s %d checkout(s) print the advice\n' "$(basename "$wf")" "$uses"
    MISSING=$((MISSING + 1))
  fi
done

echo
if [ "$MISSING" -eq 0 ]; then
  echo "Closed: all $CHECKOUTS checkout(s) start a git that knows what to call the branch."
else
  echo "Open: $MISSING workflow(s) still print the advice block on every job."
fi
