#!/usr/bin/env bash
# Integration test for issue #112 fixes #1 and #3, executed in a throwaway
# ubuntu:24.04 container (no image build, no Playwright download):
#
#   1. resolve_node_lts_major() returns the *current* Node LTS from
#      nodejs.org/dist/index.json, not a hardcoded major.
#   2. `nvm alias default` points at that major, so a fresh login shell runs the
#      same Node the build installed.
#   3. The prune loop leaves exactly one directory under ~/.nvm/versions/node
#      even when an older Node was installed first, and
#      assert_single_runtime_versions() agrees.
#
# Usage: bash experiments/node-lts-integration-test.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${TEST_BASE_IMAGE:-ubuntu:24.04}"

echo "==> Running Node LTS integration test in $IMAGE"

docker run --rm \
  -v "$REPO_ROOT/ubuntu/24.04/common.sh:/tmp/common.sh:ro" \
  "$IMAGE" bash -euo pipefail -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null
    apt-get install -y -qq curl ca-certificates >/dev/null

    . /tmp/common.sh

    NODE_MAJOR="$(resolve_node_lts_major)"
    echo "resolved Node LTS major: $NODE_MAJOR"
    case "$NODE_MAJOR" in
      ""|*[!0-9]*) echo "FAIL: resolver did not return a numeric major"; exit 1 ;;
    esac
    if [ "$NODE_MAJOR" -lt 22 ]; then
      echo "FAIL: resolved major $NODE_MAJOR is older than Node 22 (the oldest"
      echo "      LTS still in maintenance when issue #112 was filed)"
      exit 1
    fi

    NVM_INSTALL_VERSION="$(resolve_nvm_version)"
    echo "resolved nvm tag: $NVM_INSTALL_VERSION"
    curl -fsSL -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_INSTALL_VERSION}/install.sh" 2>/dev/null | bash >/dev/null 2>&1

    export NVM_DIR="$HOME/.nvm"
    . "$NVM_DIR/nvm.sh"

    # Simulate the stale state the boxes were in: an older Node installed first.
    nvm install 20 >/dev/null 2>&1
    nvm install "$NODE_MAJOR" >/dev/null 2>&1
    nvm use "$NODE_MAJOR" >/dev/null
    nvm alias default "$NODE_MAJOR" >/dev/null

    NODE_KEEP="$(nvm current)"
    for installed in $(ls -1 "$NVM_DIR/versions/node"); do
      if [ "$installed" != "$NODE_KEEP" ]; then
        nvm uninstall "$installed" >/dev/null
      fi
    done

    echo "--- assertions ---"
    failed=0

    count="$(ls -1 "$NVM_DIR/versions/node" | wc -l)"
    if [ "$count" -eq 1 ]; then
      echo "PASS: exactly one Node under ~/.nvm/versions/node"
    else
      echo "FAIL: $count Node versions under ~/.nvm/versions/node"; failed=1
    fi

    active="$(node --version)"
    if [ "${active#v}" = "${active#v$NODE_MAJOR.}" ]; then
      echo "FAIL: active node $active is not major $NODE_MAJOR"; failed=1
    else
      echo "PASS: active node is $active"
    fi

    # A fresh login shell must agree with the build (the nvm default alias).
    login_node="$(bash -lc "node --version" 2>/dev/null || echo none)"
    if [ "$login_node" = "$active" ]; then
      echo "PASS: login shell runs the same Node ($login_node)"
    else
      echo "FAIL: login shell runs $login_node, build installed $active"; failed=1
    fi

    if assert_single_runtime_versions; then
      echo "PASS: assert_single_runtime_versions accepts the pruned tree"
    else
      echo "FAIL: assert_single_runtime_versions rejected the pruned tree"; failed=1
    fi

    # Negative control: the invariant must actually fire when a second runtime
    # is present, otherwise the assertions above prove nothing.
    nvm install 20 >/dev/null 2>&1
    if assert_single_runtime_versions >/dev/null 2>&1; then
      echo "FAIL: assert_single_runtime_versions passed with two Node versions"; failed=1
    else
      echo "PASS: assert_single_runtime_versions rejects two Node versions"
    fi

    exit "$failed"
  '

echo "==> Node LTS integration test passed"
