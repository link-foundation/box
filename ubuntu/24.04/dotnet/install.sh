#!/usr/bin/env bash
# .NET SDK installation (newest LTS channel available in the archive)
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

log_step "Installing the .NET SDK"

if ! command_exists dotnet; then
  apt_update_with_retry
  # Which channel is installed is decided at build time: the newest active LTS
  # (from Microsoft's releases index) that this Ubuntu archive can actually
  # install. Hardcoding 8.0 kept the box a full LTS behind — issue #112.
  # Override with DOTNET_CHANNEL.
  if command -v resolve_dotnet_apt_channel >/dev/null 2>&1; then
    DOTNET_SDK_CHANNEL="$(resolve_dotnet_apt_channel)"
  else
    DOTNET_SDK_CHANNEL="${DOTNET_CHANNEL:-10.0}"
  fi
  log_info "Installing .NET SDK ${DOTNET_SDK_CHANNEL}..."
  maybe_sudo apt install -y "dotnet-sdk-${DOTNET_SDK_CHANNEL}"
  log_success ".NET SDK ${DOTNET_SDK_CHANNEL} installed"
else
  log_info ".NET SDK already installed."
fi

if command_exists dotnet; then
  log_success ".NET SDK: $(dotnet --version 2>/dev/null || echo installed)"
fi

log_success ".NET installation complete"
