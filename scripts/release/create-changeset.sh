#!/bin/bash
# Create a changeset file for manual releases
# Usage: ./scripts/release/create-changeset.sh --bump-type <patch|minor|major> [--description "Description"]
#
# This script is used by workflow_dispatch to create a changeset for manual releases

set -e

# Parse arguments
BUMP_TYPE=""
DESCRIPTION=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --bump-type)
      BUMP_TYPE="$2"
      shift 2
      ;;
    --description)
      DESCRIPTION="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Validate bump type
if [[ ! "$BUMP_TYPE" =~ ^(patch|minor|major)$ ]]; then
  echo "Usage: $0 --bump-type <patch|minor|major> [--description \"Description\"]"
  exit 1
fi

# Default description if not provided
if [ -z "$DESCRIPTION" ]; then
  DESCRIPTION="Manual $BUMP_TYPE release"
fi

# Generate random changeset name
RANDOM_ID=$(openssl rand -hex 4 2>/dev/null || head -c 8 /dev/urandom | xxd -p)
CHANGESET_FILE=".changeset/manual-release-${RANDOM_ID}.md"

# Create changeset file
mkdir -p .changeset

cat >"$CHANGESET_FILE" <<EOF
---
bump: $BUMP_TYPE
---

$DESCRIPTION
EOF

echo "Created changeset: $CHANGESET_FILE"
echo ""
cat "$CHANGESET_FILE"
