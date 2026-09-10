#!/bin/bash
# Check for manual VERSION file modifications in pull requests
# This script prevents manual version changes - versions should only be changed by CI/CD
#
# Environment variables (set by GitHub Actions):
#   - GITHUB_HEAD_REF: Branch name of the PR head
#   - GITHUB_BASE_REF: Branch name of the PR base (defaults to 'main')

# The comparison against the base branch goes through pr-diff-range.sh so that a
# git that cannot answer is reported rather than read as "VERSION is unchanged".
# Before issue #123 this script ran
#   VERSION_DIFF=$(git diff "origin/${BASE_REF}...HEAD" -- VERSION 2>/dev/null || echo "")
# and a range that does not resolve - no `fetch-depth: 0`, a renamed base
# branch, a failed fetch - exits 128 and prints nothing, so the check passed on
# a branch that had rewritten VERSION from 1.0.0 to 9.9.9. Measured in
# experiments/issue-123/repro-version-gate-silent-pass.sh.
# shellcheck source=scripts/release/pr-diff-range.sh
source "$(dirname "${BASH_SOURCE[0]}")/pr-diff-range.sh"

echo "Checking for manual version changes in VERSION file..."

# Skip check for automated release PRs
HEAD_REF="${GITHUB_HEAD_REF:-}"
if [[ "$HEAD_REF" == changeset-release/* ]] || [[ "$HEAD_REF" == changeset-manual-release-* ]]; then
  echo "Skipping version check for automated release PR: $HEAD_REF"
  exit 0
fi

if ! CHANGED="$(pr_changed_files -- VERSION)"; then
  exit 1
fi

if [ -n "$CHANGED" ]; then
  echo ""
  echo "::error::Manual VERSION change detected"
  echo ""
  echo "VERSION changes are prohibited in pull requests."
  echo "Versions are managed automatically by the CI/CD pipeline using changesets."
  echo ""
  echo "To request a version bump:"
  echo "  1. Create a changeset file in .changeset/ directory"
  echo "  2. Use format: bump: patch|minor|major followed by description"
  echo "  3. The release workflow will automatically bump VERSION when merged"
  echo ""
  echo "Detected change:"
  # The range resolved a moment ago, so this is a display detail and not the
  # decision - the decision was made on the name list above.
  pr_diff -- VERSION || echo "  (VERSION)"
  exit 1
fi

echo "No manual version changes detected - check passed"
exit 0
