# Case Study: Failing CI/CD Run — Permission Denied for JSON Measurements

**Issue**: [#46 - Fix failing CI/CD run](https://github.com/link-foundation/box/issues/46)
**CI Runs**:
- [22261112919, Job 64399507098](https://github.com/link-foundation/box/actions/runs/22261112919/job/64399507098) — First failure: "No such file or directory"
- [22263724056](https://github.com/link-foundation/box/actions/runs/22263724056/job/64405913545) — Second failure: "Permission denied"

**Date**: 2026-02-21
**Status**: Investigation Complete — Fix Applied (v1.3.6)

## Executive Summary

This issue has two related but distinct failures:

### First Failure (Run 22261112919) — "No such file or directory"

```
cat: data/disk-space-measurements.json: No such file or directory
##[error]Process completed with exit code 1.
```

Root cause: `su - box` (login shell) changes CWD to `/home/box`. The relative path `data/disk-space-measurements.json` then resolves to `/home/box/data/disk-space-measurements.json` — a path that was never created. **Fix**: Convert the relative JSON path to an absolute path using `realpath` before passing to `su - box`. Applied in PR #47 (v1.3.5).

### Second Failure (Run 22263724056) — "Permission denied"

```
cat: /home/runner/work/box/box/data/disk-space-measurements.json: Permission denied
##[error]Process completed with exit code 1.
```

Root cause: After applying the `realpath` fix, the absolute path was passed correctly, but the box user still could not access the file. The GitHub Actions workspace directory `/home/runner/work/box/box/` is owned by `runner` and has permissions `750`, denying traverse access to the `box` user (who is not in the `runner` group). The first fix granted `o+rx` only to the immediate parent `data/` directory, but not to the workspace root — so the kernel path traversal check still failed at `/home/runner/work/box/box/`. **Fix**: Copy the JSON file to `/tmp/` (world-accessible, mode `1777`) before running the box user script, then copy it back. Applied in v1.3.6.

## Timeline of Events

| Time (UTC) | Event |
|------------|-------|
| 2026-02-21T17:29:57 | Job started on ubuntu-24.04 runner (version 20260201.15.1) |
| 2026-02-21T17:31:25 | `measure-disk-space.sh` invoked: `sudo ./scripts/measure-disk-space.sh --json-output data/disk-space-measurements.json` |
| 2026-02-21T17:31:26 | JSON initialized at `data/disk-space-measurements.json` (relative to runner CWD: `/home/runner/work/box/box/data/disk-space-measurements.json`) |
| 2026-02-21T17:31:26 | Measurements begin for system components (Essential Tools, .NET, C/C++, etc.) |
| 2026-02-21T17:32:57 | GitLab CLI recorded as last successful system measurement |
| 2026-02-21T17:32:57 | `su - box -c "bash /tmp/box-measure.sh 'data/disk-space-measurements.json'"` executed |
| 2026-02-21T17:32:57 | Login shell changes CWD to `/home/box`; relative path resolves to wrong location |
| 2026-02-21T17:32:58 | Bun installs successfully to `/home/box/.bun/bin/bun` |
| 2026-02-21T17:32:58 | `add_measurement "Bun"` calls `cat data/disk-space-measurements.json` — **file not found** |
| 2026-02-21T17:32:58 | Script exits with code 1; `set -euo pipefail` propagates failure |
| 2026-02-21T17:32:58 | Workflow step fails: `cat: data/disk-space-measurements.json: No such file or directory` |

## Root Cause Analysis

### Primary Cause: `su -` (Login Shell) Changes Working Directory

The `su -` command (equivalent to `su --login` or `su -l`) simulates a full login for the target user. According to the [Linux `su` man page](https://manpages.ubuntu.com/manpages/focal/en/man1/su.1.html) and [Linuxize's su documentation](https://linuxize.com/post/su-command-in-linux/):

> When using `su -`, the command **changes the current working directory to the home directory of the target user**. All environment variables are reset to the target user's environment.

The relevant code in `measure-disk-space.sh` (line 646):

```bash
su - box -c "bash /tmp/box-measure.sh '$JSON_OUTPUT_FILE'"
```

Where `JSON_OUTPUT_FILE` is `data/disk-space-measurements.json` (a relative path).

**Before `su - box`**: Working directory = `/home/runner/work/box/box`
- Relative path resolves to: `/home/runner/work/box/box/data/disk-space-measurements.json` ✓ (file exists)

**After `su - box`**: Working directory = `/home/box`
- Relative path resolves to: `/home/box/data/disk-space-measurements.json` ✗ (file does not exist)

The box-measure.sh script's `add_measurement` function then fails at:

```bash
current_json=$(cat "$JSON_OUTPUT_FILE")  # Fails: No such file or directory
```

This error propagates through `set -euo pipefail`, causing the box-measure.sh to exit with code 1, which then causes the outer script and the workflow step to fail.

### Why Bun Appears in the Error

The failure appears immediately after Bun installation because Bun is the **first measurement** in box-measure.sh. The successful Bun installation output (`bun was installed successfully to ~/.bun/bin/bun`) appears before the JSON read failure because:

1. `measure_install "Bun" "Runtime" install_bun` — calls `install_bun` which succeeds
2. `add_measurement "Bun" ...` — calls `cat "$JSON_OUTPUT_FILE"` which fails

Bun itself is **not the cause** of the failure. The error would have occurred even if Bun installation was skipped, as the JSON file issue affects all measurements.

### Why the JSON File Was "Missing"

The JSON file was never truly missing — it was created correctly at:
```
/home/runner/work/box/box/data/disk-space-measurements.json
```

But the box user's script looked for it at:
```
/home/box/data/disk-space-measurements.json
```

This directory (`/home/box/data/`) was never created, making the path completely inaccessible to the box user. Additionally, even if the directory existed, the box user would not normally have write access to the runner's working directory structure.

### Contributing Factors

1. **`set -euo pipefail` in outer script**: `set -euo pipefail` at the top of `measure-disk-space.sh` (line 2) ensures any failure in the subprocess chain propagates correctly — this is correct behavior, but amplifies the visibility of the root cause bug.

2. **`su -` vs `su`**: The login shell option (`-`) was chosen deliberately to give the box user a clean environment for installation. This is the correct approach for user-space installations, but requires careful handling of paths. According to [Baeldung's analysis](https://www.baeldung.com/linux/su-command-options), `su -` "simulates a full login" and "resets environment variables and changes to the user's home directory."

3. **Relative path throughout**: The JSON output file is passed as a relative path from the CLI argument `--json-output data/disk-space-measurements.json`. This relative path is never converted to an absolute path, so it becomes invalid after a working directory change.

## Solution

### Fix 1 (v1.3.5, PR #47): Convert to Absolute Path Before `su - box`

Resolve the JSON output path to an absolute path before executing the box user's sub-script. This ensures the path remains valid regardless of what working directory the sub-shell starts in.

```bash
JSON_OUTPUT_FILE_ABS="$(realpath "$JSON_OUTPUT_FILE")"
chmod o+rw "$JSON_OUTPUT_FILE_ABS"
chmod o+rx "$(dirname "$JSON_OUTPUT_FILE_ABS")"

if [ "$EUID" -eq 0 ]; then
  su - box -c "bash /tmp/box-measure.sh '$JSON_OUTPUT_FILE_ABS'"
else
  sudo -i -u box bash /tmp/box-measure.sh "$JSON_OUTPUT_FILE_ABS"
fi
```

This resolved the "No such file or directory" error but not the "Permission denied" error.

### Fix 2 (v1.3.6, PR #48): Copy JSON File to `/tmp/` for Box User Access

The deeper problem is that the box user cannot traverse the workspace directory tree. The GitHub Actions workspace root (`/home/runner/work/box/box/`) is owned by `runner` with permissions `750`. The `box` user is not in the `runner` group, so they get `EACCES` when trying to traverse the directory — even if the file itself is world-readable.

The fix copies the JSON file to `/tmp/` (world-accessible, mode `1777`), runs the box user script against that copy, then copies it back:

```bash
JSON_OUTPUT_FILE_ABS="$(realpath "$JSON_OUTPUT_FILE")"
JSON_TMP_COPY="$(mktemp /tmp/disk-space-measurements-XXXXXX.json)"
cp "$JSON_OUTPUT_FILE_ABS" "$JSON_TMP_COPY"
chmod o+rw "$JSON_TMP_COPY"

if [ "$EUID" -eq 0 ]; then
  su - box -c "bash /tmp/box-measure.sh '$JSON_TMP_COPY'"
else
  sudo -i -u box bash /tmp/box-measure.sh "$JSON_TMP_COPY"
fi

cp "$JSON_TMP_COPY" "$JSON_OUTPUT_FILE_ABS"
rm -f "$JSON_TMP_COPY"
```

### Why Fix 2 Is Correct

For the box user to access a file at `/home/runner/work/box/box/data/measurements.json`, they need execute (`x`) permission on **every directory** in the path:

| Directory | Owner | Typical mode | Box user can traverse? |
|-----------|-------|-------------|---------------------------|
| `/home/runner/` | runner | 755 | Yes (world x) |
| `/home/runner/work/` | runner | 755 | Yes (world x) |
| `/home/runner/work/box/` | runner | 755 | Yes (world x) |
| `/home/runner/work/box/box/` | runner | **750** | **No** (no world x) |
| `.../data/` | root | was set to o+rx by Fix 1 | Yes |
| `.../measurements.json` | root | was set to o+rw by Fix 1 | Yes |

Fix 1 set `o+rx` on `data/` and `o+rw` on the file but missed `/home/runner/work/box/box/` which has no world-execute bit. Fix 2 sidesteps the issue entirely by using `/tmp/` which is world-accessible (`1777`).

### Alternative Approaches Considered

1. **Walk all ancestor directories and chmod**: `chmod o+rx` every directory from `/` to `data/`. This works but widens permissions on runner-owned directories unnecessarily and has a larger blast radius.

2. **Use `su` without `-`** (no login shell): Would preserve the working directory but break user-space tool installations that expect a clean home environment. Not recommended.

3. **Pass absolute path directly from CLI**: Requires users to always specify absolute paths in the workflow, which is error-prone.

4. **Use `cd` inside `su -` command**: Adding `cd /path/to/workdir &&` before the script call would work but is fragile.

## Technical Details

### Environment Comparison

| Context | Working Directory | `data/disk-space-measurements.json` resolves to |
|---------|------------------|--------------------------------------------------|
| Runner shell | `/home/runner/work/box/box` | `/home/runner/work/box/box/data/disk-space-measurements.json` ✓ |
| Root (outer script) | `/home/runner/work/box/box` | `/home/runner/work/box/box/data/disk-space-measurements.json` ✓ |
| `su - box` | `/home/box` | `/home/box/data/disk-space-measurements.json` ✗ |

### Affected Script Section

**File**: `scripts/measure-disk-space.sh`, lines 644–649

```bash
# Execute box user measurements
if [ "$EUID" -eq 0 ]; then
  su - box -c "bash /tmp/box-measure.sh '$JSON_OUTPUT_FILE'"
else
  sudo -i -u box bash /tmp/box-measure.sh "$JSON_OUTPUT_FILE"
fi
```

The `sudo -i -u box` also creates a login shell (`-i` flag = simulate initial login), so the same path issue would affect that branch too.

### Bun Installation Script Behavior

For reference, Bun's install script (`https://bun.sh/install`) uses `set -euo pipefail` and adds `~/.bun/bin` to `$HOME/.bash_profile`. The script exits 0 on success and 1 on failure. In this CI run, Bun installed successfully (exit 0), confirming that Bun itself is not the failure source.

## CI Run Data

- **Workflow**: "Measure Disk Space and Update README"
- **Job**: "Measure Component Disk Space"
- **Run ID**: 22261112919
- **Job ID**: 64399507098
- **Runner**: ubuntu-24.04, version 20260201.15.1
- **Commit**: 38673b0f4aa8c91069a9473a5df1d157c8522584 (main)
- **Trigger**: Push to main branch

### Components Successfully Recorded Before Failure

| Component | Category | Size |
|-----------|----------|------|
| Essential Tools | System | 0MB |
| .NET SDK 8.0 | Runtime | 481MB |
| C/C++ Tools (CMake, Clang, LLVM, LLD) | Build Tools | 56MB |
| Assembly Tools (NASM, FASM) | Build Tools | 3MB |
| R Language | Runtime | 115MB |
| Ruby Build Dependencies | Dependencies | 0MB |
| Python Build Dependencies | Dependencies | 40MB |
| GitHub CLI | Development Tools | 0MB |
| GitLab CLI | Development Tools | 27MB |

### Components Not Recorded (Box User Installations)

All box user installations failed due to the JSON path issue:
- Bun, gh-setup-git-identity, glab-setup-git-identity, Deno, NVM + Node.js 20
- Pyenv + Python, Go, Rust, SDKMAN + Java 21, Kotlin, Lean, Opam + Rocq
- Homebrew, PHP 8.3, Perlbrew + Perl, rbenv + Ruby, Swift

## References

### External Links

1. [Ubuntu Manpage: su (focal)](https://manpages.ubuntu.com/manpages/focal/en/man1/su.1.html) — official documentation for `su` behavior
2. [Linuxize: Su Command in Linux](https://linuxize.com/post/su-command-in-linux/) — `su -` changes to target user's home directory
3. [Baeldung: Why Do We Use su – and Not Just su?](https://www.baeldung.com/linux/su-command-options) — explains login shell environment reset
4. [Bun Installation Documentation](https://bun.sh/docs/installation) — Bun install script behavior
5. [Bun install script source](https://bun.sh/install) — uses `set -euo pipefail`, adds to `~/.bash_profile`

### Internal Logs

- Full CI log: `ci-run-log.txt` (saved locally during investigation)
- CI run: `gh run view 22261112919 --repo link-foundation/box --log`

---

*Case study compiled: 2026-02-21*
*Investigation by: AI Issue Solver*
