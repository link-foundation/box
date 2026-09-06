#!/usr/bin/env bash
# Perl installation via Perlbrew
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
fi

log_step "Installing Perl via Perlbrew"

if [ ! -d "$HOME/.perl5" ]; then
  log_info "Installing Perlbrew (Perl version manager)..."

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
    } >>"$HOME/.bashrc"
  fi

  if [ -f "$PERLBREW_ROOT/etc/bashrc" ]; then
    sed -i 's/\$1/${1:-}/g' "$PERLBREW_ROOT/etc/bashrc" 2>/dev/null || true
    sed -i 's/\$PERLBREW_LIB/${PERLBREW_LIB:-}/g' "$PERLBREW_ROOT/etc/bashrc" 2>/dev/null || true
    sed -i 's/\$outsep/${outsep:-}/g' "$PERLBREW_ROOT/etc/bashrc" 2>/dev/null || true

    set +u
    source "$PERLBREW_ROOT/etc/bashrc"
    set -u
    log_success "Perlbrew installed and configured"

    log_info "Installing latest stable Perl version..."
    PERLBREW_OUTPUT=$(perlbrew available 2>&1 || true)
    LATEST_PERL=$(echo "$PERLBREW_OUTPUT" | grep -oE 'perl-5\.[0-9]+\.[0-9]+' | head -1 || true)

    if [ -n "$LATEST_PERL" ]; then
      log_info "Installing $LATEST_PERL..."
      if ! perlbrew list | grep -q "$LATEST_PERL"; then
        perlbrew install "$LATEST_PERL" --notest || true
      fi

      if perlbrew list | grep -q "$LATEST_PERL"; then
        perlbrew switch "$LATEST_PERL"
        log_success "Perl version manager setup complete"
      fi
    fi
  fi
else
  log_info "Perlbrew already installed."
fi

log_success "Perl installation complete"
