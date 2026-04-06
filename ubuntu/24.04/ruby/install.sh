#!/usr/bin/env bash
# Ruby installation via rbenv
# Usage: curl -fsSL <url> | bash  OR  bash install.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../common.sh" ]; then
  source "$SCRIPT_DIR/../common.sh"
elif [ -f "/tmp/common.sh" ]; then
  source "/tmp/common.sh"
else
  set -euo pipefail
  log_info() { echo "[*] $1"; }
  log_success() { echo "[✓] $1"; }
  log_step() { echo "==> $1"; }
  command_exists() { command -v "$1" &>/dev/null; }
  maybe_sudo() { if [ "$EUID" -eq 0 ]; then "$@"; elif command -v sudo &>/dev/null; then sudo "$@"; else "$@"; fi; }
fi

log_step "Installing Ruby via rbenv"

# Note: Build dependencies (libyaml-dev, libssl-dev, etc.) are provided by essentials-box.

if [ ! -d "$HOME/.rbenv" ]; then
  log_info "Installing rbenv (Ruby version manager)..."

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
  log_success "rbenv installed and configured"

  # Install latest stable Ruby 3.x version (avoid pre-release 4.x)
  log_info "Installing latest stable Ruby version..."
  LATEST_RUBY=$(rbenv install -l 2>/dev/null | grep -E '^\s*3\.[0-9]+\.[0-9]+$' | tail -1 | tr -d '[:space:]')

  if [ -n "$LATEST_RUBY" ]; then
    log_info "Installing Ruby $LATEST_RUBY..."
    if ! rbenv versions | grep -q "$LATEST_RUBY"; then
      rbenv install "$LATEST_RUBY"
    else
      log_info "Ruby $LATEST_RUBY already installed."
    fi

    rbenv global "$LATEST_RUBY"
    log_success "Ruby version manager setup complete"
    ruby --version
  fi
else
  log_info "rbenv already installed."
fi

log_success "Ruby installation complete"
