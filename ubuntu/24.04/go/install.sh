#!/usr/bin/env bash
# Go (Golang) installation
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

log_step "Installing Go"

if [ ! -d "$HOME/.go" ] && [ ! -d "/usr/local/go" ]; then
  log_info "Installing Golang..."

  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) GO_ARCH="amd64" ;;
    aarch64) GO_ARCH="arm64" ;;
    armv7l) GO_ARCH="armv6l" ;;
    *) GO_ARCH="" ;;
  esac

  if [ -n "$GO_ARCH" ]; then
    GO_VERSION=$(curl -sL 'https://go.dev/VERSION?m=text' | head -n1)

    if [ -n "$GO_VERSION" ]; then
      GO_TARBALL="${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
      GO_URL="https://go.dev/dl/${GO_TARBALL}"

      log_info "Downloading Go $GO_VERSION for $GO_ARCH..."
      TEMP_DIR=$(mktemp -d)
      curl -sL "$GO_URL" -o "$TEMP_DIR/$GO_TARBALL"

      log_info "Installing Go to $HOME/.go..."
      mkdir -p "$HOME/.go"
      tar -xzf "$TEMP_DIR/$GO_TARBALL" -C "$HOME/.go" --strip-components=1
      rm -rf "$TEMP_DIR"

      if ! grep -q 'GOROOT.*\.go' "$HOME/.bashrc" 2>/dev/null; then
        {
          echo ''
          echo '# Go configuration'
          echo 'export GOROOT="$HOME/.go"'
          echo 'export GOPATH="$HOME/.go/path"'
          echo 'export PATH="$GOROOT/bin:$GOPATH/bin:$PATH"'
        } >>"$HOME/.bashrc"
      fi

      export GOROOT="$HOME/.go"
      export GOPATH="$HOME/.go/path"
      export PATH="$GOROOT/bin:$GOPATH/bin:$PATH"
      mkdir -p "$GOPATH"

      if command -v go &>/dev/null; then
        log_success "Golang installed: $(go version)"
      fi
    fi
  fi
else
  log_info "Golang already installed."
fi

log_success "Go installation complete"
