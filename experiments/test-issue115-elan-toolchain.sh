#!/usr/bin/env bash
# test-issue115-elan-toolchain.sh
#
# Issue #115. Every box that advertises Lean shipped elan and no Lean.
#
# elan's installer records the default toolchain and exits 0 *without*
# installing it. Reproduced in a clean ubuntu:24.04 container:
#
#   $ curl https://elan.lean-lang.org/elan-init.sh -sSf | sh -s -- -y \
#       --default-toolchain stable
#   info: downloading installer
#   info: default toolchain set to 'stable'
#   $ echo $?
#   0
#   $ ls /root/.elan/toolchains
#   ls: cannot access '/root/.elan/toolchains': No such file or directory
#   $ elan toolchain list
#   no installed toolchains
#
# ubuntu/24.04/lean/install.sh ran exactly that and logged "Lean installed
# successfully", so the build passed. The published images agree:
# konard/box-lean:latest has no ~/.elan/toolchains and a 13 MB ~/.elan, and in
# konard/box:latest `lean --version` prints
#
#   info: downloading https://releases.lean-lang.org/lean4/v4.33.1/lean-4.33.1-linux.tar.zst
#   Lean (version 4.33.1, ...)
#
# CI's `docker run box lean --version` therefore passed by *fetching Lean at
# test time* - a false negative of the exact kind this issue is about - while a
# user offline, behind a proxy, or on a rate-limited network got a box whose
# headline tool does not run.
#
# The fix has two halves and this suite pins both:
#   1. install.sh installs the toolchain explicitly and fails the build if none
#      is installed, so a silent no-op cannot ship again;
#   2. test-box.sh checks Lean with the network taken away, so "it downloads
#      itself" can never be mistaken for "it is installed".
#
# Usage:
#   bash experiments/test-issue115-elan-toolchain.sh
#   ELAN_LIVE=1 bash experiments/test-issue115-elan-toolchain.sh   # + docker
#
# The live half is opt-in: it needs docker and pulls ~200 MB from
# releases.lean-lang.org. The static half is what runs in CI.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

INSTALL="ubuntu/24.04/lean/install.sh"
TEST_BOX="scripts/ci/test-box.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- 1. install.sh actually installs a toolchain ------------------------------

if [ -f "$INSTALL" ]; then
  pass "$INSTALL exists"
else
  fail "$INSTALL is missing"
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

SRC="$(cat "$INSTALL")"

if [[ "$SRC" == *"elan toolchain install"* ]]; then
  pass "install.sh runs 'elan toolchain install' (elan-init alone installs nothing)"
else
  fail "install.sh never runs 'elan toolchain install'; the image would ship elan and no Lean"
fi

if [[ "$SRC" == *"elan default"* ]]; then
  pass "install.sh sets the default toolchain explicitly"
else
  fail "install.sh does not run 'elan default'"
fi

# ... and to the resolved toolchain, not to the alias. `elan default stable`
# leaves the alias in ~/.elan/settings.toml, and elan then resolves it over the
# network on every `lean` invocation:
#   warning: failed to query latest release, using existing version '...'
if [[ "$SRC" == *'elan default "$RESOLVED_TOOLCHAIN"'* ]]; then
  pass "the default is the resolved toolchain, so lean never queries the network"
else
  fail "install.sh defaults to the requested alias; every offline 'lean' run will warn"
fi

if [[ "$SRC" == *"elan toolchain list"* ]]; then
  pass "install.sh asserts a toolchain is installed before declaring success"
else
  fail "install.sh does not verify the toolchain; a silent no-op would ship again"
fi

# The version policy from issue #112: every runtime version is resolved at build
# time and overridable, never hardcoded.
if [[ "$SRC" == *'${LEAN_VERSION:-'* ]]; then
  pass "the toolchain is overridable via LEAN_VERSION (issue #112 version policy)"
else
  fail "install.sh hardcodes the Lean toolchain; LEAN_VERSION should override it"
fi

# The assertion has to run after the install, not before it - order matters more
# than presence here.
# Comment lines quote both commands (the reproduction above does), so match
# only lines that are code.
code_line() { grep -n "$1" "$INSTALL" | grep -v ':[[:space:]]*#' | head -1 | cut -d: -f1; }
INSTALL_LINE="$(code_line 'elan toolchain install')"
ASSERT_LINE="$(code_line 'elan toolchain list')"
if [ -n "$INSTALL_LINE" ] && [ -n "$ASSERT_LINE" ] && [ "$ASSERT_LINE" -gt "$INSTALL_LINE" ]; then
  pass "the toolchain assertion runs after the install (line $ASSERT_LINE > $INSTALL_LINE)"
else
  fail "the toolchain assertion does not follow the install (install=$INSTALL_LINE assert=$ASSERT_LINE)"
fi

# `elan` lives in ~/.elan/bin, which install.sh appends to ~/.bashrc - and
# ~/.bashrc is not read by the rest of this very script. Without an explicit
# export the install lines above would be "command not found".
if [[ "$SRC" == *'export PATH="$HOME/.elan/bin:$PATH"'* ]]; then
  pass "install.sh exports ~/.elan/bin for its own remaining commands"
else
  fail "install.sh relies on ~/.bashrc for elan on PATH; it is not sourced here"
fi

# --- 2. test-box.sh checks Lean offline ---------------------------------------

if [ -f "$TEST_BOX" ]; then
  pass "$TEST_BOX exists"
else
  fail "$TEST_BOX is missing"
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

BOX_SRC="$(cat "$TEST_BOX")"

if [[ "$BOX_SRC" == *"--network none"* ]]; then
  pass "test-box.sh has an offline helper (docker run --network none)"
else
  fail "test-box.sh has no offline helper; a download-on-first-use tool still passes"
fi

LEAN_CASE="$(awk '/^    lean\)$/ {inc=1} inc {print} inc && /^      ;;$/ {exit}' "$TEST_BOX")"

if [ -n "$LEAN_CASE" ]; then
  pass "test-box.sh has a lean) case"
else
  fail "test-box.sh has no lean) case"
fi

if [[ "$LEAN_CASE" == *"box_offline_sh"* ]]; then
  pass "the lean checks run offline"
else
  fail "the lean checks run with the network up; they would pass on a Lean-less image"
fi

if [[ "$LEAN_CASE" == *"lean --version"* ]]; then
  pass "the lean checks run 'lean --version'"
else
  fail "the lean checks never run lean itself"
fi

if [[ "$LEAN_CASE" == *"elan toolchain list"* ]]; then
  pass "the lean checks assert elan has an installed toolchain"
else
  fail "the lean checks do not look at 'elan toolchain list'"
fi

# A network-enabled `box lean --version` would defeat the offline one by
# populating nothing - but it is also the exact line that used to lie. It must
# be gone.
if [[ "$LEAN_CASE" == *$'\n      box lean --version'* ]]; then
  fail "the online 'box lean --version' check is still there"
else
  pass "the online 'box lean --version' check is gone"
fi

# --- 3. live reproduction (opt-in) --------------------------------------------

if [ "${ELAN_LIVE:-0}" = "1" ]; then
  if ! command -v docker >/dev/null 2>&1; then
    fail "ELAN_LIVE=1 but docker is not available"
  else
    echo "--- live: elan-init with --default-toolchain installs nothing ---"
    BROKEN="$(docker run --rm ubuntu:24.04 bash -c '
      apt-get update -qq >/dev/null 2>&1
      apt-get install -y -qq curl ca-certificates >/dev/null 2>&1
      curl https://elan.lean-lang.org/elan-init.sh -sSf \
        | sh -s -- -y --default-toolchain stable >/dev/null 2>&1
      "$HOME/.elan/bin/elan" toolchain list 2>&1' || true)"
    echo "elan toolchain list -> $BROKEN"
    if [[ "$BROKEN" == *"no installed toolchains"* ]]; then
      pass "reproduced upstream behaviour: --default-toolchain installs no toolchain"
    else
      fail "elan-init now installs the toolchain ($BROKEN); the workaround may be droppable"
    fi

    echo "--- live: the fix installs it ---"
    FIXED="$(docker run --rm ubuntu:24.04 bash -c '
      apt-get update -qq >/dev/null 2>&1
      apt-get install -y -qq curl ca-certificates >/dev/null 2>&1
      curl https://elan.lean-lang.org/elan-init.sh -sSf \
        | sh -s -- -y --default-toolchain stable >/dev/null 2>&1
      export PATH="$HOME/.elan/bin:$PATH"
      elan toolchain install stable >/dev/null 2>&1
      elan default stable >/dev/null 2>&1
      elan toolchain list 2>&1' || true)"
    echo "elan toolchain list -> $FIXED"
    if [[ "$FIXED" == *"no installed toolchains"* ]] || [ -z "$FIXED" ]; then
      fail "'elan toolchain install stable' did not install a toolchain"
    else
      pass "'elan toolchain install stable' installs a toolchain"
    fi
  fi
else
  echo "(skipping the live docker reproduction; set ELAN_LIVE=1 to run it)"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
