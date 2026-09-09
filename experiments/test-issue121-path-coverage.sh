#!/usr/bin/env bash
# test-issue121-path-coverage.sh
#
# Issue #121. Fixtures for scripts/ci/check-workflow-path-coverage.mjs.
#
# The gap it closes: a `paths:` filter is the cheapest way to build a check that
# cannot fail. The job exists, the gate works, its fixtures pass — and because
# the filter matches none of the files the gate reads, the pull request that
# breaks exactly what the gate was written for never starts it. Nothing is red,
# nothing is skipped, nothing is reported: the workflow is simply absent from
# the list, which looks exactly like a clean tree.
# experiments/reproduce-issue121-workflow-trigger-gap.sh measures the instances
# that were here.
#
# Every fixture below builds a throwaway git repository, because the checker
# discovers workflows with `git ls-files` and asks each gate what it reads —
# both of which are answers about the repository it is standing in.
#
# Usage: bash experiments/test-issue121-path-coverage.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
CHECK="$ROOT/scripts/ci/check-workflow-path-coverage.mjs"

PASS=0
FAIL=0
pass() {
  PASS=$((PASS + 1))
  echo "PASS: $1"
}
fail() {
  FAIL=$((FAIL + 1))
  echo "FAIL: $1"
}

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node is not installed; this suite drives a checker written in JavaScript."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SEQ=0
LAST_OUT=""
LAST_RC=0

# Starts a fresh repository under $WORK and leaves $REPO pointing at it.
new_repo() {
  SEQ=$((SEQ + 1))
  REPO="$WORK/repo-$SEQ"
  mkdir -p "$REPO/.github/workflows" "$REPO/scripts/ci"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email fixture@example.invalid
  git -C "$REPO" config user.name fixture
}

# Writes a file, creating its directory, and stages it so `git ls-files` sees it.
put() {
  local path="$1"
  shift
  mkdir -p "$REPO/$(dirname "$path")"
  printf '%s\n' "$@" >"$REPO/$path"
  git -C "$REPO" add -f -- "$path"
}

# A gate that discovers files by extension and answers --list-inputs, which is
# the contract the checker reads. Written as a real script rather than a stub,
# because the checker executes it.
put_gate() { # put_gate <path> <glob>...
  local path="$1"
  shift
  mkdir -p "$REPO/$(dirname "$path")"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    echo 'if [ "${1:-}" = "--list-inputs" ]; then'
    printf '  git ls-files -- %s\n' "$*"
    echo '  exit 0'
    echo 'fi'
    echo 'exit 0'
  } >"$REPO/$path"
  chmod +x "$REPO/$path"
  git -C "$REPO" add -f -- "$path"
}

run_check() {
  LAST_OUT="$(cd "$REPO" && node "$CHECK" "$@" 2>&1)"
  LAST_RC=$?
}

expect_rc() {
  local want="$1" label="$2"
  if [ "$LAST_RC" -eq "$want" ]; then
    pass "$label"
  else
    fail "$label (expected exit $want, got $LAST_RC)"
    printf '%s\n' "$LAST_OUT" | sed 's/^/    /'
  fi
}

expect_mentions() {
  local needle="$1" label="$2"
  if printf '%s\n' "$LAST_OUT" | grep -qF "$needle"; then
    pass "$label"
  else
    fail "$label (output does not mention '$needle')"
    printf '%s\n' "$LAST_OUT" | sed 's/^/    /'
  fi
}

expect_silent_about() {
  local needle="$1" label="$2"
  if printf '%s\n' "$LAST_OUT" | grep -qF "$needle"; then
    fail "$label (output mentions '$needle')"
    printf '%s\n' "$LAST_OUT" | sed 's/^/    /'
  else
    pass "$label"
  fi
}

# The minimum workflow: one filtered event running one gate.
workflow() { # workflow <name> <event> <run-line> <pattern>...
  local name="$1" event="$2" run="$3"
  shift 3
  {
    echo "name: $name"
    echo 'on:'
    echo "  $event:"
    echo '    paths:'
    local pattern
    for pattern in "$@"; do
      echo "      - '$pattern'"
    done
    echo 'jobs:'
    echo '  check:'
    echo '    runs-on: ubuntu-24.04'
    echo '    steps:'
    echo "      - run: $run"
  } >"$REPO/.github/workflows/$name.yml"
  git -C "$REPO" add -f -- ".github/workflows/$name.yml"
}

echo "=== Part 1: a filter that cannot match what the gate reads is reported ==="

new_repo
put_gate scripts/ci/lint.sh "'*.mjs'"
put src/app.mjs 'export const x = 1'
workflow lint pull_request 'bash scripts/ci/lint.sh' '**.sh'
run_check
expect_rc 1 "a gate reading .mjs under a '**.sh' filter is a finding"
expect_mentions 'src/app.mjs' "and the annotation names the file that starts nothing"
expect_mentions '::error file=.github/workflows/lint.yml,line=' \
  "anchored on the workflow's paths list, with a line"

new_repo
put_gate scripts/ci/lint.sh "'*.mjs'"
put src/app.mjs 'export const x = 1'
workflow lint pull_request 'bash scripts/ci/lint.sh' '**.mjs' 'scripts/ci/lint.sh'
run_check
expect_rc 0 "widening the filter to '**.mjs' closes it"

echo ""
echo "=== Part 2: GitHub's pattern semantics, which are the whole point ==="

# '**/Dockerfile' requires a directory component, so it cannot match a root
# Dockerfile. That is not a corner case here: dockerfiles.yml carried exactly
# this filter and the root Dockerfile — the one this repository's own image is
# built from — could not start it (issue #121).
new_repo
put_gate scripts/ci/hadolint.sh "'Dockerfile' '**/Dockerfile'"
put Dockerfile 'FROM ubuntu:24.04'
put ubuntu/24.04/Dockerfile 'FROM ubuntu:24.04'
workflow docker pull_request 'bash scripts/ci/hadolint.sh' '**/Dockerfile' 'scripts/ci/hadolint.sh'
run_check
expect_rc 1 "'**/Dockerfile' does not match a root Dockerfile"
expect_mentions 'Dockerfile' "and the root Dockerfile is the file it names"
expect_silent_about 'ubuntu/24.04/Dockerfile' "while the nested one does match"

new_repo
put_gate scripts/ci/hadolint.sh "'Dockerfile' '**/Dockerfile'"
put Dockerfile 'FROM ubuntu:24.04'
put ubuntu/24.04/Dockerfile 'FROM ubuntu:24.04'
workflow docker pull_request 'bash scripts/ci/hadolint.sh' 'Dockerfile' '**/Dockerfile' 'scripts/ci/hadolint.sh'
run_check
expect_rc 0 "adding the bare 'Dockerfile' pattern covers both"

# '*' does not cross a slash; '**' does.
new_repo
put_gate scripts/ci/lint.sh "'*.sh'"
put tools/deep/run.sh 'true'
workflow lint pull_request 'bash scripts/ci/lint.sh' 'tools/*.sh' 'scripts/ci/lint.sh'
run_check
expect_rc 1 "'tools/*.sh' does not reach tools/deep/run.sh: '*' does not cross a slash"

new_repo
put_gate scripts/ci/lint.sh "'*.sh'"
put tools/deep/run.sh 'true'
workflow lint pull_request 'bash scripts/ci/lint.sh' 'tools/**' 'scripts/ci/lint.sh'
run_check
expect_rc 0 "'tools/**' does reach it"

# An extensionless hook is invisible to every '*.sh' glob, which is why
# run-shellcheck.sh and run-shfmt.sh look in .githooks/ explicitly.
new_repo
put_gate scripts/ci/lint.sh "'*.sh' '.githooks/*'"
put .githooks/pre-commit 'true'
put a.sh 'true'
workflow lint pull_request 'bash scripts/ci/lint.sh' '**.sh' 'scripts/ci/lint.sh'
run_check
expect_rc 1 "an extensionless .githooks/pre-commit is not covered by '**.sh'"
expect_mentions '.githooks/pre-commit' "and it is named"

echo ""
echo "=== Part 3: the gate script itself has to re-run its own gate ==="

new_repo
put_gate scripts/ci/lint.sh "'*.md'"
put README.md '# hi'
workflow lint pull_request 'bash scripts/ci/lint.sh' '**.md'
run_check
expect_rc 1 "editing the checker must start the workflow that runs it"
expect_mentions 'scripts/ci/lint.sh' "and the checker is what the finding names"

# A path that only ever appears in a comment is not something the workflow runs.
new_repo
put_gate scripts/ci/lint.sh "'*.md'"
put README.md '# hi'
put scripts/ci/unused.sh 'true'
{
  echo 'name: lint'
  echo 'on:'
  echo '  pull_request:'
  echo '    paths:'
  echo "      - '**.md'"
  echo "      - 'scripts/ci/lint.sh'"
  echo 'jobs:'
  echo '  check:'
  echo '    runs-on: ubuntu-24.04'
  echo '    steps:'
  echo '      # see scripts/ci/unused.sh for the older approach'
  echo '      - run: bash scripts/ci/lint.sh'
} >"$REPO/.github/workflows/lint.yml"
git -C "$REPO" add -f -- .github/workflows/lint.yml
run_check
expect_rc 0 "a script named only in a comment is not treated as run"

echo ""
echo "=== Part 4: reachability is a union, over events and over workflows ==="

# measure-disk-space spends three hours on a push and runs its cheap preflights
# on a pull request. A script only the preflight reads belongs in the
# pull_request filter alone, and that is not a hole.
new_repo
put_gate scripts/ci/lint.sh "'*.mjs'"
put src/app.mjs 'export const x = 1'
{
  echo 'name: both'
  echo 'on:'
  echo '  push:'
  echo '    paths:'
  echo "      - 'never-matches-anything.txt'"
  echo '  pull_request:'
  echo '    paths:'
  echo "      - '**.mjs'"
  echo "      - 'scripts/ci/lint.sh'"
  echo 'jobs:'
  echo '  check:'
  echo '    runs-on: ubuntu-24.04'
  echo '    steps:'
  echo '      - run: bash scripts/ci/lint.sh'
} >"$REPO/.github/workflows/both.yml"
git -C "$REPO" add -f -- .github/workflows/both.yml
run_check
expect_rc 0 "a narrow push filter is fine when pull_request covers the inputs"

# Two workflows running the same gate: between them they have to cover it.
new_repo
put_gate scripts/ci/lint.sh "'*.mjs' '*.md'"
put src/app.mjs 'export const x = 1'
put README.md '# hi'
workflow js pull_request 'bash scripts/ci/lint.sh' '**.mjs' 'scripts/ci/lint.sh'
workflow docs pull_request 'bash scripts/ci/lint.sh' '**.md' 'scripts/ci/lint.sh'
run_check
expect_rc 0 "two workflows each covering half of the inputs is covered"

new_repo
put_gate scripts/ci/lint.sh "'*.mjs' '*.md' '*.txt'"
put src/app.mjs 'export const x = 1'
put README.md '# hi'
put notes.txt 'hello'
workflow js pull_request 'bash scripts/ci/lint.sh' '**.mjs' 'scripts/ci/lint.sh'
workflow docs pull_request 'bash scripts/ci/lint.sh' '**.md' 'scripts/ci/lint.sh'
run_check
expect_rc 1 "but the file neither of them covers is still reported"
expect_mentions 'notes.txt' "and it is the one named"

echo ""
echo "=== Part 5: events that do not gate a change do not count as coverage ==="

# A workflow_dispatch is somebody remembering. A schedule is next week. Neither
# reports on the pull request that introduced the defect, which is the question.
new_repo
put_gate scripts/ci/lint.sh "'*.mjs'"
put src/app.mjs 'export const x = 1'
{
  echo 'name: manual'
  echo 'on:'
  echo '  workflow_dispatch:'
  echo '  schedule:'
  echo "    - cron: '0 0 * * 0'"
  echo '  pull_request:'
  echo '    paths:'
  echo "      - '**.sh'"
  echo 'jobs:'
  echo '  check:'
  echo '    runs-on: ubuntu-24.04'
  echo '    steps:'
  echo '      - run: bash scripts/ci/lint.sh'
} >"$REPO/.github/workflows/manual.yml"
git -C "$REPO" add -f -- .github/workflows/manual.yml
run_check
expect_rc 1 "workflow_dispatch and schedule do not make an unmatched input covered"

# No paths filter at all: every change starts it, so there is nothing to check.
new_repo
put_gate scripts/ci/lint.sh "'*.mjs'"
put src/app.mjs 'export const x = 1'
{
  echo 'name: always'
  echo 'on:'
  echo '  pull_request:'
  echo 'jobs:'
  echo '  check:'
  echo '    runs-on: ubuntu-24.04'
  echo '    steps:'
  echo '      - run: bash scripts/ci/lint.sh'
} >"$REPO/.github/workflows/always.yml"
git -C "$REPO" add -f -- .github/workflows/always.yml
run_check
expect_rc 0 "an unfiltered pull_request trigger covers everything"

echo ""
echo "=== Part 6: the discovery contract is enforced in both directions ==="

new_repo
put_gate scripts/ci/lint.sh "'*.mjs'"
put src/app.mjs 'export const x = 1'
workflow lint pull_request 'bash scripts/ci/lint.sh' '**.mjs' 'scripts/ci/lint.sh'
put scripts/ci/silent.sh '#!/usr/bin/env bash' 'git ls-files -- "*.txt"'
run_check
expect_rc 2 "a scripts/ci gate that discovers files but will not list them is 'could not run'"
expect_mentions 'scripts/ci/silent.sh' "and it is named, with the reason"

new_repo
put_gate scripts/ci/lint.sh "'*.mjs'"
put src/app.mjs 'export const x = 1'
workflow lint pull_request 'bash scripts/ci/lint.sh' '**.mjs' 'scripts/ci/lint.sh'
put_gate scripts/ci/detect-changes.sh "'*.txt'"
run_check
expect_rc 2 "an exempt script that DOES answer --list-inputs is an error too"
expect_mentions 'NO_DISCOVERY_CONTRACT' "so the exemption list cannot quietly grow to hide a gate"

new_repo
put_gate scripts/ci/lint.sh "'*.mjs'"
put src/app.mjs 'export const x = 1'
workflow lint pull_request 'bash scripts/ci/lint.sh' '**.mjs' 'scripts/ci/lint.sh'
put scripts/ci/detect-changes.sh '#!/usr/bin/env bash' 'git ls-files -- "*.txt"'
run_check
expect_rc 0 "the exempt scripts are exempt"

echo ""
echo "=== Part 7: usage and exit codes ==="

new_repo
put_gate scripts/ci/lint.sh "'*.mjs'"
put src/app.mjs 'export const x = 1'
workflow lint pull_request 'bash scripts/ci/lint.sh' '**.mjs' 'scripts/ci/lint.sh'

run_check --not-an-option
expect_rc 2 "an unknown option exits 2 (could not run), not 1 (found a problem)"

run_check --verbose
expect_rc 0 "--verbose does not change the verdict"
expect_mentions '[reach]' "and it says what it decided about each script"
expect_mentions '[contract]' "and about each script's discovery contract"

run_check --list-inputs
expect_rc 0 "--list-inputs exits 0"
if [ "$LAST_OUT" = ".github/workflows/lint.yml" ]; then
  pass "and prints the workflows it reads, one per line and nothing else"
else
  fail "--list-inputs printed something unexpected"
  printf '%s\n' "$LAST_OUT" | sed 's/^/    /'
fi

echo ""
echo "=== Part 8: the repository passes, and the gate runs in CI ==="

REAL_RC=0
REAL_OUT="$(cd "$ROOT" && node "$CHECK" 2>&1)" || REAL_RC=$?
if [ "$REAL_RC" -eq 0 ]; then
  pass "every gate in this repository can be started by every file it reads"
else
  fail "this repository does not pass its own path-coverage gate (exit $REAL_RC)"
  printf '%s\n' "$REAL_OUT" | sed 's/^/    /'
fi

REPRO_RC=0
bash "$ROOT/experiments/reproduce-issue121-workflow-trigger-gap.sh" >"$WORK/repro.log" 2>&1 || REPRO_RC=$?
if [ "$REPRO_RC" -eq 0 ]; then
  pass "the reproduction still measures the gap and confirms it is closed"
else
  fail "the reproduction exited $REPRO_RC"
  sed 's/^/    /' "$WORK/repro.log"
fi

if grep -rqF 'check-workflow-path-coverage.mjs' "$ROOT/.github/workflows"; then
  pass "check-workflow-path-coverage.mjs is called by a workflow"
else
  fail "the gate is not called by any workflow, so it checks nothing"
fi

if grep -rqF 'test-issue121-path-coverage.sh' "$ROOT/.github/workflows"; then
  pass "these fixtures run in CI too"
else
  fail "these fixtures are not called by any workflow"
fi

if grep -qF 'check-workflow-path-coverage.mjs' "$ROOT/scripts/ci/run-precommit-checks.sh"; then
  pass "and the pre-commit hook runs it before the commit exists"
else
  fail "the pre-commit hook does not run it"
fi

echo ""
echo "Passed: $PASS, Failed: $FAIL"
[ "$FAIL" -eq 0 ]
