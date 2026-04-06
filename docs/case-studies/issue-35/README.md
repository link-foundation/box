# Case Study: Component Sizes Not Calculated or Pushed to README on Push to Main

**Issue:** [#35 - Components sizes are not calculated or pushed to README.md on push to main branch](https://github.com/link-foundation/box/issues/35)

**Date of Investigation:** 2026-01-31

## Executive Summary

The `measure-disk-space.yml` workflow has never successfully measured all component disk sizes and pushed the results to `README.md`. Two root causes were identified: (1) the workflow's path-based trigger did not include the measurement scripts themselves, so fixes to those scripts never re-triggered the workflow, and (2) the `sed`-based JSON manipulation in the measurement script was fragile and failed on component names containing special characters (e.g., `C/C++ Tools`). Additionally, a pipeline masking issue (`| tee`) hid script failures from the workflow, allowing it to continue with incomplete data.

## Timeline of Events

| Time (UTC) | Event | Details |
|------------|-------|---------|
| 2026-01-29 14:07:09 | First workflow run (035998b) | Succeeded superficially, but only recorded 1 component (0MB) due to broken apt (issue-29). No validation existed yet, so 0MB data was committed to main. |
| 2026-01-29 ~14:09 | 0MB data committed | `chore: update component disk space measurements (0MB total)` pushed to main (commit 3d75e41) |
| 2026-01-29 ~14:35 | Issue-29 fix merged | PR #30 fixes apt cleanup, adds validation step (commit a646fe6) |
| 2026-01-29 18:21:09 | Second workflow run (a646fe6) | Triggered by issue-29 fix merge. **Failed** with sed error on "C/C++ Tools" component. Only 2 components measured. Validation correctly rejected. |
| 2026-01-29 18:39-18:48 | Issue-31 fix developed | PR #32 changes sed delimiter from `/` to `\|` |
| 2026-01-29 ~18:48 | Issue-31 fix merged (52cbffc) | sed delimiter fixed, but this only changed `scripts/measure-disk-space.sh` |
| 2026-01-29 18:48+ | **No workflow re-trigger** | The workflow path filter only watches `scripts/ubuntu-24-server-install.sh`, `Dockerfile`, and the workflow file itself — NOT `scripts/measure-disk-space.sh` |
| 2026-01-31 | Issue #35 opened | Component sizes still show 0MB in README |

## Root Cause Analysis

### Root Cause 1: Incomplete Workflow Path Triggers

The `measure-disk-space.yml` workflow was configured to trigger only on changes to:
```yaml
paths:
  - 'scripts/ubuntu-24-server-install.sh'
  - 'Dockerfile'
  - '.github/workflows/measure-disk-space.yml'
```

Missing from this list:
- `scripts/measure-disk-space.sh` — the main measurement script
- `scripts/update-readme-sizes.sh` — the README updater script

This meant that fixing the measurement script (issue-31, commit 52cbffc) did **not** trigger a re-run of the measurement workflow. The fixed code was never executed.

### Root Cause 2: Fragile sed-Based JSON Manipulation

The `add_measurement()` function used `sed` to manipulate JSON, which is inherently fragile:

```bash
# Even with | delimiter (after issue-31 fix), sed is fragile for JSON:
current_json=$(echo "$current_json" | sed "s|\"components\": \[\]|\"components\": [$new_component]|")
current_json=$(echo "$current_json" | sed "s|\]$|,$new_component]|")
```

While the issue-31 fix changed the delimiter from `/` to `|`, this approach remains vulnerable to:
- Any future component name containing `|`
- Regex metacharacters in component values
- Multi-line JSON formatting changes
- Shell quoting edge cases with special characters

### Root Cause 3: Pipeline Masking Script Failures

The workflow ran the measurement script through a pipe:
```yaml
sudo ./scripts/measure-disk-space.sh ... 2>&1 | tee measurement.log
```

Without `set -o pipefail` in the workflow step, bash reports the exit code of the **last** command in the pipeline (`tee`, which always succeeds), not the measurement script. When the script crashed due to the sed error, the workflow continued as if nothing happened, producing incomplete JSON data.

### How the Three Root Causes Interacted

```
Issue-29 fix (a646fe6) merged to main
    │
    ▼
measure-disk-space workflow triggered (correct — install script changed)
    │
    ▼
Script crashes on "C/C++ Tools" due to sed / delimiter (issue-31)
    │                                          │
    ▼                                          ▼
Pipeline masks failure             Only 2 components in JSON
(tee exit code 0)                  (total_size_mb: 0)
    │                                          │
    ▼                                          ▼
Workflow continues                 Validation catches incomplete data
                                              │
                                              ▼
                                   Workflow fails (correct behavior)
```

```
Issue-31 fix (52cbffc) merged to main
    │
    ▼
measure-disk-space workflow NOT triggered
(scripts/measure-disk-space.sh not in path triggers)
    │
    ▼
README still shows 0MB — issue #35 opened
```

## Solution

### Fix 1: Add Measurement Scripts to Workflow Path Triggers

```yaml
paths:
  - 'scripts/ubuntu-24-server-install.sh'
  - 'scripts/measure-disk-space.sh'        # NEW
  - 'scripts/update-readme-sizes.sh'       # NEW
  - 'Dockerfile'
  - '.github/workflows/measure-disk-space.yml'
```

This ensures any changes to measurement-related scripts will trigger a re-run.

### Fix 2: Add pipefail to Workflow Measurement Step

```yaml
run: |
  set -o pipefail
  # ... measurement commands ...
  sudo ./scripts/measure-disk-space.sh ... 2>&1 | tee measurement.log
```

This ensures script failures propagate through the `tee` pipeline and are detected by the workflow.

### Fix 3: Replace sed-Based JSON Manipulation with Python

Instead of using sed (which is fragile for structured data), use Python's `json` module:

**Before (fragile sed):**
```bash
current_json=$(echo "$current_json" | sed "s|\"components\": \[\]|\"components\": [$new_component]|")
```

**After (robust Python):**
```bash
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
```

Python's `json` module handles all special characters correctly and produces valid JSON output regardless of component names.

## Evidence

### Failed Run Logs (Run 21489818730)

The sed error at the C/C++ Tools component:
```
[✓] Recorded: .NET SDK 8.0 - 481MB
[*] Measuring installation: C/C++ Tools (CMake, Clang, LLVM, LLD)
...
sed: -e expression #1, char 20: unknown option to `s'
=== Measurement complete ===
```

Validation failure:
```
Total size: 0MB
Component count: 2
WARNING: Measurements appear incomplete or invalid!
  - Total size: 0MB (expected >= 1000MB)
  - Components: 2 (expected >= 10)
```

### "Successful" Run Logs (Run 21481304786)

The earlier run appeared successful but actually failed silently:
```
E: Package 'build-essential' has no installation candidate
E: Unable to locate package expect
[!] Installation of Essential Tools failed
[✓] Recorded: Essential Tools - 0MB
=== Measurement complete ===
```

This run had no validation step, so it committed 0MB data to main.

## Files Modified

- `.github/workflows/measure-disk-space.yml` — Added measurement scripts to path triggers; added `set -o pipefail`
- `scripts/measure-disk-space.sh` — Replaced sed-based JSON manipulation with Python

## Prevention

1. **Include all related scripts in workflow triggers**: When a workflow depends on scripts, ensure those scripts are listed in the `paths` filter
2. **Use language-appropriate tools for data manipulation**: Use Python/jq for JSON, not sed/awk
3. **Enable pipefail in CI steps**: Always use `set -o pipefail` when piping command output through `tee` or other tools
4. **Test script changes trigger workflows**: Verify path filters match all relevant files

## Related Issues

- [#29 - Components size update failed](https://github.com/link-foundation/box/issues/29) — APT cleanup breaking package installation (fixed)
- [#31 - CI/CD failed](https://github.com/link-foundation/box/issues/31) — sed delimiter error with `/` in component names (partially fixed, this issue completes the fix)

## CI Logs

Full CI logs are preserved in:
- `ci-logs/measure-disk-space-failed-21489818730.log` — Failed run with sed error
- `ci-logs/measure-disk-space-success-21481304786.log` — Earlier run with broken apt

Online:
- [GitHub Actions Run 21489818730](https://github.com/link-foundation/box/actions/runs/21489818730) — Failed measurement run
- [GitHub Actions Run 21481304786](https://github.com/link-foundation/box/actions/runs/21481304786) — Earlier "successful" run with 0MB data

## Conclusion

This issue was caused by a combination of three problems: incomplete workflow path triggers, fragile sed-based JSON manipulation, and pipeline error masking. The issue-31 fix addressed the immediate sed delimiter problem but was never re-executed because the workflow path triggers didn't include the measurement script. The comprehensive fix adds the missing path triggers, replaces sed with Python for JSON manipulation (eliminating the entire class of special-character bugs), and adds `pipefail` to detect script failures properly. Once merged, the workflow will trigger and should produce accurate component size measurements.
