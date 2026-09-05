#!/usr/bin/env bash
# full-box: adopt the Rust toolchain from the rust image and refresh it, inside
# a single image layer (issue #112).
#
# Why this is not just a COPY --from=rust-stage:
#   ~/.rustup is whatever the rust image was built with. Release CI falls back
#   to konard/box-rust:latest whenever the rust matrix did not rebuild, so the
#   full image regularly shipped a months-old `stable`. Running `rustup update`
#   after a COPY does not fix it either — the stale toolchain is already
#   committed in the copied layer and deleting it later only writes a whiteout,
#   so the image would carry both toolchains (the 2.2 GB ~/.rustup in the
#   issue). Binding the stage and copying inside this RUN keeps the copy, the
#   update and the prune in the same layer, so only the refreshed toolchain is
#   ever committed.
#
# Runs twice by design: as root to copy and chown, then re-executed as the box
# user (rustup must not write root-owned files into the box home).
set -euo pipefail

STAGE_HOME="${STAGE_HOME:-/mnt/rust-home}"
BOX_USER="${BOX_USER:-box}"
BOX_HOME="${BOX_HOME:-/home/box}"

if [ -f /tmp/common.sh ]; then
  # shellcheck disable=SC1091
  . /tmp/common.sh
else
  set -euo pipefail
  log_info() { echo "[*] $1"; }
  log_success() { echo "[✓] $1"; }
  log_warning() { echo "[!] $1"; }
  log_error() { echo "[✗] $1"; }
  log_step() { echo "==> $1"; }
fi

export CARGO_HOME="$BOX_HOME/.cargo"
export RUSTUP_HOME="$BOX_HOME/.rustup"
export PATH="$CARGO_HOME/bin:$PATH"

if [ "$(id -u)" -eq 0 ]; then
  log_step "Adopting Rust toolchain from the rust image"

  if [ ! -d "$STAGE_HOME/.cargo" ] || [ ! -d "$STAGE_HOME/.rustup" ]; then
    log_error "rust stage has no .cargo/.rustup under $STAGE_HOME"
    exit 1
  fi

  rm -rf "$BOX_HOME/.cargo" "$BOX_HOME/.rustup"
  cp -a "$STAGE_HOME/.cargo" "$BOX_HOME/.cargo"
  cp -a "$STAGE_HOME/.rustup" "$BOX_HOME/.rustup"
  chown -R "$BOX_USER:$BOX_USER" "$BOX_HOME/.cargo" "$BOX_HOME/.rustup"
  log_success "Copied .cargo and .rustup from the rust image"

  if command -v runuser >/dev/null 2>&1; then
    exec runuser -u "$BOX_USER" -- bash "$0"
  else
    exec su "$BOX_USER" -c "bash $0"
  fi
fi

# --- Below here we are the box user ---

log_step "Refreshing the Rust stable toolchain"
log_info "As copied from the rust image: $(rustc --version 2>/dev/null || echo 'unknown')"

rustup update stable
rustup default stable

# One toolchain per image (issue #112).
RUST_KEEP="$(rustup show active-toolchain 2>/dev/null | awk '{print $1}')"
for toolchain in $(rustup toolchain list 2>/dev/null | awk '{print $1}'); do
  if [ -n "$RUST_KEEP" ] && [ "$toolchain" != "$RUST_KEEP" ]; then
    log_info "Removing extra Rust toolchain $toolchain (keeping $RUST_KEEP)"
    rustup toolchain uninstall "$toolchain" || log_warning "Could not uninstall $toolchain"
  fi
done

log_success "Rust in this image: $(rustc --version), $(cargo --version)"

if command -v assert_single_runtime_versions >/dev/null 2>&1; then
  BOX_HOME="$BOX_HOME" assert_single_runtime_versions
fi
