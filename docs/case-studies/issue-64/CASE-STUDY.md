# Case Study: Issue #64 — Hive Mind Compatibility Gap Analysis

## Executive Summary

This case study documents a systematic comparison between the sandbox's `full-sandbox` Docker image and the requirements of the [hive-mind system](https://github.com/link-assistant/hive-mind/blob/main/scripts/ubuntu-24-server-install.sh). The analysis identifies missing tools and proposes concrete fixes.

---

## 1. Data Collection

### 1.1 Hive Mind Install Script Analysis

Source: `https://github.com/link-assistant/hive-mind/blob/main/scripts/ubuntu-24-server-install.sh`

The hive-mind install script installs the following tools as **`hive` user** (local/user-specific priority):

| Category | Tool | Install Method | Location |
|----------|------|----------------|----------|
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
| System | dotnet-sdk-8.0 | apt | system |
| System | cmake, clang, llvm, lld | apt | system |
| System | build-essential, git, gh, etc. | apt | system |

**Global bun packages installed by hive-mind** (critical finding):
```
@link-assistant/hive-mind
@link-assistant/claude-profiles
@anthropic-ai/claude-code
@openai/codex
@qwen-code/qwen-code
@google/gemini-cli
@github/copilot
opencode-ai
@link-assistant/agent
start-command
gh-setup-git-identity
gh-pull-all
gh-load-issue
gh-load-pull-request
gh-upload-log
```

**Playwright** (full browser automation stack):
- Playwright OS system dependencies (via `npx playwright@latest install-deps`)
- `@playwright/mcp@latest` (global npm)
- `@playwright/test@latest` (global npm)
- Browsers: chromium, chrome, firefox, webkit, msedge (arch-dependent), chromium-headless-shell
- Claude MCP configuration

### 1.2 Full-Sandbox Current State

The full-sandbox assembles from individual language images and adds:

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
| Global pkg | gh-setup-git-identity | ✅ Present (essentials) |
| Global pkg | glab-setup-git-identity | ✅ Present (essentials, bonus) |
| **Global pkg** | **@anthropic-ai/claude-code** | ❌ **MISSING** |
| **Global pkg** | **@openai/codex** | ❌ **MISSING** |
| **Global pkg** | **@qwen-code/qwen-code** | ❌ **MISSING** |
| **Global pkg** | **@google/gemini-cli** | ❌ **MISSING** |
| **Global pkg** | **@github/copilot** | ❌ **MISSING** |
| **Global pkg** | **opencode-ai** | ❌ **MISSING** |
| **Global pkg** | **@link-assistant/hive-mind** | ❌ **MISSING** |
| **Global pkg** | **@link-assistant/claude-profiles** | ❌ **MISSING** |
| **Global pkg** | **@link-assistant/agent** | ❌ **MISSING** |
| **Global pkg** | **start-command** | ❌ **MISSING** |
| **Global pkg** | **gh-pull-all** | ❌ **MISSING** |
| **Global pkg** | **gh-load-issue** | ❌ **MISSING** |
| **Global pkg** | **gh-load-pull-request** | ❌ **MISSING** |
| **Global pkg** | **gh-upload-log** | ❌ **MISSING** |
| **Browser automation** | **Playwright (OS deps + browsers + MCP)** | ❌ **MISSING** |

---

## 2. Root Cause Analysis

### 2.1 Why Are These Tools Missing?

The sandbox was originally designed as a **programming language runtime environment** — providing compilers, interpreters, and build tools. The Hive Mind system extends this to include an **AI coding agent workflow** layer, which requires:

1. **AI CLI tools** (`claude-code`, `codex`, `gemini-cli`, etc.) — These are the agent frontends that enable AI-assisted coding.
2. **Workflow utilities** (`gh-pull-all`, `gh-load-issue`, etc.) — These are hive-mind–specific tools for managing GitHub workflows within the AI agent loop.
3. **Browser automation** (Playwright) — Required for web interaction, screenshot capture, and UI testing within AI agent workflows.

### 2.2 Installation Strategy: Local Over Global

Per `REQUIREMENTS.md` and the hive-mind script philosophy: **user-specific (local) installation is prioritized over global installation** for portability between Docker images. This means:

- Bun global packages: `bun install -g <pkg>` → installs to `~/.bun/bin/`
- npm global packages: `npm install -g <pkg>` → installs to NVM-managed node prefix
- System (apt) packages are only used when no local alternative exists

---

## 3. Gap Analysis Summary

### Missing: AI Coding Agent CLI Tools

These tools are required for the Hive Mind system to function as an AI coding environment:

| Package | Purpose | Install Method |
|---------|---------|----------------|
| `@anthropic-ai/claude-code` | Claude Code CLI (primary AI agent) | `bun install -g` |
| `@openai/codex` | OpenAI Codex CLI | `bun install -g` |
| `@qwen-code/qwen-code` | Qwen coding agent | `bun install -g` |
| `@google/gemini-cli` | Google Gemini CLI | `bun install -g` |
| `@github/copilot` | GitHub Copilot CLI | `bun install -g` |
| `opencode-ai` | OpenCode AI agent | `bun install -g` |

### Missing: Hive Mind Workflow Tools

| Package | Purpose | Install Method |
|---------|---------|----------------|
| `@link-assistant/hive-mind` | Hive Mind orchestrator | `bun install -g` |
| `@link-assistant/claude-profiles` | Claude profile manager | `bun install -g` |
| `@link-assistant/agent` | Agent runner | `bun install -g` |
| `start-command` | Process start utility | `bun install -g` |
| `gh-pull-all` | Clone all user repos | `bun install -g` |
| `gh-load-issue` | Load GitHub issue | `bun install -g` |
| `gh-load-pull-request` | Load GitHub PR | `bun install -g` |
| `gh-upload-log` | Upload log to GitHub | `bun install -g` |

### Missing: Playwright Browser Automation

| Component | Purpose |
|-----------|---------|
| Playwright OS dependencies | System libs required by browser engines |
| `@playwright/mcp` | Playwright MCP server for Claude Code |
| `@playwright/test` | Playwright test CLI |
| Chromium browser | Primary headless browser |
| Firefox browser | Secondary browser |
| WebKit browser | Safari-compatible browser |
| Chrome/Edge (x86_64 only) | Additional browsers |
| Chromium Headless Shell | CI-optimized headless browser |

---

## 4. Solution

### 4.1 Approach

Add the missing tools to `ubuntu/24.04/full-sandbox/install.sh` and `Dockerfile`:

1. **Global bun/npm packages** — Install as `sandbox` user in the user-setup section of `install.sh`
2. **Playwright** — Install OS deps as root, then browsers as `sandbox` user
3. Update `REQUIREMENTS.md` to document the new requirements
4. Follow the existing pattern of local (user-space) installation

### 4.2 Key Design Decisions

- **Graceful failures**: Some packages (like `@link-assistant/hive-mind`) may not be published yet; use `|| true` and skip on errors
- **Architecture-aware browsers**: Chrome/Edge not available on ARM64; install Chromium instead
- **Local priority**: All packages installed to user's home directory, not system-wide
- **Playwright MCP config**: Added to Claude CLI config if available

---

## 5. References

- [Hive Mind Install Script](https://github.com/link-assistant/hive-mind/blob/main/scripts/ubuntu-24-server-install.sh)
- [Playwright Installation Docs](https://playwright.dev/docs/intro)
- [Playwright MCP](https://github.com/microsoft/playwright-mcp)
- [Claude Code npm package](https://www.npmjs.com/package/@anthropic-ai/claude-code)
- [OpenAI Codex](https://www.npmjs.com/package/@openai/codex)
- [Google Gemini CLI](https://www.npmjs.com/package/@google/gemini-cli)
- [Issue #44: PHP installation strategy](../../case-studies/issue-44/CASE-STUDY.md)
- [Issue #62: CI toolchain tests](../../case-studies/issue-62/CASE-STUDY.md)
