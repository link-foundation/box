#!/usr/bin/env bash
# C/C++ development tools installation (CMake, Clang, LLVM, LLD)
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

log_step "Installing C/C++ Development Tools"

apt_update_with_retry

log_info "Installing build-essential, CMake, Clang/LLVM, LLD..."
maybe_sudo apt install -y build-essential cmake clang llvm lld
log_success "C/C++ development tools installed"

log_success "C/C++ tools installation complete"
