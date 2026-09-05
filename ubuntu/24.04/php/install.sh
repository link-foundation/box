#!/usr/bin/env bash
# PHP installation: Homebrew (user-specific/local) with apt fallback (global)
# Usage: curl -fsSL <url> | bash  OR  bash install.sh
#
# Strategy (Issue #44, #53):
#   1. Try Homebrew installation (user-specific, under /home/linuxbrew/.linuxbrew)
#      with timeout to prevent 2+ hour source compilations or network hangs
#   2. If Homebrew fails/times out, mark as "global" for apt fallback
#      (apt installation is handled by the Dockerfile as root)
#
# Environment variables:
#   PHP_HOMEBREW_TIMEOUT - Timeout in seconds for Homebrew install (default: 1800 = 30 min)
#   PHP_VERBOSE          - Set to "1" to enable verbose output (default: 0)
#   PHP_BREW_FORMULA     - Homebrew formula to install (default: php = latest stable)
#
# Output:
#   ~/.php-install-method - "local" if Homebrew succeeded, "global" if fallback needed

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
  maybe_sudo() { if [ "$EUID" -eq 0 ]; then "$@"; elif command -v sudo &>/dev/null; then sudo "$@"; else "$@"; fi; }
  apt_update_with_retry() { maybe_sudo apt-get update -y -o Acquire::Retries=3; }
fi

# Timeout for Homebrew PHP installation (default: 30 minutes)
PHP_HOMEBREW_TIMEOUT="${PHP_HOMEBREW_TIMEOUT:-1800}"

# Verbose mode for debugging (Issue #53)
PHP_VERBOSE="${PHP_VERBOSE:-0}"
if [ "$PHP_VERBOSE" = "1" ]; then
  export HOMEBREW_VERBOSE=1
  log_info "Verbose mode enabled"
fi

# The formula is unversioned on purpose (issue #112): homebrew-core's `php`
# always resolves to the current stable PHP, so a rebuilt box follows PHP
# upstream instead of staying on the 8.3 that was current when this was
# written. Pin with PHP_BREW_FORMULA=php@8.3 for a reproducible build.
PHP_BREW_FORMULA="${PHP_BREW_FORMULA:-php}"

log_step "Installing PHP (${PHP_BREW_FORMULA})"
log_info "Timeout: ${PHP_HOMEBREW_TIMEOUT} seconds"
log_info "Architecture: $(uname -m)"
log_info "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# =============================================================================
# Homebrew Installation (Preferred - User-specific/Local)
# Installs to /home/linuxbrew/.linuxbrew (can be COPY'd between Docker images)
# =============================================================================
install_php_homebrew() {
  local start_time=$(date +%s)
  log_info "Attempting PHP installation via Homebrew (user-specific)..."
  log_info "Timeout: ${PHP_HOMEBREW_TIMEOUT} seconds"
  log_info "Start timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  # Ensure Homebrew directory exists
  if [ ! -d /home/linuxbrew/.linuxbrew ]; then
    log_info "Creating Homebrew directory..."
    maybe_sudo mkdir -p /home/linuxbrew/.linuxbrew
    maybe_sudo chown -R "$(whoami)":"$(whoami)" /home/linuxbrew 2>/dev/null || true
  fi

  # Install Homebrew if not present
  if ! command_exists brew; then
    log_info "Installing Homebrew..."
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" 2>&1 || {
      log_warning "Homebrew installation failed"
      return 1
    }

    if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
      eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    elif [[ -x "$HOME/.linuxbrew/bin/brew" ]]; then
      eval "$("$HOME/.linuxbrew/bin/brew" shellenv)"
    fi

    if ! grep -q "brew shellenv" "$HOME/.bashrc" 2>/dev/null; then
      BREW_PREFIX=$(brew --prefix 2>/dev/null || echo "/home/linuxbrew/.linuxbrew")
      echo "eval \"\$($BREW_PREFIX/bin/brew shellenv)\"" >> "$HOME/.bashrc"
    fi
  else
    eval "$(brew shellenv 2>/dev/null)" || true
  fi

  # Install PHP via Homebrew with timeout
  if command_exists brew; then
    if ! brew list --formula 2>/dev/null | grep -E "^php(@[0-9.]+)?$" >/dev/null; then
      log_info "Installing PHP via Homebrew..."

      # Only needed for versioned formulas (php@8.3 and friends); the default
      # unversioned `php` comes from homebrew-core, so a failing tap must not
      # abort the install.
      case "$PHP_BREW_FORMULA" in
        *@*)
          if ! brew tap | grep "shivammathur/php" >/dev/null; then
            brew tap shivammathur/php || {
              log_warning "Failed to tap shivammathur/php"
              return 1
            }
          fi
          ;;
      esac

      {
        export HOMEBREW_NO_ANALYTICS=1
        export HOMEBREW_NO_AUTO_UPDATE=1

        log_info "Installing ${PHP_BREW_FORMULA} (timeout: ${PHP_HOMEBREW_TIMEOUT}s)..."
        log_info "Phase: brew install starting at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

        # Use timeout to prevent 2+ hour source compilations or network hangs (Issue #53)
        # The timeout covers the entire install process including dependency installation
        if timeout --signal=TERM --kill-after=60 "${PHP_HOMEBREW_TIMEOUT}" \
             brew install "$PHP_BREW_FORMULA" 2>&1; then
          log_success "Homebrew PHP install command completed at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        else
          local exit_code=$?
          if [ "$exit_code" -eq 124 ]; then
            log_warning "Homebrew PHP installation TIMED OUT after ${PHP_HOMEBREW_TIMEOUT}s"
            log_warning "This indicates bottles are unavailable and source compilation was attempted"
          else
            log_warning "Homebrew PHP installation failed (exit code: $exit_code)"
          fi
          return 1
        fi

        if brew list --formula 2>/dev/null | grep -E "^php(@[0-9.]+)?$" >/dev/null; then
          log_info "Phase: brew link starting at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
          # Link with timeout to catch potential hangs (Issue #53)
          timeout --signal=TERM --kill-after=30 300 \
            brew link --overwrite --force "$PHP_BREW_FORMULA" 2>&1 | grep -v "Warning" || true
          log_info "Phase: brew link completed at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

          BREW_PREFIX=$(brew --prefix 2>/dev/null || echo "")
          PHP_OPT_DIR="${PHP_BREW_FORMULA##*/}"
          if [[ -n "$BREW_PREFIX" && -d "$BREW_PREFIX/opt/$PHP_OPT_DIR" ]]; then
            export PATH="$BREW_PREFIX/opt/$PHP_OPT_DIR/bin:$BREW_PREFIX/opt/$PHP_OPT_DIR/sbin:$PATH"

            if ! grep -q "opt/${PHP_OPT_DIR}/bin" "$HOME/.bashrc" 2>/dev/null; then
              cat >> "$HOME/.bashrc" << PHP_PATH_EOF

# PHP PATH configuration (Homebrew - user-specific/local)
export PATH="\$(brew --prefix)/opt/${PHP_OPT_DIR}/bin:\$(brew --prefix)/opt/${PHP_OPT_DIR}/sbin:\$PATH"
PHP_PATH_EOF
            fi
          fi

          # Verify PHP works
          log_info "Phase: verification starting at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
          if command_exists php && php --version | grep -E "^PHP [0-9]" >/dev/null; then
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            log_success "$(php --version | head -n1) installed via Homebrew (user-specific/local)"
            log_info "Total Homebrew installation time: ${duration} seconds"
            echo "local" > "$HOME/.php-install-method"
            return 0
          else
            log_warning "PHP installed but version check failed"
            return 1
          fi
        else
          log_warning "${PHP_BREW_FORMULA} not found in Homebrew after install attempt"
          return 1
        fi
      }
    else
      log_info "PHP already installed via Homebrew"
      echo "local" > "$HOME/.php-install-method"
      return 0
    fi
  fi

  return 1
}

# =============================================================================
# APT Installation (Fallback - Global)
# Called when running as root (e.g., from Dockerfile) or with sudo
# Installs to /usr/bin (system-wide, cannot be COPY'd between Docker images)
# =============================================================================
install_php_apt() {
  log_info "Installing PHP via apt packages (global fallback)..."

  apt_update_with_retry || {
    log_warning "apt update failed"
  }

  # Unversioned metapackages track whatever PHP the distro currently ships,
  # so this fallback does not need editing every Ubuntu release (issue #112).
  local apt_packages=(
    php-cli
    php-common
    php-curl
    php-mbstring
    php-xml
    php-zip
    php-bcmath
    php-opcache
  )

  if maybe_sudo apt-get install -y "${apt_packages[@]}" 2>/dev/null; then
    if command_exists php && php --version | grep -E "^PHP [0-9]" >/dev/null; then
      log_success "$(php --version | head -n1) installed via apt (global)"

      if ! grep -q "# PHP configuration" "$HOME/.bashrc" 2>/dev/null; then
        cat >> "$HOME/.bashrc" << 'PHP_BASHRC_EOF'

# PHP configuration (installed via apt - global)
alias php-version='php --version'
PHP_BASHRC_EOF
      fi

      echo "global" > "$HOME/.php-install-method"
      return 0
    fi
  fi

  log_error "apt installation failed"
  return 1
}

# =============================================================================
# Main Installation Logic
# =============================================================================

# Check if PHP is already installed
if command_exists php && php --version 2>/dev/null | grep -E "^PHP [0-9]" >/dev/null; then
  PHP_VERSION=$(php --version 2>/dev/null | head -n 1)
  log_success "PHP already installed: $PHP_VERSION"
  if [ -f "$HOME/.php-install-method" ]; then
    : # already set
  elif command_exists brew && brew list --formula 2>/dev/null | grep -E "^php(@[0-9.]+)?$" >/dev/null; then
    echo "local" > "$HOME/.php-install-method"
  else
    echo "global" > "$HOME/.php-install-method"
  fi
  exit 0
fi

# Try Homebrew first (user-specific/local)
if install_php_homebrew; then
  log_success "PHP installation complete via Homebrew (local/user-specific)"
  exit 0
fi

# Homebrew failed - try apt if we have root or sudo
if [ "$EUID" -eq 0 ] || sudo -n true 2>/dev/null; then
  if install_php_apt; then
    log_success "PHP installation complete via apt (global fallback)"
    exit 0
  fi
fi

# If we can't install via apt either (no root/sudo), just mark as global
# The Dockerfile will handle the apt installation as root
log_warning "Homebrew PHP failed, marking for apt fallback (will be handled by Dockerfile)"
echo "global" > "$HOME/.php-install-method"

# Add a placeholder bashrc entry
if ! grep -q "# PHP configuration" "$HOME/.bashrc" 2>/dev/null; then
  cat >> "$HOME/.bashrc" << 'PHP_BASHRC_EOF'

# PHP configuration (installed via apt - global)
alias php-version='php --version'
PHP_BASHRC_EOF
fi

log_info "PHP marked as 'global' - apt installation deferred to Dockerfile"
