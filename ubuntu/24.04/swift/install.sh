#!/usr/bin/env bash
# Swift installation
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
  log_error() { echo "[✗] $1"; }
  log_step() { echo "==> $1"; }
  command_exists() { command -v "$1" &>/dev/null; }
fi

log_step "Installing Swift"

if ! command_exists swift; then
  log_info "Installing Swift..."

  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)
      SWIFT_DIR="ubuntu2404"
      SWIFT_FILE_SUFFIX="ubuntu24.04"
      ;;
    aarch64)
      SWIFT_DIR="ubuntu2404-aarch64"
      SWIFT_FILE_SUFFIX="ubuntu24.04-aarch64"
      ;;
    *)
      SWIFT_DIR=""
      SWIFT_FILE_SUFFIX=""
      ;;
  esac

  if [ -n "$SWIFT_DIR" ]; then
    # swift.org's release feed is walked newest-first and each candidate's
    # tarball is probed, because not every release publishes a build for every
    # Ubuntu/arch combination. A hardcoded version (6.0.3) silently ages —
    # issue #112. Pin with SWIFT_VERSION for a reproducible build.
    if ! command -v resolve_swift_versions >/dev/null 2>&1; then
      resolve_swift_versions() { echo "${SWIFT_VERSION:-6.3.3}"; }
    fi
    if ! command -v remote_file_exists >/dev/null 2>&1; then
      # -L matters: download.swift.org redirects a missing tarball to
      # swift.org/404.html, and curl treats the 302 itself as success.
      remote_file_exists() { curl -fsSIL --max-time 30 "$1" >/dev/null 2>&1; }
    fi

    SWIFT_RELEASE="RELEASE"
    # Resolve before clearing SWIFT_VERSION: the resolver reads it as the pin.
    SWIFT_CANDIDATES="$(resolve_swift_versions)"
    SWIFT_VERSION=""
    SWIFT_URL=""
    for candidate in $SWIFT_CANDIDATES; do
      candidate_package="swift-${candidate}-${SWIFT_RELEASE}-${SWIFT_FILE_SUFFIX}"
      candidate_url="https://download.swift.org/swift-${candidate}-release/${SWIFT_DIR}/swift-${candidate}-${SWIFT_RELEASE}/${candidate_package}.tar.gz"
      if remote_file_exists "$candidate_url"; then
        SWIFT_VERSION="$candidate"
        SWIFT_PACKAGE="$candidate_package"
        SWIFT_URL="$candidate_url"
        break
      fi
      log_info "No Swift $candidate build for ${SWIFT_FILE_SUFFIX}, trying the previous release..."
    done

    if [ -z "$SWIFT_URL" ]; then
      log_error "No Swift release with a ${SWIFT_FILE_SUFFIX} toolchain was found"
      exit 1
    fi

    log_info "Downloading Swift $SWIFT_VERSION for $ARCH..."
    TEMP_DIR=$(mktemp -d)

    if curl -fsSL "$SWIFT_URL" -o "$TEMP_DIR/swift.tar.gz"; then
      log_info "Installing Swift to $HOME/.swift..."
      mkdir -p "$HOME/.swift"
      tar -xzf "$TEMP_DIR/swift.tar.gz" -C "$TEMP_DIR"
      cp -r "$TEMP_DIR/${SWIFT_PACKAGE}/usr" "$HOME/.swift/"
      rm -rf "$TEMP_DIR"

      if ! grep -q 'swift' "$HOME/.bashrc" 2>/dev/null; then
        {
          echo ''
          echo '# Swift configuration'
          echo 'export PATH="$HOME/.swift/usr/bin:$PATH"'
        } >> "$HOME/.bashrc"
      fi

      export PATH="$HOME/.swift/usr/bin:$PATH"

      if command -v swift &>/dev/null; then
        log_success "Swift installed: $(swift --version | head -n1)"
      fi
    else
      log_error "Failed to download Swift from $SWIFT_URL"
      rm -rf "$TEMP_DIR"
    fi
  else
    log_warning "Swift installation skipped: unsupported architecture $ARCH"
  fi
else
  log_info "Swift already installed."
fi

log_success "Swift installation complete"
