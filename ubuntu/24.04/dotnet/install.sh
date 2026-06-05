#!/usr/bin/env bash
# .NET SDK 8.0 installation
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

log_step "Installing .NET SDK 8.0"

if ! command_exists dotnet; then
  log_info "Installing .NET SDK 8.0..."
  apt_update_with_retry
  maybe_sudo apt install -y dotnet-sdk-8.0
  log_success ".NET SDK 8.0 installed"
else
  log_info ".NET SDK already installed."
fi

log_success ".NET installation complete"
