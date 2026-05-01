#!/usr/bin/env bash
# Issue #84 reproduction: changeset descriptions may contain apostrophes,
# quotes, and whitespace. apply-changesets.sh must not feed that text through
# xargs, because xargs treats quotes as syntax in its default mode.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_UNDER_TEST="${ROOT}/scripts/release/apply-changesets.sh"
WORKDIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

cd "$WORKDIR"
mkdir -p .changeset
printf '1.2.3\n' > VERSION

CHANGESET_FILE=".changeset/quote test's file.md"
cat > "$CHANGESET_FILE" <<'EOF'
---
bump: patch
---

The parser must keep buildx's apostrophe, "double quotes", and
extra   whitespace without treating any of it as shell or xargs syntax.
EOF

DRY_RUN=true "$SCRIPT_UNDER_TEST" > output.log

grep -F "Processing: $CHANGESET_FILE" output.log
grep -F "New version: 1.2.4" output.log
grep -F "DRY_RUN mode: Skipping commit and push" output.log
if grep -Fq "xargs:" output.log; then
  echo "FAIL: output contains an xargs parsing error" >&2
  cat output.log >&2
  exit 1
fi
grep -Fx "1.2.4" VERSION

echo "PASS: apply-changesets handles quotes safely"
