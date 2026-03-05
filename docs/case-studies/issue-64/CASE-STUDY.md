# Case Study: Issue #64 — Hive Mind Compatibility Gap Analysis

## Executive Summary

This case study documents a systematic comparison between the sandbox's `full-sandbox` Docker image and the general-purpose development tools required by the [hive-mind system](https://github.com/link-assistant/hive-mind/blob/main/scripts/ubuntu-24-server-install.sh). The analysis identifies what general-purpose (non-AI-specific) tools are missing from the sandbox.

**Key finding**: The full-sandbox is already a superset of the general-purpose development stack that hive-mind requires. The only missing general-purpose tool is `expect`, used for interactive TTY scripting automation. AI-specific tools (Claude Code, Codex, Gemini CLI, Playwright, Hive Mind workflow utilities) belong in the hive-mind image, not in the universal sandbox.

---

## 1. Data Collection

### 1.1 Hive Mind Install Script Analysis

Source: `https://github.com/link-assistant/hive-mind/blob/main/scripts/ubuntu-24-server-install.sh`

The hive-mind install script installs two categories of tools:

**A. General-purpose development tools** (also belong in the sandbox):

| Category | Tool | Install Method | Location |
|----------|------|----------------|----------|
| System | `wget curl unzip zip git sudo ca-certificates gnupg` | apt | system |
| System | `dotnet-sdk-8.0` | apt | system |
| System | `build-essential` | apt | system |
| System | `expect` | apt | system |
| System | `screen` | apt | system |
| System | `cmake clang llvm lld` | apt | system |
| System | Python build deps (libssl-dev, zlib1g-dev, etc.) | apt | system |
| System | GitHub CLI (`gh`) | apt (keyring) | system |
| System | `bubblewrap` | apt | system |
| Runtime | Node.js 20 | NVM | `~/.nvm` |
| Runtime | Bun | Official installer | `~/.bun` |
| Runtime | Deno | Official installer | `~/.deno` |
| Runtime | Python (latest stable) | Pyenv | `~/.pyenv` |
| Runtime | Go (latest stable) | Manual tarball | `~/.go` |
| Runtime | Rust | rustup | `~/.cargo`, `~/.rustup` |
| Runtime | Java 21 LTS | SDKMAN | `~/.sdkman` |
| Runtime | PHP 8.3 | Homebrew (shivammathur/php) | `/home/linuxbrew` |
| Runtime | Perl (latest) | Perlbrew | `~/.perl5` |
| Prover | Lean 4 | elan | `~/.elan` |
| Prover | Rocq/Coq | opam | `~/.opam` |
| Package mgr | Homebrew | Official installer | `/home/linuxbrew` |

**B. AI/Hive-Mind-specific tools** (belong in the hive-mind image, NOT in the sandbox):

| Category | Tool | Install Method |
|----------|------|----------------|
| AI agent | `@anthropic-ai/claude-code` | `bun install -g` |
| AI agent | `@openai/codex` | `bun install -g` |
| AI agent | `@qwen-code/qwen-code` | `bun install -g` |
| AI agent | `@google/gemini-cli` | `bun install -g` |
| AI agent | `@github/copilot` | `bun install -g` |
| AI agent | `opencode-ai` | `bun install -g` |
| Hive Mind | `@link-assistant/hive-mind` | `bun install -g` |
| Hive Mind | `@link-assistant/claude-profiles` | `bun install -g` |
| Hive Mind | `@link-assistant/agent` | `bun install -g` |
| Workflow | `start-command` | `bun install -g` |
| Workflow | `gh-pull-all` | `bun install -g` |
| Workflow | `gh-load-issue` | `bun install -g` |
| Workflow | `gh-load-pull-request` | `bun install -g` |
| Workflow | `gh-upload-log` | `bun install -g` |
| Browser automation | Playwright (OS deps + browsers + MCP) | npm + npx |

### 1.2 Full-Sandbox Current State (Before This Fix)

| Category | Tool | Status |
|----------|------|--------|
| Runtime | Node.js 20 (NVM) | ✅ Present (JS sandbox) |
| Runtime | Bun | ✅ Present (JS sandbox) |
| Runtime | Deno | ✅ Present (JS sandbox) |
| Runtime | Python (pyenv) | ✅ Present |
| Runtime | Go | ✅ Present |
| Runtime | Rust | ✅ Present |
| Runtime | Java 21 (SDKMAN) | ✅ Present |
| Runtime | Kotlin (SDKMAN) | ✅ Present (bonus) |
| Runtime | PHP 8.3 (Homebrew/apt) | ✅ Present |
| Runtime | Perl (Perlbrew) | ✅ Present |
| Runtime | Ruby (rbenv) | ✅ Present (bonus) |
| Runtime | Swift | ✅ Present (bonus) |
| Runtime | R | ✅ Present (bonus) |
| Prover | Lean 4 (elan) | ✅ Present |
| Prover | Rocq/Coq (opam) | ✅ Present |
| System | dotnet-sdk-8.0 | ✅ Present |
| System | cmake, clang, llvm, lld | ✅ Present |
| System | Assembly (nasm, fasm) | ✅ Present (bonus) |
| System | build-essential, git, gh | ✅ Present |
| System | screen | ✅ Present (essentials) |
| System | bubblewrap | ✅ Present |
| Global pkg | gh-setup-git-identity | ✅ Present (essentials) |
| Global pkg | glab-setup-git-identity | ✅ Present (essentials, bonus) |
| **System** | **expect** | ❌ **MISSING** |

---

## 2. Root Cause Analysis

### 2.1 Architecture Principle: Separation of Concerns

The `full-sandbox` is designed as a **universal development sandbox** — a base image for software development across many languages. It is intentionally not AI-specific.

The Hive Mind system is an AI coding agent orchestrator that **inherits from the sandbox** and adds:
- AI agent CLI frontends
- Workflow automation utilities
- Playwright browser automation

This separation means:
- **Sandbox** → universal programming environment (language runtimes, compilers, tools)
- **Hive Mind image** → extends sandbox + adds AI tools on top

Violating this boundary by adding AI tools to the sandbox would:
1. Bloat the universal sandbox with AI-specific software
2. Create a maintenance burden when AI tool versions change
3. Make the sandbox less useful for non-AI use cases

### 2.2 The One True Gap: `expect`

The `expect` tool is a **general-purpose interactive automation utility** — it allows scripts to programmatically interact with programs that require user input (TTY interaction scripting). This is not AI-specific; it's a standard development and operations tool.

Hive-mind installs `expect` in its main apt section alongside other essential tools (`wget`, `curl`, `git`, etc.), confirming it's considered a general-purpose tool needed for the development environment.

---

## 3. Gap Analysis Summary

### General-Purpose Tools: Missing From Sandbox

| # | Tool | Category | Severity | Fix |
|---|------|----------|----------|-----|
| 1 | `expect` | System (apt) | Low | Add to Dockerfile apt-get install |

### AI-Specific Tools: Out-of-Scope for Sandbox

These tools are installed by hive-mind but are **intentionally NOT added** to the universal sandbox. Hive Mind inherits from the sandbox and adds them on top:

| Tool | Reason Not in Sandbox |
|------|----------------------|
| `@anthropic-ai/claude-code` | AI-agent specific, not general development |
| `@openai/codex` | AI-agent specific |
| `@google/gemini-cli` | AI-agent specific |
| `@qwen-code/qwen-code` | AI-agent specific |
| `@github/copilot` | AI-agent specific |
| `opencode-ai` | AI-agent specific |
| `@link-assistant/hive-mind` | Hive Mind orchestrator — belongs in hive-mind image |
| `start-command`, `gh-pull-all`, etc. | Hive Mind workflow tools — belongs in hive-mind image |
| Playwright + browsers | Browser automation for AI workflows — belongs in hive-mind image |

### Things Full-Sandbox Has That Hive-Mind Does Not (Bonuses)

The sandbox is already a superset of hive-mind's general-purpose stack:

| Tool | Present In |
|------|-----------|
| Kotlin (SDKMAN) | Full-sandbox only |
| Ruby (rbenv) | Full-sandbox only |
| Swift | Full-sandbox only |
| R (`r-base`) | Full-sandbox only |
| Assembly (nasm, fasm) | Full-sandbox only |
| GitLab CLI (`glab`) + `glab-setup-git-identity` | Full-sandbox only |

---

## 4. Solution

### 4.1 Changes Made

1. **`ubuntu/24.04/full-sandbox/Dockerfile`**: Add `expect` to the apt-get install block
2. **`ubuntu/24.04/full-sandbox/install.sh`**: Add `expect` install to the system packages section
3. **`REQUIREMENTS.md`**: Document `expect` in FR-3 (Development Tools); add C-5 (local-first installation policy)
4. **`.github/workflows/release.yml`**: Add `expect -v` check to CI tests

### 4.2 Design Decision: Where AI Tools Belong

The Hive Mind system should:
1. Use the sandbox image as its base (`FROM konard/sandbox:latest`)
2. Add its AI CLIs (`claude-code`, `codex`, `gemini-cli`, etc.) in the hive-mind Dockerfile
3. Add Playwright and browser automation in the hive-mind Dockerfile
4. Add its workflow utilities (`gh-pull-all`, `gh-load-issue`, etc.) in the hive-mind Dockerfile

This way, the sandbox remains a clean, universal development environment that any project can build upon.

---

## 5. References

- [Hive Mind Install Script](https://github.com/link-assistant/hive-mind/blob/main/scripts/ubuntu-24-server-install.sh)
- [expect(1) man page](https://linux.die.net/man/1/expect)
- [Issue #44: PHP installation strategy](../../case-studies/issue-44/CASE-STUDY.md)
- [Issue #62: CI toolchain tests](../../case-studies/issue-62/CASE-STUDY.md)
