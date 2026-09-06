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
  log_warning() { echo "[!] $1"; }
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
    } >>"$HOME/.bashrc"
  fi
  log_success "rbenv installed and configured"
else
  # ruby-build ships the list of installable Rubies as data, so an rbenv that
  # was cloned months ago cannot install anything released since. Refresh it
  # before asking for "the latest" (issue #112).
  log_info "rbenv already installed; refreshing rbenv and ruby-build..."
  git -C "$HOME/.rbenv" pull --ff-only 2>/dev/null || log_warning "Could not update rbenv"
  if [ -d "$HOME/.rbenv/plugins/ruby-build" ]; then
    git -C "$HOME/.rbenv/plugins/ruby-build" pull --ff-only 2>/dev/null || log_warning "Could not update ruby-build"
  fi
fi

export PATH="$HOME/.rbenv/bin:$PATH"
eval "$(rbenv init - bash)"

# `rbenv install -l` lists only stable releases, so the newest numeric entry is
# the latest stable Ruby of any major. The old filter was pinned to 3.x, which
# would silently keep the box on Ruby 3 forever once Ruby 4 ships.
log_info "Resolving the latest stable Ruby version..."
LATEST_RUBY="${RUBY_VERSION:-}"
if [ -z "$LATEST_RUBY" ]; then
  LATEST_RUBY=$(rbenv install -l 2>/dev/null | grep -E '^[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+$' | tail -1 | tr -d '[:space:]')
fi

if [ -n "$LATEST_RUBY" ]; then
  log_info "Installing Ruby $LATEST_RUBY..."
  if ! rbenv versions --bare 2>/dev/null | grep -E "^${LATEST_RUBY}$" >/dev/null; then
    rbenv install "$LATEST_RUBY"
  else
    log_info "Ruby $LATEST_RUBY already installed."
  fi

  rbenv global "$LATEST_RUBY"
  rbenv rehash

  # One Ruby per image (issue #112).
  for installed in $(rbenv versions --bare 2>/dev/null); do
    if [ "$installed" != "$LATEST_RUBY" ]; then
      log_info "Removing extra Ruby $installed (keeping $LATEST_RUBY)"
      rm -rf "$HOME/.rbenv/versions/$installed"
    fi
  done
  rbenv rehash

  log_success "Ruby version manager setup complete"
  ruby --version
else
  log_warning "Could not resolve a Ruby version to install"
fi

# Build-time invariant: exactly one Ruby under ~/.rbenv/versions.
if command -v assert_single_runtime_versions >/dev/null 2>&1; then
  assert_single_runtime_versions
fi

log_success "Ruby installation complete"
