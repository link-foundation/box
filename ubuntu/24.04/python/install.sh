#!/usr/bin/env bash
# Python installation via Pyenv
# Usage: curl -fsSL <url> | bash  OR  bash install.sh
# Requires: essentials-box (provides build dependencies: libssl-dev, zlib1g-dev, etc.)

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

log_step "Installing Python via Pyenv"

# Note: Build dependencies (libssl-dev, zlib1g-dev, libbz2-dev, libreadline-dev,
# libsqlite3-dev, libncursesw5-dev, xz-utils, tk-dev, libxml2-dev, libxmlsec1-dev,
# libffi-dev, liblzma-dev) are provided by essentials-box.

# --- Pyenv ---
if [ ! -d "$HOME/.pyenv" ]; then
  log_info "Installing Pyenv..."
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
  log_success "Pyenv installed and configured"
else
  log_info "Pyenv already installed."
fi

# Load pyenv for current session
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
if command -v pyenv >/dev/null 2>&1; then
  eval "$(pyenv init --path)"
  eval "$(pyenv init -)"
  log_success "Pyenv loaded for current session"

  # Install latest stable Python version
  log_info "Installing latest stable Python version..."
  LATEST_PYTHON=$(pyenv install --list | grep -E '^\s*[0-9]+\.[0-9]+\.[0-9]+$' | tail -1 | tr -d '[:space:]')

  if [ -n "$LATEST_PYTHON" ]; then
    log_info "Installing Python $LATEST_PYTHON..."
    if ! pyenv versions --bare | grep -q "^${LATEST_PYTHON}$"; then
      pyenv install "$LATEST_PYTHON"
    else
      log_info "Python $LATEST_PYTHON already installed."
    fi

    log_info "Setting Python $LATEST_PYTHON as global default..."
    pyenv global "$LATEST_PYTHON"
    log_success "Python version manager setup complete"
    python --version
  fi
fi

log_success "Python installation complete"
