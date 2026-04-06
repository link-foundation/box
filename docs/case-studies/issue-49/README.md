# Case Study: Failing CI/CD — Component Count Below Threshold (sed JSON Bug Resurfaces in Box Script)

**Issue**: [#49 - Fix CI/CD](https://github.com/link-foundation/box/issues/49)
**CI Run**: [22265618808, Job 64411353868](https://github.com/link-foundation/box/actions/runs/22265618808/job/64411353868)
**Date**: 2026-02-21
**Status**: Investigation Complete — Fix Applied (v1.3.7)

## Executive Summary

The "Measure Disk Space and Update README" CI workflow failed at the "Validate measurements" step with:

```
Total size: 7545MB
Component count: 9
WARNING: Measurements appear incomplete or invalid!
  - Total size: 7545MB (expected >= 1000MB)
  - Components: 9 (expected >= 10)
```

Despite all 18 box user components printing `[✓] Recorded: ...` to stdout, they were **not actually saved to the JSON file**. The `add_measurement()` function in the `box-measure.sh` heredoc uses `sed` to append JSON components, but the `sed` pattern `s|\]$|,...|` does not match the compact (single-line) JSON produced by `python3`, so the function silently fails to write any data while still printing a success message.

This is the same class of bug previously fixed in the **outer** `measure-disk-space.sh` (Issue #35), but the fix was not applied to the **inner** `box-measure.sh` heredoc that runs as the `box` user.

## Timeline of Events

| Time (UTC) | Event |
|------------|-------|
| 2026-02-21T22:31:01 | Job started on ubuntu-24.04 runner (version 20260201.15.1) |
| 2026-02-21T22:31:02 | Repository checked out at commit `50de572` (main branch) |
| 2026-02-21T22:32:18 | APT updated, disk space freed |
| 2026-02-21T22:32:29 | Pre-flight checks passed, box user created |
| 2026-02-21T22:32:29–22:34:12 | 9 system components recorded via outer script (python3 JSON) |
| 2026-02-21T22:34:12 | `su - box -c "bash /tmp/box-measure.sh '$JSON_TMP_COPY'"` executed |
| 2026-02-21T22:34:13 | Bun install starts inside box-measure.sh |
| 2026-02-21T22:34:19 | Bun recorded (stdout: `[✓] Recorded: Bun - 97MB`) — but JSON file unchanged |
| 2026-02-21T22:34:19–22:50:25 | 17 more box components "recorded" (stdout only, JSON unchanged) |
| 2026-02-21T22:42:28 | PHP 8.3 Homebrew tap fails (`git clone` exits with 128) — recorded as 52MB (partial install) |
| 2026-02-21T22:50:25 | `[✓] Box user measurements complete` printed |
| 2026-02-21T22:50:25 | JSON copied back from `/tmp` — still contains only 9 components |
| 2026-02-21T22:50:25 | Validation: `Total size: 7545MB, Component count: 9` — **FAIL** |
| 2026-02-21T22:50:25 | Workflow fails with exit code 1 |

## Root Cause Analysis

### Primary Cause: sed Pattern Does Not Match python3-Generated Compact JSON

The `box-measure.sh` heredoc (embedded in `measure-disk-space.sh` lines 304–640) defines its own `add_measurement()` function using `sed`:

```bash
add_measurement() {
  local name="$1"
  local category="$2"
  local size_bytes="$3"
  local size_mb="$4"

  local current_json
  current_json=$(cat "$JSON_OUTPUT_FILE")
  local new_component="{\"name\": \"$name\", \"category\": \"$category\", \"size_bytes\": $size_bytes, \"size_mb\": $size_mb}"

  # Use | as sed delimiter to avoid issues with / in component names (e.g., "C/C++ Tools")
  if echo "$current_json" | grep -q '"components": \[\]'; then
    current_json=$(echo "$current_json" | sed "s|\"components\": \[\]|\"components\": [$new_component]|")
  else
    current_json=$(echo "$current_json" | sed "s|\]$|,$new_component]|")
  fi

  echo "$current_json" > "$JSON_OUTPUT_FILE"
  log_success "Recorded: $name - ${size_mb}MB"
}
```

The second `sed` branch uses the pattern `\]$` (match `]` at end of line). This was designed for a multi-line JSON format where `]` appears alone at the end of a line. However, the outer `measure-disk-space.sh` script uses `python3`'s `json.dump()` which produces **compact (single-line) JSON**:

```json
{"generated_at": "", "total_size_mb": 0, "components": [{"name": "Essential Tools", "category": "System", "size_bytes": 0, "size_mb": 0}, ...]}
```

In this format, the line ends with `}` (the root object close), **not** `]` (the array close). The pattern `\]$` finds no match, and `sed` leaves the string unchanged. The function then writes the **unmodified JSON** back to the file and prints the success message — giving a false positive.

### Reproduction

```bash
# Simulate what python3 writes:
cat > /tmp/test.json << 'EOF'
{"generated_at": "", "total_size_mb": 0, "components": [{"name": "Essential Tools", "category": "System", "size_bytes": 0, "size_mb": 0}]}
EOF

# Attempt sed-based append (as box-measure.sh does):
current_json=$(cat /tmp/test.json)
new_component='{"name": "Bun", "category": "Runtime", "size_bytes": 97000000, "size_mb": 97}'
current_json=$(echo "$current_json" | sed "s|\]$|,$new_component]|")
echo "$current_json" > /tmp/test.json

# Check result:
python3 -c "import json; data=json.load(open('/tmp/test.json')); print(f'Count: {len(data[\"components\"])}')"
# Output: Count: 1  (Bun was NOT added!)
```

The `[✓] Recorded` message is always printed **after** the `echo "$current_json" > "$JSON_OUTPUT_FILE"` line — regardless of whether the JSON was actually modified. The function has no mechanism to detect that `sed` made zero replacements.

### Why the First Component Branch Also Fails

The first branch (`grep -q '"components": \[\]'`) checks for an empty components array `"components": []`. However, since the outer script has already written 9 system components to the JSON before passing it to the box user, the file never contains `"components": []`. So only the second (broken) branch is ever reached.

### Secondary Issue: PHP Homebrew Tap Failure

During this run, PHP 8.3 installation via Homebrew also failed:

```
Error: Failure while executing; `git clone https://github.com/shivammathur/homebrew-php ...` exited with 128.
Error: No available formula with the name "shivammathur/php/php@8.3".
```

However, because the `install_php` function is wrapped in `|| true`, the failure is swallowed and `measure_install` records PHP as 52MB (from partial installation). This means PHP's measurement is unreliable. The Homebrew tap may be temporarily unavailable or the tap/formula name has changed. This secondary issue does not affect the primary failure (component count).

### How the Bug Was Previously "Fixed" — and Why It Recurred

Issue #35 identified the exact same `sed` fragility problem in the **outer** `measure-disk-space.sh` and fixed it by switching to `python3`. The fix comment in the outer script even mentions the `box-measure.sh`:

```bash
# Add component measurement to JSON
# Uses Python for reliable JSON manipulation, avoiding sed issues with special
# characters in component names (e.g., "C/C++ Tools"). See docs/case-studies/issue-35.
```

However, the `box-measure.sh` heredoc (embedded in the same file) was **not updated** at the time of the issue-35 fix. The inner script was added with sed-based manipulation and never converted to python3. Since the inner script runs with the outer script's already-python3-generated JSON (which is compact), the sed patterns fail silently.

The issue-46 fix (copying JSON to `/tmp/`) confirmed that data transfer between the outer and inner scripts works correctly — the problem is that the inner script writes nothing back.

## Solution

Replace the `sed`-based `add_measurement()` in `box-measure.sh` with the same `python3`-based approach used in the outer script:

**Before (broken sed approach):**
```bash
add_measurement() {
  local name="$1"
  local category="$2"
  local size_bytes="$3"
  local size_mb="$4"

  local current_json
  current_json=$(cat "$JSON_OUTPUT_FILE")
  local new_component="{\"name\": \"$name\", \"category\": \"$category\", \"size_bytes\": $size_bytes, \"size_mb\": $size_mb}"

  if echo "$current_json" | grep -q '"components": \[\]'; then
    current_json=$(echo "$current_json" | sed "s|\"components\": \[\]|\"components\": [$new_component]|")
  else
    current_json=$(echo "$current_json" | sed "s|\]$|,$new_component]|")
  fi

  echo "$current_json" > "$JSON_OUTPUT_FILE"
  log_success "Recorded: $name - ${size_mb}MB"
}
```

**After (robust python3 approach):**
```bash
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

  log_success "Recorded: $name - ${size_mb}MB"
}
```

Python's `json` module handles all edge cases correctly:
- Component names with special characters (`/`, `|`, `"`, `\`, etc.)
- Any JSON format (compact or pretty-printed)
- Atomic read-modify-write (no partial state issues)

## Evidence

### Components Reported vs. Actually Recorded

From CI log (run 22265618808):

| Component | stdout says | Actually in JSON? |
|-----------|-------------|------------------|
| Essential Tools | `[✓] Recorded` | ✓ (outer python3) |
| .NET SDK 8.0 | `[✓] Recorded` | ✓ (outer python3) |
| C/C++ Tools | `[✓] Recorded` | ✓ (outer python3) |
| Assembly Tools | `[✓] Recorded` | ✓ (outer python3) |
| R Language | `[✓] Recorded` | ✓ (outer python3) |
| Ruby Build Dependencies | `[✓] Recorded` | ✓ (outer python3) |
| Python Build Dependencies | `[✓] Recorded` | ✓ (outer python3) |
| GitHub CLI | `[✓] Recorded` | ✓ (outer python3) |
| GitLab CLI | `[✓] Recorded` | ✓ (outer python3) |
| **Bun** | `[✓] Recorded` | **✗ (sed failed)** |
| **gh-setup-git-identity** | `[✓] Recorded` | **✗ (sed failed)** |
| **glab-setup-git-identity** | `[✓] Recorded` | **✗ (sed failed)** |
| **Deno** | `[✓] Recorded` | **✗ (sed failed)** |
| **NVM + Node.js 20** | `[✓] Recorded` | **✗ (sed failed)** |
| **Pyenv + Python (latest)** | `[✓] Recorded` | **✗ (sed failed)** |
| **Go (latest)** | `[✓] Recorded` | **✗ (sed failed)** |
| **Rust (via rustup)** | `[✓] Recorded` | **✗ (sed failed)** |
| **SDKMAN + Java 21** | `[✓] Recorded` | **✗ (sed failed)** |
| **Kotlin (via SDKMAN)** | `[✓] Recorded` | **✗ (sed failed)** |
| **Lean (via elan)** | `[✓] Recorded` | **✗ (sed failed)** |
| **Opam + Rocq/Coq** | `[✓] Recorded` | **✗ (sed failed)** |
| **Homebrew** | `[✓] Recorded` | **✗ (sed failed)** |
| **PHP 8.3 (via Homebrew)** | `[✓] Recorded` | **✗ (sed failed)** |
| **Perlbrew + Perl (latest)** | `[✓] Recorded` | **✗ (sed failed)** |
| **rbenv + Ruby (latest)** | `[✓] Recorded` | **✗ (sed failed)** |
| **Swift 6.x** | `[✓] Recorded` | **✗ (sed failed)** |

### Validation Output

```
Total size: 7545MB
Component count: 9
WARNING: Measurements appear incomplete or invalid!
  - Total size: 7545MB (expected >= 1000MB)
  - Components: 9 (expected >= 10)

This likely indicates a problem with the measurement script.
See docs/case-studies/issue-29 for common causes.
```

```
##[error]Process completed with exit code 1.
```

## Files Modified

- `scripts/measure-disk-space.sh` — Replaced `sed`-based `add_measurement()` in the `box-measure.sh` heredoc with `python3`-based implementation

## Prevention

1. **Don't use sed for JSON manipulation**: `sed` is a stream editor designed for line-based text, not structured data. Always use `python3 -c "import json; ..."` or `jq` for JSON manipulation in shell scripts.
2. **When fixing a bug in a function, check all copies of that function**: The `add_measurement()` function exists in two places — the outer script and the heredoc. The issue-35 fix correctly updated the outer script but missed the heredoc copy.
3. **Add smoke tests for `add_measurement()`**: A small test that calls `add_measurement` and then verifies the JSON using `python3 -c "import json; ..."` would have caught this immediately.
4. **Detect no-op sed operations**: When `sed` finds no match, it returns exit code 0 — there's no built-in way to detect that a substitution didn't happen. This silent failure mode makes sed particularly dangerous for critical data mutations.

## Related Issues

- [#35 - Component Sizes Not Calculated or Pushed to README](https://github.com/link-foundation/box/issues/35) — Same `sed` JSON bug in the outer script (fixed with python3)
- [#31 - CI/CD failed](https://github.com/link-foundation/box/issues/31) — sed delimiter error with `/` in component names
- [#29 - Components size update failed](https://github.com/link-foundation/box/issues/29) — APT cleanup breaking package installation
- [#46 - Fix CI/CD](https://github.com/link-foundation/box/issues/46) — Permission denied when box user reads JSON (fixed with `/tmp/` copy)

## CI Logs

Full CI logs preserved in:
- `ci-logs/run-22265618808.log` — Full workflow log for the failing run

Online:
- [GitHub Actions Run 22265618808](https://github.com/link-foundation/box/actions/runs/22265618808/job/64411353868) — Failed measurement run

---

*Case study compiled: 2026-02-21*
*Investigation by: AI Issue Solver*
