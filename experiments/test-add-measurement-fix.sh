#!/usr/bin/env bash
set -euo pipefail

# Test that the python3-based add_measurement correctly appends to compact JSON
# (as produced by the outer measure-disk-space.sh via python3 json.dump)

JSON_FILE="/tmp/test-fix-measurement.json"

# Simulate what the outer script writes after 9 system components
python3 -c "
import json
data = {
    'generated_at': '',
    'total_size_mb': 0,
    'components': [
        {'name': 'Essential Tools', 'category': 'System', 'size_bytes': 0, 'size_mb': 0},
        {'name': '.NET SDK 8.0', 'category': 'Runtime', 'size_bytes': 504463360, 'size_mb': 481},
        {'name': 'C/C++ Tools (CMake, Clang, LLVM, LLD)', 'category': 'Build Tools', 'size_bytes': 58720256, 'size_mb': 56},
        {'name': 'Assembly Tools (NASM, FASM)', 'category': 'Build Tools', 'size_bytes': 3145728, 'size_mb': 3},
        {'name': 'R Language', 'category': 'Runtime', 'size_bytes': 120586240, 'size_mb': 115},
        {'name': 'Ruby Build Dependencies', 'category': 'Dependencies', 'size_bytes': 0, 'size_mb': 0},
        {'name': 'Python Build Dependencies', 'category': 'Dependencies', 'size_bytes': 41943040, 'size_mb': 40},
        {'name': 'GitHub CLI', 'category': 'Development Tools', 'size_bytes': 0, 'size_mb': 0},
        {'name': 'GitLab CLI', 'category': 'Development Tools', 'size_bytes': 28311552, 'size_mb': 27}
    ]
}
with open('/tmp/test-fix-measurement.json', 'w') as f:
    json.dump(data, f)
print('Initial JSON written (compact, single line):')
"

echo "Initial JSON:"
cat "$JSON_FILE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'Components: {len(d[\"components\"])}')"

# Now simulate the new python3-based add_measurement
add_measurement_python3() {
  local name="$1"
  local category="$2"
  local size_bytes="$3"
  local size_mb="$4"

  python3 -c "
import json, sys
with open('$JSON_FILE', 'r') as f:
    data = json.load(f)
data['components'].append({
    'name': sys.argv[1],
    'category': sys.argv[2],
    'size_bytes': int(sys.argv[3]),
    'size_mb': int(sys.argv[4])
})
with open('$JSON_FILE', 'w') as f:
    json.dump(data, f)
" "$name" "$category" "$size_bytes" "$size_mb"

  echo "[✓] Recorded: $name - ${size_mb}MB"
}

# Add box user components
add_measurement_python3 "Bun" "Runtime" 97000000 97
add_measurement_python3 "gh-setup-git-identity" "Development Tools" 4000000 4
add_measurement_python3 "glab-setup-git-identity" "Development Tools" 4000000 4
add_measurement_python3 "Deno" "Runtime" 113000000 113
add_measurement_python3 "NVM + Node.js 20" "Runtime" 219000000 219
add_measurement_python3 "Pyenv + Python (latest)" "Runtime" 370000000 370
add_measurement_python3 "Go (latest)" "Runtime" 268000000 268
add_measurement_python3 "Rust (via rustup)" "Runtime" 0 0
add_measurement_python3 "SDKMAN + Java 21" "Runtime" 552000000 552
add_measurement_python3 "Kotlin (via SDKMAN)" "Runtime" 161000000 161
add_measurement_python3 "Lean (via elan)" "Runtime" 12000000 12
add_measurement_python3 "Opam + Rocq/Coq" "Runtime" 1246000000 1246
add_measurement_python3 "Homebrew" "Package Manager" 0 0
add_measurement_python3 "PHP 8.3 (via Homebrew)" "Runtime" 52000000 52
add_measurement_python3 "Perlbrew + Perl (latest)" "Runtime" 346000000 346
add_measurement_python3 "rbenv + Ruby (latest)" "Runtime" 157000000 157
add_measurement_python3 "Swift 6.x" "Runtime" 2532000000 2532

echo ""
echo "=== Final JSON component count ==="
python3 -c "
import json
with open('$JSON_FILE') as f:
    data = json.load(f)
print(f'Component count: {len(data[\"components\"])}')
print('Components:')
for c in data['components']:
    print(f\"  - {c['name']}: {c['size_mb']}MB\")
"

COMPONENT_COUNT=$(python3 -c "import json; print(len(json.load(open('$JSON_FILE'))['components']))")
echo ""
echo "=== Validation ==="
if [ "$COMPONENT_COUNT" -ge 10 ]; then
  echo "PASS: Component count $COMPONENT_COUNT >= 10"
else
  echo "FAIL: Component count $COMPONENT_COUNT < 10"
  exit 1
fi
