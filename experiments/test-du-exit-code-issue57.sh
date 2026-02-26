#!/usr/bin/env bash
# Reproducer for Issue #57: `du` exit code regression under `set -euo pipefail`
#
# This script demonstrates the root cause: `du -sb` on a non-existent path
# returns exit code 1, which propagates through command substitution `$()` and
# kills a `set -euo pipefail` script even when stderr is redirected to /dev/null.
#
# See: docs/case-studies/issue-57/CASE-STUDY.md

set -o nounset

echo "=== Test 1: du fails on non-existent path ==="
if bash -c 'set -euo pipefail
result=$(du -sb /tmp/nonexistent_issue57_dir 2>/dev/null | awk "{sum+=\$1} END{print sum+0}")
echo "Result: $result"
echo "ERROR: Script should have exited before reaching here"'; then
  echo "UNEXPECTED SUCCESS"
else
  echo "CONFIRMED: Script exited with code $? (expected 1)"
fi

echo ""
echo "=== Test 2: Fixed version — check path exists first ==="
bash -c 'set -euo pipefail
existing_dir=$(mktemp -d /tmp/issue57-test-XXXXXX)

du_paths=()
[[ -d /tmp/nonexistent_issue57_dir ]] && du_paths+=(/tmp/nonexistent_issue57_dir)
[[ -d "$existing_dir" ]] && du_paths+=("$existing_dir")  # existing dir

if [[ ${#du_paths[@]} -gt 0 ]]; then
  result=$(du -sb "${du_paths[@]}" 2>/dev/null | awk "{sum+=\$1} END{print sum+0}")
else
  result=0
fi
rmdir "$existing_dir"
echo "Result: ${result} bytes (only existing paths measured)"
echo "SUCCESS: Script completed without error"'

echo ""
echo "=== Test 3: Demonstrate that 2>/dev/null suppresses error message but not exit code ==="
tmpdir=$(mktemp -d)
echo "Attempting: du -sb $tmpdir /tmp/nonexistent_issue57_dir 2>/dev/null"
du_output=$(du -sb "$tmpdir" /tmp/nonexistent_issue57_dir 2>/dev/null || echo "EXIT_CODE_$?")
echo "Output: $du_output"
rmdir "$tmpdir"

echo ""
echo "=== All tests complete ==="
