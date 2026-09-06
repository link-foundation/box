#!/usr/bin/env bash
# JavaScript/TypeScript runtime installation (Node.js via NVM, Bun, Deno)
# Usage: curl -fsSL <url> | bash  OR  bash install.sh
# Requires: curl, git (should be pre-installed on Ubuntu 24.04)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../common.sh" ]; then
  source "$SCRIPT_DIR/../common.sh"
elif [ -f "/tmp/common.sh" ]; then
  source "/tmp/common.sh"
else
  set -euo pipefail
  log_info() { echo "[*] $1"; }
  log_success() { echo "[✓] $1"; }
  log_warning() { echo "[!] $1"; }
  log_step() { echo "==> $1"; }
  command_exists() { command -v "$1" &>/dev/null; }
fi

# Network-bound build steps — npm registry installs and Playwright browser
# downloads — occasionally fail transiently in CI (ECONNRESET, 429, registry 5xx,
# or a flaky third-party repo such as packages.microsoft.com serving an invalid
# GPG key body when Playwright installs the 'msedge' browser), which used to fail
# the whole image build on a single blip. Retry a command a few times with
# exponential backoff before giving up. Mirrors apt_update_with_retry() in
# ../common.sh, including the overridable retry budget so it can be unit-tested
# with a zero delay.
run_with_retry() {
  local max_retries="${BUILD_RETRY_MAX_RETRIES:-5}"
  local delay="${BUILD_RETRY_INITIAL_DELAY:-5}"
  local attempt=1

  while [ "$attempt" -le "$max_retries" ]; do
    if "$@"; then
      return 0
    fi

    if [ "$attempt" -eq "$max_retries" ]; then
      log_warning "command still failing after ${max_retries} attempts: $*"
      return 1
    fi

    log_warning "attempt ${attempt}/${max_retries} failed: $* — retrying in ${delay}s"
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
}

# The build-time version policy lives in ../common.sh. When this script is run
# standalone (curl | bash) without it, fall back to the same pinned versions.
if ! command -v resolve_nvm_version >/dev/null 2>&1; then
  resolve_nvm_version() { echo "${NVM_VERSION:-v0.40.7}"; }
fi
if ! command -v resolve_node_lts_major >/dev/null 2>&1; then
  resolve_node_lts_major() { echo "${NODE_VERSION:-24}"; }
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
    } >>"$HOME/.bashrc"
  fi
  log_success "Deno installed"
else
  log_info "Deno already installed."
fi

# --- NVM + Node.js ---
# The nvm installer tag and the Node.js major are both resolved at build time
# (see the version policy in ../common.sh): a hardcoded major silently ages out
# of LTS support between releases, which is exactly what issue #112 reports.
# Override for a reproducible or pinned build with NVM_VERSION / NODE_VERSION.
NVM_INSTALL_VERSION="$(resolve_nvm_version)"
if [ ! -d "$HOME/.nvm" ]; then
  log_info "Installing NVM ${NVM_INSTALL_VERSION}..."
  curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_INSTALL_VERSION}/install.sh" | bash
  log_success "NVM ${NVM_INSTALL_VERSION} installed"
else
  log_info "NVM already installed."
fi

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

NODE_MAJOR="$(resolve_node_lts_major)"
log_info "Node.js LTS resolved for this build: ${NODE_MAJOR}"

if ! nvm ls "$NODE_MAJOR" 2>/dev/null | grep "v${NODE_MAJOR}\." >/dev/null; then
  log_info "Installing Node.js ${NODE_MAJOR}..."
  nvm install "$NODE_MAJOR"
  log_success "Node.js ${NODE_MAJOR} installed"
else
  log_info "Node.js ${NODE_MAJOR} already installed"
fi

# `nvm use` only affects this shell. Without an explicit default alias, a login
# shell (and therefore the image's effective PATH) keeps whatever nvm aliased
# first, so the box could ship one Node and run another.
nvm use "$NODE_MAJOR"
nvm alias default "$NODE_MAJOR"

# Keep one version per language root (issue #112): drop any other Node that a
# previous layer or an earlier build of this image left behind, so the image
# never carries two runtimes worth of bytes.
NODE_KEEP="$(nvm current)"
# list_installed_versions (../common.sh) globs the directory instead of parsing
# `ls`, so a version directory is never word-split and nvm's own bookkeeping
# entries are never handed to `nvm uninstall`.
while IFS= read -r installed; do
  if [ "$installed" != "$NODE_KEEP" ]; then
    log_info "Removing extra Node.js $installed (keeping $NODE_KEEP)"
    nvm uninstall "$installed" || log_warning "Could not uninstall Node.js $installed"
  fi
done < <(list_installed_versions "$NVM_DIR/versions/node")

log_success "Node.js $(node --version) active, nvm default alias set to ${NODE_MAJOR}"

log_info "Updating npm to latest version..."
run_with_retry npm install -g npm@latest --no-fund --silent
log_success "npm updated to latest version"

# --- Playwright CLI + @playwright/test + @puppeteer/browsers ---
log_step "Installing Playwright, @playwright/test, and @puppeteer/browsers CLIs"

log_info "Installing playwright, @playwright/test, and @puppeteer/browsers globally via npm..."
run_with_retry npm install -g playwright @playwright/test @puppeteer/browsers --no-fund --force
log_success "playwright, @playwright/test, and @puppeteer/browsers CLIs installed"

# Verify installations
command -v playwright || {
  echo "ERROR: playwright not found after install"
  exit 1
}
log_success "playwright CLI verified"

# --- Download Playwright browser binaries ---
log_step "Downloading Playwright browser binaries"

# 'playwright install' downloads browser binaries: chromium/firefox/webkit/
# chromium-headless-shell come from Playwright's CDN, but msedge and chrome are
# fetched from third-party apt repos (packages.microsoft.com / Google) that
# occasionally return a transient error — e.g. an invalid GPG key body that makes
# the install abort with "gpg: no valid OpenPGP data found" / "Failed to install
# msedge". Retry the whole step; Playwright skips already-installed browsers, so a
# retry only re-attempts the one that blipped.
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ] || [ "$ARCH" = "amd64" ]; then
  log_info "x86_64 detected: installing all browsers (chromium, firefox, webkit, msedge, chromium-headless-shell, chrome)"
  run_with_retry playwright install chromium firefox webkit msedge chromium-headless-shell chrome
else
  log_info "$ARCH detected: installing compatible browsers (chromium, firefox, webkit, chromium-headless-shell)"
  run_with_retry playwright install chromium firefox webkit chromium-headless-shell
fi
log_success "Playwright browser binaries downloaded"

# Verify at least chromium is available
if [ -d "$HOME/.cache/ms-playwright" ]; then
  log_success "Playwright browser cache exists at $HOME/.cache/ms-playwright"
else
  echo "ERROR: Playwright browser cache not found at $HOME/.cache/ms-playwright"
  exit 1
fi

# Build-time invariant: exactly one Node.js under ~/.nvm/versions/node.
if command -v assert_single_runtime_versions >/dev/null 2>&1; then
  assert_single_runtime_versions
fi

log_success "JavaScript/TypeScript runtimes installation complete"
