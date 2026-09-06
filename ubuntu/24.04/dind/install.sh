#!/usr/bin/env bash
set -euo pipefail

# Docker-in-Docker (dind-box) installation script
# Adds the Docker Engine, CLI, containerd, Buildx, and Compose plugins to any
# existing box image (js, essentials, full, or any language box).
#
# Usage: BASE_VARIANT=<name> bash ubuntu/24.04/dind/install.sh
#
# This script is idempotent and runs as root during image build.
# It also adds the box user to the docker group so the inner dockerd is usable
# without sudo from the user shell.
#
# References:
#   - https://docs.docker.com/engine/install/ubuntu/
#   - https://github.com/cruizba/ubuntu-dind
#   - docs/case-studies/issue-80/CASE-STUDY.md

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../common.sh" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/../common.sh"
elif [ -f "/tmp/common.sh" ]; then
  # shellcheck disable=SC1091
  source "/tmp/common.sh"
else
  log_info() { echo "[*] $1"; }
  log_success() { echo "[✓] $1"; }
  log_warning() { echo "[!] $1"; }
  log_error() { echo "[✗] $1"; }
  log_step() { echo "==> $1"; }
  command_exists() { command -v "$1" &>/dev/null; }
  maybe_sudo() { if [ "$EUID" -eq 0 ]; then "$@"; elif command -v sudo &>/dev/null; then sudo "$@"; else "$@"; fi; }
  apt_update_with_retry() { maybe_sudo apt-get update -y -o Acquire::Retries=3; }
fi

log_step "Installing Docker-in-Docker (dind-box) layer"

# --- Pre-flight ---
if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
  log_error "This script requires sudo access."
  exit 1
fi

ARCH="$(dpkg --print-architecture)"
log_info "Detected architecture: $ARCH"

# --- Install Docker Engine, CLI, containerd, Buildx, Compose ---
log_step "Adding Docker apt repository"

export DEBIAN_FRONTEND=noninteractive

apt_update_with_retry
maybe_sudo apt-get install -y \
  ca-certificates curl gnupg lsb-release iptables uidmap

maybe_sudo install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | maybe_sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  maybe_sudo chmod a+r /etc/apt/keyrings/docker.gpg
fi

UBUNTU_CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-noble}}")"
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
  | maybe_sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

log_step "Installing docker-ce, docker-ce-cli, containerd.io, buildx, compose"
apt_update_with_retry
maybe_sudo apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin \
  fuse-overlayfs

log_success "Docker packages installed"

# --- Ensure docker group exists and add box user ---
log_step "Configuring docker group for box user"
if ! getent group docker >/dev/null; then
  maybe_sudo groupadd docker
fi
if id box &>/dev/null; then
  maybe_sudo usermod -aG docker box
  log_success "Added box user to docker group"
else
  log_warning "box user not present yet; skipping group membership"
fi

# --- Allow the box-owned entrypoint to perform only the root setup dind needs ---
if id box &>/dev/null; then
  log_step "Configuring scoped sudo for dind entrypoint"
  printf '%s\n' \
    'box ALL=(root) NOPASSWD: /usr/bin/dockerd, /usr/bin/chgrp, /usr/bin/chmod, /usr/bin/mkdir' \
    | maybe_sudo install -m 0440 -o root -g root /dev/stdin /etc/sudoers.d/box-dind
  if command_exists visudo; then
    maybe_sudo visudo -cf /etc/sudoers.d/box-dind >/dev/null
  fi
  maybe_sudo install -m 0644 -o box -g box /dev/null /var/log/dockerd.log
  log_success "Configured dind sudoers entry and writable dockerd log"
else
  log_warning "box user not present; skipping dind sudoers entry"
fi

# --- Install dind entrypoint ---
log_step "Installing dind entrypoint"
maybe_sudo install -m 0755 "$SCRIPT_DIR/dind-entrypoint.sh" /usr/local/bin/dind-entrypoint.sh
log_success "dind entrypoint installed at /usr/local/bin/dind-entrypoint.sh"

# --- Persist marker so users / tests can detect dind-box images ---
maybe_sudo mkdir -p /etc/box
echo "dind-box" | maybe_sudo tee /etc/box/variant >/dev/null

# --- Cleanup ---
log_step "Cleaning up apt caches"
maybe_sudo apt-get clean
maybe_sudo rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

log_step "dind-box layer installation complete"
log_success "Run with: docker run --privileged konard/<base>-dind"
