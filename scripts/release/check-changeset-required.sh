#!/bin/bash
# Require a changeset from any pull request that changes what this repository
# ships, and validate the changeset it added.
#
# Extracted from the inline `changeset-check` step of .github/workflows/release.yml
# (issue #123). Inline it could not be run outside a workflow, and it carried
# two defects that only became visible once it could be:
#
#   1. `CODE_CHANGES=$(git diff --name-only "origin/${BASE}...HEAD" | grep -E ... || true)`
#      read a `git diff` that exits 128 as "no code changes detected, changeset
#      not required" and exited 0 - so on a checkout without `fetch-depth: 0`,
#      or with a renamed base branch, the gate passed *and* short-circuited
#      before validate-changeset.sh, the one gate that fails safe, could run.
#      Measured in experiments/issue-123/repro-version-gate-silent-pass.sh.
#      pr_changed_files reports that state as an error now.
#
#   2. `echo "$CODE_CHANGES"` printed paths taken from the pull request with the
#      runner's command processing live. A file named `##[error]anything` is a
#      workflow command anywhere in a physical line, which is this issue's
#      log-injection class; the paths go through run_with_commands_stopped now,
#      as they already did in validate-changeset.sh.
#
# Environment variables (set by GitHub Actions):
#   - GITHUB_BASE_REF: Base branch name (defaults to 'main')
#   - GITHUB_HEAD_REF: Head branch name

# shellcheck source=scripts/release/pr-diff-range.sh
source "$(dirname "${BASH_SOURCE[0]}")/pr-diff-range.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# What "changes what this repository ships" means. `.github/actions/` is here
# and was not in the inline version: the four composite actions are executed by
# every release build, so a change to one of them changes the pipeline exactly
# as a change to a workflow does. `.githooks/` is here for the same reason -
# it is the contributor-facing half of the same checks.
CODE_PATH_REGEX='^(Dockerfile|VERSION|scripts/|ubuntu/|\.github/workflows/|\.github/actions/|\.githooks/)'

HEAD_REF="${GITHUB_HEAD_REF:-}"

# Release pull requests are opened by the pipeline itself and carry the version
# bump rather than a changeset.
if [[ "$HEAD_REF" == changeset-release/* ]] || [[ "$HEAD_REF" == changeset-manual-release-* ]]; then
  echo "Skipping changeset check for release PR"
  exit 0
fi

if ! CHANGED="$(pr_changed_files)"; then
  exit 1
fi

CODE_CHANGES="$(printf '%s\n' "$CHANGED" | grep -E "$CODE_PATH_REGEX")"

if [ -z "$CODE_CHANGES" ]; then
  echo "No code changes detected, changeset not required"
  exit 0
fi

echo "Code changes detected:"
run_with_commands_stopped printf '%s\n' "$CODE_CHANGES"
echo ""

bash "${SCRIPT_DIR}/validate-changeset.sh"
