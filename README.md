# sandbox

A Docker container image that contains most popular language runtimes and tools to be reused for multiple software development tasks.

## Overview

This sandbox provides a pre-configured development environment with common language runtimes installed. It is designed to be AI-agnostic and can be used as a base image for various development workflows.

## Included Runtimes & Tools

### Programming Languages
- **Node.js 20** (via NVM) + npm + Bun + Deno
- **Python** (latest stable via pyenv)
- **Go** (latest stable)
- **Rust** (via rustup) + Cargo
- **Java 21 LTS** (Eclipse Temurin via SDKMAN)
- **Kotlin** (via SDKMAN)
- **PHP 8.3** (via Homebrew)
- **Perl** (latest stable via Perlbrew)
- **Ruby** (latest stable via rbenv)
- **Swift 6.x** (latest stable)
- **R** (latest stable)
- **.NET SDK 8.0**
- **Assembly** (GNU Assembler, NASM, LLVM-MC, FASM)

### Theorem Provers
- **Lean** (via elan)
- **Rocq/Coq** (via opam)

### Build Tools
- **CMake**
- **Make**
- **GCC/G++**
- **Clang/Clang++**
- **LLVM**
- **LLD Linker**

### Development Tools
- **Git**
- **GitHub CLI (gh)**
- **Homebrew**

## Modular Architecture

The sandbox is split into modular components, allowing you to use only what you need:

```
JS sandbox (konard/sandbox-js)
  └─ Essentials sandbox (konard/sandbox-essentials)
       ├─ sandbox-python     (built in parallel)
       ├─ sandbox-go         (built in parallel)
       ├─ sandbox-rust       (built in parallel)
       ├─ sandbox-java       (built in parallel)
       ├─ sandbox-kotlin     (built in parallel)
       ├─ sandbox-ruby       (built in parallel)
       ├─ sandbox-php        (built in parallel)
       ├─ sandbox-perl       (built in parallel)
       ├─ sandbox-swift      (built in parallel)
       ├─ sandbox-lean       (built in parallel)
       └─ sandbox-rocq       (built in parallel)
            └─ Full sandbox (konard/sandbox) ← merges all via COPY --from
```

| Image | Description | Base Image |
|-------|-------------|------------|
| `konard/sandbox` | Full sandbox (all languages) | Assembled from all language images |
| `konard/sandbox-essentials` | Essentials (git identity tools) | Built on JS sandbox |
| `konard/sandbox-js` | JavaScript only | Ubuntu 24.04 |
| `konard/sandbox-python` | Python (pyenv) | Built on essentials |
| `konard/sandbox-go` | Go (latest stable) | Built on essentials |
| `konard/sandbox-rust` | Rust (rustup + cargo) | Built on essentials |
| `konard/sandbox-java` | Java 21 (SDKMAN + Temurin) | Built on essentials |
| `konard/sandbox-kotlin` | Kotlin (SDKMAN) | Built on essentials |
| `konard/sandbox-ruby` | Ruby (rbenv) | Built on essentials |
| `konard/sandbox-php` | PHP 8.3 (Homebrew) | Built on essentials |
| `konard/sandbox-perl` | Perl (Perlbrew) | Built on essentials |
| `konard/sandbox-swift` | Swift 6.x | Built on essentials |
| `konard/sandbox-lean` | Lean (elan) | Built on essentials |
| `konard/sandbox-rocq` | Rocq/Coq (Opam) | Built on essentials |

### Per-Language Install Scripts & Dockerfiles

Each language has its own standalone `install.sh` and `Dockerfile` under `ubuntu/24.04/<language>/`:

| Language | Directory | Key Tools |
|----------|-----------|-----------|
| JavaScript/TypeScript | `ubuntu/24.04/js/` | NVM, Node.js, Bun, Deno, npm |
| Python | `ubuntu/24.04/python/` | Pyenv, latest stable Python |
| Go | `ubuntu/24.04/go/` | Latest stable Go |
| Rust | `ubuntu/24.04/rust/` | rustup, Cargo |
| Java | `ubuntu/24.04/java/` | SDKMAN, Eclipse Temurin 21 |
| Kotlin | `ubuntu/24.04/kotlin/` | SDKMAN, Kotlin |
| .NET | `ubuntu/24.04/dotnet/` | .NET SDK 8.0 |
| R | `ubuntu/24.04/r/` | R base |
| Ruby | `ubuntu/24.04/ruby/` | rbenv, latest Ruby 3.x |
| PHP | `ubuntu/24.04/php/` | Homebrew, PHP 8.3 |
| Perl | `ubuntu/24.04/perl/` | Perlbrew, latest Perl |
| Swift | `ubuntu/24.04/swift/` | Swift 6.x |
| Lean | `ubuntu/24.04/lean/` | elan, Lean prover |
| Rocq/Coq | `ubuntu/24.04/rocq/` | Opam, Rocq prover |
| C/C++ | `ubuntu/24.04/cpp/` | CMake, Clang, LLVM, LLD |
| Assembly | `ubuntu/24.04/assembly/` | NASM, FASM (x86_64) |

Each install script can be run standalone on Ubuntu 24.04:

```bash
# Install just Go on your Ubuntu 24.04 system
curl -fsSL https://raw.githubusercontent.com/link-foundation/sandbox/main/ubuntu/24.04/go/install.sh | bash
```

## Docker Images

### Docker Hub - Combo Sandboxes

| Image | Multi-arch | AMD64 | ARM64 |
|-------|------------|-------|-------|
| Full Sandbox | [`konard/sandbox:latest`](https://hub.docker.com/r/konard/sandbox/tags?name=latest) | [`latest-amd64`](https://hub.docker.com/r/konard/sandbox/tags?name=latest-amd64) | [`latest-arm64`](https://hub.docker.com/r/konard/sandbox/tags?name=latest-arm64) |
| Essentials | [`konard/sandbox-essentials:latest`](https://hub.docker.com/r/konard/sandbox-essentials/tags?name=latest) | [`latest-amd64`](https://hub.docker.com/r/konard/sandbox-essentials/tags?name=latest-amd64) | [`latest-arm64`](https://hub.docker.com/r/konard/sandbox-essentials/tags?name=latest-arm64) |
| JS | [`konard/sandbox-js:latest`](https://hub.docker.com/r/konard/sandbox-js/tags?name=latest) | [`latest-amd64`](https://hub.docker.com/r/konard/sandbox-js/tags?name=latest-amd64) | [`latest-arm64`](https://hub.docker.com/r/konard/sandbox-js/tags?name=latest-arm64) |

### Docker Hub - Language Sandboxes

| Language | Multi-arch | AMD64 | ARM64 |
|----------|------------|-------|-------|
| Python | [`konard/sandbox-python:latest`](https://hub.docker.com/r/konard/sandbox-python/tags?name=latest) | [`latest-amd64`](https://hub.docker.com/r/konard/sandbox-python/tags?name=latest-amd64) | [`latest-arm64`](https://hub.docker.com/r/konard/sandbox-python/tags?name=latest-arm64) |
| Go | [`konard/sandbox-go:latest`](https://hub.docker.com/r/konard/sandbox-go/tags?name=latest) | [`latest-amd64`](https://hub.docker.com/r/konard/sandbox-go/tags?name=latest-amd64) | [`latest-arm64`](https://hub.docker.com/r/konard/sandbox-go/tags?name=latest-arm64) |
| Rust | [`konard/sandbox-rust:latest`](https://hub.docker.com/r/konard/sandbox-rust/tags?name=latest) | [`latest-amd64`](https://hub.docker.com/r/konard/sandbox-rust/tags?name=latest-amd64) | [`latest-arm64`](https://hub.docker.com/r/konard/sandbox-rust/tags?name=latest-arm64) |
| Java | [`konard/sandbox-java:latest`](https://hub.docker.com/r/konard/sandbox-java/tags?name=latest) | [`latest-amd64`](https://hub.docker.com/r/konard/sandbox-java/tags?name=latest-amd64) | [`latest-arm64`](https://hub.docker.com/r/konard/sandbox-java/tags?name=latest-arm64) |
| Kotlin | [`konard/sandbox-kotlin:latest`](https://hub.docker.com/r/konard/sandbox-kotlin/tags?name=latest) | [`latest-amd64`](https://hub.docker.com/r/konard/sandbox-kotlin/tags?name=latest-amd64) | [`latest-arm64`](https://hub.docker.com/r/konard/sandbox-kotlin/tags?name=latest-arm64) |
| Ruby | [`konard/sandbox-ruby:latest`](https://hub.docker.com/r/konard/sandbox-ruby/tags?name=latest) | [`latest-amd64`](https://hub.docker.com/r/konard/sandbox-ruby/tags?name=latest-amd64) | [`latest-arm64`](https://hub.docker.com/r/konard/sandbox-ruby/tags?name=latest-arm64) |
| PHP | [`konard/sandbox-php:latest`](https://hub.docker.com/r/konard/sandbox-php/tags?name=latest) | [`latest-amd64`](https://hub.docker.com/r/konard/sandbox-php/tags?name=latest-amd64) | [`latest-arm64`](https://hub.docker.com/r/konard/sandbox-php/tags?name=latest-arm64) |
| Perl | [`konard/sandbox-perl:latest`](https://hub.docker.com/r/konard/sandbox-perl/tags?name=latest) | [`latest-amd64`](https://hub.docker.com/r/konard/sandbox-perl/tags?name=latest-amd64) | [`latest-arm64`](https://hub.docker.com/r/konard/sandbox-perl/tags?name=latest-arm64) |
| Swift | [`konard/sandbox-swift:latest`](https://hub.docker.com/r/konard/sandbox-swift/tags?name=latest) | [`latest-amd64`](https://hub.docker.com/r/konard/sandbox-swift/tags?name=latest-amd64) | [`latest-arm64`](https://hub.docker.com/r/konard/sandbox-swift/tags?name=latest-arm64) |
| Lean | [`konard/sandbox-lean:latest`](https://hub.docker.com/r/konard/sandbox-lean/tags?name=latest) | [`latest-amd64`](https://hub.docker.com/r/konard/sandbox-lean/tags?name=latest-amd64) | [`latest-arm64`](https://hub.docker.com/r/konard/sandbox-lean/tags?name=latest-arm64) |
| Rocq | [`konard/sandbox-rocq:latest`](https://hub.docker.com/r/konard/sandbox-rocq/tags?name=latest) | [`latest-amd64`](https://hub.docker.com/r/konard/sandbox-rocq/tags?name=latest-amd64) | [`latest-arm64`](https://hub.docker.com/r/konard/sandbox-rocq/tags?name=latest-arm64) |

### GitHub Container Registry - Combo Sandboxes

| Image | Multi-arch | AMD64 | ARM64 |
|-------|------------|-------|-------|
| Full Sandbox | [`ghcr.io/link-foundation/sandbox:latest`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox?tag=latest) | [`latest-amd64`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox?tag=latest-amd64) | [`latest-arm64`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox?tag=latest-arm64) |
| Essentials | [`ghcr.io/link-foundation/sandbox-essentials:latest`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-essentials?tag=latest) | [`latest-amd64`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-essentials?tag=latest-amd64) | [`latest-arm64`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-essentials?tag=latest-arm64) |
| JS | [`ghcr.io/link-foundation/sandbox-js:latest`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-js?tag=latest) | [`latest-amd64`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-js?tag=latest-amd64) | [`latest-arm64`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-js?tag=latest-arm64) |

### GitHub Container Registry - Language Sandboxes

| Language | Multi-arch | AMD64 | ARM64 |
|----------|------------|-------|-------|
| Python | [`ghcr.io/link-foundation/sandbox-python:latest`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-python?tag=latest) | [`latest-amd64`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-python?tag=latest-amd64) | [`latest-arm64`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-python?tag=latest-arm64) |
| Go | [`ghcr.io/link-foundation/sandbox-go:latest`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-go?tag=latest) | [`latest-amd64`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-go?tag=latest-amd64) | [`latest-arm64`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-go?tag=latest-arm64) |
| Rust | [`ghcr.io/link-foundation/sandbox-rust:latest`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-rust?tag=latest) | [`latest-amd64`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-rust?tag=latest-amd64) | [`latest-arm64`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-rust?tag=latest-arm64) |
| Java | [`ghcr.io/link-foundation/sandbox-java:latest`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-java?tag=latest) | [`latest-amd64`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-java?tag=latest-amd64) | [`latest-arm64`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-java?tag=latest-arm64) |
| Kotlin | [`ghcr.io/link-foundation/sandbox-kotlin:latest`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-kotlin?tag=latest) | [`latest-amd64`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-kotlin?tag=latest-amd64) | [`latest-arm64`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-kotlin?tag=latest-arm64) |
| Ruby | [`ghcr.io/link-foundation/sandbox-ruby:latest`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-ruby?tag=latest) | [`latest-amd64`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-ruby?tag=latest-amd64) | [`latest-arm64`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-ruby?tag=latest-arm64) |
| PHP | [`ghcr.io/link-foundation/sandbox-php:latest`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-php?tag=latest) | [`latest-amd64`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-php?tag=latest-amd64) | [`latest-arm64`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-php?tag=latest-arm64) |
| Perl | [`ghcr.io/link-foundation/sandbox-perl:latest`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-perl?tag=latest) | [`latest-amd64`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-perl?tag=latest-amd64) | [`latest-arm64`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-perl?tag=latest-arm64) |
| Swift | [`ghcr.io/link-foundation/sandbox-swift:latest`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-swift?tag=latest) | [`latest-amd64`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-swift?tag=latest-amd64) | [`latest-arm64`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-swift?tag=latest-arm64) |
| Lean | [`ghcr.io/link-foundation/sandbox-lean:latest`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-lean?tag=latest) | [`latest-amd64`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-lean?tag=latest-amd64) | [`latest-arm64`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-lean?tag=latest-arm64) |
| Rocq | [`ghcr.io/link-foundation/sandbox-rocq:latest`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-rocq?tag=latest) | [`latest-amd64`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-rocq?tag=latest-amd64) | [`latest-arm64`](https://github.com/link-foundation/sandbox/pkgs/container/sandbox-rocq?tag=latest-arm64) |

## Usage

### Quick Start

Pull multi-arch (auto-selects your platform):
```bash
docker pull konard/sandbox:latest
```

Pull specific architecture:
```bash
# AMD64
docker pull konard/sandbox:latest-amd64

# ARM64 (Apple Silicon, Raspberry Pi, etc.)
docker pull konard/sandbox:latest-arm64
```

Pull from GHCR:
```bash
docker pull ghcr.io/link-foundation/sandbox:latest
```

### Run interactively

```bash
docker run -it ghcr.io/link-foundation/sandbox:latest
```

### Use as base image

```dockerfile
FROM ghcr.io/link-foundation/sandbox:latest

# Your additional setup here
COPY . /workspace
RUN npm install
```

### Build locally

```bash
git clone https://github.com/link-foundation/sandbox.git
cd sandbox
docker build -t sandbox .
```

## Architecture Support

The image is built for both `linux/amd64` and `linux/arm64` architectures.

### CI/CD Build Requirements

**IMPORTANT: ARM64 builds MUST use native ARM64 runners.**

| Architecture | Runner | Build Time |
|-------------|--------|------------|
| `linux/amd64` | `ubuntu-latest` | ~5-10 minutes |
| `linux/arm64` | `ubuntu-24.04-arm` (native) | ~30-60 minutes |

Native ARM64 runners provide optimal build performance for compilation-heavy workloads. Emulation would incur a 10-30x performance penalty.

For detailed analysis, see [Case Study: Issue #7](docs/case-studies/issue-7/README.md).

## Environment

The container runs as the `sandbox` user with home directory at `/home/sandbox`. All language runtimes are installed in user-local directories:

- Node.js: `~/.nvm`
- Python: `~/.pyenv`
- Go: `~/.go`
- Rust: `~/.cargo`
- Java/Kotlin: `~/.sdkman`
- Ruby: `~/.rbenv`
- Swift: `~/.swift`
- Lean: `~/.elan`
- Perl: `~/.perl5`
- OCaml/Rocq: `~/.opam`

<!-- COMPONENT_SIZES_START -->
## Component Sizes

_Last updated: 2026-03-06T14:16:07Z_

**Total installation size: 7003.0 MB**

| Component | Category | Size (MB) |
|-----------|----------|-----------|
| Swift 6.x | Runtime | 2655.26 |
| Opam + Rocq/Coq | Runtime | 1307.26 |
| Rust (via rustup) | Runtime | 647.62 |
| .NET SDK 8.0 | Runtime | 504.93 |
| Pyenv + Python (latest) | Runtime | 387.77 |
| Perlbrew + Perl (latest) | Runtime | 364.98 |
| Go (latest) | Runtime | 281.74 |
| NVM + Node.js 20 | Runtime | 230.74 |
| Kotlin (via SDKMAN) | Runtime | 169.1 |
| rbenv + Ruby (latest) | Runtime | 165.11 |
| Deno | Runtime | 121.92 |
| R Language | Runtime | 121.14 |
| Bun | Runtime | 103.94 |
| PHP 8.3 (via Homebrew) | Runtime | 55.04 |
| Lean (via elan) | Runtime | 13.25 |
| SDKMAN + Java 21 | Runtime | 6.3 |
| C/C++ Tools (CMake, Clang, LLVM, LLD) | Build Tools | 58.85 |
| Assembly Tools (NASM, FASM) | Build Tools | 3.92 |
| GitLab CLI | Development Tools | 29.19 |
| gh-setup-git-identity | Development Tools | 4.37 |
| glab-setup-git-identity | Development Tools | 4.37 |
| GitHub CLI | Development Tools | 0.02 |
| Homebrew | Package Manager | 178.92 |
| Python Build Dependencies | Dependencies | 41.82 |
| Bubblewrap | Dependencies | 0.17 |
| Ruby Build Dependencies | Dependencies | 0.0 |
| Essential Tools | System | 0.75 |

_Note: Sizes are measured after cleanup and may vary based on system state and package versions._

<!-- COMPONENT_SIZES_END -->

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) - System architecture and design decisions
- [REQUIREMENTS.md](REQUIREMENTS.md) - Project requirements and constraints
- [docs/case-studies/](docs/case-studies/) - Case studies and incident analysis

## License

MIT License - see [LICENSE](LICENSE) for details.
