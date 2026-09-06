#!/usr/bin/env bash
set -euo pipefail

# Test script to verify JSON manipulation functions work correctly
# with component names containing special characters like C/C++

JSON_OUTPUT_FILE="/tmp/test-disk-space-measurements.json"

# Initialize JSON
cat >"$JSON_OUTPUT_FILE" <<'EOF'
{
  "generated_at": "",
  "total_size_mb": 0,
  "components": []
}
EOF

echo "=== Initial JSON ==="
cat "$JSON_OUTPUT_FILE"
echo ""

# Add component measurement (same function from measure-disk-space.sh)
add_measurement() {
  local name="$1"
  local category="$2"
  local size_bytes="$3"
  local size_mb="$4"

  python3 -c "
import json, sys
with open('$JSON_OUTPUT_FILE', 'r') as f:
    data = json.load(f)
data['components'].append({
    'name': sys.argv[1],
    'category': sys.argv[2],
    'size_bytes': int(sys.argv[3]),
    'size_mb': int(sys.argv[4])
})
with open('$JSON_OUTPUT_FILE', 'w') as f:
    json.dump(data, f)
" "$name" "$category" "$size_bytes" "$size_mb"

  echo "[✓] Recorded: $name - ${size_mb}MB"
}

# Finalize JSON
finalize_json_output() {
  local total_mb="$1"

  python3 -c "
import json
from datetime import datetime, timezone
with open('$JSON_OUTPUT_FILE', 'r') as f:
    data = json.load(f)
data['generated_at'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
data['total_size_mb'] = int('$total_mb')
with open('$JSON_OUTPUT_FILE', 'w') as f:
    json.dump(data, f)
"

  echo "[✓] Finalized JSON output with total: ${total_mb}MB"
}

# Test with various component names including special characters
echo "=== Adding components ==="
add_measurement "Essential Tools" "System" 737280 0
add_measurement ".NET SDK 8.0" "Runtime" 504913920 481
add_measurement "C/C++ Tools (CMake, Clang, LLVM, LLD)" "Build Tools" 52428800 50
add_measurement "Assembly Tools (NASM, FASM)" "Build Tools" 10485760 10
add_measurement "R Language" "Runtime" 314572800 300
add_measurement "NVM + Node.js 20" "Runtime" 209715200 200
add_measurement "Pyenv + Python (latest)" "Runtime" 524288000 500
add_measurement "Go (latest)" "Runtime" 524288000 500
add_measurement "Rust (via rustup)" "Runtime" 1073741824 1024
add_measurement "SDKMAN + Java 21" "Runtime" 419430400 400
add_measurement "Kotlin (via SDKMAN)" "Runtime" 104857600 100
add_measurement "Homebrew" "Package Manager" 524288000 500
add_measurement "PHP 8.3 (via Homebrew)" "Runtime" 209715200 200

# Finalize
echo ""
echo "=== Finalizing ==="
finalize_json_output 4265

echo ""
echo "=== Final JSON ==="
python3 -m json.tool "$JSON_OUTPUT_FILE"

echo ""
echo "=== Validation ==="
TOTAL=$(python3 -c "import json; print(json.load(open('$JSON_OUTPUT_FILE'))['total_size_mb'])")
COUNT=$(python3 -c "import json; print(len(json.load(open('$JSON_OUTPUT_FILE'))['components']))")
echo "Total size: ${TOTAL}MB"
echo "Component count: ${COUNT}"

if [ "$TOTAL" -ge 1000 ] && [ "$COUNT" -ge 10 ]; then
  echo "[✓] PASS: Measurements valid (total >= 1000MB, components >= 10)"
else
  echo "[✗] FAIL: Measurements invalid"
  exit 1
fi

# Cleanup
rm -f "$JSON_OUTPUT_FILE"
echo ""
echo "=== All tests passed ==="
