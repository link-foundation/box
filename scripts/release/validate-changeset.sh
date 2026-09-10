#!/bin/bash
# Validate changeset for CI - ensures at least one valid changeset is added by the PR
#
# Key behavior:
# - Only checks changeset files ADDED by the current PR (not pre-existing ones)
# - Uses git diff to compare PR head against base branch
# - Validates that the PR adds at least one changeset with proper format
#
# Environment variables:
#   - GITHUB_BASE_REF: Base branch name (defaults to 'main')
#   - GITHUB_HEAD_REF: Head branch name

# The paths below come from the pull request under test, and a file may be
# named `##[error]anything.md`. The runner reads that from the middle of a line
# (issue #123), so the paths are printed with command processing stopped; this
# script's own `::error::`/`::warning::` annotations stay outside the guard.
#
# pr-diff-range.sh sources run-with-commands-stopped.sh, and is itself here
# because `git diff --name-status "origin/${BASE_REF}...HEAD" 2>/dev/null` read
# a range that does not resolve as "this pull request added no changeset". That
# is the safe direction - this script fails either way - but it is the wrong
# message: it sends a contributor who did add a changeset off to add another
# one, when the truth is that the job could not see the base branch (issue
# #123).
# shellcheck source=scripts/release/pr-diff-range.sh
source "$(dirname "${BASH_SOURCE[0]}")/pr-diff-range.sh"

CHANGESET_DIR=".changeset"
HEAD_REF="${GITHUB_HEAD_REF:-}"

echo "Validating changesets for PR..."

# Skip for automated release PRs
if [[ "$HEAD_REF" == changeset-release/* ]] || [[ "$HEAD_REF" == changeset-manual-release-* ]]; then
  echo "Skipping changeset check for automated release PR"
  exit 0
fi

# Get added changeset files (status 'A' for added)
if ! CHANGED_WITH_STATUS="$(pr_changed_files_with_status)"; then
  exit 1
fi

# The repository's own changesets, and only those.
#
# `apply-changesets.sh` and `check-changesets.sh` both consume exactly
# `find .changeset -maxdepth 1 -name '*.md' ! -name README.md`, so that set is
# what this gate has to agree with: a file this gate validates but the release
# never applies is a file whose format nothing depends on.
#
# It used to match `.changeset/` *anywhere* in the path, and this branch's own
# release run is what that costs (issue #123). PR #124 commits pinned copies of
# the template repositories as evidence, so the pull request adds
#
#   dev/log/issues/123/pulls/124/templates/go/.changeset/add-changeset-workflow.md
#
# - a changeset belonging to another project, written in that project's own
# changesets format (`'go-ai-driven-development-pipeline-template': minor`, not
# `bump: patch`) - and the gate failed the release with `Invalid changeset
# format`, which is a true statement about a file that is not its subject.
# That is this issue's own defect class: a check reporting a verdict about data
# it never should have read. Every other checker in scripts/ci/ already excludes
# dev/log/ explicitly; this one had no path anchor at all, so anchoring it at
# the repository root fixes the general case rather than that one directory.
#
# Tab-separated because `git diff --name-status` separates its columns with a
# tab and a path may contain spaces; the old `awk '{print $2}'` truncated any
# path that did.
CHANGESET_PATH_REGEX="^$(printf '%s' "$CHANGESET_DIR" | sed 's/\./\\./g')/[^/]+\.md$"

ADDED_CHANGESETS=$(printf '%s\n' "$CHANGED_WITH_STATUS" \
  | awk -F'\t' '$1 ~ /^A/ { print $2 }' \
  | grep -E "$CHANGESET_PATH_REGEX" \
  | grep -v '/README\.md$' || true)

if [ -z "$ADDED_CHANGESETS" ]; then
  echo ""
  echo "::error::No changeset found"
  echo ""
  echo "This PR appears to have code changes but no changeset file."
  echo ""
  echo "Please add a changeset file to ${CHANGESET_DIR}/ directory with the format:"
  echo ""
  echo "  ---"
  echo "  bump: patch"
  echo "  ---"
  echo ""
  echo "  Description of changes"
  echo ""
  echo "Bump types: patch (bug fixes), minor (new features), major (breaking changes)"
  exit 1
fi

echo "Found added changeset(s):"
run_with_commands_stopped echo "$ADDED_CHANGESETS"

# Validate each changeset format. Read line by line rather than with
# `for CHANGESET in $ADDED_CHANGESETS`: a path is one line, not one word, and
# word-splitting `.changeset/a fix.md` produced two paths that are both absent,
# so the loop warned twice and the gate passed - a changeset whose format was
# never read, reported as validated (issue #123).
while IFS= read -r CHANGESET; do
  [ -n "$CHANGESET" ] || continue
  echo ""
  run_with_commands_stopped echo "Validating: $CHANGESET"

  # git says this pull request added the file, so it is in HEAD by construction
  # (the range is three-dot, against the merge base). Missing here means the
  # checkout and the diff disagree, and there is no content to judge - which is
  # a reason to stop, not to pass. It used to be a ::warning:: followed by
  # `continue`, i.e. the gate concluding "valid" about a file it never opened.
  if [ ! -f "$CHANGESET" ]; then
    echo "::error::Changeset file not found in the checkout: $CHANGESET"
    echo "git reports this pull request added it, so the working tree and the"
    echo "diff disagree. The format cannot be checked, so this is an error"
    echo "rather than a skip."
    exit 1
  fi

  CONTENT=$(cat "$CHANGESET")

  # Check for valid bump type
  if ! echo "$CONTENT" | grep -qE "^bump:\s*(patch|minor|major)\s*$"; then
    echo "::error::Invalid changeset format in $CHANGESET"
    echo "Expected 'bump: patch|minor|major' in frontmatter"
    exit 1
  fi

  echo "Valid changeset format"
done <<<"$ADDED_CHANGESETS"

echo ""
echo "Changeset validation passed"
exit 0
