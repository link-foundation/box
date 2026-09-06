#!/usr/bin/env bash
# test-issue115-secretlint-gate.sh
#
# Issue #115, best practice #11. Pins the secretlint gate and, above all, the
# canary that makes its silence mean something.
#
# The defect this exists to prevent is a false negative that was measured, not
# imagined. The first version of the gate ran
#
#   npx --yes -p secretlint -p @secretlint/secretlint-rule-preset-recommend \
#     secretlint "**/*"
#
# against a repository with a planted AWS key and exited 0. The key was AWS's
# documentation example (AKIAIOSFODNN7EXAMPLE and its matching secret), which
# @secretlint/secretlint-rule-aws allow-lists. A scanner that reports nothing
# looks identical whether the tree is clean or the rules never loaded.
#
# Static assertions only; the live scan is the workflow's job. Set
# SECRETLINT_LIVE=1 to also run the canary here (needs network + npx).
#
# Usage: bash experiments/test-issue115-secretlint-gate.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

RUNNER="scripts/ci/run-secretlint.sh"
CONFIG=".secretlintrc.json"
WORKFLOW=".github/workflows/security.yml"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

for f in "$RUNNER" "$CONFIG" "$WORKFLOW"; do
  if [ -f "$f" ]; then
    pass "$f exists"
  else
    fail "$f is missing"
  fi
done

if [ "$FAIL" -gt 0 ]; then
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

RUNNER_SRC="$(cat "$RUNNER")"

# --- the canary ---------------------------------------------------------------

if [[ "$RUNNER_SRC" == *"CANARY_STATUS"* ]] && [[ "$RUNNER_SRC" == *'if [ "$CANARY_STATUS" -eq 0 ]; then'* ]]; then
  pass "the runner fails when the canary is NOT detected"
else
  fail "the runner does not check that secretlint found the planted key"
fi

if [[ "$RUNNER_SRC" == *"rand_alnum"* ]] && [[ "$RUNNER_SRC" == *"/dev/urandom"* ]]; then
  pass "the canary key is generated, so the scan cannot trip over the runner itself"
else
  fail "the canary is a literal; the repository scan would flag this very file"
fi

# AWS's documented example key is allow-listed by the rule. If it ever appears
# as the canary again, the gate is back to passing against a planted secret.
if grep -q 'AKIAIOSFODNN7EXAMPLE' "$RUNNER" \
   && ! grep -q 'AKIAIOSFODNN7EXAMPLE' <<< "$(grep -v '^#' "$RUNNER")"; then
  pass "the allow-listed example key appears only in the comment explaining it"
elif ! grep -q 'AKIAIOSFODNN7EXAMPLE' "$RUNNER"; then
  pass "the allow-listed example key is not used as a canary"
else
  fail "AWS's allow-listed example key is used in runner code; the canary proves nothing"
fi

if [[ "$RUNNER_SRC" == *"mktemp -d"* ]] && [[ "$RUNNER_SRC" == *"trap 'rm -rf"* ]]; then
  pass "the canary lives in a temporary directory that is cleaned up"
else
  fail "the canary is written into the working tree, or is not cleaned up"
fi

# --- pinning ------------------------------------------------------------------

VERSION="$(sed -n 's/^SECRETLINT_VERSION="\([^"]*\)".*/\1/p' "$RUNNER")"
if [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  pass "secretlint is pinned to an exact version ($VERSION)"
else
  fail "secretlint is not pinned to an exact version (got '${VERSION:-none}')"
fi

if grep -q "secretlint@\${SECRETLINT_VERSION}" "$RUNNER" \
   && grep -q "preset-recommend@\${SECRETLINT_VERSION}" "$RUNNER"; then
  pass "the rule preset is pinned to the same version as the runner"
else
  fail "the rule preset floats independently of the pinned runner"
fi

# --- configuration ------------------------------------------------------------

if grep -q 'secretlint-rule-preset-recommend' "$CONFIG"; then
  pass "$CONFIG enables the recommended rule preset"
else
  fail "$CONFIG enables no rules"
fi

if python3 -c 'import json,sys; json.load(open(".secretlintrc.json"))' 2>/dev/null; then
  pass "$CONFIG is valid JSON"
else
  fail "$CONFIG is not valid JSON; secretlint would fall back to no rules"
fi

# --- workflow wiring ----------------------------------------------------------

WORKFLOW_SRC="$(cat "$WORKFLOW")"

if [[ "$WORKFLOW_SRC" == *"bash scripts/ci/run-secretlint.sh"* ]]; then
  pass "the workflow runs the shared runner, so CI and a laptop run one command"
else
  fail "the workflow inlines its own secretlint invocation"
fi

if [[ "$WORKFLOW_SRC" == *"test-issue115-secretlint-gate.sh"* ]]; then
  pass "the workflow also runs this suite"
else
  fail "the workflow does not run this suite"
fi

for lang in javascript-typescript python actions; do
  if grep -q "$lang" "$WORKFLOW"; then
    pass "CodeQL analyses $lang"
  else
    fail "CodeQL does not analyse $lang"
  fi
done

if grep -q 'security-events: write' "$WORKFLOW"; then
  pass "the CodeQL job can upload its results"
else
  fail "CodeQL has no security-events: write permission; the upload would fail"
fi

if grep -q "cron: '0 6 \* \* 1'" "$WORKFLOW"; then
  pass "the scan runs weekly, not only on changes"
else
  fail "there is no schedule; a dependency can rot without a push"
fi

# dev/log/ is verbatim third-party source kept as issue evidence. CodeQL
# findings in it cannot be acted on, and a tool that reports what nobody can fix
# is a tool reviewers learn to skip - so it is excluded, exactly as it is for
# the shellcheck, hadolint and zizmor runners.
# (The line above deliberately does not begin with the word shellcheck: a
# comment that starts with it is parsed as a shellcheck directive, SC1073.)
CODEQL_CONFIG=".github/codeql-config.yml"
if grep -q 'config-file: .github/codeql-config.yml' "$WORKFLOW"; then
  pass "CodeQL is initialised with a config file"
else
  fail "CodeQL has no config-file; it would analyse the vendored evidence tree"
fi

if [ -f "$CODEQL_CONFIG" ] && grep -qE '^\s*-\s*dev/log\s*$' "$CODEQL_CONFIG"; then
  pass "the CodeQL config excludes dev/log"
else
  fail "$CODEQL_CONFIG does not exclude dev/log"
fi

# The languages CodeQL analyses have to exist, or the job is a green check over
# nothing - the same failure mode as the missing canary.
for pattern in '\.mjs$' '\.py$'; do
  n="$(git ls-files | grep -vE '^dev/log/' | grep -cE "$pattern")"
  if [ "$n" -gt 0 ]; then
    pass "there are $n tracked files matching $pattern for CodeQL to analyse"
  else
    fail "no tracked file matches $pattern; that CodeQL language analyses nothing"
  fi
done

# --- optional live run --------------------------------------------------------

if [ "${SECRETLINT_LIVE:-0}" = "1" ]; then
  echo "--- SECRETLINT_LIVE=1: running the gate for real ---"
  if bash "$RUNNER"; then
    pass "the live gate passes: canary detected, working tree clean"
  else
    fail "the live gate failed"
  fi
else
  echo "note: set SECRETLINT_LIVE=1 to run the real scan (needs network + npx)"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
