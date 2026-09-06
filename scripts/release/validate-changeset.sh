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

CHANGESET_DIR=".changeset"
BASE_REF="${GITHUB_BASE_REF:-main}"
HEAD_REF="${GITHUB_HEAD_REF:-}"

echo "Validating changesets for PR..."

# Skip for automated release PRs
if [[ "$HEAD_REF" == changeset-release/* ]] || [[ "$HEAD_REF" == changeset-manual-release-* ]]; then
  echo "Skipping changeset check for automated release PR"
  exit 0
fi

# Fetch base branch
git fetch origin "$BASE_REF" 2>/dev/null || true

# Get added changeset files (status 'A' for added)
ADDED_CHANGESETS=$(git diff --name-status "origin/${BASE_REF}...HEAD" 2>/dev/null \
  | grep "^A.*${CHANGESET_DIR}/.*\.md$" \
  | grep -v "README.md" \
  | awk '{print $2}')

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
echo "$ADDED_CHANGESETS"

# Validate each changeset format
for CHANGESET in $ADDED_CHANGESETS; do
  echo ""
  echo "Validating: $CHANGESET"

  if [ ! -f "$CHANGESET" ]; then
    echo "::warning::Changeset file not found: $CHANGESET"
    continue
  fi

  CONTENT=$(cat "$CHANGESET")

  # Check for valid bump type
  if ! echo "$CONTENT" | grep -qE "^bump:\s*(patch|minor|major)\s*$"; then
    echo "::error::Invalid changeset format in $CHANGESET"
    echo "Expected 'bump: patch|minor|major' in frontmatter"
    exit 1
  fi

  echo "Valid changeset format"
done

echo ""
echo "Changeset validation passed"
exit 0
