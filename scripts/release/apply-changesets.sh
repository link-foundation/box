#!/bin/bash
# Apply changesets to bump VERSION file
# This script:
# 1. Reads all changeset files
# 2. Determines the highest bump type (major > minor > patch)
# 3. Updates the VERSION file
# 4. Deletes the processed changeset files
# 5. Commits and pushes the changes
#
# Environment variables:
#   - DRY_RUN: Set to 'true' to skip commit and push

set -e

CHANGESET_DIR=".changeset"
VERSION_FILE="VERSION"
DRY_RUN="${DRY_RUN:-false}"

echo "Applying changesets to VERSION file..."

# Get current version
if [ ! -f "$VERSION_FILE" ]; then
  echo "::error::VERSION file not found"
  exit 1
fi

CURRENT_VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')
echo "Current version: $CURRENT_VERSION"

# Parse version components
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

trim_description() {
  sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

# Find all changeset files. Use NUL-delimited paths so future changeset names
# with whitespace or shell metacharacters are still processed safely.
CHANGESETS=()
if [ -d "$CHANGESET_DIR" ]; then
  while IFS= read -r -d '' CHANGESET; do
    CHANGESETS+=("$CHANGESET")
  done < <(find "$CHANGESET_DIR" -maxdepth 1 -name "*.md" ! -name "README.md" -type f -print0 | sort -z)
fi

if [ "${#CHANGESETS[@]}" -eq 0 ]; then
  echo "No changesets found, nothing to apply"
  exit 0
fi

echo "Found changesets:"
printf '%s\n' "${CHANGESETS[@]}"

# Determine highest bump type
HIGHEST_BUMP="patch"
DESCRIPTIONS=""

for CHANGESET in "${CHANGESETS[@]}"; do
  echo ""
  echo "Processing: $CHANGESET"

  # Read bump type from changeset
  BUMP_TYPE=$(grep -E "^bump:\s*(patch|minor|major)" "$CHANGESET" | sed 's/bump:\s*//' | tr -d '[:space:]')

  if [ -z "$BUMP_TYPE" ]; then
    echo "::warning::No valid bump type in $CHANGESET, defaulting to patch"
    BUMP_TYPE="patch"
  fi

  echo "  Bump type: $BUMP_TYPE"

  # Update highest bump
  case "$BUMP_TYPE" in
    major)
      HIGHEST_BUMP="major"
      ;;
    minor)
      if [ "$HIGHEST_BUMP" != "major" ]; then
        HIGHEST_BUMP="minor"
      fi
      ;;
    patch)
      # Keep current highest
      ;;
  esac

  # Extract description (everything after the second ---)
  DESCRIPTION=$(awk '/^---$/{n++; next} n>=2' "$CHANGESET" | tr '\n' ' ' | trim_description)
  if [ -n "$DESCRIPTION" ]; then
    if [ -n "$DESCRIPTIONS" ]; then
      DESCRIPTIONS="$DESCRIPTIONS; $DESCRIPTION"
    else
      DESCRIPTIONS="$DESCRIPTION"
    fi
  fi
done

echo ""
echo "Highest bump type: $HIGHEST_BUMP"

# Calculate new version
case "$HIGHEST_BUMP" in
  major)
    MAJOR=$((MAJOR + 1))
    MINOR=0
    PATCH=0
    ;;
  minor)
    MINOR=$((MINOR + 1))
    PATCH=0
    ;;
  patch)
    PATCH=$((PATCH + 1))
    ;;
esac

NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
echo "New version: $NEW_VERSION"

# Update VERSION file
echo "$NEW_VERSION" > "$VERSION_FILE"
echo "Updated VERSION file"

# Delete processed changesets
echo ""
echo "Deleting processed changesets:"
for CHANGESET in "${CHANGESETS[@]}"; do
  echo "  Removing: $CHANGESET"
  rm -f "$CHANGESET"
done

if [ "$DRY_RUN" = "true" ]; then
  echo ""
  echo "DRY_RUN mode: Skipping commit and push"
  echo "new_version=$NEW_VERSION"
  exit 0
fi

# Configure git
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

# Commit and push
echo ""
echo "Committing version bump..."
git add -A
if [ -n "$DESCRIPTIONS" ]; then
  git commit -m "$NEW_VERSION: $DESCRIPTIONS"
else
  git commit -m "$NEW_VERSION"
fi

echo "Pushing to main..."
git push origin main

echo ""
echo "Version bump completed: $CURRENT_VERSION -> $NEW_VERSION"

# Output for GitHub Actions
if [ -n "$GITHUB_OUTPUT" ]; then
  echo "new_version=$NEW_VERSION" >> "$GITHUB_OUTPUT"
  echo "version_bumped=true" >> "$GITHUB_OUTPUT"
  echo "old_version=$CURRENT_VERSION" >> "$GITHUB_OUTPUT"
fi
