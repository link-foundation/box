#!/usr/bin/env bash
# test-issue121-git-init-hint.sh
#
# Holds in place the fix for the advice block every job log opened with:
#
#   hint: Using 'master' as the name for the initial branch. This default branch
#   hint: name will change to "main" in Git 3.0. ...
#
# actions/checkout runs `git init` before any step of ours can run, so the only
# way to configure that git is to hand it the configuration in the environment,
# at workflow scope. experiments/reproduce-issue121-git-init-hint.sh measures
# the before-state: 19 checkouts across the downloaded run logs, 247 lines.
#
# Two failure modes are worth more than the hint itself, and both are checked
# here because both are silent:
#
#   * A `GIT_CONFIG_COUNT` that does not cover the highest `GIT_CONFIG_KEY_n`.
#     git reads exactly COUNT pairs and ignores the rest without a word, so
#     adding a second setting and forgetting the counter looks like it worked.
#   * A job- or step-level `env:` naming GIT_CONFIG_COUNT. Step env replaces
#     the workflow's rather than merging into it, so the setting would vanish
#     for that step alone.
#
# Usage: bash experiments/test-issue121-git-init-hint.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF_DIR="$ROOT/.github/workflows"
PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  echo "PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "FAIL: $1"
  [ "$#" -gt 1 ] && printf '%s\n' "$2" | sed 's/^/      /'
  return 0
}

# The workflow-scope `env:` block of a file: from a line `env:` at column 0 to
# the next line at column 0. A job-level block is indented and never matches,
# which is the point - a per-job copy would be missing from the next job added.
workflow_env_block() {
  awk '
    /^env:/ { inblock = 1; next }
    /^[^ \t]/ { inblock = 0 }
    inblock { print }
  ' "$1"
}

echo "== Part 1: the mechanism this fix relies on =="

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Without the setting: the advice, and a branch named after the old default.
# `env -u` because this repository's own environment must not decide it.
PLAIN="$(env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 \
  git init "$WORK/plain" 2>&1)"
if printf '%s\n' "$PLAIN" | grep -q "^hint: Using 'master'"; then
  pass "an unconfigured git init prints the advice block (the thing being fixed)"
else
  # Not a failure of the fix: a git that never prints it, or one already
  # configured system-wide, cannot demonstrate the before-state.
  pass "this git prints no advice block by default; the fix is still correct here"
fi

CONFIGURED="$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=init.defaultBranch GIT_CONFIG_VALUE_0=main \
  git init "$WORK/configured" 2>&1)"
if printf '%s\n' "$CONFIGURED" | grep -q '^hint:'; then
  fail "the environment did not suppress the advice" "$CONFIGURED"
else
  pass "the same command with GIT_CONFIG_* in the environment prints none"
fi

BRANCH="$(git -C "$WORK/configured" symbolic-ref --short HEAD 2>/dev/null || echo '?')"
if [ "$BRANCH" = "main" ]; then
  pass "and the repository it created is on main, not on whatever git defaults to"
else
  fail "the configured git init produced branch '$BRANCH'"
fi

# The counter is not decoration: git reads exactly GIT_CONFIG_COUNT pairs.
IGNORED="$(GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0=init.defaultBranch GIT_CONFIG_VALUE_0=main \
  GIT_CONFIG_KEY_1=user.name GIT_CONFIG_VALUE_1=ignored \
  git config --get user.name 2>/dev/null || true)"
if [ "$IGNORED" != "ignored" ]; then
  pass "a KEY_1 above the count is ignored silently - hence the check below"
else
  fail "git read a pair beyond GIT_CONFIG_COUNT; the consistency check assumes it does not"
fi

echo
echo "== Part 2: every workflow that checks out configures the git that does it =="

CHECKOUT_WORKFLOWS=()
for wf in "$WF_DIR"/*.yml; do
  grep -qE 'uses:[[:space:]]*actions/checkout' "$wf" || continue
  CHECKOUT_WORKFLOWS+=("$wf")
done

if [ "${#CHECKOUT_WORKFLOWS[@]}" -ge 10 ]; then
  pass "${#CHECKOUT_WORKFLOWS[@]} workflows check out a repository"
else
  fail "only ${#CHECKOUT_WORKFLOWS[@]} workflows appear to check out; the sweep is looking in the wrong place"
fi

for wf in "${CHECKOUT_WORKFLOWS[@]}"; do
  name="$(basename "$wf")"
  BLOCK="$(workflow_env_block "$wf")"

  if printf '%s\n' "$BLOCK" | grep -qE '^ +GIT_CONFIG_KEY_0:[[:space:]]*init\.defaultBranch$'; then
    pass "$name sets init.defaultBranch at workflow scope"
  else
    fail "$name checks out but does not configure the git that does it"
  fi

  if printf '%s\n' "$BLOCK" | grep -qE "^ +GIT_CONFIG_VALUE_0:[[:space:]]*main$"; then
    pass "$name names main, the branch this repository actually uses"
  else
    fail "$name sets init.defaultBranch to something other than main"
  fi

  # Quoted: an unquoted 1 is a YAML integer, and a workflow `env:` value has to
  # be a string. GitHub coerces it, actionlint reports it, and a reader cannot
  # tell which of the two happened at a glance.
  if printf '%s\n' "$BLOCK" | grep -qE "^ +GIT_CONFIG_COUNT:[[:space:]]*'[0-9]+'$"; then
    pass "$name quotes GIT_CONFIG_COUNT, so it is a string like every other env value"
  else
    fail "$name does not carry a quoted GIT_CONFIG_COUNT" "$(printf '%s\n' "$BLOCK" | grep GIT_CONFIG_COUNT || echo '(absent)')"
  fi

  # The counter has to cover every pair, or the ones above it are dropped in
  # silence. Checked against the highest index actually present.
  COUNT="$(printf '%s\n' "$BLOCK" | sed -nE "s/^ +GIT_CONFIG_COUNT:[[:space:]]*'?([0-9]+)'?$/\1/p" | head -1)"
  HIGHEST="$(printf '%s\n' "$BLOCK" | sed -nE 's/^ +GIT_CONFIG_KEY_([0-9]+):.*/\1/p' | sort -n | tail -1)"
  if [ -n "$COUNT" ] && [ -n "$HIGHEST" ] && [ "$COUNT" -eq $((HIGHEST + 1)) ]; then
    pass "$name's GIT_CONFIG_COUNT covers every pair it declares"
  else
    fail "$name declares keys up to index ${HIGHEST:-none} with a count of ${COUNT:-none}"
  fi

  # A step- or job-level redefinition replaces the workflow's block for that
  # scope rather than merging with it, which would drop the setting exactly
  # where somebody thought they were adding to it.
  if grep -qE '^ {4,}GIT_CONFIG_COUNT:' "$wf"; then
    fail "$name redefines GIT_CONFIG_COUNT below workflow scope, shadowing the workflow's"
  else
    pass "$name does not shadow it in a job or a step"
  fi
done

echo
echo "== Part 3: the wiring =="

if grep -rqE 'test-issue121-git-init-hint\.sh' "$WF_DIR"; then
  pass "a workflow runs this suite directly"
else
  fail "nothing in .github/workflows runs this suite"
fi

if grep -q 'test-issue121-git-init-hint.sh' "$ROOT/scripts/ci/run-experiments.sh" 2>/dev/null; then
  fail "this suite is listed in run-experiments.sh; discovery is supposed to find it"
else
  pass "and run-experiments.sh finds it by discovery, not by a list"
fi

if [ -x "$ROOT/experiments/reproduce-issue121-git-init-hint.sh" ]; then
  pass "the measurement behind it is committed and executable"
else
  fail "experiments/reproduce-issue121-git-init-hint.sh is missing or not executable"
fi

echo ""
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
