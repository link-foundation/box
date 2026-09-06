#!/usr/bin/env bash
# Test script to verify the sed fix for component names containing /

set -euo pipefail

echo "=== Testing sed fix for component names with forward slashes ==="
echo ""

# Test the problematic component name
COMPONENT_NAME="C/C++ Tools (CMake, Clang, LLVM, LLD)"
CATEGORY="Build Tools"
SIZE_BYTES=51908608
SIZE_MB=49

# Create test JSON
JSON_FILE=$(mktemp)
cat >"$JSON_FILE" <<'EOF'
{
  "generated_at": "",
  "total_size_mb": 0,
  "components": []
}
EOF

echo "Initial JSON:"
cat "$JSON_FILE"
echo ""

# Create new component entry
new_component="{\"name\": \"$COMPONENT_NAME\", \"category\": \"$CATEGORY\", \"size_bytes\": $SIZE_BYTES, \"size_mb\": $SIZE_MB}"

echo "Component to add: $new_component"
echo ""

# Old method (with / as delimiter) - this would fail
echo "Testing OLD method (/ delimiter) - should fail:"
if echo '{"components": []}' | sed "s/\"components\": \[\]/\"components\": [$new_component]/" 2>&1; then
  echo "OLD method unexpectedly succeeded"
else
  echo "OLD method FAILED as expected (sed error)"
fi
echo ""

# New method (with | as delimiter) - this should work
echo "Testing NEW method (| delimiter) - should succeed:"
if echo '{"components": []}' | sed "s|\"components\": \[\]|\"components\": [$new_component]|" 2>&1; then
  echo "NEW method SUCCEEDED as expected"
else
  echo "NEW method failed (unexpected!)"
  exit 1
fi
echo ""

# Full test - add component to JSON file
echo "Full test - adding component to JSON:"
current_json=$(cat "$JSON_FILE")
current_json=$(echo "$current_json" | sed "s|\"components\": \[\]|\"components\": [$new_component]|")
echo "$current_json" >"$JSON_FILE"

echo "Updated JSON:"
cat "$JSON_FILE"
echo ""

# Verify the JSON is valid
if python3 -c "import json; json.load(open('$JSON_FILE'))" 2>/dev/null; then
  echo "JSON is valid!"
else
  echo "JSON is invalid!"
  exit 1
fi

# Clean up
rm -f "$JSON_FILE"

echo ""
echo "=== All tests passed! ==="
