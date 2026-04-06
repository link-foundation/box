# Requirements

This document defines the requirements and constraints for the box Docker image project.

## Functional Requirements

### FR-1: Multi-Language Support

The Docker image MUST include the following programming language runtimes:

| Language | Version | Manager |
|----------|---------|---------|
| Node.js | 20.x LTS | nvm |
| Python | Latest stable | pyenv |
| Go | Latest stable | Manual |
| Rust | Latest stable | rustup |
| Java | 21 LTS | SDKMAN |
| Kotlin | Latest stable | SDKMAN |
| PHP | 8.3 | Homebrew (preferred) / apt (fallback) |
| Perl | Latest stable | Perlbrew |
| Ruby | Latest stable | rbenv |
| Swift | 6.x | Manual |
| R | Latest stable | System package |
| .NET | 8.0 | System package |
| Assembly | - | System packages (nasm, fasm) |

### FR-2: Theorem Prover Support

The Docker image MUST include:

| Prover | Version | Manager |
|--------|---------|---------|
| Lean | 4.x | elan |
| Rocq (Coq) | Latest | opam |

### FR-3: Development Tools

The Docker image MUST include:

- Git
- GitHub CLI (`gh`)
- Homebrew (linuxbrew)
- CMake
- Make
- GCC/G++
- Clang/Clang++
- LLVM
- LLD linker
- Assembly tools (GNU Assembler, NASM, LLVM-MC, FASM)
- `expect` (interactive automation tool for scripting TTY interactions)

### FR-4: Multi-Architecture Support

The Docker image MUST be available for:

- `linux/amd64` (x86-64)
- `linux/arm64` (AArch64)

### FR-5: Container Registry

The Docker image MUST be published to GitHub Container Registry (ghcr.io).

## Non-Functional Requirements

### NFR-1: Build Time

| Architecture | Maximum Build Time |
|-------------|-------------------|
| AMD64 | 30 minutes |
| ARM64 | 120 minutes |

Builds exceeding these times indicate a configuration problem and MUST be investigated.

### NFR-2: Security

- The container MUST run as a non-root user
- Sensitive data MUST NOT be baked into the image
- Base images MUST be from trusted sources

### NFR-3: Reproducibility

- Builds MUST be reproducible from the same commit
- All dependencies MUST be pinned or use stable channels

## CI/CD Requirements

### CI-1: Native Runners Only (CRITICAL)

**ARM64 builds MUST use native ARM64 runners.**

| Requirement | Specification |
|-------------|---------------|
| AMD64 Runner | `ubuntu-latest` or equivalent |
| ARM64 Runner | `ubuntu-24.04-arm` (native ARM64) |
| Emulation | MUST NOT be used for ARM64 builds |

**Rationale**: Emulation incurs a 10-30x performance penalty, making compilation-heavy builds timeout or run for 6+ hours instead of 30-60 minutes.

**Reference**: [Case Study: Issue #7](docs/case-studies/issue-7/README.md)

### CI-2: Timeout Protection

All jobs MUST have appropriate timeout limits:

| Job | Maximum Timeout |
|-----|----------------|
| AMD64 build | 60 minutes |
| ARM64 build | 120 minutes |
| Other jobs | 30 minutes |

### CI-3: Change Detection

The workflow MUST detect relevant changes and skip unnecessary builds:

- Dockerfile changes trigger builds
- Script changes trigger builds
- Documentation-only changes SHOULD NOT trigger builds

### CI-4: Concurrency Control

- Only one build per branch should run at a time
- New pushes should cancel in-progress builds on the same branch

## Constraints

### C-1: GitHub Actions Free Tier

The project MUST work within GitHub Actions free tier limits for public repositories:

- Native ARM64 runners: Available for free (public repos, since Jan 2025)
- Storage: Within GitHub's cache limits
- Concurrency: Within free tier limits

### C-2: No External Dependencies

CI/CD workflows MUST NOT depend on:

- External services (other than GitHub and package registries)
- Self-hosted runners
- Paid services

### C-3: PHP Installation Strategy (Issue #44)

PHP MUST be installed using a **user-specific** method (Homebrew) when possible, with apt as fallback:

| Priority | Method | Location | Tag Suffix | Mergeability |
|----------|--------|----------|------------|--------------|
| 1 (preferred) | Homebrew | `/home/linuxbrew/.linuxbrew` | `-local` | COPY --from supported |
| 2 (fallback) | apt | `/usr/bin` (global) | `-global` | Must install via apt in full-box |

**Rationale**: User-specific installation allows Docker images to be merged via `COPY --from` in the full-box. Global (apt) installation cannot be merged this way and requires reinstallation.

**Timeout**: Homebrew PHP installation has a timeout (default: 30 minutes). If bottles are unavailable and source compilation is attempted, the timeout triggers fallback to apt.

**Tagging**: PHP images include a method suffix tag (`-local` or `-global`) in addition to the standard tags. The `latest` tag references whichever method succeeded.

### C-4: Homebrew ARM64 Linux Limitation

Homebrew does not provide pre-built bottles for ARM64 Linux. Packages requiring compilation (like PHP) MUST:

- Be built on native ARM64 runners
- Have sufficient timeout allocated
- NOT use emulation

### C-5: Local-First Installation Policy (Issue #64)

All tools MUST prefer **local (user-specific) installation** over global (system-wide) installation:

- Bun global packages: `bun install -g` → `~/.bun/bin/`
- npm global packages: `npm install -g` → NVM-managed node prefix
- System (apt) packages only when no local alternative exists

**Rationale**: Local installation allows Docker image layers to be assembled via `COPY --from`, enabling parallel builds and easy portability between images. Tools that require AI-specific packages (such as AI coding agents or workflow utilities) should be installed in images that inherit from the box, rather than in the box itself.

## Future Considerations

### Potential Improvements

1. **Build Caching**: Registry-based caching for Docker layers
2. **Pre-built Base Images**: Heavy dependencies could be pre-built monthly
3. **Dependency Audit**: Regular review of included tools for necessity

### Not in Scope

1. Windows container support
2. macOS support
3. GPU/CUDA support

## Compliance Checklist

Before merging any CI/CD changes, verify:

- [ ] ARM64 job uses `ubuntu-24.04-arm` runner
- [ ] No emulation setup step for ARM64 builds
- [ ] Appropriate timeouts are configured
- [ ] Change detection works correctly
- [ ] Build completes within time limits

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-01-16 | Initial requirements document |
| 1.1 | 2026-03-05 | Add `expect` to FR-3, add C-5 (local-first installation policy) per issue #64 |
