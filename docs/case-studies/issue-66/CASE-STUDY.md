# Case Study: Issue #66 — bash syntax error when running `bash` inside `bash`

## Executive Summary

Running `bash` (or `sh`, `zsh`) inside an already-running bash session in the sandbox container produces a fatal syntax error:

```
bash: /home/sandbox/.bashrc: line 167: syntax error: unexpected end of file
```

**Root cause**: The `.bashrc` merge algorithm in the Dockerfile used line-level deduplication. It skipped any line already present in the base `.bashrc`. Since the base `.bashrc` already contains several standalone `fi` lines (closing Ubuntu's built-in `if` blocks), the `fi` that closes the Perlbrew `if [ -n "$PS1" ]; then ... fi` block was silently discarded, leaving an unclosed `if` — which produces the "unexpected end of file" syntax error every time bash starts.

**Secondary finding**: SDKMAN's `.bashrc` snippet used bash-specific `[[ ]]` double-bracket syntax and `source` instead of POSIX `.`, which would fail when `.bashrc` is sourced under `/bin/sh` (dash on Ubuntu).

---

## 1. Data Collection

### 1.1 Error Reproduction

The reported error:

```
konard@MacBook-Pro-Konstantin ~ % $ --isolated docker --image konard/sandbox:1.3.14 -- bash
$ bash
bash: /home/sandbox/.bashrc: line 167: syntax error: unexpected end of file
```

This error occurs when:
1. Container starts → `entrypoint.sh` sources `~/.bashrc` (works, because `entrypoint.sh` is already running bash)
2. User runs `bash` → new bash process starts, tries to source `~/.bashrc`
3. `~/.bashrc` has a syntax error (unclosed `if`) → bash reports it and aborts

The same error occurs with any interactive bash invocation: `bash`, `bash -i`, `bash --login`, `sh`.

### 1.2 .bashrc Generation

The `~/.bashrc` for the sandbox user is not a static file — it is constructed at Docker image build time by the Dockerfile's merge step (lines 136–152 in root `Dockerfile`, lines 155–171 in `ubuntu/24.04/full-sandbox/Dockerfile`).

The merge algorithm:
1. Takes the essentials-sandbox `.bashrc` as the base
2. For each of 11 language stages (python, go, rust, java, kotlin, ruby, php, perl, swift, lean, rocq), reads each line of that language's `.bashrc`
3. Appends each line **only if it is not already present** in the base (`grep -qxF "$line"`)

### 1.3 How the Bug Manifests

Ubuntu's `/etc/skel/.bashrc` (which forms the starting `.bashrc`) already contains multiple standalone `fi` lines at the top level:

```bash
if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(cat /etc/debian_chroot)
fi   ← standalone 'fi' in base

if [ "$TERM" = "xterm-color" ] ...; then
    color_prompt=yes
fi   ← standalone 'fi' in base
```

The Perl stage adds this block to its `.bashrc`:

```bash
# Perlbrew configuration
if [ -n "$PS1" ]; then
  export PERLBREW_ROOT="$HOME/.perl5"
  [ -f "$PERLBREW_ROOT/etc/bashrc" ] && source "$PERLBREW_ROOT/etc/bashrc"
fi   ← this 'fi' gets deduplicated!
```

When the merge algorithm processes Perl's `.bashrc`, it reaches the closing `fi`. The `grep -qxF "fi"` check finds that `fi` is **already in the base** (from Ubuntu's `if` blocks). So the `fi` is **skipped**. The result in the merged `.bashrc`:

```bash
# Perlbrew configuration
if [ -n "$PS1" ]; then            ← if block opens
  export PERLBREW_ROOT="$HOME/.perl5"
  [ -f "$PERLBREW_ROOT/etc/bashrc" ] && source "$PERLBREW_ROOT/etc/bashrc"
                                  ← fi was SKIPPED by deduplication!
```

This unclosed `if` causes bash to report:
```
bash: /home/sandbox/.bashrc: line N: syntax error: unexpected end of file
```

### 1.4 Experiment Reproduction

A reproducible test is available at `experiments/test-bashrc-merge.sh`. Running it confirms:

```
Old algorithm produces syntax error:
/tmp/.bashrc-merged: line 57: syntax error: unexpected end of file
  -> SYNTAX ERROR (bug reproduced!)

Lines skipped (already in base):
  SKIPPED: 'fi'   ← Perlbrew's closing fi was lost
```

---

## 2. Root Cause Analysis

### 2.1 Primary Root Cause: Line-Level Deduplication Breaks Multi-Line Constructs

The merge algorithm treats each line in isolation. Shell `if/fi` blocks span **multiple lines** with structural relationships between them. A closing `fi` has meaning only in the context of its opening `if`. Line-level deduplication cannot preserve this relationship.

Any line that appears as a "structural token" in shell syntax — `fi`, `done`, `esac`, `}` — is a deduplication collision hazard if such a token already exists elsewhere in the base file.

**Affected code:**
- `Dockerfile` lines 136–152
- `ubuntu/24.04/full-sandbox/Dockerfile` lines 155–171

### 2.2 Secondary Issue: Bash-Specific Syntax in `.bashrc`

The SDKMAN install sections in `java/install.sh`, `kotlin/install.sh`, and `full-sandbox/install.sh` write:

```bash
[[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]] && source "$HOME/.sdkman/bin/sdkman-init.sh"
```

Both `[[ ]]` (extended test) and `source` are **bash extensions not available in POSIX sh**. On Ubuntu 24.04, `/bin/sh` is `dash`. If `.bashrc` is sourced from a `sh` or `dash` script, this line would fail:

```
/bin/sh: 1: [[: not found
```

The POSIX-compatible equivalent is:
```bash
[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ] && . "$HOME/.sdkman/bin/sdkman-init.sh"
```

**Affected files:**
- `ubuntu/24.04/java/install.sh` line 30
- `ubuntu/24.04/kotlin/install.sh` line 31
- `ubuntu/24.04/full-sandbox/install.sh` line 188

---

## 3. Timeline

1. **Image build**: Dockerfile merge step runs, `fi` from Perlbrew block is deduplicated away → `.bashrc` has unclosed `if`
2. **Container start**: `entrypoint.sh` sources `.bashrc` via `. "$HOME/.bashrc"`. This apparently succeeds because `entrypoint.sh` is a plain script (non-interactive bash), and `.bashrc` starts with `case $- in *i*) ;; *) return;; esac` — so it **returns early** before reaching the unclosed `if` block
3. **User runs `bash`**: New interactive bash session starts, does NOT return early (interactive), reaches the `if [ -n "$PS1" ]; then` block without its `fi`, hits end-of-file → syntax error

This explains why the container appears to start fine, but running `bash` inside it fails.

---

## 4. Solution

### 4.1 Fix 1: Section-Header Deduplication in Merge Algorithm

Instead of deduplicating line-by-line, the algorithm now deduplicates by **section header** — the unique `# <Tool> configuration` comment that introduces each language's `.bashrc` block.

The new algorithm:
- Reads each language's `.bashrc`
- When it encounters a line matching `^# .+ configuration$`, checks if this header is already in the base
- If the header is NOT present: appends the header and all subsequent lines until the next section header
- If the header IS present: skips the entire section (no deduplication of individual structural tokens)

This preserves all multi-line constructs intact and handles cross-language deduplication correctly (e.g., both `java/install.sh` and `kotlin/install.sh` write `# SDKMAN configuration` — the second occurrence is correctly skipped as a whole).

**Files changed:**
- `Dockerfile` (merge RUN step)
- `ubuntu/24.04/full-sandbox/Dockerfile` (merge RUN step)

### 4.2 Fix 2: POSIX-Compatible SDKMAN Syntax

Replace `[[ -s ... ]] && source` with `[ -s ... ] && .` in all three install scripts.

**Files changed:**
- `ubuntu/24.04/java/install.sh`
- `ubuntu/24.04/kotlin/install.sh`
- `ubuntu/24.04/full-sandbox/install.sh`

### 4.3 Verification

An automated test at `experiments/test-bashrc-merge-fix.sh` verifies:

1. The old algorithm produces a syntax error (bug confirmed)
2. The new algorithm produces a valid `.bashrc` (fix confirmed)
3. SDKMAN section appears exactly once (kotlin dedup works)
4. Perlbrew `if/fi` block is complete and balanced
5. No `[[ ]]` bash-specific syntax in the merged output

Running the test:
```bash
bash experiments/test-bashrc-merge-fix.sh
```

Expected output: `ALL TESTS PASSED - Fix is verified!` (13/13 passing)

---

## 5. Why `entrypoint.sh` Was Not Affected

The `.bashrc` starts with:

```bash
case $- in
    *i*) ;;
      *) return;;
esac
```

This guard returns early for non-interactive shells. `entrypoint.sh` is not an interactive shell, so it returns before reaching the broken `if [ -n "$PS1" ]` block. This is why the container started fine — the broken `.bashrc` was never fully executed.

When the user runs `bash` explicitly, it starts an interactive session (because `bash` inherits the TTY). The interactive shell does NOT return early, executes the full `.bashrc`, and hits the unclosed `if` at the end of file.

This also explains the issue title: "We should not run `bash` inside `bash`" — the entrypoint was already bash, and starting another bash exposed the broken `.bashrc`.

---

## 6. References

- [Issue #66: We should not run bash inside bash](https://github.com/link-foundation/sandbox/issues/66)
- [PR #67: Fix .bashrc merge algorithm and SDKMAN POSIX syntax](https://github.com/link-foundation/sandbox/pull/67)
- [Bash manual: Bash startup files](https://www.gnu.org/software/bash/manual/bash.html#Bash-Startup-Files)
- [POSIX Shell Grammar](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html)
- [experiments/test-bashrc-merge.sh](../../experiments/test-bashrc-merge.sh) — bug reproduction
- [experiments/test-bashrc-merge-fix.sh](../../experiments/test-bashrc-merge-fix.sh) — fix verification
