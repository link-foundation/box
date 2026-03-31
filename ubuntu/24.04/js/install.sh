#!/usr/bin/env bash
# JavaScript/TypeScript runtime installation (Node.js via NVM, Bun, Deno)
# Usage: curl -fsSL <url> | bash  OR  bash install.sh
# Requires: curl, git (should be pre-installed on Ubuntu 24.04)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../common.sh" ]; then
  source "$SCRIPT_DIR/../common.sh"
else
  set -euo pipefail
  log_info() { echo "[*] $1"; }
  log_success() { echo "[✓] $1"; }
  log_warning() { echo "[!] $1"; }
  log_step() { echo "==> $1"; }
  command_exists() { command -v "$1" &>/dev/null; }
fi

log_step "Installing JavaScript/TypeScript runtimes"

# --- Bun ---
if ! command_exists bun; then
  log_info "Installing Bun..."
  curl -fsSL https://bun.sh/install | bash
  export BUN_INSTALL="$HOME/.bun"
  export PATH="$BUN_INSTALL/bin:$PATH"
  log_success "Bun installed"
else
  log_info "Bun already installed."
fi

export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# --- Deno ---
if ! command_exists deno; then
  log_info "Installing Deno..."
  curl -fsSL https://deno.land/install.sh | sh -s -- -y
  export DENO_INSTALL="$HOME/.deno"
  export PATH="$DENO_INSTALL/bin:$PATH"
  if ! grep -q 'DENO_INSTALL' "$HOME/.bashrc" 2>/dev/null; then
    {
      echo ''
      echo '# Deno configuration'
      echo 'export DENO_INSTALL="$HOME/.deno"'
      echo 'export PATH="$DENO_INSTALL/bin:$PATH"'
    } >> "$HOME/.bashrc"
  fi
  log_success "Deno installed"
else
  log_info "Deno already installed."
fi

# --- NVM + Node.js ---
if [ ! -d "$HOME/.nvm" ]; then
  log_info "Installing NVM..."
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
  log_success "NVM installed"
else
  log_info "NVM already installed."
fi

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

if ! nvm ls 20 2>/dev/null | grep -q 'v20'; then
  log_info "Installing Node.js 20..."
  nvm install 20
  log_success "Node.js 20 installed"
else
  log_info "Node.js 20 already installed"
fi
nvm use 20

log_info "Updating npm to latest version..."
npm install -g npm@latest --no-fund --silent
log_success "npm updated to latest version"

# --- Playwright CLI + @playwright/test + @puppeteer/browsers ---
log_step "Installing Playwright, @playwright/test, and @puppeteer/browsers CLIs"

log_info "Installing playwright, @playwright/test, and @puppeteer/browsers globally via npm..."
npm install -g playwright @playwright/test @puppeteer/browsers --no-fund --force
log_success "playwright, @playwright/test, and @puppeteer/browsers CLIs installed"

# Verify installations
command -v playwright || { echo "ERROR: playwright not found after install"; exit 1; }
log_success "playwright CLI verified"

# --- Download Playwright browser binaries ---
log_step "Downloading Playwright browser binaries"

ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ] || [ "$ARCH" = "amd64" ]; then
  log_info "x86_64 detected: installing all browsers (chromium, firefox, webkit, msedge, chromium-headless-shell, chrome)"
  playwright install chromium firefox webkit msedge chromium-headless-shell chrome
else
  log_info "$ARCH detected: installing compatible browsers (chromium, firefox, webkit, chromium-headless-shell)"
  playwright install chromium firefox webkit chromium-headless-shell
fi
log_success "Playwright browser binaries downloaded"

# Verify at least chromium is available
if [ -d "$HOME/.cache/ms-playwright" ]; then
  log_success "Playwright browser cache exists at $HOME/.cache/ms-playwright"
else
  echo "ERROR: Playwright browser cache not found at $HOME/.cache/ms-playwright"
  exit 1
fi

log_success "JavaScript/TypeScript runtimes installation complete"
