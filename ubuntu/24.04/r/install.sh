#!/usr/bin/env bash
# R language installation
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
  apt_update_with_retry() { maybe_sudo apt-get update -y -o Acquire::Retries=3; }
fi

log_step "Installing R"

if ! command_exists R; then
  log_info "Installing R statistical language..."
  apt_update_with_retry
  maybe_sudo apt install -y r-base
  log_success "R language installed"
else
  log_info "R already installed."
fi

log_success "R installation complete"
