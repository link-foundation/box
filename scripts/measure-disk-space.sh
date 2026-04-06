#!/usr/bin/env bash
set -euo pipefail

# Disk Space Measurement Script for Box Environment
# This script measures disk space used by each installed component.
# It wraps the installation script with disk space tracking capabilities.
#
# Usage: ./measure-disk-space.sh [--json-output FILE]
#
# Output: JSON file with disk space measurements for each component

# Parse arguments
JSON_OUTPUT_FILE="${1:-/tmp/disk-space-measurements.json}"
if [[ "$1" == "--json-output" ]] && [[ -n "${2:-}" ]]; then
  JSON_OUTPUT_FILE="$2"
fi

# Color codes for enhanced output (disabled in non-TTY)
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  NC='\033[0m' # No Color
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  CYAN=''
  NC=''
fi

# Logging functions
log_info() { echo -e "${BLUE}[*]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_note() { echo -e "${CYAN}[i]${NC} $1"; }
log_step() { echo -e "\n${GREEN}==>${NC} ${BLUE}$1${NC}\n"; }

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

# Get current disk usage in bytes
get_disk_usage_bytes() {
  df / --output=used --block-size=1 | tail -1 | tr -d '[:space:]'
}

# Get current disk usage in MB (for display)
get_disk_usage_mb() {
  df / --output=used --block-size=1M | tail -1 | tr -d '[:space:]'
}

# Cleanup function to ensure accurate measurements
cleanup_for_measurement() {
  # Clean apt cache (downloaded .deb files) but preserve package lists
  # NOTE: We intentionally do NOT delete /var/lib/apt/lists/* as it breaks
  # package installation. See docs/case-studies/issue-29 for details.
  maybe_sudo apt-get clean 2>/dev/null || true

  # Clean temp files
  maybe_sudo rm -rf /tmp/* 2>/dev/null || true
  maybe_sudo rm -rf /var/tmp/* 2>/dev/null || true

  # Sync filesystem
  sync
}

# Initialize JSON output
init_json_output() {
  cat > "$JSON_OUTPUT_FILE" << 'EOF'
{
  "generated_at": "",
  "total_size_mb": 0,
  "components": []
}
EOF
  log_info "Initialized JSON output at $JSON_OUTPUT_FILE"
}

# Add component measurement to JSON
# Uses Python for reliable JSON manipulation, avoiding sed issues with special
# characters in component names (e.g., "C/C++ Tools"). See docs/case-studies/issue-35.
# Args: component_name category size_bytes size_mb
add_measurement() {
  local name="$1"
  local category="$2"
  local size_bytes="$3"
  local size_mb="$4"

  python3 -c "
import json, sys
with open('$JSON_OUTPUT_FILE', 'r') as f:
    data = json.load(f)
data['components'].append({
    'name': sys.argv[1],
    'category': sys.argv[2],
    'size_bytes': int(sys.argv[3]),
    'size_mb': float(sys.argv[4])
})
with open('$JSON_OUTPUT_FILE', 'w') as f:
    json.dump(data, f)
" "$name" "$category" "$size_bytes" "$size_mb"

  log_success "Recorded: $name - ${size_mb}MB"
}

# Finalize JSON output with timestamp and total
# Uses Python for reliable JSON manipulation.
finalize_json_output() {
  local total_mb="$1"

  python3 -c "
import json
from datetime import datetime, timezone
with open('$JSON_OUTPUT_FILE', 'r') as f:
    data = json.load(f)
data['generated_at'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
data['total_size_mb'] = float('$total_mb')
with open('$JSON_OUTPUT_FILE', 'w') as f:
    json.dump(data, f)
"

  log_success "Finalized JSON output with total: ${total_mb}MB"
}

# Measure installation of a component
# Args: component_name category install_command...
measure_install() {
  local name="$1"
  local category="$2"
  shift 2

  log_info "Measuring installation: $name"

  # Cleanup before measurement
  cleanup_for_measurement

  # Record starting disk usage
  local start_bytes
  start_bytes=$(get_disk_usage_bytes)

  # Run installation command
  if "$@"; then
    # Cleanup after installation
    cleanup_for_measurement

    # Record ending disk usage
    local end_bytes
    end_bytes=$(get_disk_usage_bytes)

    # Calculate difference
    local diff_bytes=$((end_bytes - start_bytes))

    # Handle negative values (can happen due to cleanup removing more than installed)
    if [ "$diff_bytes" -lt 0 ]; then
      diff_bytes=0
    fi

    # Convert to MB with decimal precision (1 MB = 1,000,000 bytes).
    # Integer floor division via / 1024 / 1024 truncates any component under
    # 1 MiB to 0 MB, which is misleading (e.g. 741 KB shows as 0 MB).
    # Use awk for floating-point division to get precise values (e.g. 0.74 MB).
    # See docs/case-studies/issue-55 for full root cause analysis.
    local diff_mb
    diff_mb=$(awk "BEGIN {printf \"%.2f\", $diff_bytes / 1000000}")

    add_measurement "$name" "$category" "$diff_bytes" "$diff_mb"
    return 0
  else
    log_warning "Installation of $name failed"
    add_measurement "$name" "$category" 0 0
    return 1
  fi
}

# Measure apt package installation
measure_apt_install() {
  local name="$1"
  local category="$2"
  shift 2
  local packages="$*"

  measure_install "$name" "$category" maybe_sudo apt install -y $packages
}

# ============================================================================
# MAIN MEASUREMENT SCRIPT
# ============================================================================

log_step "Starting Disk Space Measurement"
log_note "Results will be saved to: $JSON_OUTPUT_FILE"

# Initialize output
init_json_output

# Record baseline
cleanup_for_measurement
BASELINE_MB=$(get_disk_usage_mb)
log_info "Baseline disk usage: ${BASELINE_MB}MB"

# --- Pre-flight Checks ---
log_step "Running pre-flight checks"

if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
  log_error "This script requires sudo access."
  exit 1
fi

log_success "Pre-flight checks passed"

# --- Create box user if missing ---
if ! id "box" &>/dev/null; then
  log_info "Creating box user..."
  useradd -m -d /home/box -s /bin/bash box 2>/dev/null || adduser --disabled-password --gecos "" --home /home/box box
  passwd -d box 2>/dev/null || true
  usermod -aG sudo box 2>/dev/null || true
fi

# --- Prepare APT ---
log_step "Preparing APT sources"
maybe_sudo apt update -y || true
cleanup_for_measurement

# ============================================================================
# SYSTEM PREREQUISITES (measured as a group)
# ============================================================================
log_step "Measuring System Prerequisites"

measure_apt_install "Essential Tools" "System" \
  wget curl unzip zip git sudo ca-certificates gnupg build-essential expect screen

# ============================================================================
# PROGRAMMING LANGUAGES - APT PACKAGES
# ============================================================================
log_step "Measuring APT-based Languages and Tools"

measure_apt_install ".NET SDK 8.0" "Runtime" dotnet-sdk-8.0
measure_apt_install "C/C++ Tools (CMake, Clang, LLVM, LLD)" "Build Tools" cmake clang llvm lld
measure_apt_install "Assembly Tools (NASM, FASM)" "Build Tools" nasm fasm
measure_apt_install "R Language" "Runtime" r-base
measure_apt_install "Bubblewrap" "Dependencies" bubblewrap
measure_apt_install "Ruby Build Dependencies" "Dependencies" libyaml-dev
measure_apt_install "Python Build Dependencies" "Dependencies" \
  libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
  libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev

# ============================================================================
# GitHub CLI
# ============================================================================
log_step "Measuring GitHub CLI"

install_gh_cli() {
  maybe_sudo mkdir -p -m 755 /etc/apt/keyrings
  local out
  out=$(mktemp)
  wget -nv -O"$out" https://cli.github.com/packages/githubcli-archive-keyring.gpg
  cat "$out" | maybe_sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
  maybe_sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  rm -f "$out"
  maybe_sudo mkdir -p -m 755 /etc/apt/sources.list.d
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | maybe_sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
  maybe_sudo apt update -y
  maybe_sudo apt install -y gh
}

measure_install "GitHub CLI" "Development Tools" install_gh_cli

# ============================================================================
# GitLab CLI
# ============================================================================
log_step "Measuring GitLab CLI"

measure_apt_install "GitLab CLI" "Development Tools" glab

# ============================================================================
# Homebrew Directory Preparation
# ============================================================================
log_step "Preparing Homebrew Directory"

if [ ! -d /home/linuxbrew/.linuxbrew ]; then
  maybe_sudo mkdir -p /home/linuxbrew/.linuxbrew
  if id "box" &>/dev/null; then
    maybe_sudo chown -R box:box /home/linuxbrew
  fi
fi

# ============================================================================
# BOX USER INSTALLATIONS
# The following tools are installed as the box user
# ============================================================================
log_step "Measuring Box User Installations"

# Create measurement script for box user
cat > /tmp/box-measure.sh << 'EOF_BOX'
#!/usr/bin/env bash
set -euo pipefail

JSON_OUTPUT_FILE="${1:-/tmp/disk-space-measurements.json}"

# Logging
log_info() { echo -e "\033[0;34m[*]\033[0m $1"; }
log_success() { echo -e "\033[0;32m[✓]\033[0m $1"; }
log_warning() { echo -e "\033[1;33m[!]\033[0m $1"; }

command_exists() { command -v "$1" &>/dev/null; }

maybe_sudo() {
  if [ "$EUID" -eq 0 ]; then "$@"
  elif command_exists sudo; then sudo "$@"
  else "$@"
  fi
}

get_disk_usage_bytes() {
  df / --output=used --block-size=1 | tail -1 | tr -d '[:space:]'
}

cleanup_for_measurement() {
  # Clean apt cache but preserve package lists (see docs/case-studies/issue-29)
  maybe_sudo apt-get clean 2>/dev/null || true
  rm -rf /tmp/measure-* 2>/dev/null || true
  sync
}

add_measurement() {
  local name="$1"
  local category="$2"
  local size_bytes="$3"
  local size_mb="$4"

  # Use Python for reliable JSON manipulation, matching the outer script.
  # sed-based approaches fail silently on compact (single-line) JSON produced by
  # python3's json.dump(), because the pattern \]$ does not match when the line
  # ends with } (the root object close) rather than ] (the array close).
  # See docs/case-studies/issue-49 for the full root cause analysis.
  python3 -c "
import json, sys
with open('$JSON_OUTPUT_FILE', 'r') as f:
    data = json.load(f)
data['components'].append({
    'name': sys.argv[1],
    'category': sys.argv[2],
    'size_bytes': int(sys.argv[3]),
    'size_mb': float(sys.argv[4])
})
with open('$JSON_OUTPUT_FILE', 'w') as f:
    json.dump(data, f)
" "$name" "$category" "$size_bytes" "$size_mb"

  log_success "Recorded: $name - ${size_mb}MB"
}

measure_install() {
  local name="$1"
  local category="$2"
  shift 2

  log_info "Measuring: $name"
  cleanup_for_measurement
  local start_bytes
  start_bytes=$(get_disk_usage_bytes)

  if "$@"; then
    cleanup_for_measurement
    local end_bytes
    end_bytes=$(get_disk_usage_bytes)
    local diff_bytes=$((end_bytes - start_bytes))
    [ "$diff_bytes" -lt 0 ] && diff_bytes=0
    # Convert to MB with decimal precision. Use awk for floating-point division
    # to get precise values (e.g. 0.74 MB instead of 0 or 1).
    # See docs/case-studies/issue-55.
    local diff_mb
    diff_mb=$(awk "BEGIN {printf \"%.2f\", $diff_bytes / 1000000}")
    add_measurement "$name" "$category" "$diff_bytes" "$diff_mb"
  else
    log_warning "Installation of $name failed"
    add_measurement "$name" "$category" 0 0
  fi
}

# --- Bun ---
install_bun() {
  curl -fsSL https://bun.sh/install | bash
  export BUN_INSTALL="$HOME/.bun"
  export PATH="$BUN_INSTALL/bin:$PATH"
}
measure_install "Bun" "Runtime" install_bun

# Ensure bun is in PATH for subsequent installs
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# --- gh-setup-git-identity ---
install_gh_identity() {
  bun install -g gh-setup-git-identity
}
measure_install "gh-setup-git-identity" "Development Tools" install_gh_identity

# --- glab-setup-git-identity ---
install_glab_identity() {
  bun install -g glab-setup-git-identity
}
measure_install "glab-setup-git-identity" "Development Tools" install_glab_identity

# --- Deno ---
install_deno() {
  curl -fsSL https://deno.land/install.sh | sh -s -- -y
  export DENO_INSTALL="$HOME/.deno"
  export PATH="$DENO_INSTALL/bin:$PATH"
}
measure_install "Deno" "Runtime" install_deno

# --- NVM + Node.js ---
install_nvm_node() {
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
  nvm install 20
  npm install -g npm@latest --no-fund --silent
}
measure_install "NVM + Node.js 20" "Runtime" install_nvm_node

# Load NVM for subsequent commands
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# --- Pyenv + Python ---
install_pyenv_python() {
  curl https://pyenv.run | bash
  export PYENV_ROOT="$HOME/.pyenv"
  export PATH="$PYENV_ROOT/bin:$PATH"
  eval "$(pyenv init --path)"
  eval "$(pyenv init -)"

  LATEST_PYTHON=$(pyenv install --list | grep -E '^\s*[0-9]+\.[0-9]+\.[0-9]+$' | tail -1 | tr -d '[:space:]')
  if [ -n "$LATEST_PYTHON" ]; then
    pyenv install "$LATEST_PYTHON"
    pyenv global "$LATEST_PYTHON"
  fi
}
measure_install "Pyenv + Python (latest)" "Runtime" install_pyenv_python

# Load pyenv
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init --path)" 2>/dev/null || true
eval "$(pyenv init -)" 2>/dev/null || true

# --- Golang ---
install_golang() {
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) GO_ARCH="amd64" ;;
    aarch64) GO_ARCH="arm64" ;;
    *) GO_ARCH="" ;;
  esac

  if [ -n "$GO_ARCH" ]; then
    GO_VERSION=$(curl -sL 'https://go.dev/VERSION?m=text' | head -n1)
    GO_TARBALL="${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
    GO_URL="https://go.dev/dl/${GO_TARBALL}"

    TEMP_DIR=$(mktemp -d)
    curl -sL "$GO_URL" -o "$TEMP_DIR/$GO_TARBALL"
    mkdir -p "$HOME/.go"
    tar -xzf "$TEMP_DIR/$GO_TARBALL" -C "$HOME/.go" --strip-components=1
    rm -rf "$TEMP_DIR"

    export GOROOT="$HOME/.go"
    export GOPATH="$HOME/.go/path"
    export PATH="$GOROOT/bin:$GOPATH/bin:$PATH"
    mkdir -p "$GOPATH"
  fi
}
measure_install "Go (latest)" "Runtime" install_golang

# Load Go
export GOROOT="$HOME/.go"
export GOPATH="$HOME/.go/path"
export PATH="$GOROOT/bin:$GOPATH/bin:$PATH"

# --- Rust ---
install_rust() {
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  [ -f "$HOME/.cargo/env" ] && \. "$HOME/.cargo/env"
}
# Use du-based measurement for Rust because the df-delta method is unreliable:
# rustup downloads files to /tmp then moves them to ~/.rustup and ~/.cargo,
# which can show near-zero df delta due to move-vs-copy on same filesystem.
# See docs/case-studies/issue-55 for full analysis.
cleanup_for_measurement
if install_rust; then
  cleanup_for_measurement
  # Only pass paths that exist to du; passing a non-existent path causes du to
  # exit with code 1, which kills the script under set -euo pipefail even though
  # stderr is redirected. See docs/case-studies/issue-57 for root cause analysis.
  rust_paths=()
  [[ -d "$HOME/.rustup" ]] && rust_paths+=("$HOME/.rustup")
  [[ -d "$HOME/.cargo" ]] && rust_paths+=("$HOME/.cargo")
  if [[ ${#rust_paths[@]} -gt 0 ]]; then
    rust_bytes=$(du -sb "${rust_paths[@]}" 2>/dev/null | awk '{sum+=$1} END{print sum+0}')
  else
    rust_bytes=0
  fi
  rust_mb=$(awk "BEGIN {printf \"%.2f\", $rust_bytes / 1000000}")
  add_measurement "Rust (via rustup)" "Runtime" "$rust_bytes" "$rust_mb"
else
  log_warning "Installation of Rust (via rustup) failed"
  add_measurement "Rust (via rustup)" "Runtime" 0 0
fi

# Load Rust
[ -f "$HOME/.cargo/env" ] && \. "$HOME/.cargo/env"

# --- SDKMAN + Java ---
install_sdkman_java() {
  curl -s "https://get.sdkman.io?rcupdate=false&ci=true" | bash
  export SDKMAN_DIR="$HOME/.sdkman"
  set +u
  [ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ] && source "$SDKMAN_DIR/bin/sdkman-init.sh"
  sdk install java 21-tem < /dev/null || sdk install java 21-open < /dev/null || true
  set -u
}
measure_install "SDKMAN + Java 21" "Runtime" install_sdkman_java

# Load SDKMAN
export SDKMAN_DIR="$HOME/.sdkman"
set +u
[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ] && source "$SDKMAN_DIR/bin/sdkman-init.sh"
set -u

# --- Kotlin ---
install_kotlin() {
  set +u
  sdk install kotlin < /dev/null || true
  set -u
}
measure_install "Kotlin (via SDKMAN)" "Runtime" install_kotlin

# --- Lean ---
install_lean() {
  curl https://elan.lean-lang.org/elan-init.sh -sSf | sh -s -- -y --default-toolchain stable
  [ -f "$HOME/.elan/env" ] && \. "$HOME/.elan/env"
}
measure_install "Lean (via elan)" "Runtime" install_lean

# Load Lean
[ -f "$HOME/.elan/env" ] && \. "$HOME/.elan/env"

# --- Opam + Rocq ---
install_opam_rocq() {
  sudo apt install -y bubblewrap 2>/dev/null || true
  bash -c "sh <(curl -fsSL https://opam.ocaml.org/install.sh) --no-backup" <<< "y" || sudo apt install -y opam || true

  if command -v opam &>/dev/null; then
    opam init --disable-sandboxing --auto-setup -y || true
    eval "$(opam env --switch=default 2>/dev/null)" || true
    opam repo add rocq-released https://rocq-prover.org/opam/released 2>/dev/null || true
    opam update 2>/dev/null || true
    opam pin add rocq-prover --yes 2>/dev/null || opam install rocq-prover -y 2>/dev/null || opam install coq -y 2>/dev/null || true
  fi
}
measure_install "Opam + Rocq/Coq" "Runtime" install_opam_rocq

# --- Homebrew ---
install_homebrew() {
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || true

  if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  elif [[ -x "$HOME/.linuxbrew/bin/brew" ]]; then
    eval "$("$HOME/.linuxbrew/bin/brew" shellenv)"
  fi
}
# Use du-based measurement for Homebrew because the outer script pre-creates
# /home/linuxbrew/.linuxbrew before this runs, making the df-delta near-zero.
# See docs/case-studies/issue-55 for full analysis.
cleanup_for_measurement
if install_homebrew; then
  cleanup_for_measurement
  # Only pass paths that exist to du; passing a non-existent path causes du to
  # exit with code 1, which kills the script under set -euo pipefail even though
  # stderr is redirected. See docs/case-studies/issue-57 for root cause analysis.
  brew_paths=()
  [[ -d /home/linuxbrew/.linuxbrew ]] && brew_paths+=(/home/linuxbrew/.linuxbrew)
  [[ -d "$HOME/.linuxbrew" ]] && brew_paths+=("$HOME/.linuxbrew")
  if [[ ${#brew_paths[@]} -gt 0 ]]; then
    brew_bytes=$(du -sb "${brew_paths[@]}" 2>/dev/null | awk '{sum+=$1} END{print sum+0}')
  else
    brew_bytes=0
  fi
  brew_mb=$(awk "BEGIN {printf \"%.2f\", $brew_bytes / 1000000}")
  add_measurement "Homebrew" "Package Manager" "$brew_bytes" "$brew_mb"
else
  log_warning "Installation of Homebrew failed"
  add_measurement "Homebrew" "Package Manager" 0 0
fi

# Load Homebrew
if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
elif [[ -x "$HOME/.linuxbrew/bin/brew" ]]; then
  eval "$("$HOME/.linuxbrew/bin/brew" shellenv)"
fi

# --- PHP ---
install_php() {
  if command -v brew &>/dev/null; then
    brew tap shivammathur/php || true
    export HOMEBREW_NO_ANALYTICS=1
    export HOMEBREW_NO_AUTO_UPDATE=1
    brew install shivammathur/php/php@8.3 || true
    brew link --overwrite --force shivammathur/php/php@8.3 2>&1 | grep -v "Warning" || true
  fi
}
measure_install "PHP 8.3 (via Homebrew)" "Runtime" install_php

# --- Perlbrew + Perl ---
install_perlbrew_perl() {
  export PERLBREW_ROOT="$HOME/.perl5"
  curl -L https://install.perlbrew.pl | bash

  if [ -f "$PERLBREW_ROOT/etc/bashrc" ]; then
    sed -i 's/\$1/${1:-}/g' "$PERLBREW_ROOT/etc/bashrc" 2>/dev/null || true
    sed -i 's/\$PERLBREW_LIB/${PERLBREW_LIB:-}/g' "$PERLBREW_ROOT/etc/bashrc" 2>/dev/null || true
    sed -i 's/\$outsep/${outsep:-}/g' "$PERLBREW_ROOT/etc/bashrc" 2>/dev/null || true

    set +u
    source "$PERLBREW_ROOT/etc/bashrc"
    set -u

    LATEST_PERL=$(perlbrew available 2>&1 | grep -oE 'perl-5\.[0-9]+\.[0-9]+' | head -1 || true)
    if [ -n "$LATEST_PERL" ]; then
      perlbrew install "$LATEST_PERL" --notest || true
      perlbrew switch "$LATEST_PERL" || true
    fi
  fi
}
measure_install "Perlbrew + Perl (latest)" "Runtime" install_perlbrew_perl

# --- rbenv + Ruby ---
install_rbenv_ruby() {
  git clone https://github.com/rbenv/rbenv.git "$HOME/.rbenv"
  mkdir -p "$HOME/.rbenv/plugins"
  git clone https://github.com/rbenv/ruby-build.git "$HOME/.rbenv/plugins/ruby-build"

  export PATH="$HOME/.rbenv/bin:$PATH"
  eval "$(rbenv init - bash)"

  LATEST_RUBY=$(rbenv install -l 2>/dev/null | grep -E '^\s*3\.[0-9]+\.[0-9]+$' | tail -1 | tr -d '[:space:]')
  if [ -n "$LATEST_RUBY" ]; then
    rbenv install "$LATEST_RUBY"
    rbenv global "$LATEST_RUBY"
  fi
}
measure_install "rbenv + Ruby (latest)" "Runtime" install_rbenv_ruby

# --- Swift ---
install_swift() {
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) SWIFT_DIR="ubuntu2404"; SWIFT_FILE_SUFFIX="ubuntu24.04" ;;
    aarch64) SWIFT_DIR="ubuntu2404-aarch64"; SWIFT_FILE_SUFFIX="ubuntu24.04-aarch64" ;;
    *) SWIFT_DIR=""; SWIFT_FILE_SUFFIX="" ;;
  esac

  if [ -n "$SWIFT_DIR" ]; then
    SWIFT_VERSION="6.0.3"
    SWIFT_RELEASE="RELEASE"
    SWIFT_PACKAGE="swift-${SWIFT_VERSION}-${SWIFT_RELEASE}-${SWIFT_FILE_SUFFIX}"
    SWIFT_URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/${SWIFT_DIR}/swift-${SWIFT_VERSION}-${SWIFT_RELEASE}/${SWIFT_PACKAGE}.tar.gz"

    TEMP_DIR=$(mktemp -d)
    if curl -fsSL "$SWIFT_URL" -o "$TEMP_DIR/swift.tar.gz"; then
      mkdir -p "$HOME/.swift"
      tar -xzf "$TEMP_DIR/swift.tar.gz" -C "$TEMP_DIR"
      cp -r "$TEMP_DIR/${SWIFT_PACKAGE}/usr" "$HOME/.swift/"
      rm -rf "$TEMP_DIR"
      export PATH="$HOME/.swift/usr/bin:$PATH"
    fi
  fi
}
measure_install "Swift 6.x" "Runtime" install_swift

log_success "Box user measurements complete"
EOF_BOX

chmod +x /tmp/box-measure.sh

# Resolve JSON output path to absolute before passing to box user.
# 'su - box' and 'sudo -i -u box' both create login shells that change
# the working directory to the box user's home (/home/box). Relative
# paths like 'data/disk-space-measurements.json' would then resolve to the wrong
# location, causing "No such file or directory" errors.
# See docs/case-studies/issue-46 for the full root cause analysis.
JSON_OUTPUT_FILE_ABS="$(realpath "$JSON_OUTPUT_FILE")"
# The box user needs to read and write the JSON file, but the GitHub Actions
# workspace directories (e.g. /home/runner/work/box/box/) are owned by
# 'runner' and typically have mode 750, so 'box' (not in the 'runner' group)
# cannot traverse them even if the file itself is world-readable.
# Solution: copy the JSON file to /tmp (world-accessible, mode 1777), run the
# box measurements against that copy, then copy the result back.
JSON_TMP_COPY="$(mktemp /tmp/disk-space-measurements-XXXXXX.json)"
cp "$JSON_OUTPUT_FILE_ABS" "$JSON_TMP_COPY"
chmod o+rw "$JSON_TMP_COPY"

# Execute box user measurements against the /tmp copy
if [ "$EUID" -eq 0 ]; then
  su - box -c "bash /tmp/box-measure.sh '$JSON_TMP_COPY'"
else
  sudo -i -u box bash /tmp/box-measure.sh "$JSON_TMP_COPY"
fi

# Copy the updated measurements back to the original location
cp "$JSON_TMP_COPY" "$JSON_OUTPUT_FILE_ABS"
rm -f "$JSON_TMP_COPY"

rm -f /tmp/box-measure.sh

# ============================================================================
# FINALIZE
# ============================================================================
log_step "Finalizing Measurements"

cleanup_for_measurement
FINAL_MB=$(get_disk_usage_mb)
TOTAL_MB=$(awk "BEGIN {printf \"%.2f\", $FINAL_MB - $BASELINE_MB}")

finalize_json_output "$TOTAL_MB"

log_step "Measurement Complete!"
log_success "Total installation size: ${TOTAL_MB}MB"
log_success "Results saved to: $JSON_OUTPUT_FILE"

# Print summary
echo ""
echo "=== DISK SPACE SUMMARY ==="
cat "$JSON_OUTPUT_FILE" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(f\"Generated: {data['generated_at']}\")
print(f\"Total Size: {data['total_size_mb']}MB\")
print()
print('Components by Category:')
categories = {}
for comp in data['components']:
    cat = comp['category']
    if cat not in categories:
        categories[cat] = []
    categories[cat].append(comp)

for cat, comps in sorted(categories.items()):
    print(f'  {cat}:')
    for c in sorted(comps, key=lambda x: x['size_mb'], reverse=True):
        print(f\"    {c['name']}: {c['size_mb']}MB\")
" 2>/dev/null || cat "$JSON_OUTPUT_FILE"
