#!/usr/bin/env bash
# Rust installation via rustup
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
fi

log_step "Installing Rust"

if [ ! -d "$HOME/.cargo" ]; then
  log_info "Installing Rust..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  if [ -f "$HOME/.cargo/env" ]; then
    \. "$HOME/.cargo/env"
    log_success "Rust installed successfully"
  fi
else
  log_info "Rust already installed."
fi

[ -f "$HOME/.cargo/env" ] && \. "$HOME/.cargo/env"

# `stable` is a moving target, and this script also runs on top of an existing
# ~/.rustup that was built weeks or months earlier (the image is rebuilt far
# more often than the rust layer). Refreshing unconditionally is what keeps a
# rebuilt box on the current stable instead of the snapshot the layer was
# created with — issue #112.
if command_exists rustup; then
  log_info "Refreshing rustup and the stable toolchain..."
  rustup self update || log_warning "rustup self-update unavailable (managed installation)"
  rustup update stable
  rustup default stable

  # One toolchain per image (issue #112): an extra toolchain is ~1.5 GB of
  # bytes nobody asked for, and it makes `cargo` behaviour depend on which
  # toolchain a directory happens to select.
  RUST_KEEP="$(rustup show active-toolchain 2>/dev/null | awk '{print $1}')"
  for toolchain in $(rustup toolchain list 2>/dev/null | awk '{print $1}'); do
    if [ -n "$RUST_KEEP" ] && [ "$toolchain" != "$RUST_KEEP" ]; then
      log_info "Removing extra Rust toolchain $toolchain (keeping $RUST_KEEP)"
      rustup toolchain uninstall "$toolchain" || log_warning "Could not uninstall $toolchain"
    fi
  done

  log_success "Rust toolchain: $(rustc --version 2>/dev/null || echo unknown)"
fi

# Build-time invariant: exactly one toolchain under ~/.rustup/toolchains.
if command -v assert_single_runtime_versions >/dev/null 2>&1; then
  assert_single_runtime_versions
fi

log_success "Rust installation complete"
