# Architecture

This document describes the architecture and design decisions for the box Docker image project.

## Overview

The box is a multi-architecture Docker image that provides a comprehensive development environment with popular programming language runtimes and tools pre-installed. It is designed to be used as a base image for AI-assisted development workflows.

## System Architecture

```
+------------------------------------------+
|           Docker Container               |
|  +------------------------------------+  |
|  |     User: box (non-root)       |  |
|  |     Home: /home/box               |  |
|  +------------------------------------+  |
|                                          |
|  +------------------------------------+  |
|  |      Language Runtimes             |  |
|  |  +-----+ +------+ +-----+ +-----+  |  |
|  |  |Node | |Python| | Go  | |Rust |  |  |
|  |  |.js  | |(pyenv)|(~/.go)|(cargo)|  |  |
|  |  |(nvm)| |      |       |       |  |  |
|  |  +-----+ +------+ +-----+ +-----+  |  |
|  |  +-----+ +------+ +-----+ +-----+  |  |
|  |  |Java/| | PHP  | |Perl | |Ruby |  |  |
|  |  |Kotln| |(brew)|(perl | |(rbenv|  |  |
|  |  |(sdk | |      | brew) |)     |  |  |
|  |  | man)| |      |       |       |  |  |
|  |  +-----+ +------+ +-----+ +-----+  |  |
|  |  +-----+ +------+ +-----+ +-----+  |  |
|  |  |Swift| | R    | |.NET | |Assem|  |  |
|  |  |(~/.s| |(sys) |(sys) | |bly  |  |  |
|  |  |wift)| |      |       | tools |  |  |
|  |  +-----+ +------+ +-----+ +-----+  |  |
|  +------------------------------------+  |
|                                          |
|  +------------------------------------+  |
|  |     Theorem Provers                |  |
|  |  +------+  +------+                |  |
|  |  | Lean |  | Rocq |                |  |
|  |  |(elan)|  |(opam)|                |  |
|  |  +------+  +------+                |  |
|  +------------------------------------+  |
|                                          |
|  +------------------------------------+  |
|  |     Build Tools                    |  |
|  |  CMake, Make, GCC, Clang, LLVM     |  |
|  +------------------------------------+  |
|                                          |
|  +------------------------------------+  |
|  |     Development Tools              |  |
|  |  Git, GitHub CLI (gh), Homebrew    |  |
|  +------------------------------------+  |
+------------------------------------------+
         |                   |
    linux/amd64         linux/arm64
```

## Multi-Architecture Support

The image is built for two architectures:

| Architecture | Runner Type | Build Time |
|-------------|-------------|------------|
| `linux/amd64` | `ubuntu-latest` | ~5-10 minutes |
| `linux/arm64` | `ubuntu-24.04-arm` (native) | ~30-60 minutes |

### Critical: Native ARM64 Runners Only

**IMPORTANT: ARM64 builds MUST use native ARM64 runners.**

Reason: Emulation incurs a 10-30x performance penalty, making builds that take 30-60 minutes natively run for 6+ hours (or timeout entirely).

See [Case Study: Docker ARM64 Build Timeout](docs/case-studies/issue-7/README.md) for detailed analysis.

## Build Pipeline

The CI/CD pipeline uses per-image change detection for efficiency. Only images whose
scripts or Dockerfiles changed are rebuilt. Unchanged images reuse the latest published version.

All language images are built in parallel, and the full box assembles them via
multi-stage `COPY --from` once all are ready.

```
┌──────────────────┐
│  detect-changes  │  (per-image + per-language granularity)
│  (ubuntu-latest) │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐  ← built first (base layer)
│  build-js        │
│  (amd64 + arm64) │  (parallel per arch)
└────────┬─────────┘
         │
         ▼
┌────────────────────────┐
│  build-essentials      │  ← built on JS box
│  (amd64 + arm64)       │  (parallel per arch)
└────────┬───────────────┘
         │
         ▼
┌────────────────────────────────────────────────────┐
│  build-languages (matrix: 11 languages)            │  ← ALL in parallel
│  python, go, rust, java, kotlin, ruby, php, perl,  │
│  swift, lean, rocq                                 │
│  (amd64 + arm64 per language)                      │
└────────────────────┬───────────────────────────────┘
                     │
                     ▼
┌────────────────────────┐
│  docker-build-push     │  ← full box: COPY --from all language images
│  (amd64 + arm64)       │  (multi-stage assembly, waits for all languages)
└────────┬───────────────┘
         │
         ▼
┌──────────────────┐
│ manifests        │  ← multi-arch manifests for js, essentials, languages, full
│ (multi-arch)     │
└──────────────────┘
```

Each image only rebuilds if its own scripts/Dockerfiles changed, or if a dependency
(common.sh, essentials) changed. The full box uses `COPY --from` to merge
pre-built language runtimes from all language images, plus `apt install` for
system-level packages (.NET, R, C/C++, Assembly).

## File Structure

```
box/
├── .github/
│   └── workflows/
│       └── release.yml              # CI/CD workflow
├── ubuntu/
│   └── 24.04/
│       ├── common.sh                # Shared functions for all install scripts
│       ├── js/                      # JavaScript/TypeScript (Node.js, Bun, Deno)
│       │   ├── install.sh
│       │   └── Dockerfile
│       ├── python/                  # Python (Pyenv)
│       │   ├── install.sh
│       │   └── Dockerfile
│       ├── go/                      # Go
│       │   ├── install.sh
│       │   └── Dockerfile
│       ├── rust/                    # Rust (rustup)
│       │   ├── install.sh
│       │   └── Dockerfile
│       ├── java/                    # Java (SDKMAN, Temurin)
│       │   ├── install.sh
│       │   └── Dockerfile
│       ├── kotlin/                  # Kotlin (SDKMAN)
│       │   ├── install.sh
│       │   └── Dockerfile
│       ├── dotnet/                  # .NET SDK 8.0
│       │   ├── install.sh
│       │   └── Dockerfile
│       ├── r/                       # R language
│       │   ├── install.sh
│       │   └── Dockerfile
│       ├── ruby/                    # Ruby (rbenv)
│       │   ├── install.sh
│       │   └── Dockerfile
│       ├── php/                     # PHP 8.3 (Homebrew)
│       │   ├── install.sh
│       │   └── Dockerfile
│       ├── perl/                    # Perl (Perlbrew)
│       │   ├── install.sh
│       │   └── Dockerfile
│       ├── swift/                   # Swift 6.x
│       │   ├── install.sh
│       │   └── Dockerfile
│       ├── lean/                    # Lean (elan)
│       │   ├── install.sh
│       │   └── Dockerfile
│       ├── rocq/                    # Rocq/Coq (Opam)
│       │   ├── install.sh
│       │   └── Dockerfile
│       ├── cpp/                     # C/C++ (CMake, Clang, LLVM)
│       │   ├── install.sh
│       │   └── Dockerfile
│       ├── assembly/                # Assembly (NASM, FASM)
│       │   ├── install.sh
│       │   └── Dockerfile
│       ├── essentials-box/      # Minimal box (git identity tools)
│       │   ├── install.sh
│       │   └── Dockerfile
│       └── full-box/            # Complete box (all languages)
│           ├── install.sh
│           └── Dockerfile
├── scripts/
│   ├── ubuntu-24-server-install.sh  # Legacy full installation script
│   ├── entrypoint.sh                # Container entrypoint
│   ├── measure-disk-space.sh        # Disk space measurement
│   └── ...                          # Other scripts
├── docs/
│   └── case-studies/                # Case studies
├── data/                            # Data files
├── experiments/                     # Experimental scripts
├── Dockerfile                       # Root Dockerfile (full box)
├── README.md                        # Project overview
├── ARCHITECTURE.md                  # This file
├── REQUIREMENTS.md                  # Project requirements
└── LICENSE                          # MIT License
```

## Modular Design

The box follows a modular architecture where all language images depend on
`essentials-box`, and the full box assembles them via multi-stage `COPY --from`:

```
┌─────────────────────────────────────────────────────────────┐
│  JS box (konard/box-js)                             │
│  └─ Node.js, Bun, Deno, npm                                │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  Essentials box (konard/box-essentials)              │
│  └─ + git, gh, glab, identity tools, dev libraries          │
└──┬──────┬──────┬──────┬──────┬──────┬──────┬──────┬────┬──┬─┘
   │      │      │      │      │      │      │      │    │  │
   ▼      ▼      ▼      ▼      ▼      ▼      ▼      ▼    ▼  ▼
 Python  Go   Rust  Java  Kotlin Ruby  PHP  Perl Swift Lean Rocq
   │      │      │      │      │      │      │      │    │  │
   └──────┴──────┴──────┴──────┴──────┴──────┴──────┴────┴──┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  Full box (konard/box)                               │
│  └─ COPY --from all language images                          │
│  └─ + apt: .NET, R, C/C++, Assembly (system packages)       │
└─────────────────────────────────────────────────────────────┘
```

Each language image is also available as a standalone Docker image
(e.g., `konard/box-python`, `konard/box-go`, etc.), each with
essentials pre-installed (JS, git, gh, glab, dev libraries).

### Benefits

1. **Configurable disk usage**: Users can choose only the languages they need
2. **Parallel CI/CD**: All language images are built in parallel
3. **Faster iteration**: Changes to one language only rebuild that image
4. **Efficient assembly**: Full box uses `COPY --from` to merge pre-built files
5. **No dependency conflicts**: Each language builds in isolation on essentials
6. **Standalone scripts**: Each `install.sh` works directly on Ubuntu 24.04 via `curl | bash`

## Design Decisions

### 1. Non-Root User

The container runs as a non-root user (`box`) for security. All language runtimes are installed in user-local directories.

### 2. Version Managers

Most languages use version managers (nvm, pyenv, sdkman, etc.) to:
- Allow easy version switching
- Keep installations in user space
- Provide consistent cross-platform behavior

### 3. Separate Architecture Jobs

ARM64 and AMD64 builds run as separate jobs (not a single multi-platform build) to:
- Use native runners for each architecture
- Avoid emulation entirely
- Enable parallel building when runners are available

### 4. PHP Installation: Homebrew with apt Fallback (Issue #44)

PHP uses a **tiered installation strategy**:

1. **Homebrew (preferred/local)**: Installs to `/home/linuxbrew/.linuxbrew` as the box user
   - Provides user-specific installation that can be merged via `COPY --from` in Docker
   - Subject to a 30-minute timeout to prevent 2+ hour source compilations
   - A marker file (`~/.php-install-method`) records `local` on success

2. **apt (fallback/global)**: Installs to `/usr/bin` system-wide
   - Used when Homebrew bottles are unavailable and compilation would exceed timeout
   - Cannot be merged via `COPY --from` — full-box must reinstall via apt
   - Marker file records `global`

PHP images are tagged with `-local` or `-global` suffix to indicate the install method.
The full-box reads the marker file and adjusts accordingly:
- If `local`: copies `/home/linuxbrew/.linuxbrew` from php-stage
- If `global`: installs PHP packages via apt directly

## Performance Considerations

### Build Time Optimization

1. **Native runners**: Always use architecture-native runners
2. **Caching**: GitHub Actions cache for Docker layers
3. **Timeout protection**: 120-minute safety timeout on ARM64 job

### Why Emulation is Prohibited

User-mode emulation translates every instruction at runtime:

| Metric | Native | Emulated |
|--------|--------|----------|
| Simple operations | 1x | ~2-5x slower |
| Compilation (gcc, etc.) | 1x | 10-30x slower |
| Full build | 30-60 min | 6+ hours |

For compilation-heavy workloads like this image, emulation makes builds impractical.

## References

- [GitHub: Linux arm64 hosted runners for free](https://github.blog/changelog/2025-01-16-linux-arm64-hosted-runners-now-available-for-free-in-public-repositories-public-preview/)
- [Emulation performance issues](https://github.com/docker/build-push-action/issues/982)
- [Case Study: Issue #7 Analysis](docs/case-studies/issue-7/README.md)
