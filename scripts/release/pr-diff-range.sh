#!/usr/bin/env bash
# pr-diff-range.sh
#
# "What did this pull request change?", asked so that a git that cannot answer
# is not mistaken for the answer "nothing".
#
# Why this exists (issue #123)
# ----------------------------
#
# Three gates in the release workflow asked that question by reading
#
#   git diff --name-only "origin/${GITHUB_BASE_REF}...HEAD"
#
# and discarding the exit status - `2>/dev/null || echo ""` in
# check-version.sh, `2>/dev/null | grep` in validate-changeset.sh, and
# `| grep -E ... || true` in release.yml's inline changeset-check step. `git
# diff` exits 128 and prints nothing when the range does not resolve, which is
# what a checkout without `fetch-depth: 0`, a deleted or renamed base branch,
# or a failed `git fetch` leaves behind. Two of the three then reported the
# passing answer: measured in experiments/issue-123/repro-version-gate-silent-pass.sh,
# a fixture whose branch rewrites VERSION from 1.0.0 to 9.9.9 and changes a
# script with no changeset comes out as
#
#   check-version.sh       exit=0   No manual version changes detected - check passed
#   inline changeset-check exit=0   No code changes detected, changeset not required
#
# once refs/remotes/origin/main is removed and nothing else is touched.
#
# The same question is asked a fourth time in this repository, by
# scripts/ci/detect-changes.sh, and there it is already answered correctly:
# "Never under-build. With no usable range the safe classification is 'all of
# it changed'". So this is not a question the repository failed to think about
# - it is one that was answered two different ways in four files. This helper
# is the one answer: a range that will not resolve is an error with a name, and
# the caller never sees an empty list it cannot distinguish from a real one.
#
# Usage (sourced):
#   source "$(dirname "${BASH_SOURCE[0]}")/pr-diff-range.sh"
#   if ! files="$(pr_changed_files -- VERSION)"; then exit 1; fi
#
# `pr_changed_files` prints the changed paths on stdout, one per line, and
# returns 0. On failure it prints an ::error:: annotation naming the cause and
# returns 1, so `if ! files=...` is the only correct way to call it.
#
# Environment:
#   PR_DIFF_RANGE_VERBOSE=1   trace the range this helper resolved  (default: off)
#   BOX_VERBOSE=1             the same switch, repository-wide      (default: off)
#
# The failure path already says everything it can. The trace is about the path
# that *succeeds*: issue #123's three gates were silent about which base ref they
# read, whether the ref had to be fetched, and how many files came back, so a
# wrong answer looked exactly like a right one in the log and finding out cost a
# re-run. With the switch on, every answer carries the range it was computed
# from. Off by default, because it belongs on stderr of a passing check only when
# someone is asking.

# shellcheck source=scripts/ci/run-with-commands-stopped.sh
source "$(dirname "${BASH_SOURCE[0]}")/../ci/run-with-commands-stopped.sh"

PR_DIFF_RANGE_VERBOSE="${PR_DIFF_RANGE_VERBOSE:-${BOX_VERBOSE:-0}}"

# Traces go to stderr, for the same reason the error annotation does: every
# caller reads this file's stdout through a command substitution, so a trace on
# stdout would be captured as part of the answer - a file list with a diagnostic
# line in it, which is a worse failure than the one this helper exists to fix.
pr_trace() {
  [ "$PR_DIFF_RANGE_VERBOSE" = "1" ] || return 0
  # Branch names and git's output are not text this repository writes, and `##[`
  # anywhere in a physical line is a command to the runner.
  run_with_commands_stopped printf '[pr-diff-range] %s\n' "$*" >&2
}

# The base branch of the pull request. `main` is the historical default of both
# callers and is kept: every caller runs only on `pull_request`, where the runner
# always sets GITHUB_BASE_REF, so the fallback is reached only outside CI.
pr_base_ref() {
  printf '%s' "${GITHUB_BASE_REF:-main}"
}

# Make refs/remotes/origin/<base> readable. Returns 0 when it already is - which
# is the normal case, because every job running these gates checks out with
# `fetch-depth: 0` - and otherwise fetches exactly that branch. The output of a
# failed fetch is kept in PR_DIFF_RANGE_DIAGNOSTIC rather than sent to
# /dev/null, because it is the only text that says *why*.
pr_ensure_base_ref() {
  local base="$1" out
  PR_DIFF_RANGE_DIAGNOSTIC=''

  if git rev-parse --verify -q "refs/remotes/origin/${base}^{commit}" >/dev/null 2>&1; then
    pr_trace "origin/${base} already present at $(git rev-parse --short "refs/remotes/origin/${base}" 2>/dev/null)"
    return 0
  fi

  pr_trace "origin/${base} is not in this checkout; fetching just that branch"
  if out="$(git fetch --no-tags origin "+refs/heads/${base}:refs/remotes/origin/${base}" 2>&1)"; then
    if git rev-parse --verify -q "refs/remotes/origin/${base}^{commit}" >/dev/null 2>&1; then
      pr_trace "fetched origin/${base} at $(git rev-parse --short "refs/remotes/origin/${base}" 2>/dev/null)"
      return 0
    fi
    out="git fetch reported success but refs/remotes/origin/${base} still does not resolve"
  fi

  PR_DIFF_RANGE_DIAGNOSTIC="$out"
  return 1
}

# The annotation a caller gets instead of a wrong answer. Callers redirect it to
# stderr, because every one of them reads this file's stdout through a command
# substitution - an error message printed to stdout would be captured as the
# answer instead of shown, which is how the first draft of this helper managed
# to exit 1 and print nothing at all. The runner parses workflow commands on
# both streams, so the annotation still arrives.
#
# The base ref and git's
# own output are printed with workflow-command processing stopped: a branch name
# is text this repository does not write, and `##[` anywhere in a physical line
# is a command to the runner (this issue's log-injection class).
pr_range_error() {
  local base="$1"
  echo "::error::Cannot compare this pull request against its base branch"
  echo ""
  echo "The check below needs the diff between the base branch and this pull"
  echo "request, and git could not produce it. Passing the check on an answer"
  echo "git did not give would hide exactly what it exists to catch, so this is"
  echo "an error rather than a skip."
  echo ""
  echo "Usual cause: the job checked out without 'fetch-depth: 0', so"
  echo "origin/<base> is not in the local repository. Other causes: the base"
  echo "branch was renamed or deleted while the pull request was open, or the"
  echo "fetch itself failed."
  echo ""
  run_with_commands_stopped echo "  base branch: ${base}"
  if [ -n "${PR_DIFF_RANGE_DIAGNOSTIC:-}" ]; then
    echo "  git said:"
    run_with_commands_stopped sed 's/^/    /' <<<"${PR_DIFF_RANGE_DIAGNOSTIC}"
  fi
}

# Print the files this pull request changed, restricted to the pathspecs given
# after `--` (all files when none are). Returns 1, having printed the
# annotation, when the range does not resolve.
pr_changed_files() {
  local base out status
  base="$(pr_base_ref)"

  if ! pr_ensure_base_ref "$base"; then
    pr_range_error "$base" >&2
    return 1
  fi

  # Two-dot would report changes the base branch made since the branch point as
  # if this pull request had made them; three-dot is the diff against the merge
  # base, which is what every caller means. It is also the form that fails when
  # no merge base exists, which is a state a gate must not treat as "clean".
  pr_trace "range origin/${base}...HEAD merge-base $(git merge-base "origin/${base}" HEAD 2>/dev/null) pathspec ${*:-<all>}"

  out="$(git diff --name-only "origin/${base}...HEAD" "$@" 2>&1)"
  status=$?

  if [ "$status" -ne 0 ]; then
    PR_DIFF_RANGE_DIAGNOSTIC="$out"
    pr_range_error "$base" >&2
    return 1
  fi

  if [ -n "$out" ]; then
    pr_trace "$(printf '%s\n' "$out" | wc -l) path(s) changed"
    printf '%s\n' "$out"
  else
    pr_trace "0 path(s) changed - and git said so, which is the whole point"
  fi
  return 0
}

# Same range, `--name-status` instead of `--name-only`, for the caller that
# needs to tell an added file from a modified one.
pr_changed_files_with_status() {
  local base out status
  base="$(pr_base_ref)"

  if ! pr_ensure_base_ref "$base"; then
    pr_range_error "$base" >&2
    return 1
  fi

  pr_trace "range origin/${base}...HEAD merge-base $(git merge-base "origin/${base}" HEAD 2>/dev/null) pathspec ${*:-<all>}"

  out="$(git diff --name-status "origin/${base}...HEAD" "$@" 2>&1)"
  status=$?

  if [ "$status" -ne 0 ]; then
    PR_DIFF_RANGE_DIAGNOSTIC="$out"
    pr_range_error "$base" >&2
    return 1
  fi

  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# Print the patch this pull request made to the pathspecs given after `--`.
# Display only, and the only function here that may answer with silence: every
# caller reaches it after one of the two above has already decided, so a git
# that cannot answer here costs the reader a hunk and not the check its verdict.
pr_diff() {
  local base
  base="$(pr_base_ref)"
  git diff "origin/${base}...HEAD" "$@" 2>/dev/null
}
