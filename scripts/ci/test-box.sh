#!/usr/bin/env bash
# Acceptance checks for one built box image.
#
# Usage: scripts/ci/test-box.sh PROFILE IMAGE
#
#   PROFILE  js | essentials | full | <language>
#            (<language> is any directory under ubuntu/24.04/ that ships a
#             single runtime: python, go, rust, java, kotlin, ruby, php, perl,
#             swift, lean, rocq, ...)
#   IMAGE    any image reference docker can run - a locally built tag in the
#            pre-merge jobs, a pushed registry reference in the release job.
#
# Issue #115: one script drives every place CI verifies an image, so the checks
# cannot drift apart. They had: the release smoke test on the *pushed* image ran
# 22 of the 29 checks the pre-merge full-box test ran, so the artifact users pull
# was verified less thoroughly than the candidate it was built from (no
# gh-setup-git-identity, no glab-setup-git-identity, no .php-install-method, and
# none of the issue #112 freshness / one-version-per-language invariants), and
# nothing reported the difference - a textbook CI false negative. The full box
# also shipped Rocq that no job had ever run.
#
# Environment:
#   BOX_VERBOSE=1          echo every docker invocation before running it
#                          (default: off)
#   BOX_CHECK_FRESHNESS=0  skip the assertions that resolve the current upstream
#                          release over the network. For running this script on
#                          a laptop without connectivity only - CI must never
#                          set it, which experiments/test-issue115-test-box.sh
#                          asserts.
#   PHP_METHOD_REFERENCE_IMAGE
#                          also print /home/box/.php-install-method from this
#                          second image, to compare a standalone language box
#                          against the composed box that copied from it.

set -euo pipefail

PROFILE="${1:-}"
IMAGE="${2:-}"

if [ -z "$PROFILE" ] || [ -z "$IMAGE" ]; then
  echo "::error title=test-box.sh::usage: scripts/ci/test-box.sh PROFILE IMAGE" >&2
  exit 2
fi

VERBOSE="${BOX_VERBOSE:-0}"
CHECK_FRESHNESS="${BOX_CHECK_FRESHNESS:-1}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

CHECKS_RUN=0

vlog() {
  if [ "$VERBOSE" = "1" ]; then
    printf '[test-box] %s\n' "$*" >&2
  fi
}

fail() {
  echo "::error title=test-box.sh ($PROFILE)::$*" >&2
  exit 1
}

# Every check runs the image through one of these two helpers, so the count
# printed at the end cannot disagree with what actually ran.
box() {
  CHECKS_RUN=$((CHECKS_RUN + 1))
  vlog "docker run --rm $IMAGE $*"
  docker run --rm "$IMAGE" "$@"
}

box_sh() {
  CHECKS_RUN=$((CHECKS_RUN + 1))
  vlog "docker run --rm $IMAGE bash -c $1"
  docker run --rm "$IMAGE" bash -c "$1"
}

# Same, with the network taken away. A `<tool> --version` that passes only
# because the tool downloads itself on first use is a false negative: CI sees a
# version string, the user sees a 200 MB download, and offline or behind a
# proxy the box simply does not work. Anything checked through this helper has
# to be *in the image* (issue #115).
box_offline_sh() {
  CHECKS_RUN=$((CHECKS_RUN + 1))
  vlog "docker run --rm --network none $IMAGE bash -c $1"
  docker run --rm --network none "$IMAGE" bash -c "$1"
}

# --- per-language checks -----------------------------------------------------
# Used by both the per-language boxes and the full box, so a language can never
# be verified in one and forgotten in the other.

check_language() {
  case "$1" in
    python)
      box python3 --version
      box pip3 --version
      ;;
    go)
      box go version
      ;;
    rust)
      box rustc --version
      box cargo --version
      box rustup --version
      ;;
    java)
      box java -version
      ;;
    kotlin)
      box kotlin -version
      ;;
    ruby)
      box ruby --version
      box gem --version
      ;;
    php)
      box php --version
      echo "--- PHP install method ---"
      box cat /home/box/.php-install-method
      ;;
    perl)
      box perl --version
      ;;
    swift)
      box swift --version
      ;;
    lean)
      # Offline on purpose. elan-init records the default toolchain without
      # installing it, so every box built before issue #115 shipped elan and no
      # Lean: `lean --version` printed a version only after downloading
      # lean-4.33.1-linux.tar.zst at test time, and CI called that a pass.
      # Verified against konard/box:latest and konard/box-lean:latest, whose
      # ~/.elan/toolchains does not exist at all.
      box_offline_sh 'lean --version'
      # ... and the toolchain is registered with elan, not just unpacked
      # somewhere: `elan toolchain list` prints "no installed toolchains" in
      # exactly the broken images above.
      box_offline_sh 'elan toolchain list | grep -qv "no installed toolchains" \
        || { echo "::error::elan has no installed toolchain; the image downloads Lean on first use"; exit 1; }
        elan toolchain list'
      # The default has to be the resolved toolchain, not the `stable` alias:
      # an alias is looked up over the network on every invocation, so a box
      # defaulting to one prints "warning: failed to query latest release" at
      # every `lean` run without connectivity.
      box_offline_sh 'out="$(lean --version 2>&1)"; printf "%s\n" "$out"
        case "$out" in
          *warning:*) echo "::error::lean warns offline; the default toolchain is an unresolved alias"; exit 1 ;;
        esac'
      ;;
    rocq)
      # Rocq 9 renamed the binary; older images only ship coqc.
      box_sh 'rocq --version 2>/dev/null || coqc --version'
      # The box advertises "Opam, Rocq prover": a Rocq box that cannot install
      # another Rocq package is half an image. konard/box:latest shipped exactly
      # that - `rocq --version` worked, `opam --version` said "not found",
      # because the full box COPYs ~/.opam but not the binary in ~/.local/bin
      # (issue #115).
      box opam --version
      ;;
    dotnet)
      box dotnet --version
      ;;
    r)
      box Rscript --version
      ;;
    cpp)
      box gcc --version
      box g++ --version
      box cmake --version
      box clang --version
      box ld.lld --version
      ;;
    assembly)
      box nasm -v
      # fasm exists on x86_64 only, and prints its banner with exit status 1,
      # so neither `fasm` alone nor a bare pipeline would report its absence.
      # shellcheck disable=SC2016  # $(uname -m) must run inside the container
      box_sh 'if [ "$(uname -m)" = x86_64 ]; then
                fasm 2>&1 | head -1 | grep -q "flat assembler" \
                  || { echo "::error::fasm is missing from an x86_64 image"; exit 1; }
                fasm 2>&1 | head -1
              else
                echo "fasm is not packaged for $(uname -m); NASM only"
              fi'
      ;;
    *)
      fail "unknown language: $1"
      ;;
  esac
}

check_cli_tools() {
  echo "--- CLI tools ---"
  box gh --version
  box glab --version
  box gh-setup-git-identity --version
  box glab-setup-git-identity --version
}

# --- freshness and one-version-per-language invariants (issue #112) -----------

expected_node_major() {
  # shellcheck source=/dev/null
  . "$REPO_ROOT/ubuntu/24.04/common.sh"
  resolve_node_lts_major
}

check_node_freshness() {
  local actual="$1"
  local expected
  expected="$(expected_node_major)"
  echo "image ships Node $actual, expected major $expected"
  case "$actual" in
    v"$expected".*) ;;
    *) fail "image ships Node $actual, expected Node $expected" ;;
  esac
}

check_full_box_invariants() {
  echo ""
  echo "--- Runtime freshness and one-version-per-language invariant (issue #112) ---"
  if [ "$CHECK_FRESHNESS" != "1" ]; then
    echo "::warning title=test-box.sh::BOX_CHECK_FRESHNESS=0, skipping the freshness assertions"
  else
    check_node_freshness "$(docker run --rm "$IMAGE" node --version)"
  fi

  # The stale `stable` next to a pinned toolchain is the 2.2 GB ~/.rustup from
  # issue #112: assert one toolchain, and that it is the one rustup itself
  # considers current. `rustup check` also reports updates for the rustup binary,
  # which is not what this asserts - toolchain lines only.
  box rustup toolchain list
  local toolchains
  toolchains="$(docker run --rm "$IMAGE" rustup toolchain list | grep -c .)"
  [ "$toolchains" -eq 1 ] || fail "$toolchains rustup toolchains in the image, expected 1"

  if [ "$CHECK_FRESHNESS" = "1" ]; then
    if docker run --rm "$IMAGE" rustup check | grep -v "^rustup " | grep "Update available"; then
      fail "the shipped Rust stable is not the current release"
    fi
  fi

  # common.sh is mounted rather than baked in, so this asserts the invariant as
  # the working tree defines it today, not as the image defined it at build time.
  CHECKS_RUN=$((CHECKS_RUN + 1))
  docker run --rm -v "$REPO_ROOT/ubuntu/24.04/common.sh:/tmp/common.sh:ro" \
    "$IMAGE" bash -c '. /tmp/common.sh && assert_single_runtime_versions'
}

# --- profiles ----------------------------------------------------------------

case "$PROFILE" in
  js)
    echo "=== Testing JS box: $IMAGE ==="
    # box-js has no entrypoint, so each runtime is activated explicitly.
    # shellcheck disable=SC2016  # $HOME/$PATH must expand inside the container
    box_sh '. $HOME/.nvm/nvm.sh && node --version'
    # shellcheck disable=SC2016
    box_sh 'export PATH=$HOME/.bun/bin:$PATH && bun --version'
    # shellcheck disable=SC2016
    box_sh 'export PATH=$HOME/.deno/bin:$PATH && deno --version'

    echo ""
    echo "--- Node freshness and one-version invariant (issue #112) ---"
    if [ "$CHECK_FRESHNESS" != "1" ]; then
      echo "::warning title=test-box.sh::BOX_CHECK_FRESHNESS=0, skipping the freshness assertions"
    else
      EXPECTED_NODE="$(expected_node_major)"
      echo "expected Node major: $EXPECTED_NODE"
      CHECKS_RUN=$((CHECKS_RUN + 1))
      docker run --rm -e EXPECTED_NODE="$EXPECTED_NODE" "$IMAGE" bash -c '
        set -e
        . "$HOME/.nvm/nvm.sh"
        actual="$(node --version)"
        echo "image ships $actual, nvm default alias -> $(nvm version default)"
        case "$actual" in
          v"$EXPECTED_NODE".*) ;;
          *) echo "::error::image ships $actual, expected Node $EXPECTED_NODE"; exit 1 ;;
        esac
        # Without an explicit default alias the image could ship one Node and
        # activate another (issue #112).
        [ "$(nvm version default)" = "$actual" ] \
          || { echo "::error::nvm default alias is $(nvm version default), active is $actual"; exit 1; }
        count="$(ls -1 "$HOME/.nvm/versions/node" | wc -l)"
        [ "$count" -eq 1 ] || { echo "::error::$count Node versions in the image"; exit 1; }
      '
    fi
    ;;

  essentials)
    echo "=== Testing essentials box: $IMAGE ==="
    check_cli_tools
    ;;

  full)
    echo "=== Testing full box: $IMAGE ==="
    echo "The image's entrypoint initialises every language environment."

    echo "--- JavaScript/TypeScript runtimes ---"
    box node --version
    box bun --version
    box deno --version

    # Every language the full box composes - including the four whose
    # standalone boxes are tested but never published (issue #115); the full
    # box installs their toolchains, so it has to answer for them.
    for language in python go rust java kotlin ruby php perl swift lean rocq \
      cpp assembly dotnet r; do
      echo "--- $language ---"
      check_language "$language"
    done

    check_cli_tools

    # expect: interactive automation tool (issue #64)
    box expect -v

    check_full_box_invariants

    if [ -n "${PHP_METHOD_REFERENCE_IMAGE:-}" ]; then
      echo ""
      echo "--- PHP install method in $PHP_METHOD_REFERENCE_IMAGE (must match the full box) ---"
      CHECKS_RUN=$((CHECKS_RUN + 1))
      docker run --rm "$PHP_METHOD_REFERENCE_IMAGE" cat /home/box/.php-install-method
    fi
    ;;

  *)
    echo "=== Testing $PROFILE box: $IMAGE ==="
    check_language "$PROFILE"
    ;;
esac

echo ""
echo "=== $PROFILE box tests passed for $IMAGE ($CHECKS_RUN checks) ==="
