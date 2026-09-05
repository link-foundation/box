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

# Retry apt metadata refreshes. Ubuntu mirrors can briefly serve mismatched
# Release and Packages files while syncing, which exits as apt code 100.
apt_update_with_retry() {
  local max_retries="${APT_UPDATE_MAX_RETRIES:-5}"
  local initial_delay="${APT_UPDATE_INITIAL_DELAY:-5}"
  local attempt=1
  local delay="$initial_delay"

  while [ "$attempt" -le "$max_retries" ]; do
    log_info "Updating apt sources (attempt ${attempt}/${max_retries})..."
    if maybe_sudo apt-get update -y \
      -o Acquire::Retries=3 \
      -o Acquire::http::Timeout=30 \
      -o Acquire::https::Timeout=30; then
      log_success "Apt sources updated"
      return 0
    fi

    if [ "$attempt" -eq "$max_retries" ]; then
      log_error "Apt update failed after ${max_retries} attempts"
      return 1
    fi

    log_warning "Apt update failed; clearing apt list state and retrying in ${delay}s"
    maybe_sudo rm -rf /var/lib/apt/lists/partial /var/lib/apt/lists/*
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
}

# Safe apt update
apt_update_safe() {
  for f in /etc/apt/sources.list.d/*.list; do
    if [ -f "$f" ] && ! grep -Eq "^deb " "$f"; then
      log_warning "Removing malformed apt source: $f"
      maybe_sudo rm -f "$f"
    fi
  done
  apt_update_with_retry || true
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

# =============================================================================
# Build-time version policy (issue #112)
# =============================================================================
# Runtimes that are not installed through a version manager's own "latest"
# selector resolve their version here, at build time, in three layers:
#
#   1. explicit override   — a <RUNTIME>_VERSION / <RUNTIME>_CHANNEL variable,
#      settable per build (docker build --build-arg / docker run -e), used to
#      reproduce an older image or to pin a hotfix;
#   2. upstream resolution — the canonical release feed of that runtime, so a
#      rebuild picks up a new LTS without a commit to this repository;
#   3. pinned fallback     — used only when the feed is unreachable, so a
#      network blip degrades the build to "slightly behind" instead of failing
#      it outright.
#
# The *_FALLBACK values are a floor, never the intended version: they are what
# the resolvers returned when they were last refreshed.

VERSION_FETCH_TIMEOUT="${VERSION_FETCH_TIMEOUT:-20}"

NODE_LTS_FALLBACK="${NODE_LTS_FALLBACK:-24}"
NVM_VERSION_FALLBACK="${NVM_VERSION_FALLBACK:-v0.40.7}"
JAVA_LTS_FALLBACK="${JAVA_LTS_FALLBACK:-25}"
DOTNET_CHANNEL_FALLBACK="${DOTNET_CHANNEL_FALLBACK:-10.0}"
SWIFT_VERSION_FALLBACK="${SWIFT_VERSION_FALLBACK:-6.3.3}"
OPAM_VERSION_FALLBACK="${OPAM_VERSION_FALLBACK:-2.5.2}"

# Fetch a release feed. Never fatal: callers fall back to a pinned version.
fetch_release_feed() {
  curl -fsSL --max-time "${VERSION_FETCH_TIMEOUT}" --retry 2 --retry-delay 1 "$1" 2>/dev/null
}

# Latest release tag of a GitHub repository, read from the /releases/latest
# redirect instead of api.github.com: the HTML endpoint is not subject to the
# unauthenticated API rate limit that CI runners routinely exhaust.
github_latest_tag() {
  local effective_url
  effective_url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
    --max-time "${VERSION_FETCH_TIMEOUT}" --retry 2 --retry-delay 1 \
    "https://github.com/$1/releases/latest" 2>/dev/null) || return 1
  case "$effective_url" in
    */releases/tag/*) echo "${effective_url##*/}" ;;
    *) return 1 ;;
  esac
}

# Newest Node.js LTS major, e.g. "24".
# Feed: https://nodejs.org/dist/index.json — newest first, LTS entries carry a
# codename ("lts":"Krypton"), non-LTS entries carry "lts":false.
resolve_node_lts_major() {
  local major=""
  if [ -n "${NODE_VERSION:-}" ]; then
    echo "${NODE_VERSION%%.*}"
    return 0
  fi
  major=$(fetch_release_feed "https://nodejs.org/dist/index.json" \
    | tr '{' '\n' | grep '"lts":"' | head -n1 \
    | sed -n 's/.*"version":"v\([0-9][0-9]*\)\..*/\1/p') || true
  if [[ "$major" =~ ^[0-9]+$ ]]; then
    echo "$major"
  else
    echo "$NODE_LTS_FALLBACK"
  fi
}

# Newest nvm installer tag, e.g. "v0.40.7".
resolve_nvm_version() {
  local tag=""
  if [ -n "${NVM_VERSION:-}" ]; then
    echo "$NVM_VERSION"
    return 0
  fi
  tag=$(github_latest_tag "nvm-sh/nvm") || true
  if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$tag"
  else
    echo "$NVM_VERSION_FALLBACK"
  fi
}

# Is this Java feature release an LTS? 8, 11, 17, then every 4th from 21.
is_java_lts_major() {
  local major="$1"
  case "$major" in
    8|11|17) return 0 ;;
    *) [[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -ge 21 ] && [ $(( (major - 21) % 4 )) -eq 0 ] ;;
  esac
}

# Newest Temurin LTS major offered by SDKMAN, e.g. "25". The vendor list also
# advertises non-LTS features (26 at the time of writing), which must not be
# picked up by a rebuild.
resolve_java_lts_major() {
  local candidate best=""
  if [ -n "${JAVA_VERSION:-}" ]; then
    echo "${JAVA_VERSION%%.*}"
    return 0
  fi
  for candidate in $(fetch_release_feed \
      "https://api.sdkman.io/2/candidates/java/linuxx64/versions/list?current=&installed=" \
      | grep -oE '[0-9]+(\.[0-9]+)*(\+[0-9.]+)?-tem' \
      | sed 's/[.+].*//; s/-tem//' | sort -un); do
    if is_java_lts_major "$candidate"; then
      best="$candidate"
    fi
  done
  if [[ "$best" =~ ^[0-9]+$ ]]; then
    echo "$best"
  else
    echo "$JAVA_LTS_FALLBACK"
  fi
}

# Newest actively supported .NET LTS channel, e.g. "10.0".
resolve_dotnet_lts_channel() {
  local channel=""
  if [ -n "${DOTNET_CHANNEL:-}" ]; then
    echo "$DOTNET_CHANNEL"
    return 0
  fi
  channel=$(fetch_release_feed \
    "https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/releases-index.json" \
    | awk '
      /"channel-version"/ { c=$0; sub(/.*"channel-version"[ ]*:[ ]*"/,"",c); sub(/".*/,"",c); p=""; t="" }
      /"support-phase"/   { p=$0; sub(/.*"support-phase"[ ]*:[ ]*"/,"",p);   sub(/".*/,"",p) }
      /"release-type"/    { t=$0; sub(/.*"release-type"[ ]*:[ ]*"/,"",t);    sub(/".*/,"",t) }
      (c != "" && p == "active" && t == "lts") { print c; c="" }
    ' | sort -V | tail -n1) || true
  if [[ "$channel" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "$channel"
  else
    echo "$DOTNET_CHANNEL_FALLBACK"
  fi
}

# Newest Swift release tag, e.g. "6.3.3". Callers must still verify that a
# tarball exists for the image's Ubuntu release: Swift does not publish a build
# for every Ubuntu version (26.04 has none as of this change), so the download
# step walks this list backwards until a URL responds.
resolve_swift_versions() {
  local versions=""
  if [ -n "${SWIFT_VERSION:-}" ]; then
    echo "$SWIFT_VERSION"
    return 0
  fi
  versions=$(fetch_release_feed "https://www.swift.org/api/v1/install/releases.json" \
    | grep -oE '"tag"[ ]*:[ ]*"swift-[0-9][0-9.]*-RELEASE"' \
    | sed -n 's/.*swift-\([0-9][0-9.]*\)-RELEASE.*/\1/p' \
    | sort -V | tail -n5 | tac) || true
  if [ -n "$versions" ]; then
    echo "$versions"
  else
    echo "$SWIFT_VERSION_FALLBACK"
  fi
}

# Newest opam release, e.g. "2.5.2".
resolve_opam_version() {
  local tag=""
  if [ -n "${OPAM_VERSION:-}" ]; then
    echo "$OPAM_VERSION"
    return 0
  fi
  tag=$(github_latest_tag "ocaml/opam") || true
  tag="${tag#v}"
  if [[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$tag"
  else
    echo "$OPAM_VERSION_FALLBACK"
  fi
}

# =============================================================================
# One-version-per-language-root invariant (issue #112)
# =============================================================================
# A box image ships exactly one version of each runtime. More than one means a
# stale toolchain was carried in by a COPY --from a cached language image and
# is silently costing gigabytes; zero means the layer never arrived. Assert it
# where the layer is built instead of discovering it in a released image.

# Count installed versions in a version-manager root, ignoring the manager's
# own bookkeeping entries ("current" symlinks, dotfiles, aliases).
count_installed_versions() {
  local root="$1" entry count=0
  [ -d "$root" ] || { echo 0; return 0; }
  for entry in "$root"/*; do
    [ -d "$entry" ] || continue
    [ -L "$entry" ] && continue
    case "$(basename "$entry")" in
      current|.*) continue ;;
    esac
    count=$((count + 1))
  done
  echo "$count"
}

# assert_single_runtime_versions [--warn]
# Fails (or, with --warn, only reports) when a language root holds more than
# one version. Roots that do not exist are skipped: language images legitimately
# ship a single runtime each.
assert_single_runtime_versions() {
  local mode="strict" home="${BOX_HOME:-$HOME}" status=0 root count candidate
  [ "${1:-}" = "--warn" ] && mode="warn"

  local roots=(
    "node:$home/.nvm/versions/node"
    "rust:$home/.rustup/toolchains"
    "python:$home/.pyenv/versions"
    "ruby:$home/.rbenv/versions"
  )
  for candidate in "$home"/.sdkman/candidates/*; do
    [ -d "$candidate" ] || continue
    roots+=("sdkman/$(basename "$candidate"):$candidate")
  done

  for root in "${roots[@]}"; do
    local name="${root%%:*}" path="${root#*:}"
    [ -d "$path" ] || continue
    count=$(count_installed_versions "$path")
    if [ "$count" -gt 1 ]; then
      log_error "$name: expected exactly 1 version in $path, found $count:"
      ls -1 "$path" | sed 's/^/      /'
      status=1
    elif [ "$count" -eq 1 ]; then
      log_success "$name: 1 version ($(ls -1 "$path" | grep -v '^current$' | head -n1))"
    fi
  done

  if [ "$status" -ne 0 ] && [ "$mode" = "strict" ]; then
    log_error "Single-version invariant violated (issue #112)"
    return 1
  fi
  return 0
}
