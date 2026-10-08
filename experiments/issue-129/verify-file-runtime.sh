#!/usr/bin/env bash
# Exercise the essentials package request in Ubuntu without rebuilding every
# language. CI still builds and tests the complete Box and DinD image chains.
# Usage: bash experiments/issue-129/verify-file-runtime.sh [--host]
# --host executes the acceptance payload with the host file utility instead.
# ESSENTIALS_INSTALLER can point at an older installer to reproduce the failure.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
IMAGE="box-file-issue129-$$"
cleanup() {
  docker image rm "$IMAGE" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
if [ "${1:-}" = --host ]; then
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/docker" <<'HOST'
#!/usr/bin/env bash
# Only the process transport is replaced; file and its magic database are real.
exec bash -euc "${!#}"
HOST
  chmod +x "$TMP/bin/docker"
  PATH="$TMP/bin:$PATH" bash "$ROOT/scripts/ci/test-box.sh" attachments host
  exit
fi
cp "${ESSENTIALS_INSTALLER:-$ROOT/ubuntu/24.04/essentials-box/install.sh}" "$TMP/install.sh"
cat >"$TMP/Dockerfile" <<'DOCKERFILE'
FROM ubuntu:24.04
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive
COPY install.sh /tmp/install.sh
RUN sed -n '/^# Core system tools$/,/^# Common development libraries/{ /^# Common development libraries/d; p; }' \
      /tmp/install.sh > /tmp/packages.sh && \
    apt-get update && \
    maybe_sudo() { "$@"; } && source /tmp/packages.sh && \
    useradd -m -s /bin/bash box && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/*.sh
USER box
DOCKERFILE
docker build --memory=512m -t "$IMAGE" "$TMP"
bash "$ROOT/scripts/ci/test-box.sh" attachments "$IMAGE"
