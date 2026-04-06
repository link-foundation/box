# Case Study: Incorrect Language Runtime Size Measurements (Issue #55)

## Summary

The component size table in the README reported several language runtimes and tools as **0 MB**, and the measurement methodology had multiple correctness issues. This case study documents all root causes found and the fixes applied.

## Issue Description

The issue ([#55](https://github.com/link-foundation/box/issues/55)) requested:
1. Verify all language runtimes and tools are listed in the component sizes table.
2. Double-check correctness of size calculations.
3. Investigate zero values suspected to be incorrect.

## Data: Problematic Measurements (as of 2026-02-22T02:06:37Z)

| Component | `size_bytes` | `size_mb` | Expected Real Size |
|---|---|---|---|
| Essential Tools | 741,376 | **0** | ~741 KB (pre-installed on runner) |
| GitHub CLI | 548,864 | **0** | ~549 KB (pre-installed on runner) |
| Ruby Build Dependencies | 0 | **0** | 0 (pre-installed on runner) |
| Rust (via rustup) | 98,304 | **0** | ~700–900 MB |
| Homebrew | 16,384 | **0** | ~200–400 MB |

---

## Root Cause Analysis

### Root Cause 1: Integer Division Truncation (`size_mb` Calculation)

**Location:** `scripts/measure-disk-space.sh`, line 169 and line 377 (inner script)

```bash
local diff_mb=$((diff_bytes / 1024 / 1024))
```

This Bash integer arithmetic floors to zero for any component using less than 1,048,576 bytes (1 MiB). Examples:

| Component | `size_bytes` | `diff_bytes / 1024 / 1024` |
|---|---|---|
| Essential Tools | 741,376 | **0** (should be 1) |
| GitHub CLI | 548,864 | **0** (should be 1) |

**Fix:** Replace the MiB-truncating formula with rounded megabytes (1 MB = 1,000,000 bytes):

```bash
local diff_mb=$(( (diff_bytes + 500000) / 1000000 ))
```

This rounds to the nearest MB and aligns with how the README and most storage tools display sizes.

---

### Root Cause 2: Pre-Installed Tools on GitHub Actions Runners

**Affected components:** Essential Tools, GitHub CLI, Ruby Build Dependencies (`libyaml-dev`)

GitHub Actions `ubuntu-24.04` runners have many packages pre-installed:
- `git`, `curl`, `wget`, `build-essential`, `ca-certificates`, `gnupg`, `zip`, `unzip`, `screen`, `expect`
- `gh` (GitHub CLI)
- Common dev libraries: `libssl-dev`, `zlib1g-dev`, `libyaml-dev`, etc.

Because these are already present before the measurement script runs, the `df /` delta before and after installing them is near-zero or exactly zero. This is **correct behavior** — the measurement captures the *additional* disk space consumed. However, the zero values are misleading to readers of the README who expect each component to show a non-zero size.

**Evidence:** The GitHub Actions runner pre-installed software list confirms `gh` and common build tools are present:
- https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md

**Fix:** Add a note in the README table explaining that 0 MB means the tool was already present on the measurement system (GitHub Actions runner), not that it has zero size.

---

### Root Cause 3: Rust (via rustup) Reports Only 98,304 bytes (~96 KB)

**Expected size:** ~700–900 MB (full Rust toolchain with `rustc`, `cargo`, `std` library)

**Actual measured:** 98,304 bytes = 96 KiB = exactly 24 × 4 KiB filesystem blocks

**Root cause:** The Rust installation uses `rustup`, which installs to `~/.cargo` and `~/.rustup`. These directories ARE on the `/` filesystem and should be captured by `df /`. However, the measurement shows only 96 KiB — which corresponds to just directory metadata (inode blocks), not actual file content.

The most likely explanation is a **measurement ordering side effect**: The Rust installer (`sh.rustup.rs`) downloads and extracts large files to `/tmp` first, then moves them to `~/.cargo` and `~/.rustup`. The `cleanup_for_measurement` function in the inner box script runs `sync` before and after, but the key issue is that the `df --block-size=1` measurement captures **used blocks** at the filesystem level. When files are moved (hardlinked) rather than copied, the filesystem block count does not change. If rustup uses `mv` from a tmpfs (`/tmp`) mount to the home directory on the root filesystem (`/`), this would show up correctly. But if the temp download location is on the same filesystem as the home dir, a `mv` is a rename (no block reallocation), and `df /` would only show the *net new* blocks — which could be just directory entries.

**Additional factor:** The `cleanup_for_measurement` in the inner script cleans `/tmp/measure-*` files, not all of `/tmp`. But the outer script's `cleanup_for_measurement` (which cleans all of `/tmp/*`) is NOT called during box user measurements. So this cleanup behavior does not explain the Rust measurement issue.

**Verification attempt:** A typical `rustup` installation creates:
- `~/.rustup/toolchains/stable-*/` (~700 MB)
- `~/.cargo/bin/` (~50 MB)

Total: ~750+ MB. A measurement of 96 KiB is clearly a **measurement error**, not a successful measurement of a minimal install.

**Proposed fix:** Instead of measuring the installation delta via `df /`, measure Rust's actual installed size directly:

```bash
du -sb ~/.rustup ~/.cargo 2>/dev/null | awk '{sum += $1} END {print sum}'
```

See Root Cause 5 for the general methodology fix.

---

### Root Cause 4: Homebrew Reports Only 16,384 bytes (16 KiB)

**Expected size:** ~200–500 MB (Homebrew itself + Linuxbrew dependencies)

**Actual measured:** 16,384 bytes = 16 KiB = 4 filesystem blocks

**Root cause:** The outer measurement script (running as root) creates the directory `/home/linuxbrew/.linuxbrew` before the box user runs:

```bash
# In measure-disk-space.sh (outer, root):
if [ ! -d /home/linuxbrew/.linuxbrew ]; then
  maybe_sudo mkdir -p /home/linuxbrew/.linuxbrew
  ...
fi
```

Then, in the box user's inner script, `measure_install "Homebrew"` runs `install_homebrew`, which calls:

```bash
NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || true
```

Homebrew's install script detects that `/home/linuxbrew/.linuxbrew` already exists and may skip creating some directories (only adding the top-level structure), resulting in minimal new block allocations. Meanwhile the actual Homebrew git repository (several hundred MB) may be treated as a "sparse clone" by Homebrew internally or may take time to materialize on disk after the install finishes.

The 16 KiB measurement represents only the new directory entries created within the existing `/home/linuxbrew/.linuxbrew` directory structure, not the actual Homebrew installation size.

**Proposed fix:** Same as Root Cause 3 — use direct `du` measurement of the installation directory.

---

### Root Cause 5: General Methodology Issue — `df /` Delta Is Unreliable for User Installations

**Core problem:** The `measure_install` function measures disk usage change via:

```bash
start_bytes=$(df / --output=used --block-size=1 | tail -1)
# ... run installation ...
end_bytes=$(df / --output=used --block-size=1 | tail -1)
diff_bytes=$((end_bytes - start_bytes))
```

This approach has several correctness issues:

1. **Block granularity**: `df` reports used blocks at filesystem granularity (typically 4 KiB blocks). Files smaller than one block each still consume one block. Large numbers of small files can appear larger than their actual content.

2. **Non-monotonic behavior**: Installers often write to `/tmp` (which is included in `df /` if `/tmp` is on the root filesystem), then delete those temp files. If more is cleaned than installed, `diff_bytes` can be negative (already handled) or suspiciously low.

3. **Sparse files**: Some large files (e.g., database files, pre-allocated disk images) are sparse and reported differently by `df` vs `du`.

4. **Filesystem caching and lazy allocation**: Some filesystems defer block allocation. The `sync` call in `cleanup_for_measurement` helps but doesn't guarantee all allocations are flushed.

5. **Multi-process interference**: On the GitHub Actions runner, background system processes may write to `/` during the measurement window, introducing noise.

**Better approach for user-space installations:** After installation, directly measure the installed directories using `du -sb`:

```bash
# Example for Rust:
rust_bytes=$(du -sb ~/.rustup ~/.cargo 2>/dev/null | awk '{sum+=$1} END{print sum}')
```

This gives the actual consumed disk space for each language's home directory, independent of timing, caching, or temp file noise.

---

### Root Cause 6: Missing Component — `bubblewrap`

**Location:** `ubuntu/24.04/full-box/install.sh`, line 66:

```bash
maybe_sudo apt install -y bubblewrap
```

`bubblewrap` is a boxing tool installed as a system prerequisite for Rocq/Opam. It is listed in the install script but **not measured** in `scripts/measure-disk-space.sh`.

**Estimated size:** ~100–300 KB (small system utility).

---

## Timeline of Events

1. **2026-02-22T02:06:37Z** — Last measurement run completed, producing the current `data/disk-space-measurements.json` with zero values for 5 components.
2. **2026-02-23** — Issue #55 filed: "Check correctness of language runtimes sizes".
3. **2026-02-23** — Investigation reveals 6 root causes (documented above).

---

## Proposed Solutions

### Solution 1 (Immediate): Fix `size_mb` Rounding

Change both occurrences of:
```bash
local diff_mb=$((diff_bytes / 1024 / 1024))
```
to:
```bash
local diff_mb=$(( (diff_bytes + 500000) / 1000000 ))
```

This ensures components between 500 KB and 1 MB show as 1 MB rather than 0 MB.

### Solution 2 (Immediate): Add `bubblewrap` Measurement

Add to the outer measurement script:
```bash
measure_apt_install "Bubblewrap" "Dependencies" bubblewrap
```

### Solution 3 (Recommended): Add Note About Pre-installed Tools

Add a note in the README and/or JSON data that zero values for pre-installed tools reflect runner baseline state, not the actual package size.

### Solution 4 (Long-term): Switch to `du`-based Measurement for User Installations

Instead of (or in addition to) the `df /` delta method, directly measure each tool's installation directory size after installation:

```bash
# After install_rust:
rust_size=$(du -sb ~/.rustup ~/.cargo 2>/dev/null | awk '{sum+=$1} END{print sum+0}')
add_measurement "Rust (via rustup)" "Runtime" "$rust_size" "$(( (rust_size + 500000) / 1000000 ))"
```

This eliminates the timing and cleanup interference issues that cause near-zero measurements for Rust and Homebrew.

---

## Files Changed

- `scripts/measure-disk-space.sh` — Fix `size_mb` rounding, add `bubblewrap`, improve Rust and Homebrew measurement using `du`
- `data/disk-space-measurements.json` — Will be updated by next CI run
- `README.md` — Component sizes table updated by CI

---

## References

- GitHub Actions ubuntu-24.04 pre-installed software: https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md
- `df` vs `du` differences: `df` measures filesystem block usage; `du` measures actual file sizes (with possible rounding up to block size)
- Rustup installation layout: https://rust-lang.github.io/rustup/concepts/components.html
- Homebrew on Linux: https://docs.brew.sh/Homebrew-on-Linux
