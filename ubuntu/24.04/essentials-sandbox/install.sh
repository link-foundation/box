#!/usr/bin/env bash
set -euo pipefail

# Essentials Sandbox Installation Script
# Installs tooling required for gh-setup-git-identity and glab-setup-git-identity
# on top of an existing JS sandbox (Node.js, Bun, Deno already available).
#
# Components added: system essentials, GitHub CLI, GitLab CLI, git identity tools
#
# This is the layer between JS sandbox and full-sandbox.

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

log_step "Installing Essentials Sandbox (on top of JS sandbox)"

# --- Pre-flight Checks ---
log_step "Running pre-flight checks"

if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
  log_error "This script requires sudo access."
  exit 1
fi

if [ -f /etc/os-release ]; then
  source /etc/os-release
  if [[ "${ID:-}" == "ubuntu" ]]; then
    log_success "Ubuntu ${VERSION_ID:-unknown} detected"
  else
    log_warning "This script is designed for Ubuntu. Detected: ${ID:-unknown}"
  fi
fi

log_success "Pre-flight checks passed"

# --- Ensure sandbox user exists ---
log_step "Setting up sandbox user"
if id "sandbox" &>/dev/null; then
  log_info "sandbox user already exists."
else
  log_info "Creating sandbox user..."
  useradd -m -d /workspace -s /bin/bash sandbox 2>/dev/null || adduser --disabled-password --gecos "" --home /workspace sandbox
  passwd -d sandbox 2>/dev/null || true
  usermod -aG sudo sandbox 2>/dev/null || true
  log_success "sandbox user created"
fi

# --- System prerequisites ---
log_step "Installing system prerequisites"

# Clean up duplicate sources
for pair in "microsoft-edge:microsoft-edge-stable" "google-chrome:google-chrome-stable"; do
  f1="/etc/apt/sources.list.d/${pair%%:*}.list"
  f2="/etc/apt/sources.list.d/${pair##*:}.list"
  if [ -f "$f1" ] && [ -f "$f2" ]; then
    maybe_sudo rm -f "$f1"
  fi
done

maybe_sudo apt update -y || true

# Core system tools
maybe_sudo apt install -y \
  wget curl unzip zip git sudo ca-certificates gnupg \
  build-essential expect screen

# Common development libraries used by multiple language runtimes
# (Python, Ruby, Rust, Go, etc. all benefit from these)
maybe_sudo apt install -y \
  libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
  libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev \
  libffi-dev liblzma-dev libyaml-dev

log_success "System prerequisites installed"

# --- Playwright and Puppeteer system dependencies ---
log_step "Installing Playwright and Puppeteer browser system dependencies"
# These are the system-level libraries required by Chromium, Firefox, and WebKit browsers
# Source: https://playwright.dev/docs/browsers#install-system-dependencies
#         https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/server/registry/nativeDeps.ts
#         https://pptr.dev/troubleshooting
maybe_sudo apt install -y \
  libasound2t64 \
  libatk-bridge2.0-0t64 \
  libatk1.0-0t64 \
  libatspi2.0-0t64 \
  libcairo2 \
  libcups2t64 \
  libdbus-1-3 \
  libdrm2 \
  libgbm1 \
  libglib2.0-0t64 \
  libnspr4 \
  libnss3 \
  libpango-1.0-0 \
  libx11-6 \
  libxcb1 \
  libxcomposite1 \
  libxdamage1 \
  libxext6 \
  libxfixes3 \
  libxkbcommon0 \
  libxrandr2 \
  libavcodec60 \
  libcairo-gobject2 \
  libfontconfig1 \
  libfreetype6 \
  libgdk-pixbuf-2.0-0 \
  libgtk-3-0t64 \
  libpangocairo-1.0-0 \
  libx11-xcb1 \
  libxcb-shm0 \
  libxcursor1 \
  libxi6 \
  libxrender1 \
  gstreamer1.0-libav \
  gstreamer1.0-plugins-bad \
  gstreamer1.0-plugins-base \
  gstreamer1.0-plugins-good \
  libatomic1 \
  libenchant-2-2 \
  libepoxy0 \
  libevent-2.1-7t64 \
  libflite1 \
  libgles2 \
  libgstreamer-gl1.0-0 \
  libgstreamer-plugins-bad1.0-0 \
  libgstreamer-plugins-base1.0-0 \
  libgstreamer1.0-0 \
  libgtk-4-1 \
  libharfbuzz-icu0 \
  libharfbuzz0b \
  libhyphen0 \
  libjpeg-turbo8 \
  liblcms2-2 \
  libmanette-0.2-0 \
  libopus0 \
  libpng16-16t64 \
  libsecret-1-0 \
  libvpx9 \
  libwayland-client0 \
  libwayland-egl1 \
  libwayland-server0 \
  libwebp7 \
  libwebpdemux2 \
  libwoff1 \
  libxml2 \
  libxslt1.1 \
  libxss1 \
  libxtst6 \
  xdg-utils \
  xvfb \
  fonts-liberation \
  fonts-noto-color-emoji \
  fonts-ipafont-gothic \
  fonts-wqy-zenhei \
  fonts-freefont-ttf
log_success "Playwright and Puppeteer system dependencies installed"

# --- GitHub CLI ---
log_step "Installing GitHub CLI"
if ! command_exists gh; then
  maybe_sudo mkdir -p -m 755 /etc/apt/keyrings
  out=$(mktemp)
  wget -nv -O"$out" https://cli.github.com/packages/githubcli-archive-keyring.gpg
  cat "$out" | maybe_sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
  maybe_sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  rm -f "$out"

  maybe_sudo mkdir -p -m 755 /etc/apt/sources.list.d
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | maybe_sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null

  maybe_sudo apt update -y
  maybe_sudo apt install -y gh
  log_success "GitHub CLI installed"
else
  log_success "GitHub CLI already installed"
fi

# --- GitLab CLI ---
log_step "Installing GitLab CLI"
if ! command_exists glab; then
  maybe_sudo apt install -y glab
  log_success "GitLab CLI installed"
else
  log_success "GitLab CLI already installed"
fi

# --- Install git identity tools as sandbox user (using Bun from JS sandbox) ---
log_step "Installing git identity tools"

cat > /tmp/essentials-identity-setup.sh <<'EOF_IDENTITY'
#!/usr/bin/env bash
set -euo pipefail

log_info() { echo "[*] $1"; }
log_success() { echo "[✓] $1"; }
command_exists() { command -v "$1" &>/dev/null; }

# Load Bun from JS sandbox
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# gh-setup-git-identity
if command_exists bun; then
  if ! command_exists gh-setup-git-identity; then
    log_info "Installing gh-setup-git-identity..."
    bun install -g gh-setup-git-identity
  fi
fi

# glab-setup-git-identity
if command_exists bun; then
  if ! command_exists glab-setup-git-identity; then
    log_info "Installing glab-setup-git-identity..."
    bun install -g glab-setup-git-identity
  fi
fi

# Git setup if gh is authenticated
if gh auth status &>/dev/null; then
  log_info "Configuring Git with GitHub identity..."
  git config --global user.name "$(gh api user --jq .login)"
  git config --global user.email "$(gh api user/emails --jq '.[] | select(.primary==true).email')"
  gh auth setup-git
fi

# --- Playwright CLI ---
log_info "Installing Playwright CLI globally via npm..."
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
if command_exists npm; then
  npm install -g playwright --no-fund --silent
  log_success "playwright CLI installed"
elif command_exists bun; then
  bun install -g playwright
  log_success "playwright CLI installed via bun"
fi

# --- Puppeteer browsers CLI ---
log_info "Installing @puppeteer/browsers CLI globally via npm..."
if command_exists npm; then
  npm install -g @puppeteer/browsers --no-fund --silent
  log_success "@puppeteer/browsers CLI installed"
elif command_exists bun; then
  bun install -g @puppeteer/browsers
  log_success "@puppeteer/browsers CLI installed via bun"
fi

log_success "Essentials identity tools setup complete"
EOF_IDENTITY

chmod +x /tmp/essentials-identity-setup.sh
if [ "$EUID" -eq 0 ]; then
  su - sandbox -c "bash /tmp/essentials-identity-setup.sh"
else
  sudo -i -u sandbox bash /tmp/essentials-identity-setup.sh
fi
rm -f /tmp/essentials-identity-setup.sh

# --- Cleanup ---
log_step "Cleaning up"
maybe_sudo apt-get clean
maybe_sudo apt-get autoclean
maybe_sudo apt-get autoremove -y
maybe_sudo rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

log_step "Essentials Sandbox setup complete!"
log_success "Added on top of JS sandbox: git, gh, glab, gh-setup-git-identity, glab-setup-git-identity, playwright, @puppeteer/browsers"
