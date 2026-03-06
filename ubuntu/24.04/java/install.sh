#!/usr/bin/env bash
# Java installation via SDKMAN (Eclipse Temurin 21 LTS)
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

log_step "Installing Java via SDKMAN"

# --- SDKMAN ---
if [ ! -d "$HOME/.sdkman" ]; then
  log_info "Installing SDKMAN (Java version manager)..."
  curl -s "https://get.sdkman.io?rcupdate=false&ci=true" | bash
  if ! grep -q 'sdkman-init.sh' "$HOME/.bashrc" 2>/dev/null; then
    {
      echo ''
      echo '# SDKMAN configuration'
      echo 'export SDKMAN_DIR="$HOME/.sdkman"'
      echo '[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ] && . "$HOME/.sdkman/bin/sdkman-init.sh"'
    } >> "$HOME/.bashrc"
  fi
  log_success "SDKMAN installed and configured"
else
  log_info "SDKMAN already installed."
fi

# Load SDKMAN and install Java
export SDKMAN_DIR="$HOME/.sdkman"
if [ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
  set +u
  source "$SDKMAN_DIR/bin/sdkman-init.sh"
  set -u
  log_success "SDKMAN loaded for current session"

  log_info "Installing Java 21 LTS (OpenJDK via Eclipse Temurin)..."
  set +u
  if ! sdk list java 2>/dev/null | grep -q "21.*tem.*installed"; then
    sdk install java 21-tem < /dev/null || {
      log_warning "Eclipse Temurin installation failed, trying default OpenJDK..."
      sdk install java 21-open < /dev/null || true
    }
  else
    log_info "Java 21 (Temurin) already installed."
  fi
  set -u

  if command -v java &>/dev/null; then
    log_success "Java version manager setup complete"
    java -version 2>&1 | head -n1
  fi
fi

log_success "Java installation complete"
