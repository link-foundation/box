#!/usr/bin/env bash
# Assembly tools installation (NASM, FASM)
# Usage: curl -fsSL <url> | bash  OR  bash install.sh
# Note: FASM is only available on x86_64 architecture

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../common.sh" ]; then
  source "$SCRIPT_DIR/../common.sh"
elif [ -f "/tmp/common.sh" ]; then
  source "/tmp/common.sh"
else
  set -euo pipefail
  log_info() { echo "[*] $1"; }
  log_success() { echo "[✓] $1"; }
  log_note() { echo "[i] $1"; }
  log_step() { echo "==> $1"; }
  command_exists() { command -v "$1" &>/dev/null; }
  maybe_sudo() { if [ "$EUID" -eq 0 ]; then "$@"; elif command -v sudo &>/dev/null; then sudo "$@"; else "$@"; fi; }
  apt_update_with_retry() { maybe_sudo apt-get update -y -o Acquire::Retries=3; }
fi

log_step "Installing Assembly Tools"

apt_update_with_retry

ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
  maybe_sudo apt-get install -y nasm fasm
  log_success "Assembly tools installed (NASM + FASM)"
else
  maybe_sudo apt-get install -y nasm
  log_success "Assembly tools installed (NASM only - FASM not available for $ARCH)"
fi

log_success "Assembly tools installation complete"
