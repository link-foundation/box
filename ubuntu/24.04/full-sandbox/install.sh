#!/usr/bin/env bash
set -euo pipefail

# Full Sandbox Installation Script
# Installs all additional language runtimes and development tools
# on top of the essentials-sandbox (which already includes JS + git identity tools).
#
# Architecture:
#   JS sandbox → essentials-sandbox → full-sandbox (this script)
#
# Each language installer is a standalone script under ubuntu/24.04/<language>/install.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../common.sh" ]; then
  source "$SCRIPT_DIR/../common.sh"
else
  # Inline fallback logging
  log_info() { echo "[*] $1"; }
  log_success() { echo "[✓] $1"; }
  log_warning() { echo "[!] $1"; }
  log_error() { echo "[✗] $1"; }
  log_note() { echo "[i] $1"; }
  log_step() { echo "==> $1"; }
  command_exists() { command -v "$1" &>/dev/null; }
  maybe_sudo() { if [ "$EUID" -eq 0 ]; then "$@"; elif command -v sudo &>/dev/null; then sudo "$@"; else "$@"; fi; }
fi

log_step "Installing Full Sandbox (on top of essentials)"

# --- Install additional system packages ---
log_step "Installing additional system packages"

maybe_sudo apt update -y || true

# .NET SDK
log_info "Installing .NET SDK 8.0..."
maybe_sudo apt install -y dotnet-sdk-8.0
log_success ".NET SDK installed"

# C/C++ tools
log_info "Installing C/C++ development tools..."
maybe_sudo apt install -y cmake clang llvm lld
log_success "C/C++ tools installed"

# Assembly tools
log_info "Installing Assembly tools..."
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
  maybe_sudo apt install -y nasm fasm
  log_success "Assembly tools installed (NASM + FASM)"
else
  maybe_sudo apt install -y nasm
  log_success "Assembly tools installed (NASM only)"
fi

# R language
log_info "Installing R statistical language..."
maybe_sudo apt install -y r-base
log_success "R language installed"

# Note: Common build dependencies (build-essential, libssl-dev, zlib1g-dev,
# libyaml-dev, etc.) are already installed in the essentials-sandbox layer.

# Bubblewrap (needed by Rocq/Opam)
log_info "Installing bubblewrap..."
maybe_sudo apt install -y bubblewrap
log_success "Bubblewrap installed"

# --- Prepare Homebrew directory ---
log_step "Preparing Homebrew directory"
if [ ! -d /home/linuxbrew/.linuxbrew ]; then
  maybe_sudo mkdir -p /home/linuxbrew/.linuxbrew
  if id "sandbox" &>/dev/null; then
    maybe_sudo chown -R sandbox:sandbox /home/linuxbrew
  fi
else
  if id "sandbox" &>/dev/null; then
    maybe_sudo chown -R sandbox:sandbox /home/linuxbrew
  fi
fi

# --- Install all language runtimes as sandbox user ---
log_step "Installing language runtimes as sandbox user"

cat > /tmp/full-sandbox-user-setup.sh <<'EOF_FULL_SETUP'
#!/usr/bin/env bash
set -euo pipefail

log_info() { echo "[*] $1"; }
log_success() { echo "[✓] $1"; }
log_warning() { echo "[!] $1"; }
log_note() { echo "[i] $1"; }
log_step() { echo "==> $1"; }
command_exists() { command -v "$1" &>/dev/null; }

# Ensure JS tools are available (installed by essentials/JS sandbox)
export BUN_INSTALL="$HOME/.bun"
export DENO_INSTALL="$HOME/.deno"
export NVM_DIR="$HOME/.nvm"
export PATH="$BUN_INSTALL/bin:$DENO_INSTALL/bin:$PATH"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# --- Python (Pyenv) ---
log_step "Installing Python"
if [ ! -d "$HOME/.pyenv" ]; then
  curl https://pyenv.run | bash
  if ! grep -q 'pyenv init' "$HOME/.bashrc" 2>/dev/null; then
    {
      echo ''
      echo '# Pyenv configuration'
      echo 'export PYENV_ROOT="$HOME/.pyenv"'
      echo 'export PATH="$PYENV_ROOT/bin:$PATH"'
      echo 'eval "$(pyenv init --path)"'
      echo 'eval "$(pyenv init -)"'
    } >> "$HOME/.bashrc"
  fi
fi

export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
if command -v pyenv >/dev/null 2>&1; then
  eval "$(pyenv init --path)"
  eval "$(pyenv init -)"
  LATEST_PYTHON=$(pyenv install --list | grep -E '^\s*[0-9]+\.[0-9]+\.[0-9]+$' | tail -1 | tr -d '[:space:]')
  if [ -n "$LATEST_PYTHON" ]; then
    if ! pyenv versions --bare | grep -q "^${LATEST_PYTHON}$"; then
      pyenv install "$LATEST_PYTHON"
    fi
    pyenv global "$LATEST_PYTHON"
  fi
fi

# --- Go ---
log_step "Installing Go"
if [ ! -d "$HOME/.go" ] && [ ! -d "/usr/local/go" ]; then
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) GO_ARCH="amd64" ;;
    aarch64) GO_ARCH="arm64" ;;
    *) GO_ARCH="" ;;
  esac
  if [ -n "$GO_ARCH" ]; then
    GO_VERSION=$(curl -sL 'https://go.dev/VERSION?m=text' | head -n1)
    if [ -n "$GO_VERSION" ]; then
      TEMP_DIR=$(mktemp -d)
      curl -sL "https://go.dev/dl/${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -o "$TEMP_DIR/go.tar.gz"
      mkdir -p "$HOME/.go"
      tar -xzf "$TEMP_DIR/go.tar.gz" -C "$HOME/.go" --strip-components=1
      rm -rf "$TEMP_DIR"
      if ! grep -q 'GOROOT.*\.go' "$HOME/.bashrc" 2>/dev/null; then
        {
          echo ''
          echo '# Go configuration'
          echo 'export GOROOT="$HOME/.go"'
          echo 'export GOPATH="$HOME/.go/path"'
          echo 'export PATH="$GOROOT/bin:$GOPATH/bin:$PATH"'
        } >> "$HOME/.bashrc"
      fi
      export GOROOT="$HOME/.go"
      export GOPATH="$HOME/.go/path"
      export PATH="$GOROOT/bin:$GOPATH/bin:$PATH"
      mkdir -p "$GOPATH"
    fi
  fi
fi

# --- Rust ---
log_step "Installing Rust"
if [ ! -d "$HOME/.cargo" ]; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  [ -f "$HOME/.cargo/env" ] && \. "$HOME/.cargo/env"
fi

# --- Java (SDKMAN) ---
log_step "Installing Java"
if [ ! -d "$HOME/.sdkman" ]; then
  curl -s "https://get.sdkman.io?rcupdate=false&ci=true" | bash
  if ! grep -q 'sdkman-init.sh' "$HOME/.bashrc" 2>/dev/null; then
    {
      echo ''
      echo '# SDKMAN configuration'
      echo 'export SDKMAN_DIR="$HOME/.sdkman"'
      echo '[[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]] && source "$HOME/.sdkman/bin/sdkman-init.sh"'
    } >> "$HOME/.bashrc"
  fi
fi

export SDKMAN_DIR="$HOME/.sdkman"
if [ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
  set +u
  source "$SDKMAN_DIR/bin/sdkman-init.sh"
  set -u

  if ! sdk list java 2>/dev/null | grep -q "21.*tem.*installed"; then
    set +u
    sdk install java 21-tem < /dev/null || sdk install java 21-open < /dev/null || true
    set -u
  fi
fi

# --- Kotlin (SDKMAN) ---
log_step "Installing Kotlin"
export SDKMAN_DIR="$HOME/.sdkman"
if [ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
  set +u
  source "$SDKMAN_DIR/bin/sdkman-init.sh"
  set -u
  if ! command_exists kotlin; then
    set +u
    sdk install kotlin < /dev/null || true
    set -u
  fi
fi

# --- Lean (elan) ---
log_step "Installing Lean"
if [ ! -d "$HOME/.elan" ]; then
  curl https://elan.lean-lang.org/elan-init.sh -sSf | sh -s -- -y --default-toolchain stable
  [ -f "$HOME/.elan/env" ] && \. "$HOME/.elan/env"
  if ! grep -q 'elan' "$HOME/.bashrc" 2>/dev/null; then
    {
      echo ''
      echo '# Lean (elan) configuration'
      echo 'export PATH="$HOME/.elan/bin:$PATH"'
    } >> "$HOME/.bashrc"
  fi
fi

# --- Rocq/Coq (Opam) ---
log_step "Installing Rocq/Coq"
if ! command_exists opam; then
  bash -c "sh <(curl -fsSL https://opam.ocaml.org/install.sh) --no-backup" <<< "y" || {
    sudo apt install -y opam || true
  }
fi

if command_exists opam; then
  if [ ! -d "$HOME/.opam" ]; then
    opam init --disable-sandboxing --auto-setup -y || true
  fi
  eval "$(opam env --switch=default 2>/dev/null)" || true

  ROCQ_ACCESSIBLE=false
  if command -v rocq &>/dev/null && rocq -v &>/dev/null; then ROCQ_ACCESSIBLE=true; fi
  if command -v rocqc &>/dev/null; then ROCQ_ACCESSIBLE=true; fi
  if command -v coqc &>/dev/null; then ROCQ_ACCESSIBLE=true; fi

  if [ "$ROCQ_ACCESSIBLE" = false ]; then
    opam repo add rocq-released https://rocq-prover.org/opam/released 2>/dev/null || true
    opam update 2>/dev/null || true
    opam pin add rocq-prover --yes 2>/dev/null || opam install rocq-prover -y 2>/dev/null || opam install coq -y || true
    eval "$(opam env --switch=default 2>/dev/null)" || true
  fi

  if ! grep -q 'opam env' "$HOME/.bashrc" 2>/dev/null; then
    {
      echo ''
      echo '# Opam (OCaml/Rocq) configuration'
      echo 'test -r $HOME/.opam/opam-init/init.sh && . $HOME/.opam/opam-init/init.sh > /dev/null 2> /dev/null || true'
    } >> "$HOME/.bashrc"
  fi
fi

# --- Homebrew + PHP ---
log_step "Installing Homebrew + PHP"
if ! command_exists brew; then
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" 2>&1 || true

  if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  elif [[ -x "$HOME/.linuxbrew/bin/brew" ]]; then
    eval "$("$HOME/.linuxbrew/bin/brew" shellenv)"
  fi

  BREW_PREFIX=$(brew --prefix 2>/dev/null || echo "/home/linuxbrew/.linuxbrew")
  if ! grep -q "brew shellenv" "$HOME/.profile" 2>/dev/null; then
    echo "eval \"\$($BREW_PREFIX/bin/brew shellenv)\"" >> "$HOME/.profile"
  fi
  if ! grep -q "brew shellenv" "$HOME/.bashrc" 2>/dev/null; then
    echo "eval \"\$($BREW_PREFIX/bin/brew shellenv)\"" >> "$HOME/.bashrc"
  fi
else
  eval "$(brew shellenv 2>/dev/null)" || true
fi

if command_exists brew; then
  if ! brew list --formula 2>/dev/null | grep -q "^php@"; then
    if ! brew tap | grep -q "shivammathur/php"; then
      brew tap shivammathur/php || true
    fi
    if brew tap | grep -q "shivammathur/php"; then
      export HOMEBREW_NO_ANALYTICS=1
      export HOMEBREW_NO_AUTO_UPDATE=1
      brew install shivammathur/php/php@8.3 || true
      if brew list --formula 2>/dev/null | grep -q "^php@8.3$"; then
        brew link --overwrite --force shivammathur/php/php@8.3 2>&1 | grep -v "Warning" || true
        BREW_PREFIX=$(brew --prefix 2>/dev/null || echo "")
        if [[ -n "$BREW_PREFIX" && -d "$BREW_PREFIX/opt/php@8.3" ]]; then
          export PATH="$BREW_PREFIX/opt/php@8.3/bin:$BREW_PREFIX/opt/php@8.3/sbin:$PATH"
          if ! grep -q "php@8.3/bin" "$HOME/.bashrc" 2>/dev/null; then
            cat >> "$HOME/.bashrc" << 'PHP_PATH_EOF'

# PHP 8.3 PATH configuration
export PATH="$(brew --prefix)/opt/php@8.3/bin:$(brew --prefix)/opt/php@8.3/sbin:$PATH"
PHP_PATH_EOF
          fi
        fi
      fi
    fi
  fi
fi

# --- Perl (Perlbrew) ---
log_step "Installing Perl"
if [ ! -d "$HOME/.perl5" ]; then
  export PERLBREW_ROOT="$HOME/.perl5"
  curl -L https://install.perlbrew.pl | bash

  if ! grep -q 'perlbrew' "$HOME/.bashrc" 2>/dev/null; then
    {
      echo ''
      echo '# Perlbrew configuration'
      echo 'if [ -n "$PS1" ]; then'
      echo '  export PERLBREW_ROOT="$HOME/.perl5"'
      echo '  [ -f "$PERLBREW_ROOT/etc/bashrc" ] && source "$PERLBREW_ROOT/etc/bashrc"'
      echo 'fi'
    } >> "$HOME/.bashrc"
  fi

  if [ -f "$PERLBREW_ROOT/etc/bashrc" ]; then
    sed -i 's/\$1/${1:-}/g' "$PERLBREW_ROOT/etc/bashrc" 2>/dev/null || true
    sed -i 's/\$PERLBREW_LIB/${PERLBREW_LIB:-}/g' "$PERLBREW_ROOT/etc/bashrc" 2>/dev/null || true
    sed -i 's/\$outsep/${outsep:-}/g' "$PERLBREW_ROOT/etc/bashrc" 2>/dev/null || true

    set +u
    source "$PERLBREW_ROOT/etc/bashrc"
    set -u

    PERLBREW_OUTPUT=$(perlbrew available 2>&1 || true)
    LATEST_PERL=$(echo "$PERLBREW_OUTPUT" | grep -oE 'perl-5\.[0-9]+\.[0-9]+' | head -1 || true)
    if [ -n "$LATEST_PERL" ]; then
      if ! perlbrew list | grep -q "$LATEST_PERL"; then
        perlbrew install "$LATEST_PERL" --notest || true
      fi
      if perlbrew list | grep -q "$LATEST_PERL"; then
        perlbrew switch "$LATEST_PERL"
      fi
    fi
  fi
fi

# --- Ruby (rbenv) ---
log_step "Installing Ruby"
if [ ! -d "$HOME/.rbenv" ]; then
  git clone https://github.com/rbenv/rbenv.git "$HOME/.rbenv"
  mkdir -p "$HOME/.rbenv/plugins"
  git clone https://github.com/rbenv/ruby-build.git "$HOME/.rbenv/plugins/ruby-build"

  if ! grep -q 'rbenv init' "$HOME/.bashrc" 2>/dev/null; then
    {
      echo ''
      echo '# rbenv configuration'
      echo 'export PATH="$HOME/.rbenv/bin:$PATH"'
      echo 'eval "$(rbenv init - bash)"'
    } >> "$HOME/.bashrc"
  fi

  export PATH="$HOME/.rbenv/bin:$PATH"
  eval "$(rbenv init - bash)"

  LATEST_RUBY=$(rbenv install -l 2>/dev/null | grep -E '^\s*3\.[0-9]+\.[0-9]+$' | tail -1 | tr -d '[:space:]')
  if [ -n "$LATEST_RUBY" ]; then
    if ! rbenv versions | grep -q "$LATEST_RUBY"; then
      rbenv install "$LATEST_RUBY"
    fi
    rbenv global "$LATEST_RUBY"
  fi
fi

# --- Swift ---
log_step "Installing Swift"
if ! command_exists swift; then
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) SWIFT_DIR="ubuntu2404"; SWIFT_FILE_SUFFIX="ubuntu24.04" ;;
    aarch64) SWIFT_DIR="ubuntu2404-aarch64"; SWIFT_FILE_SUFFIX="ubuntu24.04-aarch64" ;;
    *) SWIFT_DIR=""; SWIFT_FILE_SUFFIX="" ;;
  esac

  if [ -n "$SWIFT_DIR" ]; then
    SWIFT_VERSION="6.0.3"
    SWIFT_RELEASE="RELEASE"
    SWIFT_PACKAGE="swift-${SWIFT_VERSION}-${SWIFT_RELEASE}-${SWIFT_FILE_SUFFIX}"
    SWIFT_URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/${SWIFT_DIR}/swift-${SWIFT_VERSION}-${SWIFT_RELEASE}/${SWIFT_PACKAGE}.tar.gz"

    TEMP_DIR=$(mktemp -d)
    if curl -fsSL "$SWIFT_URL" -o "$TEMP_DIR/swift.tar.gz"; then
      mkdir -p "$HOME/.swift"
      tar -xzf "$TEMP_DIR/swift.tar.gz" -C "$TEMP_DIR"
      cp -r "$TEMP_DIR/${SWIFT_PACKAGE}/usr" "$HOME/.swift/"
      rm -rf "$TEMP_DIR"

      if ! grep -q 'swift' "$HOME/.bashrc" 2>/dev/null; then
        {
          echo ''
          echo '# Swift configuration'
          echo 'export PATH="$HOME/.swift/usr/bin:$PATH"'
        } >> "$HOME/.bashrc"
      fi
      export PATH="$HOME/.swift/usr/bin:$PATH"
    else
      rm -rf "$TEMP_DIR"
    fi
  fi
fi

# --- AI Coding Agent CLI Tools and Hive Mind Workflow Utilities ---
log_step "Installing AI coding agent CLI tools and Hive Mind workflow utilities"

# Ensure NVM/Node and Bun are loaded
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm use 20 2>/dev/null || true
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# Install AI coding agent CLIs via bun (local/user-specific, FR-6)
# These are required for Hive Mind compatibility (issue #64)
# Some packages may not always be published; failures are non-fatal (C-6)
AI_PACKAGES="@anthropic-ai/claude-code @openai/codex @qwen-code/qwen-code @google/gemini-cli @github/copilot opencode-ai"
OPTIONAL_PACKAGES="@link-assistant/hive-mind @link-assistant/claude-profiles @link-assistant/agent"

log_info "Installing AI coding agent CLIs (required)..."
for pkg in $AI_PACKAGES; do
  log_info "Installing $pkg..."
  bun install -g "$pkg" 2>&1 | grep -v "^$" | head -5 || {
    log_warning "Failed to install $pkg (may not be published yet) - continuing"
  }
done

log_info "Installing optional Hive Mind packages (graceful failure)..."
for pkg in $OPTIONAL_PACKAGES; do
  log_info "Installing $pkg..."
  bun install -g "$pkg" 2>&1 | grep -v "^$" | head -5 || {
    log_note "$pkg not available (may not be published yet) - skipping"
  }
done

# Install Hive Mind workflow utilities via bun (FR-7)
log_info "Installing Hive Mind workflow utilities..."
WORKFLOW_PACKAGES="start-command gh-pull-all gh-load-issue gh-load-pull-request gh-upload-log"
for pkg in $WORKFLOW_PACKAGES; do
  log_info "Installing $pkg..."
  bun install -g "$pkg" 2>&1 | grep -v "^$" | head -5 || {
    log_warning "Failed to install $pkg - continuing"
  }
done

log_success "AI coding agent CLIs and workflow utilities installation complete"

# --- Playwright Browser Automation (FR-8) ---
log_step "Installing Playwright browser automation"

# Update npm to latest before installing Playwright
npm install -g npm@latest --no-fund --silent 2>&1 | tail -1 || true

# Install Playwright MCP server (for Claude Code integration)
log_info "Installing Playwright MCP server..."
npm install -g @playwright/mcp@latest --no-fund --silent 2>&1 | tail -3 || {
  log_warning "npm install -g @playwright/mcp@latest failed"
}

# Install Playwright CLI (needed for install-deps and browser install)
log_info "Installing Playwright CLI..."
npm install -g @playwright/test@latest --no-fund --silent 2>&1 | tail -3 || {
  log_warning "npm install -g @playwright/test@latest failed"
}

# Install Playwright OS dependencies (system libraries for browsers)
# Run install-deps as root via sudo, using the node binary from the user's NVM
log_info "Installing Playwright OS dependencies (requires sudo)..."
NPX_PATH="$(command -v npx 2>/dev/null || true)"
if [ -n "$NPX_PATH" ]; then
  NODE_BIN_DIR="$(dirname "$(command -v node 2>/dev/null || echo /usr/bin/node)")"
  sudo env "PATH=$NODE_BIN_DIR:$PATH" "$NPX_PATH" -y playwright@latest install-deps 2>&1 | grep -v "^$" || {
    log_warning "Playwright install-deps had issues (some system libraries may be missing)"
  }
  log_success "Playwright OS dependencies installed"
else
  log_warning "npx not found - skipping Playwright OS system deps"
fi

# Install Playwright browsers (architecture-aware)
log_info "Installing Playwright browsers..."
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
  BROWSERS_TO_INSTALL="chromium firefox webkit"
  log_note "Running on arm64: Chrome and Edge not available, using Chromium instead"
else
  BROWSERS_TO_INSTALL="chromium chrome firefox webkit msedge"
fi

log_note "Installing: $BROWSERS_TO_INSTALL"
for browser in $BROWSERS_TO_INSTALL; do
  log_info "Installing Playwright browser: $browser..."
  npx -y playwright@latest install "$browser" --with-deps 2>&1 | grep -E "(Downloading|downloaded|complete|error|Error)" | head -5 || {
    log_warning "Playwright browser $browser installation failed or skipped"
  }
done

# Install chromium headless shell (CI-optimized)
log_info "Installing chromium headless shell..."
npx -y playwright@latest install chromium-headless-shell --with-deps 2>&1 | grep -E "(Downloading|downloaded|complete|error|Error)" | head -5 || {
  log_note "chromium-headless-shell installation skipped"
}

# Verify Playwright installation
if command_exists playwright; then
  log_success "Playwright: $(playwright --version)"
else
  log_warning "Playwright CLI not found in PATH"
fi

# Configure Playwright MCP for Claude CLI (if claude is available)
if command_exists claude; then
  log_info "Configuring Playwright MCP for Claude CLI..."
  claude mcp remove playwright 2>/dev/null || true
  claude mcp add playwright -s user -- npx -y @playwright/mcp@latest --isolated --headless --no-sandbox --timeout-action=600000 --viewport-size 1920x1080 2>/dev/null || {
    log_note "Claude MCP config will be available after: claude mcp add playwright -s user -- npx -y @playwright/mcp@latest --isolated --headless --no-sandbox"
  }
fi

log_success "Playwright browser automation installation complete"

# --- Installation Summary ---
log_step "Installation Summary"

echo ""
echo "System & Development Tools:"
command_exists gh && log_success "GitHub CLI: $(gh --version | head -n1)" || true
command_exists gh-setup-git-identity && log_success "gh-setup-git-identity: installed" || true
command_exists glab && log_success "GitLab CLI: $(glab --version | head -n1)" || true
command_exists glab-setup-git-identity && log_success "glab-setup-git-identity: installed" || true
command_exists git && log_success "Git: $(git --version)" || true
command_exists bun && log_success "Bun: $(bun --version)" || true
command_exists deno && log_success "Deno: $(deno --version | head -n1)" || true
command_exists node && log_success "Node.js: $(node --version)" || true
command_exists python && log_success "Python: $(python --version)" || true
command_exists go && log_success "Go: $(go version)" || true
command_exists rustc && log_success "Rust: $(rustc --version)" || true
command_exists java && log_success "Java: $(java -version 2>&1 | head -n1)" || true
command_exists kotlin && log_success "Kotlin: $(kotlin -version 2>&1 | head -n1)" || true
command_exists lean && log_success "Lean: $(lean --version)" || true
command_exists R && log_success "R: $(R --version | head -n1)" || true
command_exists ruby && log_success "Ruby: $(ruby --version)" || true
command_exists swift && log_success "Swift: $(swift --version 2>&1 | head -n1)" || true
command_exists brew && log_success "Homebrew: $(brew --version 2>/dev/null | head -n1)" || true
command_exists php && log_success "PHP: $(php --version 2>/dev/null | head -n1)" || true
command_exists perl && log_success "Perl: $(perl --version | head -n 2 | tail -n 1 | sed 's/^[[:space:]]*//')" || true
command_exists opam && log_success "Opam: $(opam --version)" || true

echo ""
echo "AI Coding Agent CLI Tools:"
command_exists claude && log_success "Claude Code: $(claude --version 2>/dev/null | head -n1)" || log_warning "Claude Code: not found"
command_exists codex && log_success "OpenAI Codex: installed" || log_warning "OpenAI Codex: not found"
command_exists gemini && log_success "Gemini CLI: installed" || log_warning "Gemini CLI: not found"
command_exists opencode && log_success "OpenCode: installed" || log_warning "OpenCode: not found"

echo ""
echo "Playwright:"
command_exists playwright && log_success "Playwright CLI: $(playwright --version)" || log_warning "Playwright CLI: not found"
PLAYWRIGHT_CACHE="$HOME/.cache/ms-playwright"
for browser in chromium firefox webkit chromium_headless_shell; do
  BROWSER_DIR=$(ls -d "$PLAYWRIGHT_CACHE/${browser}"* 2>/dev/null | head -1 || true)
  if [ -n "$BROWSER_DIR" ] && [ -d "$BROWSER_DIR" ]; then
    log_success "Playwright browser: $browser"
  else
    log_warning "Playwright browser not in cache: $browser"
  fi
done

echo ""
EOF_FULL_SETUP

chmod +x /tmp/full-sandbox-user-setup.sh
if [ "$EUID" -eq 0 ]; then
  su - sandbox -c "bash /tmp/full-sandbox-user-setup.sh"
else
  sudo -i -u sandbox bash /tmp/full-sandbox-user-setup.sh
fi
rm -f /tmp/full-sandbox-user-setup.sh

# --- Final cleanup ---
log_step "Final cleanup"
maybe_sudo apt-get clean
maybe_sudo apt-get autoclean
maybe_sudo apt-get autoremove -y
maybe_sudo rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

log_step "Full Sandbox setup complete!"
log_success "All components installed successfully"
log_note "Please restart your shell or run: source ~/.bashrc"
