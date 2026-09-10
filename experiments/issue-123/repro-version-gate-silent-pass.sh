#!/usr/bin/env bash
# What the three PR gates in the release workflow answer when git cannot answer.
#
# `scripts/release/check-version.sh`, `scripts/release/validate-changeset.sh`
# and the inline `changeset-check` step of `.github/workflows/release.yml` all
# ask the same question - "what did this pull request change?" - by reading
#
#   git diff ... "origin/${BASE_REF}...HEAD"
#
# and all three discard the exit status: `2>/dev/null || echo ""`,
# `2>/dev/null | grep ...`, and `| grep -E ... || true`. A `git diff` that
# cannot resolve the range exits 128 and prints nothing, so an unanswerable
# question is read as the answer "nothing changed" - which is the *passing*
# answer for two of the three.
#
# `scripts/ci/detect-changes.sh:113-125` asks the identical question in the
# same repository and takes the opposite branch on failure ("Never under-build.
# With no usable range the safe classification is 'all of it changed'"), so this
# is not a question the repository has failed to think about - it is one answered
# two different ways in three files.
#
# This measures both halves for each gate: a fixture where the range resolves
# (the gate must fail, because the fixture is a genuine violation) and a fixture
# where it does not (what does the gate say then?).
#
# Offline, no docker, no network. Usage:
#   bash experiments/issue-123/repro-version-gate-silent-pass.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GIT_AUTHOR_NAME=box GIT_AUTHOR_EMAIL=box@example.test
export GIT_COMMITTER_NAME=box GIT_COMMITTER_EMAIL=box@example.test

# A fixture pair: an "origin" repository with VERSION 1.0.0 and a clone whose
# branch hand-edits VERSION and adds no changeset - the violation both gates
# exist to catch.
build_fixture() {
  local name="$1"
  local origin="$WORK/$name/origin" work="$WORK/$name/work"
  mkdir -p "$origin"
  git init -q --bare --initial-branch=main "$origin"

  local seed="$WORK/$name/seed"
  mkdir -p "$seed/.changeset" "$seed/scripts"
  git init -q --initial-branch=main "$seed"
  echo "1.0.0" >"$seed/VERSION"
  echo "seed" >"$seed/scripts/build.sh"
  git -C "$seed" add -A
  git -C "$seed" commit -qm "seed"
  git -C "$seed" remote add origin "$origin"
  git -C "$seed" push -q origin main

  git clone -q "$origin" "$work"
  git -C "$work" checkout -q -b feature
  echo "9.9.9" >"$work/VERSION"             # hand-edited version: violation 1
  echo "changed" >>"$work/scripts/build.sh" # code change, no changeset: violation 2
  git -C "$work" add -A
  git -C "$work" commit -qm "hand-edit the version and change code"
  printf '%s\n' "$work"
}

# Same fixture, then the local ref the gates read is removed - which is what a
# checkout without `fetch-depth: 0` and a `git fetch` that did not succeed leave
# behind. Nothing else about the working tree differs.
break_range() {
  local work="$1"
  git -C "$work" update-ref -d refs/remotes/origin/main
  git -C "$work" remote set-url origin "$WORK/no-such-remote"
}

run_gate() {
  local label="$1" work="$2" script="$3"
  local out status
  out="$(cd "$work" && GITHUB_BASE_REF=main GITHUB_HEAD_REF=feature \
    bash "$REPO_ROOT/$script" 2>&1)"
  status=$?
  printf '  %-22s exit=%-3s %s\n' "$label" "$status" \
    "$(printf '%s' "$out" | grep -Ei 'error|passed|no manual|no changeset|no code changes|Found added' | head -1)"
}

# The inline step as it stood before this branch, transcribed from
# .github/workflows/release.yml:190-207 at 1d9fb3e. It was inline shell, so it
# could not be executed from the file at all; this is the same text with the
# workflow's `${{ }}` already substituted by the env vars the step set. It lives
# here rather than in the workflow now - scripts/release/check-changeset-required.sh
# is the same logic, and is measured beside it below.
inline_changeset_check() {
  local work="$1"
  (
    cd "$work" || exit 3
    GITHUB_BASE_REF=main
    git fetch origin "$GITHUB_BASE_REF" 2>/dev/null || true
    CODE_CHANGES=$(git diff --name-only "origin/${GITHUB_BASE_REF}...HEAD" | grep -E '^(Dockerfile|scripts/|ubuntu/|\.github/workflows/)' || true)
    if [ -z "$CODE_CHANGES" ]; then
      echo "No code changes detected, changeset not required"
      exit 0
    fi
    echo "Code changes detected"
    exit 7 # stands in for "and now validate-changeset.sh runs"
  ) >/dev/null 2>&1
  printf '  %-22s exit=%-3s %s\n' "inline (before)" "$?" \
    "$( (
      cd "$work" && GITHUB_BASE_REF=main
      git fetch origin main 2>/dev/null || true
      git diff --name-only "origin/main...HEAD" 2>/dev/null | grep -cE '^(Dockerfile|scripts/|ubuntu/|\.github/workflows/)'
    )) code file(s) seen"
}

echo "=== A. the range resolves: every gate must object ==="
ok="$(build_fixture ok)"
run_gate "check-version.sh" "$ok" scripts/release/check-version.sh
run_gate "validate-changeset.sh" "$ok" scripts/release/validate-changeset.sh
inline_changeset_check "$ok"
run_gate "changeset-required.sh" "$ok" scripts/release/check-changeset-required.sh

echo
echo "=== B. the range does not resolve: what does each gate say? ==="
broken="$(build_fixture broken)"
break_range "$broken"
echo "  (git diff origin/main...HEAD exits $(
  (cd "$broken" && git diff --name-only 'origin/main...HEAD' >/dev/null 2>&1)
  echo $?
) here)"
run_gate "check-version.sh" "$broken" scripts/release/check-version.sh
run_gate "validate-changeset.sh" "$broken" scripts/release/validate-changeset.sh
inline_changeset_check "$broken"
run_gate "changeset-required.sh" "$broken" scripts/release/check-changeset-required.sh

echo
echo "=== C. the same question, asked by scripts/ci/detect-changes.sh ==="
# Its range never resolves in the fixture below - a root commit has no HEAD~1,
# no HEAD^2 and no PR_BASE_SHA - which is the same "git cannot tell me" state
# section B put the two gates in.
root="$WORK/root"
mkdir -p "$root/scripts"
git init -q --initial-branch=main "$root"
echo seed >"$root/scripts/build.sh"
git -C "$root" add -A
git -C "$root" commit -qm root
out="$(cd "$root" && GITHUB_EVENT_NAME=pull_request \
  bash "$REPO_ROOT/scripts/ci/detect-changes.sh" 2>&1)"
printf '  %-22s %s\n' "no range at all" \
  "$(printf '%s' "$out" | grep -E 'falling back' | head -1)"
printf '  %-22s %s\n' "" \
  "$(printf '%s' "$out" | grep -E '^scripts=|^build_all=|scripts:' | head -1)"
