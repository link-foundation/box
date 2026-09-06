#!/usr/bin/env bash
# Lean theorem prover installation via elan
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

log_step "Installing Lean via elan"

# Which toolchain to bake in. `stable` is elan's own alias for the current Lean
# release, so the box follows upstream (issue #112); pin LEAN_VERSION for a
# reproducible build.
LEAN_TOOLCHAIN="${LEAN_VERSION:-stable}"

if [ ! -d "$HOME/.elan" ]; then
  log_info "Installing Lean (via elan)..."
  curl https://elan.lean-lang.org/elan-init.sh -sSf | sh -s -- -y --default-toolchain "$LEAN_TOOLCHAIN"
  if [ -f "$HOME/.elan/env" ]; then
    \. "$HOME/.elan/env"
  fi
  if ! grep -q 'elan' "$HOME/.bashrc" 2>/dev/null; then
    {
      echo ''
      echo '# Lean (elan) configuration'
      echo 'export PATH="$HOME/.elan/bin:$PATH"'
    } >>"$HOME/.bashrc"
  fi
else
  log_info "Lean (elan) already installed."
fi

export PATH="$HOME/.elan/bin:$PATH"

# elan-init records the default toolchain and exits 0 WITHOUT installing it:
#
#   $ curl .../elan-init.sh -sSf | sh -s -- -y --default-toolchain stable
#   info: default toolchain set to 'stable'
#   $ elan toolchain list
#   no installed toolchains
#
# Every box built before this line shipped elan and no Lean, and `lean
# --version` "worked" only because the shim downloaded 200 MB on first use -
# in CI that looked like a pass, and for a user offline or behind a proxy it is
# a broken image (issue #115; reproduced by
# experiments/test-issue115-elan-toolchain.sh).
log_info "Installing Lean toolchain '$LEAN_TOOLCHAIN'..."
elan toolchain install "$LEAN_TOOLCHAIN"

# One toolchain per language root (issue #112), and it has to be here now, not
# downloaded on first use.
INSTALLED_TOOLCHAINS="$(elan toolchain list 2>/dev/null | grep -cv 'no installed toolchains' || true)"
if [ "${INSTALLED_TOOLCHAINS:-0}" -lt 1 ]; then
  log_error "elan installed no Lean toolchain; the image would download one on first use"
  exit 1
fi

# Default to the *resolved* toolchain (leanprover/lean4:v4.33.1), not to the
# alias that was asked for. `stable` is resolved over the network on every
# invocation, so a box whose default is an alias prints
#
#   warning: failed to query latest release, using existing version '...'
#
# on every `lean` run without connectivity. Resolving here is also what issue
# #112 asks of every runtime: the version is decided at build time.
RESOLVED_TOOLCHAIN="$(elan toolchain list 2>/dev/null | head -n1 | awk '{print $1}')"
elan default "$RESOLVED_TOOLCHAIN"

log_success "Lean installation complete: $(lean --version)"
