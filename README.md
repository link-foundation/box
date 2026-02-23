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

## Usage

### Pull the full image

```bash
docker pull ghcr.io/link-foundation/sandbox:latest
```

### Pull the JS image

```bash
docker pull ghcr.io/link-foundation/sandbox-js:latest
```

### Pull the essentials image

```bash
docker pull ghcr.io/link-foundation/sandbox-essentials:latest
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

_Last updated: 2026-02-22T02:06:37Z_

**Total installation size: 7198.0 MB**

| Component | Category | Size (MB) |
|-----------|----------|-----------|
| Swift 6.x | Runtime | 2655.26 |
| Opam + Rocq/Coq | Runtime | 1307.27 |
| SDKMAN + Java 21 | Runtime | 579.1 |
| .NET SDK 8.0 | Runtime | 504.91 |
| Pyenv + Python (latest) | Runtime | 387.92 |
| Perlbrew + Perl (latest) | Runtime | 362.91 |
| Go (latest) | Runtime | 281.62 |
| NVM + Node.js 20 | Runtime | 230.43 |
| Kotlin (via SDKMAN) | Runtime | 169.11 |
| rbenv + Ruby (latest) | Runtime | 164.96 |
| R Language | Runtime | 121.15 |
| Deno | Runtime | 119.12 |
| Bun | Runtime | 102.38 |
| PHP 8.3 (via Homebrew) | Runtime | 55.08 |
| Lean (via elan) | Runtime | 13.29 |
| Rust (via rustup) | Runtime | 0.1 |
| C/C++ Tools (CMake, Clang, LLVM, LLD) | Build Tools | 58.83 |
| Assembly Tools (NASM, FASM) | Build Tools | 3.92 |
| GitLab CLI | Development Tools | 29.19 |
| glab-setup-git-identity | Development Tools | 4.37 |
| gh-setup-git-identity | Development Tools | 4.35 |
| GitHub CLI | Development Tools | 0.55 |
| Homebrew | Package Manager | 0.02 |
| Python Build Dependencies | Dependencies | 42.52 |
| Bubblewrap | Dependencies | 0.0 |
| Ruby Build Dependencies | Dependencies | 0.0 |
| Essential Tools | System | 0.74 |

_Note: Sizes are measured after cleanup and may vary based on system state and package versions._

<!-- COMPONENT_SIZES_END -->

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) - System architecture and design decisions
- [REQUIREMENTS.md](REQUIREMENTS.md) - Project requirements and constraints
- [docs/case-studies/](docs/case-studies/) - Case studies and incident analysis

## License

MIT License - see [LICENSE](LICENSE) for details.
