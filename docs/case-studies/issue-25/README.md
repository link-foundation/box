# Case Study: Issue #25 - CI/CD ARM64 Build Failure

## Summary

The CI/CD pipeline fails during the ARM64 Docker image build because the `fasm` (Flat Assembler) package is not available for the ARM64 architecture in Ubuntu repositories.

## Timeline of Events

| Timestamp (UTC) | Event |
|-----------------|-------|
| 2026-01-29 09:28:57 | CI pipeline triggered on main branch |
| 2026-01-29 09:29:00 | Apply Changesets job completed successfully |
| 2026-01-29 09:29:08 | docker-build-push (amd64) started |
| 2026-01-29 09:29:36 | docker-build-push (amd64) completed successfully |
| 2026-01-29 09:29:41 | docker-build-push-arm64 started |
| 2026-01-29 09:45:27 | C/C++ development tools installed successfully |
| 2026-01-29 09:45:28 | Assembly tools installation begins |
| 2026-01-29 09:45:29 | Error: `E: Package 'fasm' has no installation candidate` |
| 2026-01-29 09:45:36 | docker-build-push-arm64 failed with exit code 100 |

## Root Cause Analysis

### The Problem

The installation script `scripts/ubuntu-24-server-install.sh` at line 209 attempts to install both NASM and FASM:

```bash
maybe_sudo apt install -y nasm fasm
```

### Why It Fails on ARM64

1. **FASM Architecture Limitation**: FASM (Flat Assembler) is a self-compiling assembler specifically designed for x86 and x86-64 instruction sets. The binary itself is written in x86 assembly, making it inherently incompatible with ARM architectures.

2. **Ubuntu Package Availability**: According to [packages.ubuntu.com](https://packages.ubuntu.com/noble/fasm), the `fasm` package in Ubuntu 24.04 (Noble) is only available for the `amd64` architecture.

3. **Package Dependencies**: FASM requires `libc6-i386` (32-bit libraries for AMD64), which indicates its x86-specific nature.

### Evidence from CI Logs

```
#10 924.0 [*] Installing Assembly tools (NASM, FASM)...
#10 925.2 Package fasm is not available, but is referred to by another package.
#10 925.2 This may mean that the package is missing, has been obsoleted, or
#10 925.2 is only available from another source
#10 925.2
#10 925.2 E: Package 'fasm' has no installation candidate
```

## Available Solutions

### Solution 1: Conditional Installation Based on Architecture (Recommended)

Modify the installation script to check the system architecture and only install FASM on x86-64 systems:

```bash
# --- Install Assembly Tools ---
log_info "Installing Assembly tools..."
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
  maybe_sudo apt install -y nasm fasm
  log_success "Assembly tools installed (NASM + FASM)"
else
  maybe_sudo apt install -y nasm
  log_success "Assembly tools installed (NASM only - FASM not available for $ARCH)"
fi
```

### Solution 2: Use Alternative ARM Assemblers

For ARM64 systems, consider using native ARM assemblers as alternatives:
- **NASM**: Cross-platform, supports ARM output (with limitations)
- **GNU Assembler (as)**: Already included via `build-essential`
- **LLVM MC (llvm-mc)**: Already included via `llvm` package
- **FASMARM**: A separate project for ARM assembly, but not in Ubuntu repos

### Solution 3: Skip FASM Entirely

If FASM is not critical for the box environment, simply remove it from the installation list.

## Recommended Fix

**Solution 1** is recommended as it:
1. Maintains FASM availability on x86-64 systems where it works
2. Allows ARM64 builds to complete successfully
3. Provides clear logging about what is installed
4. Doesn't require any additional packages or builds

## References

- [Flat Assembler Official Site](https://flatassembler.net/)
- [FASMARM - ARM Cross Assembler](https://arm.flatassembler.net/)
- [Ubuntu fasm Package](https://packages.ubuntu.com/noble/fasm)
- [Ubuntu Launchpad - fasm](https://launchpad.net/ubuntu/+source/fasm)
- [GitHub Actions Run #21472785075](https://github.com/link-foundation/box/actions/runs/21472785075)

## Architecture Analysis of All Installation Items

A comprehensive review of all packages and tools in the installation script was performed to verify architecture awareness. Below is the analysis:

### Packages Already Architecture-Aware ✅

| Package/Tool | Line | How It Handles Architecture |
|--------------|------|----------------------------|
| **FASM** | 209-219 | Conditionally installed on x86-64 only |
| **Go** | 467-517 | Detects `uname -m` and downloads correct binary (amd64/arm64/armv6l) |
| **Swift** | 827-891 | Detects `uname -m` and constructs architecture-specific download URL |

### APT Packages - Available for ARM64 ✅

All APT packages in the script are available for ARM64 in Ubuntu 24.04:

| Package | Architectures |
|---------|---------------|
| cmake | amd64, arm64, armhf, i386, ppc64el, riscv64, s390x |
| clang | amd64, arm64, armhf, i386, ppc64el, riscv64, s390x |
| llvm | amd64, arm64, armhf, i386, ppc64el, riscv64, s390x |
| lld | amd64, arm64, armhf, i386, ppc64el, riscv64, s390x |
| nasm | amd64, arm64, armhf, i386, ppc64el, riscv64, s390x |
| r-base | all (architecture-independent) |
| dotnet-sdk-8.0 | amd64, arm64, s390x |
| glab | amd64, arm64, armhf, ppc64el, riscv64, s390x |
| build-essential | all architectures |
| Python build deps | all architectures |
| Ruby build deps | all architectures |

### Tools with Built-in Architecture Support ✅

These tools automatically handle architecture detection:

| Tool | ARM64 Support |
|------|---------------|
| **Homebrew** | Tier 1 support for Linux ARM64 |
| **PHP (via Homebrew)** | Supports Linux x86_64 and arm64 |
| **SDKMAN/Java** | Eclipse Temurin provides ARM64 binaries |
| **opam/OCaml/Rocq** | Pre-compiled binaries for arm64 |
| **elan/Lean** | ARM64 Linux officially supported |
| **Bun** | ARM64 Linux supported |
| **Deno** | ARM64 Linux supported |
| **NVM/Node.js** | ARM64 Linux supported |
| **Rust (rustup)** | ARM64 Linux supported |
| **Pyenv** | Builds from source, works on all architectures |
| **rbenv/ruby-build** | Builds from source, works on all architectures |
| **Perlbrew** | Builds from source, works on all architectures |

### Conclusion

After thorough analysis, **only FASM requires special architecture handling**, which is already implemented. All other packages and tools in the installation script either:
1. Are available for ARM64 in Ubuntu repositories
2. Are architecture-independent
3. Have built-in architecture detection that automatically downloads the correct binaries
4. Build from source and work on all architectures

## CI Logs

The complete CI logs from the failed run are available at:
- `./ci-logs/run-21472785075-full.log`
