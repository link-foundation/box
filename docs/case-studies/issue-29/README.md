# Case Study: Components Size Update Failed (0MB Total)

**Issue:** [#29 - Components size update failed](https://github.com/link-foundation/box/issues/29)

**Date of Investigation:** 2026-01-29

## Executive Summary

The `measure-disk-space.yml` workflow ran successfully but produced incorrect results: all components showed 0MB in size, and the total installation size was recorded as 0MB. The root cause is that the "Free up disk space" step in the workflow removes critical packages and apt metadata, making it impossible for the measurement script to install any packages afterward.

## Timeline of Events

| Date | Event | Commit | Result |
|------|-------|--------|--------|
| 2026-01-29 14:07 | Measure Disk Space workflow triggered | [035998b](https://github.com/link-foundation/box/commit/035998b08217cfa99ea947fc73b060cd4260f93c) | Workflow "succeeded" but produced incorrect data |
| 2026-01-29 14:09 | Workflow committed results | [3d75e41](https://github.com/link-foundation/box/commit/3d75e41e572224f31248aff1262ef565e7f23a34) | Commit message: "chore: update component disk space measurements (0MB total)" |

## Root Cause Analysis

### Problem Statement

When the `measure-disk-space.yml` workflow runs, it:
1. Successfully checks out the repository
2. Frees up disk space by removing large packages
3. Runs the measurement script
4. Records 0MB for all components
5. Commits and pushes the incorrect data

### Root Cause: Aggressive Disk Space Cleanup Breaks APT

The workflow's "Free up disk space" step contains the following commands:

```yaml
- name: Free up disk space
  run: |
    # Remove unnecessary large packages
    sudo apt-get remove -y '^dotnet-.*' '^llvm-.*' 'php.*' '^mongodb-.*' azure-cli google-cloud-cli google-chrome-stable firefox powershell mono-devel || true
    sudo apt-get autoremove -y
    sudo apt-get clean

    # Remove large directories
    sudo rm -rf /usr/share/dotnet
    sudo rm -rf /usr/local/lib/android
    ...
```

This causes a cascade of problems:

1. **`apt-get autoremove -y`** removes packages that other packages depend on, including development tools
2. **`apt-get clean`** removes downloaded package files from the cache

Additionally, the `measure-disk-space.sh` script's `cleanup_for_measurement()` function runs:

```bash
cleanup_for_measurement() {
  maybe_sudo apt-get clean 2>/dev/null || true
  maybe_sudo apt-get autoclean 2>/dev/null || true
  maybe_sudo rm -rf /var/lib/apt/lists/* 2>/dev/null || true  # <-- Deletes apt metadata!
  ...
}
```

### Evidence from Logs

From [Run 21481304786](https://github.com/link-foundation/box/actions/runs/21481304786):

**Step 1: Free up disk space removed critical packages:**
```
=== Initial disk space ===
Filesystem      Size  Used Avail Use% Mounted on
/dev/root        72G   50G   23G  69% /

=== Disk space after cleanup ===
Filesystem      Size  Used Avail Use% Mounted on
/dev/root        72G   26G   47G  36% /
```

This freed ~24GB but removed many development packages in the process.

**Step 2: Measurement script failed to install packages:**
```
[*] Measuring installation: Essential Tools
Reading package lists...
Building dependency tree...
Reading state information...
Package build-essential is not available, but is referred to by another package.
This may mean that the package is missing, has been obsoleted, or
is only available from another source

No apt package "expect", but there is a snap with that name.
Try "snap install expect"

E: Package 'build-essential' has no installation candidate
E: Unable to locate package expect
[!] Installation of Essential Tools failed
[✓] Recorded: Essential Tools - 0MB
```

**Step 3: Script exited early with only one component:**
```json
{
  "generated_at": "",
  "total_size_mb": 0,
  "components": [{"name": "Essential Tools", "category": "System", "size_bytes": 0, "size_mb": 0}]
}
```

### Flow Diagram

```
┌─────────────────────────────────┐
│ 1. Checkout Repository          │
└─────────────────────────────────┘
                │
                ▼
┌─────────────────────────────────┐
│ 2. Free Up Disk Space           │
│ - apt-get remove packages       │
│ - apt-get autoremove ◄────────────── Removes build-essential dependencies
│ - apt-get clean                 │
└─────────────────────────────────┘
                │
                ▼
┌─────────────────────────────────┐
│ 3. Run Measurement Script       │
│ - cleanup_for_measurement()     │
│ - rm -rf /var/lib/apt/lists/* ◄──── Deletes apt package metadata
│ - apt update                    │
└─────────────────────────────────┘
                │
                ▼
┌─────────────────────────────────┐
│ 4. Try to Install Packages      │
│ - apt install build-essential   │
│ - FAILS: Package not found  ◄─────── APT metadata is incomplete
└─────────────────────────────────┘
                │
                ▼
┌─────────────────────────────────┐
│ 5. Record 0MB, Commit, Push     │
│ - All components show 0MB       │
└─────────────────────────────────┘
```

## Solution Options

### Option 1: Remove the "Free up disk space" Step (Recommended)

The simplest fix is to remove or significantly reduce the "Free up disk space" step. The GitHub Actions runner has sufficient space for most operations, and the aggressive cleanup causes more problems than it solves.

**Pros:**
- Simple to implement
- Eliminates root cause
- APT will work correctly

**Cons:**
- Less disk space available (may hit limits for very large installations)

### Option 2: Preserve APT Functionality After Cleanup

If disk space cleanup is necessary, ensure apt-get update is run after cleanup:

```yaml
- name: Free up disk space
  run: |
    # ... cleanup commands ...

    # CRITICAL: Restore APT functionality
    sudo apt-get update
```

And modify the measurement script to NOT delete apt lists:

```bash
cleanup_for_measurement() {
  maybe_sudo apt-get clean 2>/dev/null || true
  maybe_sudo apt-get autoclean 2>/dev/null || true
  # DON'T delete apt lists: rm -rf /var/lib/apt/lists/*
  rm -rf /tmp/* 2>/dev/null || true
  rm -rf /var/tmp/* 2>/dev/null || true
  sync
}
```

**Pros:**
- Keeps disk space cleanup benefits
- APT still works

**Cons:**
- Requires changes in multiple places
- APT lists take some disk space

### Option 3: Use Docker-based Measurement

Run the measurement in a fresh Docker container rather than on the GitHub Actions runner directly. This ensures a clean environment for each measurement.

**Pros:**
- Completely isolated environment
- Reproducible measurements

**Cons:**
- More complex implementation
- Docker-in-Docker or custom runner needed

## Recommended Fix

**Option 1** is recommended for simplicity. The workflow should:

1. Remove or minimize the "Free up disk space" step
2. Ensure `apt-get update` runs before any package installation
3. Not delete `/var/lib/apt/lists/*` during cleanup

### Implementation

```yaml
# In .github/workflows/measure-disk-space.yml
# Remove or comment out the aggressive cleanup:

- name: Free up disk space
  run: |
    echo "=== Initial disk space ==="
    df -h /

    # Only remove large directories that won't affect apt
    sudo rm -rf /usr/share/dotnet
    sudo rm -rf /usr/local/lib/android
    sudo rm -rf /opt/hostedtoolcache

    # DON'T remove packages with apt-get remove
    # DON'T run apt-get autoremove

    # Refresh apt cache to ensure packages are available
    sudo apt-get update

    echo "=== Disk space after cleanup ==="
    df -h /
```

And in `scripts/measure-disk-space.sh`:

```bash
cleanup_for_measurement() {
  # Clean apt cache but preserve metadata
  maybe_sudo apt-get clean 2>/dev/null || true
  # Don't delete apt lists - they're needed for package installation
  # maybe_sudo rm -rf /var/lib/apt/lists/* 2>/dev/null || true

  # Clean temp files
  maybe_sudo rm -rf /tmp/* 2>/dev/null || true
  maybe_sudo rm -rf /var/tmp/* 2>/dev/null || true

  sync
}
```

## Prevention

To prevent this issue from recurring:

1. **Add validation step**: Before committing measurement results, validate that the total size is reasonable (e.g., > 1000MB)

2. **Add workflow testing**: Test the workflow on a branch before merging changes

3. **Add monitoring**: Alert when measurements show significant deviations from expected values

## Files

- `ci-logs/measure-disk-space-21481304786.log` - Full CI logs from the failed run (stored separately due to size)
- `measurements.json` - The incorrect measurements file that was committed

## Related Issues

- This issue is related to the GitHub Actions disk space limitations
- Similar to common CI/CD issues where cleanup steps break subsequent steps

## References

- [GitHub Actions Runner Disk Space](https://docs.github.com/en/actions/using-github-hosted-runners/about-github-hosted-runners#supported-runners-and-hardware-resources)
- [Common GitHub Actions Pitfalls](https://docs.github.com/en/actions/learn-github-actions/understanding-github-actions)
- [APT Package Management](https://wiki.debian.org/apt)

## Conclusion

The "0MB total" measurement failure was caused by aggressive disk space cleanup that removed packages and apt metadata required for the measurement script to function. The fix is straightforward: remove or reduce the cleanup step, ensure apt-get update runs after any cleanup, and avoid deleting apt lists during measurement.
