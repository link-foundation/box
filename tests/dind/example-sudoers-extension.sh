#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/dind/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_docker

tmp_dir="$(mktemp -d)"
derived_image="${DIND_EXAMPLE_ID}-sudoers"

register_temp_dir "$tmp_dir"
register_image "$derived_image"

cat >"$tmp_dir/Dockerfile" <<'DOCKERFILE'
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

USER root
RUN printf '%s\n' 'box ALL=(root) NOPASSWD: /usr/bin/id' \
      | install -m 0440 -o root -g root /dev/stdin /etc/sudoers.d/box-dind-example-id && \
    if command -v visudo >/dev/null 2>&1; then visudo -cf /etc/sudoers.d/box-dind-example-id >/dev/null; fi

USER box
ENV HOME=/home/box
DOCKERFILE

log "building a derived image with a separate sudoers extension"
docker build --build-arg BASE_IMAGE="$DIND_IMAGE" -t "$derived_image" "$tmp_dir" >/dev/null

root_uid="$(docker run --rm --entrypoint=/bin/bash "$derived_image" -lc 'sudo -n /usr/bin/id -u' | tr -d '\r')"
if [ "$root_uid" != "0" ]; then
  fail "expected sudoers extension to allow /usr/bin/id as root, got uid ${root_uid}"
fi

log "separate sudoers extension allows only the added binary"
