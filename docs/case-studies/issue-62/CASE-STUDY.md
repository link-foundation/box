# Case Study: `cargo` Not Found in `konard/box:1.3.13` Docker Image (Issue #62)

## Issue Reference
- **Issue**: https://github.com/link-foundation/box/issues/62
- **PR**: https://github.com/link-foundation/box/pull/63
- **Docker image**: `konard/box:1.3.13`
- **CI run for 1.3.13**: [22596250182](https://github.com/link-foundation/box/actions/runs/22596250182)

---

## Executive Summary

The user reported that `cargo` (Rust toolchain) is "not found" when running commands inside the `konard/box:1.3.13` Docker image using the `--isolated docker` tool with `--image konard/box:1.3.13`. Investigation reveals **two distinct but related issues**:

1. **Immediate cause**: The command tested was `сargo` (using Cyrillic Unicode character U+0441 'с' instead of ASCII 'c'). This exact string does not exist as a binary and will always fail with "not found", regardless of whether the Rust toolchain is installed.

2. **Underlying structural problem**: The `--isolated docker` runner calls commands via `/bin/sh -c "..."` which **bypasses the ENTRYPOINT** of the Docker image. Even if `cargo` (ASCII) were tested, the `nvm` shell function (required for Node.js version management) would not be accessible because NVM is a shell function only available in interactive bash sessions.

3. **CI/CD gap**: The CI test step in `release.yml` uses `|| echo "test failed"` patterns which make ALL test failures **non-fatal**. An image where `cargo`, `python`, `go`, or any other tool fails is still released successfully — CI reports "completed" even when tools don't work.

The user requested:
1. CI/CD tests that actually FAIL image builds if something isn't working
2. Prefer local/user installation via version managers over global/root installs (already implemented correctly)
3. A compiled case study in `./docs/case-studies/issue-62`

---

## Timeline of Events

### 2026-03-02T21:21:21Z — Version 1.3.13 Released

- **Event**: PR #61 merged to main, adding `release-only` mode to workflow_dispatch
- **CI Run**: [22596250182](https://github.com/link-foundation/box/actions/runs/22596250182) — SUCCESS
- Docker image `konard/box:1.3.13` published to Docker Hub and GHCR
- All build jobs succeeded (JS, essentials, language images, full-box)
- No CI test step ran against the full image (docker-build-test only runs on PRs)

### 2026-03-02T22:14Z — User Tests the Image

The user ran commands using the `--isolated docker` runner with `konard/box:1.3.13`:

```
$ --isolated docker --image konard/box:1.3.13 -- node -v
v20.20.0   ✓

$ --isolated docker --image konard/box:1.3.13 -- dotnet --version
8.0.124    ✓

$ --isolated docker --image konard/box:1.3.13 -- сargo -v
/bin/sh: 1: сargo: not found   ✗  (exit 127)

$ --isolated docker --image konard/box:1.3.13 -- nvm
/bin/sh: 1: nvm: not found     ✗  (exit 127)
```

### 2026-03-02T22:XX — Issue #62 Filed

User files the issue, reporting that `cargo` and `nvm` are not found in the 1.3.13 image.

---

## Root Cause Analysis

### Root Cause 1 (Primary for cargo): Cyrillic 'с' vs ASCII 'c'

**Evidence**: The shell output shows `/bin/sh: 1: сargo: not found`. The command in the issue body is `сargo` where the first character 'с' is Unicode U+0441 (Cyrillic small letter es), not ASCII 'c' (U+0063).

**Why this happened**: The user's keyboard layout briefly switched to Cyrillic (a common occurrence on multilingual keyboards) when typing the 'c' character. The resulting string `сargo` is not the same as `cargo` and no such binary exists anywhere.

**Verification**: The `node -v` command works (v20.20.0), and `dotnet --version` works. If the Docker image's PATH was completely broken, these would also fail. The fact that `node` and `dotnet` work confirms that PATH-accessible binaries function correctly.

**Can `cargo` (ASCII) actually be found?** Yes — the Dockerfile sets `ENV PATH="/home/box/.cargo/bin:..."` at image build time. Docker ENV variables are embedded in the image and are available even when running without the entrypoint. Running `docker run konard/box:1.3.13 cargo --version` with ASCII 'c' should work.

### Root Cause 2 (For `nvm`): NVM Is a Shell Function, Not a Binary

**Evidence**: The output shows `/bin/sh: 1: nvm: not found`.

**Why**: NVM (Node Version Manager) is implemented as a **shell function**, not a standalone binary. It is loaded into the shell by sourcing `$NVM_DIR/nvm.sh` in `.bashrc` or the entrypoint script. When the `--isolated docker` runner invokes commands via `/bin/sh -c "nvm"`, it runs a fresh, non-interactive `/bin/sh` that:
- Does NOT source `.bashrc` (which is only sourced for interactive bash sessions)
- Does NOT invoke the container's ENTRYPOINT (the runner overrides it with `/bin/sh`)
- Has no `nvm` function defined

This is **by design** — NVM was never meant to be invoked from non-interactive shells. The Node.js binary itself (`node`) IS accessible because NVM installs it at `~/.nvm/versions/node/vX/bin/node`, and its parent directory is added to PATH when NVM is initialized. The static PATH ENV in the Dockerfile does NOT include the NVM bin directory (it's version-specific), so `node` is only available after the entrypoint sources `.bashrc` or NVM.

**Wait**: The user ran `node -v` and got `v20.20.0`. If the entrypoint isn't called and NVM isn't sourced, how does `node` work?

This means the `--isolated docker` runner DOES call the ENTRYPOINT. The entrypoint script at `/usr/local/bin/entrypoint.sh` sources `.bashrc` and initializes NVM, making `node` available. The `nvm` shell function IS initialized by the entrypoint... but `nvm` is a bash function, and if the entrypoint calls `exec "$@"` where `$@` is `/bin/sh -c "nvm"`, then the `/bin/sh` subprocess won't have the bash function.

**Actual mechanism**: The `--isolated docker` runner likely invokes:
```
docker run konard/box:1.3.13 /bin/sh -c "nvm"
```
Which calls the ENTRYPOINT with args `/bin/sh -c "nvm"`. The entrypoint does `exec /bin/sh -c "nvm"`. The `/bin/sh` process gets a fresh environment — it has ENV variables (from Docker) but NOT the bash function `nvm`. So `nvm` is not found.

For `node`: the entrypoint, when running normally (i.e., via `exec /bin/sh -c "node -v"`), has already modified the PATH to include the NVM bin directory (via `source $NVM_DIR/nvm.sh`). This modified PATH is inherited by the child process `/bin/sh`. Since `node` is a binary (not a shell function), it's found in PATH. ✓

For `cargo`: the entrypoint similarly inherits `/home/box/.cargo/bin` in PATH (from both ENV and potentially from sourcing `.bashrc`). `cargo` is a binary. If the binary exists at `/home/box/.cargo/bin/cargo`, it should be accessible. The **Cyrillic character** is what caused the actual failure.

### Root Cause 3 (Structural): CI Tests Are Non-Fatal

**Evidence**: In `.github/workflows/release.yml`, the "Test full box" step (within `docker-build-test`):

```yaml
docker run --rm box-test rustc --version || echo "Rust test failed"
docker run --rm box-test node --version  || echo "Node.js test failed"
# ... etc
```

The `|| echo "..."` pattern means: if the `docker run` command fails (exit code ≠ 0), print the message but **continue with exit code 0**. This makes ALL test failures non-fatal. The step always "succeeds" regardless of what tools are missing.

**Consequence**: If `cargo` (or any other tool) genuinely didn't work, the CI/CD would still release the image. This creates a false sense of reliability — the test infrastructure exists but provides no actual quality gate.

Additionally, `docker-build-test` only runs on **pull requests**, not on push-to-main or workflow_dispatch builds. The main image release path (push/workflow_dispatch) has **no toolchain validation at all**.

---

## Online Research

### NVM Shell Function Architecture

**Source**: [NVM README](https://github.com/nvm-sh/nvm/blob/master/README.md)
> "nvm is a version manager for node.js, designed to be installed per-user, and invoked per-shell. nvm works as a shell function."

NVM is explicitly documented as a shell function, not a binary. It must be sourced into the shell session. This is standard behavior and not a bug. The correct way to access Node.js in non-interactive containers is to use the `node` binary directly (installed by NVM in `~/.nvm/versions/node/vX/bin/`), not the `nvm` shell function.

### Docker ENTRYPOINT and CMD Interaction

**Source**: [Docker documentation](https://docs.docker.com/engine/containers/run/#entrypoint-default-command-to-execute-at-runtime)

When a Docker image has `ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]` and is run as:
```
docker run image arg1 arg2
```
The container executes: `/usr/local/bin/entrypoint.sh arg1 arg2`

The entrypoint CAN be bypassed with `--entrypoint` flag. The `--isolated docker` runner likely does NOT bypass the entrypoint (since `node` works via NVM, which requires the entrypoint to run).

### Unicode Homoglyph Issues

The Cyrillic 'с' (U+0441) is visually indistinguishable from ASCII 'c' (U+0063) in most monospace fonts. This is a known class of bugs/security issues called "homoglyph attacks" or "confusable characters". In this case, it's an innocent typing error rather than a security concern.

---

## Solutions Implemented

### Solution 1: Make CI Tests Fatal (Primary Fix)

**Change**: Remove `|| echo "..."` fallbacks from test commands in `docker-build-test`. Use `set -e` (or rely on bash's default error propagation) to make any test failure fail the CI step.

**Implementation**: Updated the "Test JS box", "Test essentials box", and "Test full box" steps in `.github/workflows/release.yml` to use strict test commands that fail the step on any error.

**Also added**: A dedicated "Verify toolchains" step that runs comprehensive commands for every installed language runtime, using the entrypoint (bash) to ensure all shell-function-based tools (like NVM) are accessible.

### Solution 2: Add Comprehensive Toolchain Tests

**Change**: Added tests for ALL language toolchains including those missing from the original test matrix:
- Added: `kotlin`, `ruby`, `swift`, `r`, `cargo`, `kotlin`, `dotnet`, `python3`, `pip`, `gem`, `rustup`
- Renamed ambiguous `python` to `python3` (which is what's installed on Ubuntu 24.04)
- Added `cargo --version` alongside `rustc --version` (tests both tools)
- Added version manager commands where possible (pyenv, rbenv, etc.) via bash entrypoint

### Solution 3: Run Basic Smoke Tests on Every Build (Including Main/Dispatch)

**Change**: Added a "smoke test" step to the `docker-build-push` job that runs after each full-box image push. This ensures the released image is validated, not just PR builds.

---

## Data Files

- `ci-logs/release-1313-run-22596250182.log` — The successful CI run that built and released `konard/box:1.3.13`

---

## References

- [Issue #62](https://github.com/link-foundation/box/issues/62)
- [NVM README — NVM is a shell function](https://github.com/nvm-sh/nvm/blob/master/README.md)
- [Docker ENTRYPOINT documentation](https://docs.docker.com/engine/containers/run/#entrypoint-default-command-to-execute-at-runtime)
- [Unicode Confusables — Unicode.org](https://www.unicode.org/reports/tr39/#Confusable_Detection)
- [OWASP: Homoglyph Attacks](https://owasp.org/www-community/attacks/Unicode_Characters)
