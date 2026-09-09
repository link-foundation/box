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

# A digest pin freezes the check set as well as the binary, so the version it
# names is an invariant of this gate and not a detail. The floor is v1.7.11,
# the release that added `glob` - the check that reports a `paths:` entry
# beginning with `./`, which matches nothing and so leaves a workflow that
# never starts. `if-cond` (v1.7.9) and the removed runner labels (v1.7.8)
# arrived earlier and come with it.
# experiments/reproduce-issue121-actionlint-version-gap.sh measures all three
# against both versions; this only holds the floor.
PINNED_VERSION="$(sed -n 's|.*uses: docker://rhysd/actionlint@sha256:[0-9a-f]\{64\} # v\([0-9.]*\).*|\1|p' "$WORKFLOW" | head -1)"
FLOOR="1.7.11"

if [ -n "$PINNED_VERSION" ] \
  && [ "$(printf '%s\n%s\n' "$FLOOR" "$PINNED_VERSION" | sort -V | head -1)" = "$FLOOR" ]; then
  pass "the pinned actionlint ($PINNED_VERSION) is at least $FLOOR, so it can report a dead paths: filter"
else
  fail "the pinned actionlint (${PINNED_VERSION:-unreadable}) is at least $FLOOR, so it can report a dead paths: filter"
fi

# The reproduction command in the comment tells a reader how to get the same
# answer CI got. Naming a different version than the pin makes it a wrong
# answer that looks authoritative.
DOCUMENTED_VERSION="$(sed -n 's|.*docker run .*rhysd/actionlint:\([0-9.]*\) .*|\1|p' "$WORKFLOW" | head -1)"

if [ -n "$DOCUMENTED_VERSION" ] && [ "$DOCUMENTED_VERSION" = "$PINNED_VERSION" ]; then
  pass "the reproduce-locally command names the version that is pinned ($PINNED_VERSION)"
else
  fail "the reproduce-locally command names the version that is pinned (says ${DOCUMENTED_VERSION:-nothing}, pinned $PINNED_VERSION)"
fi

# Nothing else may name an actionlint version of its own: a suite that runs a
# different analyser than CI reports about a tree CI never saw.
# Comment lines are excluded: the history of the pin is worth recording, and a
# sentence about v1.7.7 does not run an analyser. What matters is a command.
STRAY="$(grep -rn 'rhysd/actionlint:[0-9]' --include='*.sh' --include='*.mjs' \
  scripts experiments 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"

if [ -z "$STRAY" ]; then
  pass "no script names an actionlint version independently of the workflow's pin"
else
  printf '%s\n' "$STRAY" | sed 's/^/  /'
  fail "no script names an actionlint version independently of the workflow's pin"
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
#
# Extracting the block is the whole difficulty, and the first spelling of this
# check got it wrong in both directions at once - see
# experiments/reproduce-issue121-awk-run-block-range.sh. It used
# `awk '/^\s+run: \|/,0'`, and:
#
#   * `\s` is a GNU extension. Under mawk - the default awk on Debian and
#     Ubuntu, and what runs in this repository's own containers - it matches
#     nothing, the range never opens, and the negated grep passes on a file
#     full of injections. One more check that could not fail, inside the branch
#     that exists to remove them.
#   * Under gawk, which is what GitHub's ubuntu-24.04 image ships, `\s` works
#     and `,0` never closes, because no record is ever numbered 0. The "run
#     block" is then the rest of the file, so every later step's `with:` and
#     `env:` mapping is reported - and passing an input to an action through
#     `with:` is not an injection. It failed CI on lines that were correct.
#
# A block scalar ends where the indentation returns to the key's level, so that
# is what bounds it here. A single-line `run:` is not a block scalar but carries
# the same exposure, so it is examined too. No GNU regex extensions.
run_block_lines() {
  awk '
    {
      if (in_block) {
        if ($0 ~ /^[ \t]*$/) { next }
        indent = match($0, /[^ \t]/) - 1
        if (indent > key_indent) { print FILENAME ":" FNR ": " $0; next }
        in_block = 0
      }
      if ($0 ~ /^[ \t]*run:[ \t]*[|>]/) {
        key_indent = match($0, /[^ \t]/) - 1
        in_block = 1
        next
      }
      if ($0 ~ /^[ \t]*run:[ \t]*[^ \t|>]/) { print FILENAME ":" FNR ": " $0 }
    }
  ' "$@"
}

# Scoped to the composite actions, not to dockerhub-login alone: a composite
# action runs inside the calling job holding the calling job's credentials, and
# all four of them are clean, so this is an invariant the repository can keep.
# The workflows are a different question - they carry 220 expansions inside
# `run:` blocks, matrix values and this repository's own step outputs, which is
# what the zizmor pass above judges at medium/medium and what §6 of the case
# study explains. Widening this assertion to them would be a rewrite, not a
# check.
INJECTED="$(run_block_lines .github/actions/*/action.yml | grep '\${{' || true)"
if [ -z "$INJECTED" ]; then
  pass "no run: block in any composite action interpolates a template expansion"
else
  fail "no run: block in any composite action interpolates a template expansion"
  echo "$INJECTED" | sed 's/^/    /'
fi

# The extractor itself must be able to report, or the assertion above is worth
# nothing - which is precisely how the first spelling passed. Feed it a fixture
# that does interpolate, and one that does not.
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT
cat >"$FIXTURE_DIR/injected.yml" <<'FIXTURE'
runs:
  using: 'composite'
  steps:
    - shell: bash
      run: |
        echo "logging in to ${{ inputs.registry }}"
    - uses: docker/login-action@v3
      with:
        registry: ${{ inputs.registry }}
FIXTURE
sed 's/{{ inputs.registry }}/{REGISTRY}/' "$FIXTURE_DIR/injected.yml" >"$FIXTURE_DIR/clean.yml"

if [ "$(run_block_lines "$FIXTURE_DIR/injected.yml" | grep -c '\${{')" = "1" ]; then
  pass "the extractor reports an expansion inside a run: block, and only that one"
else
  fail "the extractor reports an expansion inside a run: block, and only that one"
  run_block_lines "$FIXTURE_DIR/injected.yml" | sed 's/^/    /'
fi

if [ "$(run_block_lines "$FIXTURE_DIR/clean.yml" | grep -c '\${{')" = "0" ]; then
  pass "the extractor reports nothing when the value is read from the environment"
else
  fail "the extractor reports nothing when the value is read from the environment"
  run_block_lines "$FIXTURE_DIR/clean.yml" | sed 's/^/    /'
fi

# The `with:` mapping of the fixture holds an expansion the extractor must not
# reach; without this the two assertions above would also pass on an extractor
# that simply printed nothing.
if grep -q 'registry: \${{ inputs.registry }}' "$FIXTURE_DIR/injected.yml"; then
  pass "the fixture carries a with: expansion outside any run: block"
else
  fail "the fixture carries a with: expansion outside any run: block"
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
