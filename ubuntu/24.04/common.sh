#!/usr/bin/env bash
# Common functions and utilities shared across all box install scripts
# Source this file at the top of each install.sh:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/../common.sh"

set -euo pipefail

# Color codes for enhanced output (disabled in non-TTY)
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  CYAN=''
  NC=''
fi

# Enhanced logging functions
log_info() { echo -e "${BLUE}[*]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_note() { echo -e "${CYAN}[i]${NC} $1"; }
log_step() { echo -e "\n${GREEN}==>${NC} ${BLUE}$1${NC}\n"; }

# Verification helper
verify_command() {
  local tool_name="$1"
  local command_name="${2:-$1}"
  local version_flag="${3:---version}"

  if command -v "$command_name" &>/dev/null; then
    local version=$("$command_name" $version_flag 2>/dev/null | head -n1 || echo "installed")
    log_success "$tool_name: $version"
    return 0
  else
    log_warning "$tool_name: not found in PATH"
    return 1
  fi
}

# Check if a command exists (silent)
command_exists() {
  command -v "$1" &>/dev/null
}

# Run command with sudo only if not root and sudo is available
maybe_sudo() {
  if [ "$EUID" -eq 0 ]; then
    "$@"
  elif command_exists sudo; then
    sudo "$@"
  else
    "$@"
  fi
}

# Safe apt update
apt_update_safe() {
  log_info "Updating apt sources..."
  for f in /etc/apt/sources.list.d/*.list; do
    if [ -f "$f" ] && ! grep -Eq "^deb " "$f"; then
      log_warning "Removing malformed apt source: $f"
      maybe_sudo rm -f "$f"
    fi
  done
  maybe_sudo apt update -y || true
}

# Cleanup apt cache
apt_cleanup() {
  log_info "Cleaning up apt cache and temporary files..."
  maybe_sudo apt-get clean
  maybe_sudo apt-get autoclean
  maybe_sudo apt-get autoremove -y
  maybe_sudo rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
  log_success "Cleanup completed"
}

# Cleanup duplicate APT sources
cleanup_duplicate_apt_sources() {
  log_info "Checking for duplicate APT sources..."
  local duplicates_found=false

  if [ -f /etc/apt/sources.list.d/microsoft-edge.list ] && \
     [ -f /etc/apt/sources.list.d/microsoft-edge-stable.list ]; then
    log_info "Found duplicate Microsoft Edge APT sources"
    maybe_sudo rm -f /etc/apt/sources.list.d/microsoft-edge.list
    duplicates_found=true
  fi

  if [ -f /etc/apt/sources.list.d/google-chrome.list ] && \
     [ -f /etc/apt/sources.list.d/google-chrome-stable.list ]; then
    log_info "Found duplicate Google Chrome APT sources"
    maybe_sudo rm -f /etc/apt/sources.list.d/google-chrome-stable.list
    duplicates_found=true
  fi

  if [ "$duplicates_found" = true ]; then
    log_success "Duplicate APT sources cleaned up"
  else
    log_success "No duplicate APT sources found"
  fi
}

# Create box user if missing
ensure_box_user() {
  if id "box" &>/dev/null; then
    log_info "box user already exists."
  else
    log_info "Creating box user..."
    groupadd box 2>/dev/null || true
    useradd -m -g box -d /home/box -s /bin/bash box 2>/dev/null || {
      log_warning "User creation with useradd failed, trying adduser..."
      adduser --disabled-password --gecos "" --home /home/box box
    }
    passwd -d box 2>/dev/null || log_note "Could not remove password requirement"
    usermod -aG sudo box 2>/dev/null || log_note "Could not add to sudo group"
    chmod 2775 /home/box 2>/dev/null || true
    log_success "box user created and configured"
  fi
}

# Detect Docker environment
is_docker_build() {
  if [ "${DOCKER_BUILD:-}" = "1" ]; then
    return 0
  elif [ -f /.dockerenv ]; then
    return 0
  elif grep -qE 'docker|buildkit|containerd' /proc/1/cgroup 2>/dev/null; then
    return 0
  fi
  return 1
}
