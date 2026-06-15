#!/usr/bin/env bash
# Unit test for the JS image's network-bound build-step retry wrapper
# (issue #104 / PR #105).
#
# Two transient, third-party failures used to abort the whole JS image build with
# no retry:
#   * the lean (pr-test / language) build died on a transient npm registry error
#     during `npm install -g npm@latest`; and
#   * the dind-swift build died on `playwright install ... msedge ...` when
#     packages.microsoft.com served an invalid GPG key body
#     ("gpg: no valid OpenPGP data found" -> "Failed to install msedge").
# js/install.sh now routes every such network-bound step through run_with_retry(),
# which retries with exponential backoff. This test asserts both the POLICY (the
# wrapper exists and wraps every npm install AND the playwright browser download)
# and the BEHAVIOR (it retries, then succeeds or gives up).
set -euo pipefail

cd "$(dirname "$0")/.."

install="ubuntu/24.04/js/install.sh"
fail=0

assert_grep() {  # extended-regex, description
  if grep -qE "$1" "$install"; then
    echo "  PASS: $2"
  else
    echo "  FAIL: $2"
    fail=1
  fi
}

assert_not_grep() {  # extended-regex, description
  if grep -qE "$1" "$install"; then
    echo "  FAIL: $2"
    fail=1
  else
    echo "  PASS: $2"
  fi
}

echo "== Case 1: js/install.sh defines and uses run_with_retry =="
assert_grep '^run_with_retry\(\) \{' "defines run_with_retry()"
assert_grep 'BUILD_RETRY_MAX_RETRIES' "retry budget is overridable (BUILD_RETRY_MAX_RETRIES)"
assert_grep 'BUILD_RETRY_INITIAL_DELAY' "initial delay is overridable (BUILD_RETRY_INITIAL_DELAY)"
assert_grep 'run_with_retry npm install -g npm@latest' "wraps the npm@latest self-update"
assert_grep 'run_with_retry npm install -g playwright' "wraps the playwright/puppeteer CLI install"
assert_grep 'run_with_retry playwright install ' "wraps the playwright browser binary download (msedge/chrome flake)"

echo "== Case 2: no un-retried network install remains =="
# A bare line that *starts* with `npm install -g` or `playwright install` would be
# un-retried; the wrapped calls start with `run_with_retry`, so they must not match.
assert_not_grep '^[[:space:]]*npm install -g' "every 'npm install -g' goes through run_with_retry"
assert_not_grep '^[[:space:]]*playwright install ' "every 'playwright install' goes through run_with_retry"

echo "== Case 3: run_with_retry retry semantics =="
# install.sh as a whole performs real installs, so load just the function body.
fn="$(awk '/^run_with_retry\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$install")"
eval "$fn"
# Stub the helpers the wrapper leans on so the test stays fast and silent.
log_warning() { :; }
sleep() { :; }

attempts=0
succeed_now() { attempts=$((attempts + 1)); return 0; }
if BUILD_RETRY_INITIAL_DELAY=0 run_with_retry succeed_now && [ "$attempts" -eq 1 ]; then
  echo "  PASS: succeeds on the first attempt without retrying"
else
  echo "  FAIL: expected exactly one attempt, got ${attempts}"
  fail=1
fi

attempts=0
fail_then_succeed() { attempts=$((attempts + 1)); [ "$attempts" -ge 3 ]; }
if BUILD_RETRY_INITIAL_DELAY=0 BUILD_RETRY_MAX_RETRIES=5 run_with_retry fail_then_succeed \
  && [ "$attempts" -eq 3 ]; then
  echo "  PASS: retries transient failures and ultimately succeeds (3 attempts)"
else
  echo "  FAIL: expected success on the 3rd attempt, got ${attempts}"
  fail=1
fi

attempts=0
always_fail() { attempts=$((attempts + 1)); return 1; }
if BUILD_RETRY_INITIAL_DELAY=0 BUILD_RETRY_MAX_RETRIES=3 run_with_retry always_fail; then
  echo "  FAIL: should have given up after exhausting retries"
  fail=1
elif [ "$attempts" -eq 3 ]; then
  echo "  PASS: gives up after BUILD_RETRY_MAX_RETRIES attempts and returns non-zero"
else
  echo "  FAIL: expected exactly 3 attempts before giving up, got ${attempts}"
  fail=1
fi

echo ""
if [ "$fail" -eq 0 ]; then
  echo "RESULT: PASS - build-step retry wrapper is present and behaves correctly"
else
  echo "RESULT: FAIL"
  exit 1
fi
