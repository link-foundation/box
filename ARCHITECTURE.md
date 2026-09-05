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
│       ├── dotnet/                  # .NET SDK (LTS channel)
│       │   ├── install.sh
│       │   └── Dockerfile
│       ├── r/                       # R language (CRAN)
│       │   ├── install.sh
│       │   └── Dockerfile
│       ├── ruby/                    # Ruby (rbenv)
│       │   ├── install.sh
│       │   └── Dockerfile
│       ├── php/                     # PHP (Homebrew)
│       │   ├── install.sh
│       │   └── Dockerfile
│       ├── perl/                    # Perl (Perlbrew)
│       │   ├── install.sh
│       │   └── Dockerfile
│       ├── swift/                   # Swift (latest release)
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

### 5. Build-Time Version Resolution (Issue #112)

No image pins a runtime version in a Dockerfile or an install script. Every
version is resolved **while the image is being built**, by the resolvers in
`ubuntu/24.04/common.sh`, which every Dockerfile already copies to
`/tmp/common.sh`. Three layers, in priority order:

1. **An explicit override** — `NODE_VERSION`, `JAVA_VERSION`, `DOTNET_CHANNEL`,
   `SWIFT_VERSION`, `RUBY_VERSION`, `NVM_VERSION`, `OPAM_VERSION`,
   `PHP_BREW_FORMULA`. Set one and the build is reproducible.
2. **The upstream release feed** — nodejs.org's `index.json` (newest *LTS*, not
   newest release), SDKMAN's Java list filtered to the LTS cadence (8, 11, 17,
   then every 4th from 21), Microsoft's `releases-index.json` intersected with
   what the archive can actually install, swift.org's release list, and the
   GitHub `/releases/latest` redirect for nvm and opam.
3. **A pinned fallback** — used only when a feed is unreachable, so a network
   blip degrades to a known-good version instead of failing the build.

Two properties keep this honest:

- **One version per language root.** `assert_single_runtime_versions()` fails a
  build that leaves two entries under `~/.nvm/versions/node`,
  `~/.rustup/toolchains`, `~/.pyenv/versions`, `~/.rbenv/versions` or any
  `~/.sdkman/candidates/*`. A second entry always means a stale toolchain was
  carried in from a cached language image and is costing gigabytes.
- **Refresh happens in the layer that creates it.** `COPY --from=rust-stage`
  bakes whatever the (possibly cached) rust image was built with, and a later
  `rustup update` plus delete reclaims nothing — the bytes are already committed
  and the delete only writes a whiteout, so the image carries both toolchains.
  `full-box/refresh-rust.sh` therefore binds the stage with
  `RUN --mount=type=bind,from=rust-stage` and copies, updates and prunes inside
  a single `RUN`. `experiments/rust-refresh-layer-test.sh` measures both
  variants and asserts the difference.

The same resolvers back `scripts/ubuntu-24-server-install.sh` and
`scripts/measure-disk-space.sh` (sourced in a subshell so they cannot clobber
those scripts' own helpers), so a bare-metal install and an image agree.

**Ubuntu stays on 24.04 LTS.** It is the newest release for which Swift
publishes a Linux toolchain; swift.org's release feed carries `ubuntu2404`
builds and nothing newer. Everything installed *on top of* 24.04 tracks its own
upstream, so the base LTS being one cycle behind does not hold any runtime back.

### 6. Pull-Request Runs Are Superseded Explicitly (Issue #112)

`release.yml` gives **pull-request** runs a concurrency group that is unique per
run (`<workflow>-pr-<number>-run-<run_id>`); only push/tag runs keep the per-ref
group that serialises releases. This is deliberate and the opposite of the usual
advice, because the usual advice deadlocks: a run blocked on a shared group is
`pending`, executes no step, and therefore cannot cancel the predecessor holding
it — the predecessor kept running, the newest commit never started, and each
pending run was cancelled by the next one.

Supersession is instead done by code that actually runs, `scripts/ci/supersede.sh`:

- **`cancel-older`** — the `cancel-superseded` job, first in the run with no
  `needs:`, cancels every still-live run of this workflow that belongs to an
  earlier commit of the same pull request.
- **`stop-if-superseded`** — the first step after checkout in every expensive PR
  job re-reads the pull request head and cancels its own run if the commit has
  moved on. Necessary because a matrix job can sit queued long enough for its
  commit to become stale.
- **`watch`** — started in the background by that same step, it polls every five
  minutes for the rest of the job. `cancel-superseded` needs a runner of its own,
  and a superseded run holding the account's job concurrency is exactly why none
  is free; a job that is already running can cancel the run from the inside, and
  one cancelled run frees every slot it holds at once.

A cancel is a request, not a guarantee (the platform ignored one here while the
job it targeted ran to a green finish), so every cancel is verified and escalated
to `force-cancel` after a grace period. Everything fails open: a fork pull
request's read-only token cannot cancel anything, and losing a cancellation only
wastes runner minutes, while a false one would lose test coverage.

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
