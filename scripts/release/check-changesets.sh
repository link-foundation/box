#!/bin/bash
# Check for pending changeset files
# Outputs: has_changesets, changeset_count to GITHUB_OUTPUT

CHANGESET_DIR=".changeset"

echo "Checking for pending changeset files..."

# Count changeset files (excluding README.md and config.json)
if [ -d "$CHANGESET_DIR" ]; then
  CHANGESET_COUNT=$(find "$CHANGESET_DIR" -maxdepth 1 -name "*.md" ! -name "README.md" -type f | wc -l)
else
  CHANGESET_COUNT=0
fi

echo "Found $CHANGESET_COUNT changeset file(s)"

# Output for GitHub Actions
if [ -n "$GITHUB_OUTPUT" ]; then
  if [ "$CHANGESET_COUNT" -gt 0 ]; then
    echo "has_changesets=true" >>"$GITHUB_OUTPUT"
  else
    echo "has_changesets=false" >>"$GITHUB_OUTPUT"
  fi
  echo "changeset_count=$CHANGESET_COUNT" >>"$GITHUB_OUTPUT"
fi

echo "has_changesets=$([ "$CHANGESET_COUNT" -gt 0 ] && echo 'true' || echo 'false')"
echo "changeset_count=$CHANGESET_COUNT"
