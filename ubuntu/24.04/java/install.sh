#!/usr/bin/env bash
# Java installation via SDKMAN (Eclipse Temurin, newest LTS)
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

# The Java LTS in use is resolved at build time from SDKMAN's own vendor list
# (see ../common.sh) so a rebuild follows the LTS train — 21 today, 25 now, 29
# later — instead of freezing on whatever was current when this was written.
# Override with JAVA_VERSION for a pinned build.
if ! command -v resolve_java_lts_major >/dev/null 2>&1; then
  resolve_java_lts_major() { echo "${JAVA_VERSION:-25}"; }
fi
JAVA_MAJOR="$(resolve_java_lts_major)"

log_step "Installing Java ${JAVA_MAJOR} LTS via SDKMAN"

# --- SDKMAN ---
if [ ! -d "$HOME/.sdkman" ]; then
  log_info "Installing SDKMAN (Java version manager)..."
  curl -s "https://get.sdkman.io?rcupdate=false&ci=true" | bash
  if ! grep -q 'sdkman-init.sh' "$HOME/.bashrc" 2>/dev/null; then
    {
      echo ''
      echo '# SDKMAN configuration'
      echo 'export SDKMAN_DIR="$HOME/.sdkman"'
      echo '[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ] && . "$HOME/.sdkman/bin/sdkman-init.sh"'
    } >>"$HOME/.bashrc"
  fi
  log_success "SDKMAN installed and configured"
else
  log_info "SDKMAN already installed."
fi

# Load SDKMAN and install Java
export SDKMAN_DIR="$HOME/.sdkman"
if [ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
  set +u
  source "$SDKMAN_DIR/bin/sdkman-init.sh"
  set -u
  log_success "SDKMAN loaded for current session"

  log_info "Installing Java ${JAVA_MAJOR} LTS (OpenJDK via Eclipse Temurin)..."
  set +u
  if ! sdk list java 2>/dev/null | grep "${JAVA_MAJOR}.*tem.*installed" >/dev/null; then
    sdk install java "${JAVA_MAJOR}-tem" </dev/null || {
      log_warning "Eclipse Temurin installation failed, trying default OpenJDK..."
      sdk install java "${JAVA_MAJOR}-open" </dev/null || true
    }
  else
    log_info "Java ${JAVA_MAJOR} (Temurin) already installed."
  fi

  # One JVM per image (issue #112): make the resolved LTS the default, then
  # drop any other JDK an earlier build of this layer may have left behind.
  # list_installed_versions (../common.sh) walks the directory with a glob and
  # skips SDKMAN's own "current" symlink, so a candidate name is never split on
  # whitespace and the alias is never mistaken for an installed JDK.
  while IFS= read -r installed; do
    case "$installed" in
      "${JAVA_MAJOR}"*) sdk default java "$installed" </dev/null || true ;;
    esac
  done < <(list_installed_versions "$SDKMAN_DIR/candidates/java")
  while IFS= read -r installed; do
    case "$installed" in
      "${JAVA_MAJOR}"*) ;;
      *)
        log_info "Removing extra JDK $installed (keeping ${JAVA_MAJOR})"
        sdk uninstall java "$installed" </dev/null || log_warning "Could not uninstall JDK $installed"
        ;;
    esac
  done < <(list_installed_versions "$SDKMAN_DIR/candidates/java")
  set -u

  if command -v java &>/dev/null; then
    log_success "Java version manager setup complete"
    java -version 2>&1 | head -n1
  fi
fi

# Build-time invariant: exactly one JDK under ~/.sdkman/candidates/java.
if command -v assert_single_runtime_versions >/dev/null 2>&1; then
  assert_single_runtime_versions
fi

log_success "Java installation complete"
