#!/usr/bin/env bash
# Rocq/Coq theorem prover installation via Opam
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
fi

log_step "Installing Rocq/Coq via Opam"

# Note: bubblewrap is provided by essentials-box or the Dockerfile.

# --- Opam ---
if ! command_exists opam; then
  log_info "Installing Opam (OCaml package manager)..."

  # Install opam binary to user-writable location
  OPAM_BIN_DIR="$HOME/.local/bin"
  mkdir -p "$OPAM_BIN_DIR"
  export PATH="$OPAM_BIN_DIR:$PATH"
  # The install script asks: 1) path [/usr/local/bin], 2) create dir? [Y/n]
  printf '%s\n%s\n' "$OPAM_BIN_DIR" "Y" | bash -c "sh <(curl -fsSL https://opam.ocaml.org/install.sh) --no-backup" || {
    # Fallback: download opam binary directly
    ARCH="$(uname -m)"
    case "$ARCH" in
      x86_64)  OPAM_ARCH="x86_64" ;;
      aarch64) OPAM_ARCH="arm64" ;;
      *)       OPAM_ARCH="$ARCH" ;;
    esac
    curl -fsSL "https://github.com/ocaml/opam/releases/latest/download/opam-2.3.0-${OPAM_ARCH}-linux" -o "$OPAM_BIN_DIR/opam" && \
      chmod +x "$OPAM_BIN_DIR/opam" || true
  }

  if command_exists opam; then
    log_success "Opam installed successfully"
  fi
else
  log_info "Opam already installed."
fi

# Initialize opam and install Rocq
if command_exists opam; then
  if [ ! -d "$HOME/.opam" ]; then
    log_info "Initializing Opam..."
    opam init --disable-sandboxing --auto-setup -y || true
    log_success "Opam initialized"
  fi

  eval "$(opam env --switch=default 2>/dev/null)" || true

  ROCQ_ACCESSIBLE=false
  if command -v rocq &>/dev/null && rocq -v &>/dev/null; then
    ROCQ_ACCESSIBLE=true
  elif command -v rocqc &>/dev/null; then
    ROCQ_ACCESSIBLE=true
  elif command -v coqc &>/dev/null; then
    ROCQ_ACCESSIBLE=true
  fi

  if [ "$ROCQ_ACCESSIBLE" = false ]; then
    log_info "Installing Rocq Prover (this may take several minutes)..."
    opam repo add rocq-released https://rocq-prover.org/opam/released 2>/dev/null || true
    opam update 2>/dev/null || true

    if opam pin add rocq-prover --yes 2>/dev/null; then
      log_success "Rocq Prover pinned and installed"
    elif opam install rocq-prover -y 2>/dev/null; then
      log_success "Rocq Prover installed via opam install"
    else
      opam install coq -y || true
    fi

    eval "$(opam env --switch=default 2>/dev/null)" || true
  else
    log_info "Rocq Prover already installed."
  fi

  if ! grep -q 'opam env' "$HOME/.bashrc" 2>/dev/null; then
    {
      echo ''
      echo '# Opam (OCaml/Rocq) configuration'
      echo 'test -r $HOME/.opam/opam-init/init.sh && . $HOME/.opam/opam-init/init.sh > /dev/null 2> /dev/null || true'
    } >> "$HOME/.bashrc"
  fi
fi

# Ensure .opam directory exists (required for COPY --from in full-box)
if [ ! -d "$HOME/.opam" ]; then
  log_warning "Opam directory not found - creating minimal structure"
  mkdir -p "$HOME/.opam"
fi

log_success "Rocq/Coq installation complete"
