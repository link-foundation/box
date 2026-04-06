# Case Study: CI/CD Failed - sed Command Error with Special Characters

**Issue:** [#31 - CI/CD failed](https://github.com/link-foundation/box/issues/31)

**Date of Investigation:** 2026-01-29

## Executive Summary

The `measure-disk-space.yml` workflow failed with exit code 1 because the disk space measurement script terminated early due to a `sed` command error. The root cause is that component names containing forward slashes (`/`) break the sed substitution command that uses `/` as the delimiter. This caused only 2 of ~25 components to be measured, triggering the validation failure.

## Timeline of Events

| Time (UTC) | Event | Details |
|------------|-------|---------|
| 2026-01-29 18:21:13 | Workflow started | Run ID: 21489818730 |
| 2026-01-29 18:21:15 | Checkout completed | Repository checked out successfully |
| 2026-01-29 18:23:20 | Disk cleanup completed | ~20GB freed, 42GB available |
| 2026-01-29 18:23:20 | Measurement started | Baseline: 30428MB |
| 2026-01-29 18:24:01 | Essential Tools measured | 0MB (already installed) |
| 2026-01-29 18:24:11 | .NET SDK 8.0 measured | 481MB |
| 2026-01-29 18:24:11 | C/C++ Tools measurement started | Installation began |
| 2026-01-29 18:24:16 | **sed error occurred** | Script terminated |
| 2026-01-29 18:24:16 | Validation failed | 0MB total, 2 components |
| 2026-01-29 18:24:16 | Workflow failed | Exit code 1 |

## Root Cause Analysis

### The Bug

The `add_measurement()` function in `scripts/measure-disk-space.sh` uses `sed` with forward slash (`/`) as the delimiter:

```bash
# Line 114 (main script) and line 344 (embedded box script)
current_json=$(echo "$current_json" | sed "s/\"components\": \[\]/\"components\": [$new_component]/")

# Line 117 (main script) and line 346 (embedded box script)
current_json=$(echo "$current_json" | sed "s/\]$/,$new_component]/")
```

The `$new_component` variable contains JSON like:
```json
{"name": "C/C++ Tools (CMake, Clang, LLVM, LLD)", "category": "Build Tools", "size_bytes": ..., "size_mb": ...}
```

When the component name contains `/` (as in `C/C++ Tools`), it's interpreted as a sed delimiter, causing:
```
sed: -e expression #1, char 20: unknown option to `s'
```

### Evidence from Logs

From [Run 21489818730](https://github.com/link-foundation/box/actions/runs/21489818730/job/61909023165):

**Successful measurements before the error:**
```
[✓] Recorded: Essential Tools - 0MB
[*] Measuring installation: .NET SDK 8.0
...
[✓] Recorded: .NET SDK 8.0 - 481MB
[*] Measuring installation: C/C++ Tools (CMake, Clang, LLVM, LLD)
```

**The sed error:**
```
sed: -e expression #1, char 20: unknown option to `s'
=== Measurement complete ===
```

**Resulting corrupted JSON:**
```json
{
  "generated_at": "",
  "total_size_mb": 0,
  "components": [
    {"name": "Essential Tools", "category": "System", "size_bytes": 737280, "size_mb": 0},
    {"name": ".NET SDK 8.0", "category": "Runtime", "size_bytes": 504913920, "size_mb": 481}
  ]
}
```

Note:
- `generated_at` is empty (never finalized)
- `total_size_mb` is 0 (never calculated)
- Only 2 components instead of ~25

**Validation failure:**
```
Total size: 0MB
Component count: 2
WARNING: Measurements appear incomplete or invalid!
  - Total size: 0MB (expected >= 1000MB)
  - Components: 2 (expected >= 10)
```

### Why Only 2 Components Were Recorded

The script order was:
1. Essential Tools - **SUCCESS** (no `/` in name)
2. .NET SDK 8.0 - **SUCCESS** (no `/` in name)
3. C/C++ Tools (CMake, Clang, LLVM, LLD) - **FAILED** (contains `/`)

The sed error caused the script to exit due to `set -euo pipefail`, preventing all subsequent measurements.

### Flow Diagram

```
┌─────────────────────────────────────┐
│ 1. Measure "Essential Tools"         │
│    Name: "Essential Tools"           │
│    No / in name - sed works ✓        │
└─────────────────────────────────────┘
                │
                ▼
┌─────────────────────────────────────┐
│ 2. Measure ".NET SDK 8.0"            │
│    Name: ".NET SDK 8.0"              │
│    No / in name - sed works ✓        │
└─────────────────────────────────────┘
                │
                ▼
┌─────────────────────────────────────┐
│ 3. Measure "C/C++ Tools (...)"       │
│    Name contains "/" ◄───────────────── Problem!
│    sed "s/.../...$new_component/"    │
│    Interpreted as: s/.../...C/C++... │
│    "C" becomes invalid sed flag ◄───── sed error!
└─────────────────────────────────────┘
                │
                ▼
┌─────────────────────────────────────┐
│ 4. set -euo pipefail                 │
│    Script exits immediately          │
│    finalize_json_output() never runs │
│    total_size_mb stays 0             │
└─────────────────────────────────────┘
                │
                ▼
┌─────────────────────────────────────┐
│ 5. Validation fails                  │
│    0MB < 1000MB threshold            │
│    2 components < 10 threshold       │
│    Workflow exits with error         │
└─────────────────────────────────────┘
```

## Solution

### The Fix

Replace the sed delimiter `/` with a character that won't appear in component names. The pipe character `|` is a good choice since it's unlikely to appear in component names or JSON values:

**Before (broken):**
```bash
current_json=$(echo "$current_json" | sed "s/\"components\": \[\]/\"components\": [$new_component]/")
current_json=$(echo "$current_json" | sed "s/\]$/,$new_component]/")
```

**After (fixed):**
```bash
current_json=$(echo "$current_json" | sed "s|\"components\": \[\]|\"components\": [$new_component]|")
current_json=$(echo "$current_json" | sed "s|\]$|,$new_component]|")
```

This change needs to be made in:
1. `scripts/measure-disk-space.sh` - main script (lines 114, 117, 133, 134)
2. The embedded box-measure.sh script (lines 344, 346)

### Alternative Solutions Considered

1. **Escape forward slashes in the variable** - Complex and error-prone
2. **Use a different JSON manipulation tool (jq)** - Would add a dependency
3. **Change the component name** - Would hide useful information
4. **Use Python instead of sed** - More complex, but more robust

The chosen solution (using `|` as delimiter) is the simplest and most direct fix.

## Files Modified

- `scripts/measure-disk-space.sh` - Fixed sed delimiter from `/` to `|`

## Prevention

To prevent similar issues in the future:

1. **Use robust delimiters**: When using sed with variable content, use delimiters that won't appear in the data (like `|`, `#`, or `@`)

2. **Consider using jq for JSON manipulation**: The jq tool is designed for JSON and handles special characters properly

3. **Add unit tests**: Test the measurement script with component names containing special characters

4. **Validate component names**: If using sed with `/`, ensure component names don't contain that character

## Related Issues

- [#29 - Components size update failed](https://github.com/link-foundation/box/issues/29) - Different root cause (APT cleanup issue), but same symptom (0MB measurements)

## CI Logs

The full CI logs are available at:
- [GitHub Actions Run 21489818730](https://github.com/link-foundation/box/actions/runs/21489818730/job/61909023165) - Complete workflow output

## Conclusion

The CI/CD failure was caused by using `/` as the sed delimiter when the data being substituted (component names) could contain `/` characters. The fix is straightforward: change the sed delimiter to a character that won't appear in the data, such as `|`. This is a common pitfall when using sed with user-provided or variable data.
