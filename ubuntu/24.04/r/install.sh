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
  log_warning() { echo "[!] $1"; }
  log_step() { echo "==> $1"; }
  command_exists() { command -v "$1" &>/dev/null; }
  maybe_sudo() { if [ "$EUID" -eq 0 ]; then "$@"; elif command -v sudo &>/dev/null; then sudo "$@"; else "$@"; fi; }
  apt_update_with_retry() { maybe_sudo apt-get update -y -o Acquire::Retries=3; }
fi

log_step "Installing R"

if ! command_exists R; then
  log_info "Installing R statistical language..."
  # Prefer CRAN's maintained builds over the frozen distro package (issue #112);
  # add_cran_repo() degrades to the distro R when CRAN is unreachable.
  if command -v add_cran_repo >/dev/null 2>&1; then
    add_cran_repo || true
  fi
  apt_update_with_retry
  maybe_sudo apt-get install -y r-base || {
    log_warning "r-base install failed; retrying without the CRAN repository"
    maybe_sudo rm -f /etc/apt/sources.list.d/cran.list
    apt_update_with_retry
    maybe_sudo apt-get install -y r-base
  }
  log_success "R language installed"
else
  log_info "R already installed."
fi

if command_exists R; then
  log_success "R: $(R --version 2>/dev/null | head -n1)"
fi

log_success "R installation complete"
