# Case Study: CI/CD Failed — `du` Exit Code Regression from Issue #55 Fix (Issue #57)

## Summary

The CI/CD "Measure Disk Space and Update README" workflow failed with **exit code 1** on the merge of PR #56 (the Issue #55 fix). The script `scripts/measure-disk-space.sh` exited early inside the sandbox user sub-script when measuring Homebrew. The fix for Issue #55 introduced a regression: `du -sb` is called on paths that may not exist, and with `set -euo pipefail` active, a non-zero `du` exit code kills the script before it can record 0 MB and continue.

## Issue Reference

- **Issue**: [#57 — We have CI/CD failed](https://github.com/link-foundation/sandbox/issues/57)
- **Failed CI run**: https://github.com/link-foundation/sandbox/actions/runs/22347524656/job/64665886012
- **Log file**: `docs/case-studies/issue-57/ci-job-64665886012.txt`
- **Triggered by**: Merge of PR #56 (commit `f274bfab` — "1.3.10: Fix language runtime size measurements")

## Timeline of Events

| Time (UTC) | Event |
|---|---|
| 2026-02-22T01:47:26Z | **Last successful run** (PR #52, commit `03a9d8da`) — Homebrew failed silently, recorded 0 MB |
| 2026-02-24T10:48:21Z | PR #56 merged (`f274bfab`) — introduces the Issue #55 fix (du-based measurement for Homebrew/Rust) |
| 2026-02-24T10:48:24Z | CI job starts |
| 2026-02-24T10:58:42Z | Opam + Rocq/Coq recorded (1307.03 MB) |
| 2026-02-24T10:58:42Z | Homebrew installer runs — exits with "Insufficient permissions" |
| 2026-02-24T10:58:44Z | **Script exits with code 1** — all subsequent steps skipped |

## Failure Evidence

From `ci-job-64665886012.log` (lines 2207–2218):

```
==> Running in non-interactive mode because `$NONINTERACTIVE` is set.
/usr/bin/ldd: line 41: printf: write error: Broken pipe
/usr/bin/ldd: line 43: printf: write error: Broken pipe
==> Checking for `sudo` access (which may request your password)...
Insufficient permissions to install Homebrew to "/home/linuxbrew/.linuxbrew" (the default prefix).

Alternative (unsupported) installation methods are available at:
https://docs.brew.sh/Installation#alternative-installs

Please note this will require most formula to build from source, a buggy, slow and energy-inefficient experience.
We will close any issues without response for these unsupported configurations.

##[error]Process completed with exit code 1.
```

---

## Root Cause Analysis

### Root Cause 1: `du` returns exit code 1 for non-existent paths; `set -euo pipefail` kills the script

**Location:** `scripts/measure-disk-space.sh` (sandbox sub-script, Homebrew section, around line 588)

**The buggy code** (introduced by the Issue #55 fix in commit `3471bf8`):

```bash
if install_homebrew; then
  cleanup_for_measurement
  brew_bytes=$(du -sb /home/linuxbrew/.linuxbrew "$HOME/.linuxbrew" 2>/dev/null | awk '{sum+=$1} END{print sum+0}')
  ...
```

**What happens step by step:**

1. `install_homebrew()` is called. Inside it:
   ```bash
   NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || true
   ```
   The Homebrew installer checks `sudo` access and write permissions. The `sandbox` user has no NOPASSWD sudo, so `sudo -n -l mkdir` fails. Even though `/home/linuxbrew/.linuxbrew` is owned by sandbox (created by the outer script), the Homebrew installer exits with code 1. The `|| true` suppresses this, so `install_homebrew()` returns **0** (success).

2. Because `install_homebrew` returns 0, the `if install_homebrew; then` branch is taken.

3. Inside the branch, `du -sb /home/linuxbrew/.linuxbrew "$HOME/.linuxbrew"` is run:
   - `/home/linuxbrew/.linuxbrew` exists (created by the outer script, but empty — brew install failed)
   - `"$HOME/.linuxbrew"` does NOT exist (sandbox user HOME = `/home/sandbox`, no `.linuxbrew` there)
   - `du` exits with **code 1** because one argument doesn't exist
   - The `2>/dev/null` suppresses the stderr error message, but NOT the exit code
   - With `set -euo pipefail` active in the sandbox sub-script, the non-zero exit from `du` kills the entire script

4. The sandbox sub-script exits with code 1, which propagates to the outer `sudo -i -u sandbox bash /tmp/sandbox-measure.sh` call, which propagates to the CI step.

**Reproducer:**
```bash
bash -c 'set -euo pipefail; result=$(du -sb /tmp/nonexistent_dir 2>/dev/null | awk "{sum+=\$1} END{print sum+0}"); echo "$result"'
# → exits with code 1 (not 0)
```

### Root Cause 2: Homebrew installer permission check vs. sandbox user

The Homebrew installer (as of Jan 2026) aborts when ALL these conditions are true:
- `HOMEBREW_PREFIX` (`/home/linuxbrew/.linuxbrew`) is not writable, OR
- `/home/linuxbrew` is not writable, OR
- `/home` is not writable, AND
- `have_sudo_access()` returns false

With `NONINTERACTIVE=1`, `have_sudo_access()` runs `sudo -n -l mkdir`. The sandbox user was added to the `sudo` group via `usermod -aG sudo sandbox`, but GitHub Actions runners only grant passwordless sudo to the `runner` user. The sandbox user has no NOPASSWD entry, so `sudo -n` fails.

The outer script creates `/home/linuxbrew/.linuxbrew` and `chown -R sandbox:sandbox /home/linuxbrew` (as root), which should make the directory writable by sandbox. However, this issue represents a brittle dependency: the permission pre-setup in the outer script must work correctly for every run. If something changes (runner image update, timing issue), Homebrew will fail.

**Note**: In the previous run (commit `03a9d8da`), Homebrew also failed with the same "Insufficient permissions" error, but `measure_install "Homebrew" "Package Manager" install_homebrew` correctly handled the failure by recording 0 MB and continuing.

---

## Sequence of Events (Root Cause 1 in detail)

```
outer script (root) runs
  → creates /home/linuxbrew/.linuxbrew, chowns to sandbox
  → writes /tmp/sandbox-measure.sh
  → runs: sudo -i -u sandbox bash /tmp/sandbox-measure.sh /tmp/disk-space-*.json

    sandbox-measure.sh (runs as sandbox user, set -euo pipefail)
      → measures Bun, deno, nvm, pyenv, Go, Rust, SDKMAN, Kotlin, Lean, Opam
      → cleanup_for_measurement
      → install_homebrew() called:
          NONINTERACTIVE=1 /bin/bash -c "$(brew install.sh)" || true
          → brew installer: "Insufficient permissions" → exits 1
          → || true → install_homebrew returns 0
      → [if branch taken because install_homebrew returned 0]
      → brew_bytes=$(du -sb /home/linuxbrew/.linuxbrew "$HOME/.linuxbrew" 2>/dev/null | awk ...)
          → /home/linuxbrew/.linuxbrew exists (empty)
          → $HOME/.linuxbrew does NOT exist
          → du exits with code 1
          → 2>/dev/null silences the error message
          → EXIT CODE 1 propagates through command substitution $()
          → set -euo pipefail kills the script HERE
      ← sandbox-measure.sh exits with code 1

outer script exits with code 1
CI step fails
All subsequent steps (Update README, Validate, Commit, Push) are SKIPPED
```

---

## Comparison: Before vs. After Issue #55 Fix

### Before (commit `03a9d8da`, successful run 2026-02-22):

```bash
measure_install "Homebrew" "Package Manager" install_homebrew
```

The `measure_install` wrapper calls `install_homebrew` inside an `if "$@"; then / else` block:
```bash
if "$@"; then
  ...
else
  log_warning "Installation of $name failed"
  add_measurement "$name" "$category" 0 0
fi
```

Since `install_homebrew` returns 0 (due to `|| true`), the success branch runs, calculates `df`-based size (which was inaccurate but at least didn't crash), and continues.

### After (commit `3471bf8`, failing run 2026-02-24):

```bash
if install_homebrew; then
  brew_bytes=$(du -sb /home/linuxbrew/.linuxbrew "$HOME/.linuxbrew" 2>/dev/null | awk ...)
  ...
```

`install_homebrew` returns 0 (same as before), but now `du` is called on paths that may not exist, and its exit code is not handled. Result: script dies.

---

## Fix

The fix ensures `du` does not cause script failure when directories don't exist. There are two approaches:

### Option A: Only pass paths that exist to `du`

```bash
cleanup_for_measurement
if install_homebrew; then
  cleanup_for_measurement
  brew_paths=()
  [[ -d /home/linuxbrew/.linuxbrew ]] && brew_paths+=(/home/linuxbrew/.linuxbrew)
  [[ -d "$HOME/.linuxbrew" ]] && brew_paths+=("$HOME/.linuxbrew")
  if [[ ${#brew_paths[@]} -gt 0 ]]; then
    brew_bytes=$(du -sb "${brew_paths[@]}" 2>/dev/null | awk '{sum+=$1} END{print sum+0}')
  else
    brew_bytes=0
  fi
  brew_mb=$(awk "BEGIN {printf \"%.2f\", $brew_bytes / 1000000}")
  add_measurement "Homebrew" "Package Manager" "$brew_bytes" "$brew_mb"
else
  log_warning "Installation of Homebrew failed"
  add_measurement "Homebrew" "Package Manager" 0 0
fi
```

### Option B: Use `|| true` to suppress `du` exit code (simpler)

```bash
brew_bytes=$(du -sb /home/linuxbrew/.linuxbrew "$HOME/.linuxbrew" 2>/dev/null | awk '{sum+=$1} END{print sum+0}') || brew_bytes=0
```

**Option A** is more correct because it avoids measuring partial data silently; **Option B** is a minimal change. The same fix applies to the Rust measurement, though Rust paths (`$HOME/.rustup` and `$HOME/.cargo`) are typically both present after a successful install.

The same pattern in the outer script (lines 509–517 for Rust) should also be reviewed, though it doesn't currently fail because Rust installation succeeds and both directories exist.

---

## Related Issues

- **Issue #55**: Incorrect language runtime size measurements (introduced the regression)
- **Issue #46**: Relative path resolution for sandbox user JSON file
- **Issue #49**: sed-based JSON manipulation failures

---

## Online Research Findings

### 1. `ldd` "Broken Pipe" on GitHub Actions

The CI log includes this message:
```
/usr/bin/ldd: line 41: printf: write error: Broken pipe
/usr/bin/ldd: line 43: printf: write error: Broken pipe
```

**What causes it**: Homebrew's install.sh calls `ldd --version | head -n1` to detect the glibc version (for `outdated_glibc()` check). The `head -n1` command reads one line then closes its read-end of the pipe. This causes `ldd --version` to receive `SIGPIPE` when trying to write subsequent lines. The `/usr/bin/ldd` wrapper script in Ubuntu explicitly catches SIGPIPE via `trap`, but the `printf` calls on lines 41/43 still get "write error: Broken pipe" because the pipe to `head` is already closed.

**Impact**: Cosmetic only. Homebrew's install.sh uses `set -u` (not `set -e`), so this error does **not** abort the installer. The `head -n1` still gets its output. The broken pipe messages are a known side-effect of this common unix pipeline pattern.

**Related issues**:
- [CodSpeedHQ/action#89](https://github.com/CodSpeedHQ/action/issues/89): Same `/usr/bin/ldd: line 41: printf: write error: Broken pipe` in GitHub Actions; confirmed harmless by maintainers.
- [actions/runner-images#3414](https://github.com/actions/runner-images/issues/3414): "Broken Pipe error with Linux builds" — general discussion of pipe error messages in GitHub Actions.
- [Homebrew/install#670](https://github.com/Homebrew/install/issues/670): Resolved — glibc detection fallback added when `ldd` is missing.

**Workaround for the noise**: Homebrew could use `{ ldd --version 2>&1 || true; } | head -n1` to suppress the SIGPIPE messages, but this is a cosmetic issue and Homebrew maintainers have not prioritized it.

### 2. Homebrew Permission Check Behavior

The Homebrew installer's permission check (as of Feb 2026) aborts if ALL of these conditions are met:
```bash
! [[ -w "${HOMEBREW_PREFIX}" ]] &&    # /home/linuxbrew/.linuxbrew not writable
! [[ -w "/home/linuxbrew" ]]       && # /home/linuxbrew not writable
! [[ -w "/home" ]]                 && # /home not writable
! have_sudo_access                    # no passwordless sudo
```

In the failing CI run, even though the outer script pre-creates `/home/linuxbrew/.linuxbrew` and chowns it to sandbox, the Homebrew installer still aborts. This suggests that at the time Homebrew runs (inside the sandbox user sub-script), the writability check fails. Possible reasons:
- The `chown` completed but the directory permissions prevent sandbox from writing (mode 755 with root:root group ownership)
- OR the `chown -R sandbox:sandbox /home/linuxbrew` ran as expected, but `have_sudo_access` timing with `NONINTERACTIVE` causes ambiguous behavior

Regardless, this is considered a secondary root cause. The primary crash was the `du` exit code issue.

**Related Homebrew discussions**:
- [Discussion #5929](https://github.com/orgs/Homebrew/discussions/5929): "Insufficient permissions to install Homebrew to /home/linuxbrew/.linuxbrew" — common in containers/CI with non-root users.
- [Discussion #4212](https://github.com/orgs/Homebrew/discussions/4212): Sudo-less alternative installation methods.
- [Issue #714](https://github.com/Homebrew/install/issues/714): NONINTERACTIVE with `sudo -n -l mkdir` check.

### 3. `du` Exit Code with Non-Existent Paths (bash strict mode pitfall)

The core root cause — `du` returning exit code 1 for non-existent paths, killing a `set -euo pipefail` script even through `2>/dev/null` — is a **documented pitfall** of bash strict mode.

From [bash manual](https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin): under `set -e`, the shell exits if any simple command returns a non-zero status, with exceptions for commands used as conditions. However, **command substitution `$(...)` is NOT exempted** — if the command inside `$()` fails, the assignment statement returns the non-zero exit code.

Minimal reproducer:
```bash
bash -c 'set -euo pipefail
result=$(du -sb /tmp/nonexistent_dir 2>/dev/null | awk "{sum+=\$1} END{print sum+0}")
echo "Size: $result"'
# → exits with code 1 (echo never runs)
echo "Exit: $?"   # → 1
```

The `2>/dev/null` only redirects stderr (the error message), not the exit code. With `pipefail` and a pipeline `du ... | awk ...`, the overall exit code is the exit code of the last command to fail — but `awk` succeeds even on empty input, returning `0`. However, under `set -e`, when the command inside `$()` produces an error exit (from `du`), the substitution itself fails.

**Note**: In the specific bash version on Ubuntu 24.04 (bash 5.2), the `du -sb nonexistent 2>/dev/null | awk ...` pipeline: `awk` exits 0 on empty input, but `du` exits 1. With `pipefail`, the pipeline exit code is 1 (from `du`). The `$(...)` propagates this to the assignment, which triggers `set -e`.

---

## External Resources

- [Homebrew install.sh source](https://github.com/Homebrew/install/blob/main/install.sh) — permission check at line ~536
- [Homebrew Discussion #5929](https://github.com/orgs/Homebrew/discussions/5929) — "Insufficient permissions to install Homebrew to /home/linuxbrew/.linuxbrew"
- [Homebrew Discussion #4212](https://github.com/orgs/Homebrew/discussions/4212) — sudo-less installation discussion
- [Homebrew Issue #714](https://github.com/Homebrew/install/issues/714) — NONINTERACTIVE mode suppresses sudo password prompt
- [CodSpeedHQ/action#89](https://github.com/CodSpeedHQ/action/issues/89) — ldd broken pipe in GitHub Actions (cosmetic issue)
- [GNU bash manual: The Set Builtin](https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin) — `set -e` and command substitution behavior
