#!/usr/bin/env bash
set -euo pipefail

# Box Environment Installation Script
# This script installs common language runtimes for a development box.
# It is AI-agnostic - no AI tools or assistants are included.
# Based on: https://github.com/link-assistant/hive-mind/blob/main/scripts/ubuntu-24-server-install.sh

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

# Enhanced logging functions
log_info() {
  echo -e "${BLUE}[*]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[✓]${NC} $1"
}

log_warning() {
  echo -e "${YELLOW}[!]${NC} $1"
}

log_error() {
  echo -e "${RED}[✗]${NC} $1"
}

log_note() {
  echo -e "${CYAN}[i]${NC} $1"
}

log_step() {
  echo -e "\n${GREEN}==>${NC} ${BLUE}$1${NC}\n"
}

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

# --- Pre-flight Checks ---
log_step "Running pre-flight checks"

# Check if running as root or with sudo access
if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
  log_error "This script requires sudo access. Please run with sudo or ensure user has sudo privileges."
  exit 1
fi

# Check Ubuntu version
if [ -f /etc/os-release ]; then
  source /etc/os-release
  if [[ "$ID" != "ubuntu" ]]; then
    log_warning "This script is designed for Ubuntu. Detected: $ID"
    log_note "Continuing anyway, but some steps may fail..."
  fi

  if [[ "$VERSION_ID" != "24.04" ]] && [[ "$VERSION_ID" != "24.10" ]]; then
    log_warning "This script is tested on Ubuntu 24.x. Detected: $VERSION_ID"
    log_note "Continuing anyway, but compatibility issues may occur..."
  else
    log_success "Ubuntu $VERSION_ID detected"
  fi
fi

# Check available disk space (need at least 15GB free)
AVAILABLE_GB=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
if [ "$AVAILABLE_GB" -lt 15 ]; then
  log_warning "Low disk space detected: ${AVAILABLE_GB}GB available"
  log_warning "Recommended: at least 15GB free space"
else
  log_success "Sufficient disk space available: ${AVAILABLE_GB}GB"
fi

# Check internet connectivity
if ping -c 1 -W 5 google.com &>/dev/null; then
  log_success "Internet connectivity confirmed"
else
  log_warning "Ping test failed (may be expected in Docker environments)"
fi

log_success "Pre-flight checks passed"

log_step "Starting box environment setup"

# --- Create box user if missing ---
if id "box" &>/dev/null; then
  log_info "box user already exists."
else
  log_info "Creating box user..."
  useradd -m -d /home/box -s /bin/bash box 2>/dev/null || {
    log_warning "User creation with useradd failed, trying adduser..."
    adduser --disabled-password --gecos "" --home /home/box box
  }
  passwd -d box 2>/dev/null || log_note "Could not remove password requirement"
  usermod -aG sudo box 2>/dev/null || log_note "Could not add to sudo group"
  log_success "box user created and configured"
fi

# --- Function: apt safe update ---
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

# --- Function: cleanup disk ---
apt_cleanup() {
  log_info "Cleaning up apt cache and temporary files..."
  maybe_sudo apt-get clean
  maybe_sudo apt-get autoclean
  maybe_sudo apt-get autoremove -y
  maybe_sudo rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
  log_success "Cleanup completed"
}

# --- Function: cleanup duplicate APT sources ---
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

# --- Ensure prerequisites ---
log_step "Installing system prerequisites"

cleanup_duplicate_apt_sources
apt_update_safe

log_info "Installing essential development tools..."
maybe_sudo apt install -y wget curl unzip zip git sudo ca-certificates gnupg dotnet-sdk-8.0 build-essential expect screen
log_success "Essential tools installed"

# --- Install C/C++ Development Tools ---
log_info "Installing C/C++ development tools (CMake, Clang/LLVM)..."
sudo apt install -y cmake clang llvm lld
log_success "C/C++ development tools installed"

# --- Install Assembly Tools ---
log_info "Installing Assembly tools..."
# Note: GNU Assembler (as) is already installed as part of binutils (via build-essential)
# Note: llvm-mc is already installed as part of llvm package above
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
  # FASM (Flat Assembler) is only available for x86-64 architecture
  maybe_sudo apt install -y nasm fasm
  log_success "Assembly tools installed (NASM + FASM)"
else
  # On non-x86 architectures (ARM64, etc.), only install NASM
  # FASM is not available as it's a self-compiling x86 assembler
  maybe_sudo apt install -y nasm
  log_success "Assembly tools installed (NASM only - FASM not available for $ARCH)"
fi

# --- Install R Language ---
log_info "Installing R statistical language..."
maybe_sudo apt install -y r-base
log_success "R language installed"

# --- Install Ruby build dependencies ---
log_info "Installing Ruby build dependencies..."
maybe_sudo apt install -y libyaml-dev
log_success "Ruby build dependencies installed"

# --- Install Python build dependencies (required for pyenv) ---
log_info "Installing Python build dependencies..."
maybe_sudo apt install -y \
  libssl-dev \
  zlib1g-dev \
  libbz2-dev \
  libreadline-dev \
  libsqlite3-dev \
  libncursesw5-dev \
  xz-utils \
  tk-dev \
  libxml2-dev \
  libxmlsec1-dev \
  libffi-dev \
  liblzma-dev
log_success "Python build dependencies installed"

# --- GitHub CLI (install system-wide) ---
log_step "Installing GitHub CLI (system-wide)"
if ! command -v gh &>/dev/null; then
  log_info "Installing GitHub CLI..."
  maybe_sudo mkdir -p -m 755 /etc/apt/keyrings
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
  log_success "GitHub CLI installed"
else
  log_success "GitHub CLI already installed"
fi

# --- GitLab CLI (install system-wide) ---
log_step "Installing GitLab CLI (system-wide)"
if ! command -v glab &>/dev/null; then
  log_info "Installing GitLab CLI..."
  maybe_sudo apt install -y glab
  log_success "GitLab CLI installed"
else
  log_success "GitLab CLI already installed"
fi

# --- Detect Docker environment ---
is_docker=false
if [ "${DOCKER_BUILD:-}" = "1" ]; then
  is_docker=true
  log_note "Docker build environment detected via DOCKER_BUILD variable"
elif [ -f /.dockerenv ]; then
  is_docker=true
elif grep -qE 'docker|buildkit|containerd' /proc/1/cgroup 2>/dev/null; then
  is_docker=true
fi

if [ "$is_docker" = true ]; then
  log_step "Skipping swap setup (running in Docker container)"
else
  log_step "Skipping swap setup (swap management is out of scope for box)"
fi

# --- Prepare Homebrew directory ---
log_step "Preparing Homebrew installation directory"

if [ ! -d /home/linuxbrew/.linuxbrew ]; then
  log_info "Creating /home/linuxbrew/.linuxbrew directory"
  maybe_sudo mkdir -p /home/linuxbrew
  maybe_sudo mkdir -p /home/linuxbrew/.linuxbrew

  if id "box" &>/dev/null; then
    maybe_sudo chown -R box:box /home/linuxbrew
    log_success "Homebrew directory created and owned by box user"
  fi
else
  log_info "Homebrew directory already exists"
  if id "box" &>/dev/null; then
    maybe_sudo chown -R box:box /home/linuxbrew
  fi
fi

# --- Switch to box user for language tools setup ---
cat > /tmp/box-user-setup.sh <<'EOF_BOX_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# Define logging functions for box user session
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; NC=''
fi

log_info() { echo -e "${BLUE}[*]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_note() { echo -e "${CYAN}[i]${NC} $1"; }
log_step() { echo -e "\n${GREEN}==>${NC} ${BLUE}$1${NC}\n"; }

command_exists() {
  command -v "$1" &>/dev/null
}

maybe_sudo() {
  if [ "$EUID" -eq 0 ]; then
    "$@"
  elif command_exists sudo; then
    sudo "$@"
  else
    "$@"
  fi
}

log_step "Installing development tools as box user"

# --- Bun ---
if ! command -v bun &>/dev/null; then
  log_info "Installing Bun..."
  curl -fsSL https://bun.sh/install | bash
  export BUN_INSTALL="$HOME/.bun"
  export PATH="$BUN_INSTALL/bin:$PATH"
  log_success "Bun installed"
else
  log_info "Bun already installed."
fi

# Ensure bun is available for global installs
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# --- gh-setup-git-identity (GitHub git identity tool) ---
if command -v bun &>/dev/null; then
  if ! command -v gh-setup-git-identity &>/dev/null; then
    log_info "Installing gh-setup-git-identity..."
    bun install -g gh-setup-git-identity
    log_success "gh-setup-git-identity installed"
  else
    log_info "gh-setup-git-identity already installed."
  fi
fi

# --- glab-setup-git-identity (GitLab git identity tool) ---
if command -v bun &>/dev/null; then
  if ! command -v glab-setup-git-identity &>/dev/null; then
    log_info "Installing glab-setup-git-identity..."
    bun install -g glab-setup-git-identity
    log_success "glab-setup-git-identity installed"
  else
    log_info "glab-setup-git-identity already installed."
  fi
fi

# --- Deno ---
if ! command -v deno &>/dev/null; then
  log_info "Installing Deno..."
  curl -fsSL https://deno.land/install.sh | sh -s -- -y
  export DENO_INSTALL="$HOME/.deno"
  export PATH="$DENO_INSTALL/bin:$PATH"
  if ! grep -q 'DENO_INSTALL' "$HOME/.bashrc" 2>/dev/null; then
    {
      echo ''
      echo '# Deno configuration'
      echo 'export DENO_INSTALL="$HOME/.deno"'
      echo 'export PATH="$DENO_INSTALL/bin:$PATH"'
    } >> "$HOME/.bashrc"
  fi
  log_success "Deno installed"
else
  log_info "Deno already installed."
fi

# --- NVM + Node ---
if [ ! -d "$HOME/.nvm" ]; then
  log_info "Installing NVM..."
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
  log_success "NVM installed"
else
  log_info "NVM already installed."
fi

# --- Pyenv (Python version manager) ---
if [ ! -d "$HOME/.pyenv" ]; then
  log_info "Installing Pyenv..."
  curl https://pyenv.run | bash
  if ! grep -q 'pyenv init' "$HOME/.bashrc" 2>/dev/null; then
    {
      echo ''
      echo '# Pyenv configuration'
      echo 'export PYENV_ROOT="$HOME/.pyenv"'
      echo 'export PATH="$PYENV_ROOT/bin:$PATH"'
      echo 'eval "$(pyenv init --path)"'
      echo 'eval "$(pyenv init -)"'
    } >> "$HOME/.bashrc"
  fi
  log_success "Pyenv installed and configured"
else
  log_info "Pyenv already installed."
fi

# Load pyenv for current session
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
if command -v pyenv >/dev/null 2>&1; then
  eval "$(pyenv init --path)"
  eval "$(pyenv init -)"
  log_success "Pyenv loaded for current session"

  # Install latest stable Python version
  log_info "Installing latest stable Python version..."
  LATEST_PYTHON=$(pyenv install --list | grep -E '^\s*[0-9]+\.[0-9]+\.[0-9]+$' | tail -1 | tr -d '[:space:]')

  if [ -n "$LATEST_PYTHON" ]; then
    log_info "Installing Python $LATEST_PYTHON..."
    if ! pyenv versions --bare | grep -q "^${LATEST_PYTHON}$"; then
      pyenv install "$LATEST_PYTHON"
    else
      log_info "Python $LATEST_PYTHON already installed."
    fi

    log_info "Setting Python $LATEST_PYTHON as global default..."
    pyenv global "$LATEST_PYTHON"
    log_success "Python version manager setup complete"
    python --version
  fi
fi

# --- Golang ---
if [ ! -d "$HOME/.go" ] && [ ! -d "/usr/local/go" ]; then
  log_info "Installing Golang..."

  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) GO_ARCH="amd64" ;;
    aarch64) GO_ARCH="arm64" ;;
    armv7l) GO_ARCH="armv6l" ;;
    *) GO_ARCH="" ;;
  esac

  if [ -n "$GO_ARCH" ]; then
    GO_VERSION=$(curl -sL 'https://go.dev/VERSION?m=text' | head -n1)

    if [ -n "$GO_VERSION" ]; then
      GO_TARBALL="${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
      GO_URL="https://go.dev/dl/${GO_TARBALL}"

      log_info "Downloading Go $GO_VERSION for $GO_ARCH..."
      TEMP_DIR=$(mktemp -d)
      curl -sL "$GO_URL" -o "$TEMP_DIR/$GO_TARBALL"

      log_info "Installing Go to $HOME/.go..."
      mkdir -p "$HOME/.go"
      tar -xzf "$TEMP_DIR/$GO_TARBALL" -C "$HOME/.go" --strip-components=1
      rm -rf "$TEMP_DIR"

      if ! grep -q 'GOROOT.*\.go' "$HOME/.bashrc" 2>/dev/null; then
        {
          echo ''
          echo '# Go configuration'
          echo 'export GOROOT="$HOME/.go"'
          echo 'export GOPATH="$HOME/.go/path"'
          echo 'export PATH="$GOROOT/bin:$GOPATH/bin:$PATH"'
        } >> "$HOME/.bashrc"
      fi

      export GOROOT="$HOME/.go"
      export GOPATH="$HOME/.go/path"
      export PATH="$GOROOT/bin:$GOPATH/bin:$PATH"
      mkdir -p "$GOPATH"

      if command -v go &>/dev/null; then
        log_success "Golang installed: $(go version)"
      fi
    fi
  fi
else
  log_info "Golang already installed."
fi

# --- Rust ---
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

# --- Java (SDKMAN + OpenJDK) ---
if [ ! -d "$HOME/.sdkman" ]; then
  log_info "Installing SDKMAN (Java version manager)..."
  curl -s "https://get.sdkman.io?rcupdate=false&ci=true" | bash
  if ! grep -q 'sdkman-init.sh' "$HOME/.bashrc" 2>/dev/null; then
    {
      echo ''
      echo '# SDKMAN configuration'
      echo 'export SDKMAN_DIR="$HOME/.sdkman"'
      echo '[[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]] && source "$HOME/.sdkman/bin/sdkman-init.sh"'
    } >> "$HOME/.bashrc"
  fi
  log_success "SDKMAN installed and configured"
else
  log_info "SDKMAN already installed."
fi

# Load SDKMAN for current session and install Java
export SDKMAN_DIR="$HOME/.sdkman"
if [ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
  set +u
  source "$SDKMAN_DIR/bin/sdkman-init.sh"
  set -u
  log_success "SDKMAN loaded for current session"

  log_info "Installing Java 21 LTS (OpenJDK via Eclipse Temurin)..."
  set +u
  if ! sdk list java 2>/dev/null | grep -q "21.*tem.*installed"; then
    sdk install java 21-tem < /dev/null || {
      log_warning "Eclipse Temurin installation failed, trying default OpenJDK..."
      sdk install java 21-open < /dev/null || true
    }
  else
    log_info "Java 21 (Temurin) already installed."
  fi
  set -u

  if command -v java &>/dev/null; then
    log_success "Java version manager setup complete"
    java -version 2>&1 | head -n1
  fi
fi

# --- Lean (via elan) ---
if [ ! -d "$HOME/.elan" ]; then
  log_info "Installing Lean (via elan)..."
  curl https://elan.lean-lang.org/elan-init.sh -sSf | sh -s -- -y --default-toolchain stable
  if [ -f "$HOME/.elan/env" ]; then
    \. "$HOME/.elan/env"
    log_success "Lean installed successfully"
  fi
  if ! grep -q 'elan' "$HOME/.bashrc" 2>/dev/null; then
    {
      echo ''
      echo '# Lean (elan) configuration'
      echo 'export PATH="$HOME/.elan/bin:$PATH"'
    } >> "$HOME/.bashrc"
  fi
else
  log_info "Lean (elan) already installed."
fi

# --- Opam + Rocq (Coq theorem prover) ---
if ! command -v opam &>/dev/null; then
  log_info "Installing Opam (OCaml package manager)..."
  sudo apt install -y bubblewrap || true

  bash -c "sh <(curl -fsSL https://opam.ocaml.org/install.sh) --no-backup" <<< "y" || {
    sudo apt install -y opam || true
  }

  if command -v opam &>/dev/null; then
    log_success "Opam installed successfully"
  fi
else
  log_info "Opam already installed."
fi

# Initialize opam and install Rocq
if command -v opam &>/dev/null; then
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

# --- Homebrew ---
if ! command -v brew &>/dev/null; then
  log_info "Installing Homebrew..."

  BREW_INSTALL_OUTPUT=$(NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" 2>&1) || true

  BREW_INSTALLED=false
  if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    BREW_INSTALLED=true
    BREW_PREFIX="/home/linuxbrew/.linuxbrew"
  elif [[ -x "$HOME/.linuxbrew/bin/brew" ]]; then
    BREW_INSTALLED=true
    BREW_PREFIX="$HOME/.linuxbrew"
  fi

  if [ "$BREW_INSTALLED" = true ]; then
    log_success "Homebrew successfully installed at $BREW_PREFIX"
    eval "$($BREW_PREFIX/bin/brew shellenv)"

    if ! grep -q "$BREW_PREFIX/bin/brew shellenv" "$HOME/.profile" 2>/dev/null; then
      echo "eval \"\$($BREW_PREFIX/bin/brew shellenv)\"" >> "$HOME/.profile"
    fi
    if ! grep -q "$BREW_PREFIX/bin/brew shellenv" "$HOME/.bashrc" 2>/dev/null; then
      echo "eval \"\$($BREW_PREFIX/bin/brew shellenv)\"" >> "$HOME/.bashrc"
    fi

    if command -v brew &>/dev/null; then
      BREW_VERSION=$(brew --version 2>/dev/null | head -n1 || echo "version check failed")
      log_success "Homebrew ready: $BREW_VERSION"
    fi
  fi
else
  log_info "Homebrew already installed."
  eval "$(brew shellenv 2>/dev/null)" || true
fi

# --- PHP (via Homebrew + shivammathur/php tap) ---
if command -v brew &>/dev/null; then
  if ! brew list --formula 2>/dev/null | grep -q "^php@"; then
    log_info "Installing PHP via Homebrew..."

    if ! brew tap | grep -q "shivammathur/php"; then
      brew tap shivammathur/php || true
    fi

    if brew tap | grep -q "shivammathur/php"; then
      export HOMEBREW_NO_ANALYTICS=1
      export HOMEBREW_NO_AUTO_UPDATE=1

      log_info "Installing PHP 8.3 (this may take several minutes)..."
      brew install shivammathur/php/php@8.3 || true

      if brew list --formula 2>/dev/null | grep -q "^php@8.3$"; then
        brew link --overwrite --force shivammathur/php/php@8.3 2>&1 | grep -v "Warning" || true

        BREW_PREFIX=$(brew --prefix 2>/dev/null || echo "")
        if [[ -n "$BREW_PREFIX" && -d "$BREW_PREFIX/opt/php@8.3" ]]; then
          export PATH="$BREW_PREFIX/opt/php@8.3/bin:$BREW_PREFIX/opt/php@8.3/sbin:$PATH"

          if ! grep -q "php@8.3/bin" "$HOME/.bashrc" 2>/dev/null; then
            cat >> "$HOME/.bashrc" << 'PHP_PATH_EOF'

# PHP 8.3 PATH configuration
export PATH="$(brew --prefix)/opt/php@8.3/bin:$(brew --prefix)/opt/php@8.3/sbin:$PATH"
PHP_PATH_EOF
          fi
        fi

        if command -v php &>/dev/null; then
          PHP_VERSION=$(php --version 2>/dev/null | head -n 1 || echo "unknown version")
          log_success "PHP installed and available: $PHP_VERSION"
        fi
      fi
    fi
  else
    log_info "PHP already installed via Homebrew."
  fi
fi

# --- Perl (via Perlbrew) ---
if [ ! -d "$HOME/.perl5" ]; then
  log_info "Installing Perlbrew (Perl version manager)..."

  export PERLBREW_ROOT="$HOME/.perl5"
  curl -L https://install.perlbrew.pl | bash

  if ! grep -q 'perlbrew' "$HOME/.bashrc" 2>/dev/null; then
    {
      echo ''
      echo '# Perlbrew configuration'
      echo 'if [ -n "$PS1" ]; then'
      echo '  export PERLBREW_ROOT="$HOME/.perl5"'
      echo '  [ -f "$PERLBREW_ROOT/etc/bashrc" ] && source "$PERLBREW_ROOT/etc/bashrc"'
      echo 'fi'
    } >> "$HOME/.bashrc"
  fi

  if [ -f "$PERLBREW_ROOT/etc/bashrc" ]; then
    sed -i 's/\$1/${1:-}/g' "$PERLBREW_ROOT/etc/bashrc" 2>/dev/null || true
    sed -i 's/\$PERLBREW_LIB/${PERLBREW_LIB:-}/g' "$PERLBREW_ROOT/etc/bashrc" 2>/dev/null || true
    sed -i 's/\$outsep/${outsep:-}/g' "$PERLBREW_ROOT/etc/bashrc" 2>/dev/null || true

    set +u
    source "$PERLBREW_ROOT/etc/bashrc"
    set -u
    log_success "Perlbrew installed and configured"

    log_info "Installing latest stable Perl version (this may take several minutes)..."
    PERLBREW_OUTPUT=$(perlbrew available 2>&1 || true)
    LATEST_PERL=$(echo "$PERLBREW_OUTPUT" | grep -oE 'perl-5\.[0-9]+\.[0-9]+' | head -1 || true)

    if [ -n "$LATEST_PERL" ]; then
      log_info "Installing $LATEST_PERL..."
      if ! perlbrew list | grep -q "$LATEST_PERL"; then
        perlbrew install "$LATEST_PERL" --notest || true
      fi

      if perlbrew list | grep -q "$LATEST_PERL"; then
        perlbrew switch "$LATEST_PERL"
        log_success "Perl version manager setup complete"
      fi
    fi
  fi
else
  log_info "Perlbrew already installed."
fi

# --- Ruby (via rbenv) ---
if [ ! -d "$HOME/.rbenv" ]; then
  log_info "Installing rbenv (Ruby version manager)..."

  # Install rbenv
  git clone https://github.com/rbenv/rbenv.git "$HOME/.rbenv"

  # Install ruby-build plugin
  mkdir -p "$HOME/.rbenv/plugins"
  git clone https://github.com/rbenv/ruby-build.git "$HOME/.rbenv/plugins/ruby-build"

  if ! grep -q 'rbenv init' "$HOME/.bashrc" 2>/dev/null; then
    {
      echo ''
      echo '# rbenv configuration'
      echo 'export PATH="$HOME/.rbenv/bin:$PATH"'
      echo 'eval "$(rbenv init - bash)"'
    } >> "$HOME/.bashrc"
  fi

  export PATH="$HOME/.rbenv/bin:$PATH"
  eval "$(rbenv init - bash)"
  log_success "rbenv installed and configured"

  # Install latest stable Ruby 3.x version (avoid pre-release 4.x)
  log_info "Installing latest stable Ruby version (this may take several minutes)..."
  LATEST_RUBY=$(rbenv install -l 2>/dev/null | grep -E '^\s*3\.[0-9]+\.[0-9]+$' | tail -1 | tr -d '[:space:]')

  if [ -n "$LATEST_RUBY" ]; then
    log_info "Installing Ruby $LATEST_RUBY..."
    if ! rbenv versions | grep -q "$LATEST_RUBY"; then
      rbenv install "$LATEST_RUBY"
    else
      log_info "Ruby $LATEST_RUBY already installed."
    fi

    rbenv global "$LATEST_RUBY"
    log_success "Ruby version manager setup complete"
    ruby --version
  fi
else
  log_info "rbenv already installed."
fi

# --- Swift ---
if ! command -v swift &>/dev/null; then
  log_info "Installing Swift..."

  ARCH=$(uname -m)

  # Swift uses different URL patterns for different architectures
  # For x86_64: ubuntu2404 directory, ubuntu24.04.tar.gz filename
  # For aarch64: ubuntu2404-aarch64 directory, ubuntu24.04-aarch64.tar.gz filename
  case "$ARCH" in
    x86_64)
      SWIFT_DIR="ubuntu2404"
      SWIFT_FILE_SUFFIX="ubuntu24.04"
      ;;
    aarch64)
      SWIFT_DIR="ubuntu2404-aarch64"
      SWIFT_FILE_SUFFIX="ubuntu24.04-aarch64"
      ;;
    *)
      SWIFT_DIR=""
      SWIFT_FILE_SUFFIX=""
      ;;
  esac

  if [ -n "$SWIFT_DIR" ]; then
    # Swift version for Ubuntu 24.04
    SWIFT_VERSION="6.0.3"
    SWIFT_RELEASE="RELEASE"
    SWIFT_PACKAGE="swift-${SWIFT_VERSION}-${SWIFT_RELEASE}-${SWIFT_FILE_SUFFIX}"
    SWIFT_URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/${SWIFT_DIR}/swift-${SWIFT_VERSION}-${SWIFT_RELEASE}/${SWIFT_PACKAGE}.tar.gz"

    log_info "Downloading Swift $SWIFT_VERSION for $ARCH..."
    log_info "URL: $SWIFT_URL"
    TEMP_DIR=$(mktemp -d)

    # Download with curl -L to follow redirects, and check if download succeeded
    if curl -fsSL "$SWIFT_URL" -o "$TEMP_DIR/swift.tar.gz"; then
      log_info "Installing Swift to $HOME/.swift..."
      mkdir -p "$HOME/.swift"
      tar -xzf "$TEMP_DIR/swift.tar.gz" -C "$TEMP_DIR"
      cp -r "$TEMP_DIR/${SWIFT_PACKAGE}/usr" "$HOME/.swift/"
      rm -rf "$TEMP_DIR"

      if ! grep -q 'swift' "$HOME/.bashrc" 2>/dev/null; then
        {
          echo ''
          echo '# Swift configuration'
          echo 'export PATH="$HOME/.swift/usr/bin:$PATH"'
        } >> "$HOME/.bashrc"
      fi

      export PATH="$HOME/.swift/usr/bin:$PATH"

      if command -v swift &>/dev/null; then
        log_success "Swift installed: $(swift --version | head -n1)"
      fi
    else
      log_error "Failed to download Swift from $SWIFT_URL"
      rm -rf "$TEMP_DIR"
    fi
  else
    log_warning "Swift installation skipped: unsupported architecture $ARCH"
  fi
else
  log_info "Swift already installed."
fi

# --- Kotlin (via SDKMAN) ---
# Load SDKMAN for current session if not already loaded
export SDKMAN_DIR="$HOME/.sdkman"
if [ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
  set +u
  source "$SDKMAN_DIR/bin/sdkman-init.sh"
  set -u

  if ! command -v kotlin &>/dev/null; then
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

# --- Load NVM and install Node.js ---
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# Ensure Node 20 is installed and active
if ! nvm ls 20 | grep -q 'v20'; then
  log_info "Installing Node.js 20..."
  nvm install 20
  log_success "Node.js 20 installed"
else
  log_info "Node.js 20 already installed"
fi
nvm use 20

# Update npm to latest version
log_info "Updating npm to latest version..."
npm install -g npm@latest --no-fund --silent
log_success "npm updated to latest version"

# --- Git setup with GitHub identity (only if authenticated) ---
if gh auth status &>/dev/null; then
  log_info "Configuring Git with GitHub identity..."
  git config --global user.name "$(gh api user --jq .login)"
  git config --global user.email "$(gh api user/emails --jq '.[] | select(.primary==true).email')"
  gh auth setup-git
  log_success "Git configured with GitHub identity"
else
  log_note "GitHub CLI not authenticated - skipping Git configuration"
fi

# --- Generate Installation Summary ---
log_step "Installation Summary"

echo ""
echo "System & Development Tools:"
if command -v gh &>/dev/null; then log_success "GitHub CLI: $(gh --version | head -n1)"; else log_warning "GitHub CLI: not found"; fi
if command -v gh-setup-git-identity &>/dev/null; then log_success "gh-setup-git-identity: $(gh-setup-git-identity --version 2>&1 | head -n1)"; else log_warning "gh-setup-git-identity: not found"; fi
if command -v glab &>/dev/null; then log_success "GitLab CLI: $(glab --version | head -n1)"; else log_warning "GitLab CLI: not found"; fi
if command -v glab-setup-git-identity &>/dev/null; then log_success "glab-setup-git-identity: $(glab-setup-git-identity --version 2>&1 | head -n1)"; else log_warning "glab-setup-git-identity: not found"; fi
if command -v git &>/dev/null; then log_success "Git: $(git --version)"; else log_warning "Git: not found"; fi
if command -v bun &>/dev/null; then log_success "Bun: $(bun --version)"; else log_warning "Bun: not found"; fi
if command -v deno &>/dev/null; then log_success "Deno: $(deno --version | head -n1)"; else log_warning "Deno: not found"; fi
if command -v node &>/dev/null; then log_success "Node.js: $(node --version)"; else log_warning "Node.js: not found"; fi
if command -v npm &>/dev/null; then log_success "NPM: $(npm --version)"; else log_warning "NPM: not found"; fi
if command -v python &>/dev/null; then log_success "Python: $(python --version)"; else log_warning "Python: not found"; fi
if command -v pyenv &>/dev/null; then log_success "Pyenv: $(pyenv --version)"; else log_warning "Pyenv: not found"; fi
if command -v go &>/dev/null; then log_success "Go: $(go version)"; else log_warning "Go: not found"; fi
if command -v rustc &>/dev/null; then log_success "Rust: $(rustc --version)"; else log_warning "Rust: not found"; fi
if command -v cargo &>/dev/null; then log_success "Cargo: $(cargo --version)"; else log_warning "Cargo: not found"; fi
if command -v java &>/dev/null; then log_success "Java: $(java -version 2>&1 | head -n1)"; else log_warning "Java: not found"; fi
if command -v sdk &>/dev/null; then log_success "SDKMAN: $(sdk version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo 'installed')"; else log_warning "SDKMAN: not found"; fi
if command -v elan &>/dev/null; then log_success "Elan: $(elan --version)"; else log_warning "Elan: not found"; fi
if command -v lean &>/dev/null; then log_success "Lean: $(lean --version)"; else log_warning "Lean: not found"; fi

if command -v R &>/dev/null; then log_success "R: $(R --version | head -n1)"; else log_warning "R: not found"; fi
if command -v ruby &>/dev/null; then log_success "Ruby: $(ruby --version)"; else log_warning "Ruby: not found"; fi
if command -v rbenv &>/dev/null; then log_success "rbenv: $(rbenv --version)"; else log_warning "rbenv: not found"; fi
if command -v swift &>/dev/null; then log_success "Swift: $(swift --version 2>&1 | head -n1)"; else log_warning "Swift: not found"; fi
if command -v kotlin &>/dev/null; then log_success "Kotlin: $(kotlin -version 2>&1 | head -n1)"; else log_warning "Kotlin: not found"; fi

if command -v brew &>/dev/null; then
  BREW_VERSION=$(brew --version 2>/dev/null | head -n1 || echo "version unknown")
  log_success "Homebrew: $BREW_VERSION"
else
  log_warning "Homebrew: not found"
fi

if command -v opam &>/dev/null; then log_success "Opam: $(opam --version)"; else log_warning "Opam: not found"; fi

if command -v php &>/dev/null; then
  PHP_VERSION=$(php --version 2>/dev/null | head -n1 || echo "unknown version")
  log_success "PHP: $PHP_VERSION"
else
  log_warning "PHP: not found"
fi

if command -v perl &>/dev/null; then
  log_success "Perl: $(perl --version | head -n 2 | tail -n 1 | sed 's/^[[:space:]]*//')"
else
  log_warning "Perl: not found"
fi

if [ -f "$HOME/.opam/opam-init/init.sh" ]; then
  source "$HOME/.opam/opam-init/init.sh" > /dev/null 2>&1 || true
fi

if rocq -v &>/dev/null; then
  log_success "Rocq: $(rocq -v 2>&1 | head -n1)"
elif command -v rocqc &>/dev/null; then
  log_success "Rocq: $(rocqc --version 2>&1 | head -n1)"
elif command -v coqc &>/dev/null; then
  log_success "Coq: $(coqc --version | head -n1)"
else
  log_warning "Rocq/Coq: not found"
fi

echo ""
echo "C/C++ Development Tools:"
if command -v make &>/dev/null; then log_success "Make: $(make --version | head -n1)"; else log_warning "Make: not found"; fi
if command -v cmake &>/dev/null; then log_success "CMake: $(cmake --version | head -n1)"; else log_warning "CMake: not found"; fi
if command -v gcc &>/dev/null; then log_success "GCC: $(gcc --version | head -n1)"; else log_warning "GCC: not found"; fi
if command -v g++ &>/dev/null; then log_success "G++: $(g++ --version | head -n1)"; else log_warning "G++: not found"; fi
if command -v clang &>/dev/null; then log_success "Clang: $(clang --version | head -n1)"; else log_warning "Clang: not found"; fi
if command -v clang++ &>/dev/null; then log_success "Clang++: $(clang++ --version | head -n1)"; else log_warning "Clang++: not found"; fi
if command -v llvm-config &>/dev/null; then log_success "LLVM: $(llvm-config --version)"; else log_warning "LLVM: not found"; fi
if command -v lld &>/dev/null; then log_success "LLD Linker: $(lld --version | head -n1)"; else log_warning "LLD Linker: not found"; fi

echo ""
echo "Assembly Tools:"
if command -v as &>/dev/null; then log_success "GNU Assembler (as): $(as --version | head -n1)"; else log_warning "GNU Assembler: not found"; fi
if command -v nasm &>/dev/null; then log_success "NASM: $(nasm -v)"; else log_warning "NASM: not found"; fi
if command -v llvm-mc &>/dev/null; then log_success "LLVM MC: installed (part of LLVM)"; else log_warning "LLVM MC: not found"; fi
if command -v fasm &>/dev/null; then log_success "FASM: installed"; else log_note "FASM: not available (x86-64 only)"; fi

echo ""

EOF_BOX_SCRIPT

# Make the script executable
chmod +x /tmp/box-user-setup.sh

# Execute as box user
if [ "$EUID" -eq 0 ]; then
  su - box -c "bash /tmp/box-user-setup.sh"
else
  sudo -i -u box bash /tmp/box-user-setup.sh
fi

# Clean up the temporary script
rm -f /tmp/box-user-setup.sh

# --- Cleanup after everything ---
log_step "Cleaning up"

cleanup_duplicate_apt_sources
apt_cleanup

log_step "Setup complete!"
log_success "All components installed successfully"
log_note "Please restart your shell or run: source ~/.bashrc"
