#!/usr/bin/env bash
# Kotlin installation via SDKMAN
# Usage: curl -fsSL <url> | bash  OR  bash install.sh
# Kotlin requires a JVM at runtime (kotlinc is a shell wrapper around `java`),
# so this script also installs the current Java LTS via SDKMAN if it is not
# already present. The standalone box-kotlin image must be runnable on its own.

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

# Same build-time LTS resolution as the java box (see ../common.sh).
if ! command -v resolve_java_lts_major >/dev/null 2>&1; then
  resolve_java_lts_major() { echo "${JAVA_VERSION:-25}"; }
fi
JAVA_MAJOR="$(resolve_java_lts_major)"

log_step "Installing Kotlin via SDKMAN"

# Ensure SDKMAN is installed
if [ ! -d "$HOME/.sdkman" ]; then
  log_info "SDKMAN not found, installing..."
  curl -s "https://get.sdkman.io?rcupdate=false&ci=true" | bash
  if ! grep -q 'sdkman-init.sh' "$HOME/.bashrc" 2>/dev/null; then
    {
      echo ''
      echo '# SDKMAN configuration'
      echo 'export SDKMAN_DIR="$HOME/.sdkman"'
      echo '[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ] && . "$HOME/.sdkman/bin/sdkman-init.sh"'
    } >> "$HOME/.bashrc"
  fi
fi

export SDKMAN_DIR="$HOME/.sdkman"
if [ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
  set +u
  source "$SDKMAN_DIR/bin/sdkman-init.sh"
  set -u

  # Kotlin runtime needs Java; install it first if missing.
  if ! command_exists java; then
    log_info "Installing Java ${JAVA_MAJOR} LTS (Temurin) via SDKMAN (required by Kotlin)..."
    set +u
    sdk install java "${JAVA_MAJOR}-tem" < /dev/null || {
      log_warning "Eclipse Temurin installation failed, trying default OpenJDK..."
      sdk install java "${JAVA_MAJOR}-open" < /dev/null || true
    }
    set -u

    if command -v java &>/dev/null; then
      log_success "Java installed: $(java -version 2>&1 | head -n1)"
    else
      log_warning "Java installation did not produce a usable java binary."
    fi
  else
    log_info "Java already installed."
  fi

  if ! command_exists kotlin; then
    log_info "Installing Kotlin via SDKMAN..."
    set +u
    sdk install kotlin < /dev/null || true
    set -u

    if command -v kotlin &>/dev/null; then
      log_success "Kotlin installed: $(kotlin -version 2>&1 | head -n1)"
    fi
  else
    log_info "Kotlin already installed."
  fi
fi

# Build-time invariant: one version per SDKMAN candidate (issue #112).
if command -v assert_single_runtime_versions >/dev/null 2>&1; then
  assert_single_runtime_versions
fi

log_success "Kotlin installation complete"
