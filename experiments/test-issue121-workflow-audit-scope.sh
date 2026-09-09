#!/usr/bin/env bash
# test-issue121-workflow-audit-scope.sh
#
# Issue #121. Two audits this repository already pays for could not see part of
# what they exist to check, so both were reporting "no findings" about files
# they never opened.
#
#   1. The zizmor job scanned `.github/workflows` only. The four composite
#      actions under `.github/actions/` had never been audited by anything, and
#      the omission was hiding a High-confidence `template-injection` in
#      dockerhub-login/action.yml:93 - `${{ inputs.registry }}` interpolated
#      straight into a `run:` block. A composite action runs inside the calling
#      job, holding the calling job's credentials, so the exclusion had it
#      exactly backwards. Reproduce against the pre-fix tree:
#        docker run --rm -v "$PWD:/repo" -w /repo \
#          ghcr.io/zizmorcore/zizmor:1.30.0 --config .github/zizmor.yml \
#          --min-confidence medium --min-severity medium .github/actions
#
#   2. `.github/zizmor.yml` declares `'*': hash-pin`, but the audits that read
#      container image references (`unpinned-images` among them) are Pedantic
#      persona only, and the job ran the default `regular` persona. So the
#      policy was never applied to `uses: docker://` or `container:` at all,
#      and `docker://rhysd/actionlint:1.7.7` - a mutable tag of a repository we
#      do not control, executed in a job that checks out the tree - passed
#      every run for as long as the policy has existed.
#
# Both are the same shape as the rest of issue #121: a check that reports
# success because it cannot reach the thing it is checking.
#
# This suite is static - no docker, no network - so it runs wherever the other
# offline suites do. The zizmor invocations themselves are exercised by CI.
#
# Usage: bash experiments/test-issue121-workflow-audit-scope.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

WORKFLOW=".github/workflows/workflows.yml"
CONFIG=".github/zizmor.yml"
LOGIN_ACTION=".github/actions/dockerhub-login/action.yml"
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

echo "=== Part 1: zizmor reads the composite actions, not just the workflows ==="

if [ -f "$WORKFLOW" ]; then
  pass "$WORKFLOW exists"
else
  fail "$WORKFLOW exists"
fi

# The scan targets are the last argument of each zizmor invocation. Requiring
# both paths on the same line is deliberate: a second `zizmor` step that only
# reads .github/actions would leave the two sets of findings on different
# failure surfaces.
ZIZMOR_TARGET_LINES="$(grep -c '^\s*\.github/workflows \.github/actions\s*$' "$WORKFLOW")"
if [ "$ZIZMOR_TARGET_LINES" -eq 2 ]; then
  pass "both zizmor passes scan .github/workflows and .github/actions"
else
  fail "both zizmor passes scan .github/workflows and .github/actions (found $ZIZMOR_TARGET_LINES such target lines, want 2)"
fi

if ! grep -qE '^\s*\.github/workflows\s*$' "$WORKFLOW"; then
  pass "no zizmor pass is scoped to .github/workflows alone"
else
  fail "no zizmor pass is scoped to .github/workflows alone"
fi

for action in .github/actions/*/action.yml; do
  if [ -f "$action" ]; then
    pass "composite action in scope: $action"
  fi
done

echo
echo "=== Part 2: the pedantic pass that makes 'hash-pin' enforceable ==="

if grep -q "'\*': hash-pin" "$CONFIG"; then
  pass "$CONFIG still declares the '*': hash-pin policy"
else
  fail "$CONFIG still declares the '*': hash-pin policy"
fi

if grep -q -- '--persona pedantic' "$WORKFLOW"; then
  pass "a zizmor pass runs the pedantic persona (unpinned-images is pedantic-only)"
else
  fail "a zizmor pass runs the pedantic persona (unpinned-images is pedantic-only)"
fi

# Pedantic without both floors is hundreds of stylistic findings; that pass
# would be reverted within a week, and the enforcement with it.
if grep -q -- '--min-severity high' "$WORKFLOW" && grep -q -- '--min-confidence high' "$WORKFLOW"; then
  pass "the pedantic pass is floored at high severity and high confidence"
else
  fail "the pedantic pass is floored at high severity and high confidence"
fi

if grep -q -- '--min-severity medium' "$WORKFLOW" && grep -q -- '--min-confidence medium' "$WORKFLOW"; then
  pass "the regular pass keeps its medium/medium floors"
else
  fail "the regular pass keeps its medium/medium floors"
fi

echo
echo "=== Part 3: every container image reference is pinned by digest ==="

# What the pedantic pass would report, asserted here too so a contributor
# without docker still sees it. `container:` is included because a job-level
# container is the same exposure as a `uses: docker://` step.
UNPINNED=0
while IFS= read -r line; do
  case "$line" in
    *@sha256:*) ;;
    *)
      echo "  unpinned: $line"
      UNPINNED=$((UNPINNED + 1))
      ;;
  esac
done < <(grep -rhnE 'uses:[[:space:]]*docker://|^[[:space:]]*image:[[:space:]]*\S+' .github/workflows .github/actions \
  | grep -vE '^[0-9]+:[[:space:]]*#' || true)

if [ "$UNPINNED" -eq 0 ]; then
  pass "no workflow or composite action references a container image by mutable tag"
else
  fail "no workflow or composite action references a container image by mutable tag ($UNPINNED found)"
fi

# The digest is only auditable if the tag it was resolved from is written down.
if grep -qE 'uses: docker://rhysd/actionlint@sha256:[0-9a-f]{64} # v[0-9]+\.[0-9]+\.[0-9]+' "$WORKFLOW"; then
  pass "the actionlint digest pin carries the version it was resolved from"
else
  fail "the actionlint digest pin carries the version it was resolved from"
fi

echo
echo "=== Part 4: the template-injection the widened scope found ==="

if [ -f "$LOGIN_ACTION" ]; then
  pass "$LOGIN_ACTION exists"
else
  fail "$LOGIN_ACTION exists"
fi

# An expansion inside `run:` is substituted before bash parses the line, so a
# value carrying a quote or `$(...)` becomes code. Reading it from the
# environment makes it data whatever it holds.
if ! awk '/^\s+run: \|/,0' "$LOGIN_ACTION" | grep -q '\${{'; then
  pass "no run: block in $LOGIN_ACTION interpolates a template expansion"
else
  fail "no run: block in $LOGIN_ACTION interpolates a template expansion"
  awk '/^\s+run: \|/,0' "$LOGIN_ACTION" | grep -n '\${{' | sed 's/^/    /'
fi

if grep -q 'REGISTRY: \${{ inputs.registry }}' "$LOGIN_ACTION"; then
  pass "the registry name reaches the script through env: REGISTRY"
else
  fail "the registry name reaches the script through env: REGISTRY"
fi

if grep -q 'cannot authenticate to \${REGISTRY}' "$LOGIN_ACTION"; then
  pass "the credential-missing error still names the registry it could not reach"
else
  fail "the credential-missing error still names the registry it could not reach"
fi

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
