#!/usr/bin/env bash
#
# Reproducing + regression test for issue #108:
#   "We should not execute tests or any other CI/CD when only non essential
#    files like .gitkeep changes."
#
# Before the fix, scripts/ci/detect-changes.sh did not exist and the
# detect-changes job in release.yml diffed the WHOLE pull request against its
# base SHA. A trivial synchronize commit (a .gitkeep, a docs edit) therefore
# re-ran the full build/test matrix whenever any EARLIER commit in the PR had
# touched image source. This is exactly what happened on commit eaeed07 in
# PR #107 (run 27826090748 ran the whole suite, including a 32m48s dind-full
# job, for a commit that only reverted a task-details file).
#
# This test exercises the extracted script two ways:
#   1. Pure classification (CHANGED_FILES_OVERRIDE) — the should-build truth
#      table for every relevant file category.
#   2. Real git range resolution — throwaway repositories that reproduce the
#      GitHub Actions synthetic merge commit (refs/pull/N/merge) so we prove
#      that for pull_request events ONLY the PR head's latest commit decides
#      should-build, while push events still evaluate the whole pushed range.
#
# Exit non-zero on the first failed assertion.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ci/detect-changes.sh"

fail=0
pass=0

# run_detect: prints the should-build value for the current env/cwd.
#
# The script's exit status is swallowed deliberately. Under `set -euo pipefail`
# a command substitution that exits non-zero kills the whole suite on the spot,
# which is how the shallow-checkout defect below used to surface in CI: exit
# 128, no FAIL line, no clue which assertion died. An assertion must be able to
# fail and say so.
run_detect() {
  bash "$SCRIPT" 2>/dev/null | sed -n 's/^should-build=//p' | tail -n1 || true
}

# assert_build EXPECTED LABEL  (reads GITHUB_EVENT_NAME / overrides from env)
assert_build() {
  local expected="$1" label="$2" got
  got="$(run_detect || true)"
  if [ "$got" = "$expected" ]; then
    echo "  ok: $label (should-build=$got)"
    pass=$((pass + 1))
  else
    echo "  FAIL: $label — expected should-build=$expected, got=$got"
    fail=$((fail + 1))
  fi
}

# assert_flag EXPECTED_OUTPUT_LINE LABEL — asserts a specific name=value line.
# Capture first, then grep via herestring: piping into `grep -q` under
# `set -o pipefail` makes grep close the pipe early and SIGPIPE the producer,
# which would flakily fail the pipeline even on a match.
assert_flag() {
  local expected="$1" label="$2" out
  out="$(bash "$SCRIPT" 2>/dev/null)"
  if grep -qx "$expected" <<<"$out"; then
    echo "  ok: $label ($expected)"
    pass=$((pass + 1))
  else
    echo "  FAIL: $label — missing output line: $expected"
    fail=$((fail + 1))
  fi
}

echo "=== Part 1: pure classification (CHANGED_FILES_OVERRIDE) ==="

# --- Non-essential files must NOT trigger a build (the core of issue #108) ---
GITHUB_EVENT_NAME=pull_request CHANGED_FILES_OVERRIDE=".gitkeep" \
  assert_build false ".gitkeep only"

GITHUB_EVENT_NAME=pull_request CHANGED_FILES_OVERRIDE="README.md" \
  assert_build false "README.md only"

GITHUB_EVENT_NAME=pull_request CHANGED_FILES_OVERRIDE="docs/dind/USAGE.md
docs/case-studies/issue-108/CASE-STUDY.md" \
  assert_build false "docs-only changes"

GITHUB_EVENT_NAME=pull_request CHANGED_FILES_OVERRIDE="experiments/foo.sh
examples/bar.sh" \
  assert_build false "experiments/examples only"

GITHUB_EVENT_NAME=pull_request CHANGED_FILES_OVERRIDE=".changeset/some-change.md" \
  assert_build false "changeset only"

# --- Image source / build inputs MUST trigger a build ---
GITHUB_EVENT_NAME=pull_request CHANGED_FILES_OVERRIDE="Dockerfile" \
  assert_build true "Dockerfile"

GITHUB_EVENT_NAME=pull_request CHANGED_FILES_OVERRIDE="scripts/ci/detect-changes.sh" \
  assert_build true "scripts/ change"

GITHUB_EVENT_NAME=pull_request CHANGED_FILES_OVERRIDE="ubuntu/24.04/js/Dockerfile" \
  assert_build true "js image change"

GITHUB_EVENT_NAME=pull_request CHANGED_FILES_OVERRIDE="ubuntu/24.04/rust/Dockerfile" \
  assert_build true "rust image change"

GITHUB_EVENT_NAME=pull_request CHANGED_FILES_OVERRIDE="ubuntu/24.04/dind/entrypoint.sh" \
  assert_build true "dind image change"

GITHUB_EVENT_NAME=pull_request CHANGED_FILES_OVERRIDE="tests/dind/example-preload-images.sh" \
  assert_build true "dind CI test change"

GITHUB_EVENT_NAME=pull_request CHANGED_FILES_OVERRIDE=".github/workflows/release.yml" \
  assert_build true "workflow change"

GITHUB_EVENT_NAME=pull_request CHANGED_FILES_OVERRIDE="VERSION" \
  assert_build true "VERSION change"

# --- docs/dind/ must NOT trigger the dind build (issue #108 tightening) ---
GITHUB_EVENT_NAME=pull_request CHANGED_FILES_OVERRIDE="docs/dind/USAGE.md" \
  assert_flag "dind=false" "docs/dind/ does not set dind=true"

# --- Per-language flag plumbing ---
GITHUB_EVENT_NAME=pull_request CHANGED_FILES_OVERRIDE="ubuntu/24.04/go/Dockerfile" \
  assert_flag "go=true" "go flag set for go image change"

# --- Mixed: a non-essential change alongside a code change still builds ---
GITHUB_EVENT_NAME=pull_request CHANGED_FILES_OVERRIDE=".gitkeep
ubuntu/24.04/js/Dockerfile" \
  assert_build true "mixed .gitkeep + js change"

# --- workflow_dispatch always builds ---
GITHUB_EVENT_NAME=workflow_dispatch CHANGED_FILES_OVERRIDE="ubuntu/24.04/js/Dockerfile" \
  assert_build true "workflow_dispatch always builds"
# Its ambient-repository counterpart - no override, so the script has to resolve
# a real git range - is in Part 2b, where it runs against a throwaway repository
# instead of whatever history this checkout happens to have.

echo ""
echo "=== Part 2: git range resolution (synthetic merge commit) ==="

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git_quiet() { git -C "$REPO" "$@" >/dev/null 2>&1; }

# Build a repo whose layout mirrors a GitHub PR: a base branch (main) and a PR
# head branch, then a synthetic merge commit (parent1=base, parent2=PR head)
# exactly like refs/pull/N/merge.
setup_repo() {
  REPO="$TMP/$1"
  mkdir -p "$REPO"
  git_quiet init -b main
  git_quiet config user.email t@t.t
  git_quiet config user.name t
  mkdir -p "$REPO/ubuntu/24.04/js" "$REPO/docs"
  echo "base" > "$REPO/ubuntu/24.04/js/Dockerfile"
  echo "readme" > "$REPO/README.md"
  git_quiet add -A
  git_quiet commit -m "base commit"
}

# assert_repo_build EXPECTED LABEL — runs the script inside $REPO using the
# EVENT / PR_BASE_SHA / PUSH_BEFORE_SHA env vars and compares should-build.
assert_repo_build() {
  local expected="$1" label="$2" got
  got="$(cd "$REPO" && GITHUB_EVENT_NAME="$EVENT" PR_BASE_SHA="${PR_BASE_SHA:-}" PUSH_BEFORE_SHA="${PUSH_BEFORE_SHA:-}" bash "$SCRIPT" 2>/dev/null | sed -n 's/^should-build=//p' | tail -n1)"
  if [ "$got" = "$expected" ]; then
    echo "  ok: $label (should-build=$got)"
    pass=$((pass + 1))
  else
    echo "  FAIL: $label — expected should-build=$expected, got=$got"
    fail=$((fail + 1))
  fi
}

# --- PR whose latest commit is .gitkeep only, but an earlier commit changed an
#     image: per-commit detection => should NOT build. ---
setup_repo pr-trailing-gitkeep
git_quiet checkout -b prhead
echo "changed by PR" > "$REPO/ubuntu/24.04/js/Dockerfile"
git_quiet add -A && git_quiet commit -m "real image change (already tested when pushed)"
echo "# placeholder" > "$REPO/.gitkeep"
git_quiet add -A && git_quiet commit -m "add .gitkeep (trivial synchronize)"
git_quiet checkout main
git_quiet merge --no-ff prhead -m "Merge pull request"
EVENT=pull_request assert_repo_build false "PR trailing .gitkeep skips build (per-commit diff)"

# --- PR whose latest commit changes an image => should build. ---
setup_repo pr-trailing-code
git_quiet checkout -b prhead
echo "# doc" > "$REPO/docs/x.md"
git_quiet add -A && git_quiet commit -m "docs commit"
echo "changed" > "$REPO/ubuntu/24.04/js/Dockerfile"
git_quiet add -A && git_quiet commit -m "real image change as latest commit"
git_quiet checkout main
git_quiet merge --no-ff prhead -m "Merge pull request"
EVENT=pull_request assert_repo_build true "PR trailing image change builds"

# --- push event spanning code + trivial commits => whole range builds. ---
setup_repo push-range
BEFORE="$(git -C "$REPO" rev-parse HEAD)"
echo "changed" > "$REPO/ubuntu/24.04/js/Dockerfile"
git_quiet add -A && git_quiet commit -m "image change mid-range"
echo "# placeholder" > "$REPO/.gitkeep"
git_quiet add -A && git_quiet commit -m "trailing .gitkeep"
EVENT=push PUSH_BEFORE_SHA="$BEFORE" assert_repo_build true "push range with image change builds"

# --- push event that only touches docs across the whole range => no build. ---
setup_repo push-docs-only
BEFORE="$(git -C "$REPO" rev-parse HEAD)"
echo "# doc" > "$REPO/docs/y.md"
git_quiet add -A && git_quiet commit -m "docs only"
echo "# placeholder" > "$REPO/.gitkeep"
git_quiet add -A && git_quiet commit -m "trailing .gitkeep"
EVENT=push PUSH_BEFORE_SHA="$BEFORE" assert_repo_build false "push range docs-only skips build"

echo ""
echo "=== Part 2b: histories the script cannot diff (issue #115) ==="

# actions/checkout defaults to fetch-depth: 1. In that checkout HEAD~1 does not
# exist, and the script used to print `HEAD~1 HEAD` anyway, `git diff` exited
# 128, the `|| git diff --name-only HEAD~1 HEAD` fallback re-ran the identical
# failing command, and under `set -euo pipefail` the script died before writing
# a single output. This is what made `scripts / regression suites` red from the
# moment it was added: the suite ran the real script against its own shallow
# checkout of this repository.
#
# The rule the fallback has to satisfy: never under-build. With no usable range,
# classify every tracked file as changed.

# assert_repo_output EXPECTED_LINE LABEL — asserts a name=value line from a run
# inside $REPO, and that the script exited 0 while producing it.
assert_repo_output() {
  local expected="$1" label="$2" out status
  set +e
  out="$(cd "$REPO" && GITHUB_EVENT_NAME="$EVENT" bash "$SCRIPT" 2>/dev/null)"
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    echo "  FAIL: $label — the script exited $status"
    fail=$((fail + 1))
    return
  fi
  if grep -qx "$expected" <<<"$out"; then
    echo "  ok: $label ($expected)"
    pass=$((pass + 1))
  else
    echo "  FAIL: $label — expected line '$expected' in output"
    fail=$((fail + 1))
  fi
}

# --- root commit: HEAD~1 does not exist ---
setup_repo root-commit-only
EVENT=workflow_dispatch assert_repo_output "should-build=true" "workflow_dispatch on a root commit still decides"
EVENT=push assert_repo_output "ubuntu=true" "root commit classifies every tracked file rather than dying"

# --- shallow clone: the actions/checkout default ---
setup_repo shallow-source
git_quiet checkout -b prhead
echo "changed" > "$REPO/ubuntu/24.04/js/Dockerfile"
git_quiet add -A && git_quiet commit -m "image change"
SOURCE="$REPO"
REPO="$TMP/shallow-clone"
git clone --quiet --depth 1 "file://$SOURCE" "$REPO" >/dev/null 2>&1
git_quiet config user.email t@t.t
git_quiet config user.name t
if git -C "$REPO" rev-parse --verify -q "HEAD~1" >/dev/null 2>&1; then
  echo "  FAIL: the clone is not shallow — the fixture proves nothing"
  fail=$((fail + 1))
else
  echo "  ok: the fixture clone is shallow (HEAD~1 unreachable)"
  pass=$((pass + 1))
fi
EVENT=workflow_dispatch assert_repo_output "should-build=true" "workflow_dispatch survives a shallow checkout"
EVENT=push assert_repo_output "should-build=true" "a shallow push event builds rather than exiting 128"

echo ""
echo "=== Part 3: release.yml is wired to the script (regression guard) ==="

WF="$REPO_ROOT/.github/workflows/release.yml"

assert_grep() {
  local pattern="$1" label="$2"
  if grep -Eq "$pattern" "$WF"; then
    echo "  ok: $label"
    pass=$((pass + 1))
  else
    echo "  FAIL: $label — pattern not found: $pattern"
    fail=$((fail + 1))
  fi
}
assert_no_grep() {
  local pattern="$1" label="$2"
  if grep -Eq "$pattern" "$WF"; then
    echo "  FAIL: $label — unexpected pattern present: $pattern"
    fail=$((fail + 1))
  else
    echo "  ok: $label"
    pass=$((pass + 1))
  fi
}

assert_grep 'run: bash scripts/ci/detect-changes\.sh' "detect-changes job runs the script"
assert_grep 'fetch-depth: 0' "checkout uses full history (fetch-depth: 0)"
assert_grep 'should-build: \$\{\{ steps\.detect\.outputs\.should-build \}\}' "should-build output wired to steps.detect"
# The old whole-PR diff and the docs/dind trigger must be gone.
# shellcheck disable=SC2016  # literal $BASE_SHA is the grep pattern, not a var
assert_no_grep 'git diff --name-only "\$BASE_SHA" HEAD' "old whole-PR base.sha diff removed"
assert_no_grep 'docs/dind/' "docs/dind no longer triggers the dind build"

echo ""
echo "=== Summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ] || exit 1
echo "All issue #108 detect-changes assertions passed."
