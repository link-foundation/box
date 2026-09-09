#!/usr/bin/env bash
# test-issue121-playwright-deps.sh
#
# Issue #121: "Check for all false positives, false negatives, warnings and
# errors in CI/CD and fix them all."
#
# The warning nobody acted on. Both JS build jobs of every run printed
#
#   Playwright Host validation warning:
#   ║ Host system is missing dependencies to run browsers. ║
#   ║     sudo apt-get install libavif16                   ║
#
# (job-js-build-amd64-102285690450 and job-js-build-arm64-102285690839, both
# collected under dev/log/issues/121/pulls/122/ci-logs/), and both jobs went
# green: `playwright install` exits 0 after printing it. So the JS box shipped
# browsers whose shared libraries were not there, and every check said fine.
#
# Compared against Playwright's own ubuntu24.04 list, ubuntu/24.04/js/Dockerfile
# was seven packages short: fonts-tlwg-loma-otf, fonts-unifont, libavif16,
# libicu74, libx264-164, xfonts-cyrillic, xfonts-scalable. Only libavif16
# surfaced in the log, because host validation ldd's the browsers that were
# actually downloaded - the other six were equally absent and equally unreported.
#
# Two things hold the fix in place. ubuntu/24.04/common.sh now fails the build on
# that warning (assert_no_playwright_host_warning), and this suite fails when the
# Dockerfile drifts from the recorded list below - offline, so it runs in the
# normal experiment tier rather than only where Docker and a network are.
#
# The recorded list is a verbatim copy of deps['ubuntu24.04-x64'] from
#   https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/server/registry/nativeDeps.ts
# at commit 4302dbb90f65e80da3f4f08a2e028c9e642b64b9, read 2026-09-09.
# deps['ubuntu24.04-arm64'] is a straight copy of the x64 entry in that file, so
# one list covers both architectures the release builds.
#
# Refreshing it is a deliberate act, which is the point: when Playwright adds a
# dependency, this suite fails, someone reads the upstream diff, and the package
# is added to the Dockerfile in the same commit that updates the record.
#
# What it asserts:
#   Part 1  every package Playwright requires is installed by the Dockerfile
#   Part 2  the extras the Dockerfile adds are the known Puppeteer ones
#   Part 3  the block passes --no-install-recommends, as Playwright's own
#           installer does, so the list is complete by construction
#   Part 4  assert_no_playwright_host_warning turns the warning into a failure
#
# Usage: bash experiments/test-issue121-playwright-deps.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

PASS=0
FAIL=0

pass() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
  [ $# -gt 1 ] && printf '      %s\n' "${@:2}" >&2
  return 0
}

DOCKERFILE="ubuntu/24.04/js/Dockerfile"
COMMON="ubuntu/24.04/common.sh"

# Playwright's ubuntu24.04 dependency set, by browser. Duplicates across
# sections are intentional - they are verbatim from upstream.
PLAYWRIGHT_UBUNTU2404=(
  # tools (12)
  xvfb
  fonts-noto-color-emoji
  fonts-unifont
  libfontconfig1
  libfreetype6
  xfonts-cyrillic
  xfonts-scalable
  fonts-liberation
  fonts-ipafont-gothic
  fonts-wqy-zenhei
  fonts-tlwg-loma-otf
  fonts-freefont-ttf
  # chromium (21)
  libasound2t64
  libatk-bridge2.0-0t64
  libatk1.0-0t64
  libatspi2.0-0t64
  libcairo2
  libcups2t64
  libdbus-1-3
  libdrm2
  libgbm1
  libglib2.0-0t64
  libnspr4
  libnss3
  libpango-1.0-0
  libx11-6
  libxcb1
  libxcomposite1
  libxdamage1
  libxext6
  libxfixes3
  libxkbcommon0
  libxrandr2
  # firefox (25)
  libasound2t64
  libatk1.0-0t64
  libavcodec60
  libcairo-gobject2
  libcairo2
  libdbus-1-3
  libfontconfig1
  libfreetype6
  libgdk-pixbuf-2.0-0
  libglib2.0-0t64
  libgtk-3-0t64
  libpango-1.0-0
  libpangocairo-1.0-0
  libx11-6
  libx11-xcb1
  libxcb-shm0
  libxcb1
  libxcomposite1
  libxcursor1
  libxdamage1
  libxext6
  libxfixes3
  libxi6
  libxrandr2
  libxrender1
  # webkit (52)
  gstreamer1.0-libav
  gstreamer1.0-plugins-bad
  gstreamer1.0-plugins-base
  gstreamer1.0-plugins-good
  libicu74
  libatomic1
  libatk-bridge2.0-0t64
  libatk1.0-0t64
  libcairo-gobject2
  libcairo2
  libdbus-1-3
  libdrm2
  libenchant-2-2
  libepoxy0
  libevent-2.1-7t64
  libflite1
  libfontconfig1
  libfreetype6
  libgbm1
  libgdk-pixbuf-2.0-0
  libgles2
  libglib2.0-0t64
  libgstreamer-gl1.0-0
  libgstreamer-plugins-bad1.0-0
  libgstreamer-plugins-base1.0-0
  libgstreamer1.0-0
  libgtk-4-1
  libharfbuzz-icu0
  libharfbuzz0b
  libhyphen0
  libicu74
  libjpeg-turbo8
  liblcms2-2
  libmanette-0.2-0
  libopus0
  libpango-1.0-0
  libpangocairo-1.0-0
  libpng16-16t64
  libsecret-1-0
  libvpx9
  libwayland-client0
  libwayland-egl1
  libwayland-server0
  libwebp7
  libwebpdemux2
  libwoff1
  libx11-6
  libxkbcommon0
  libxml2
  libxslt1.1
  libx264-164
  libavif16

)

# Packages ubuntu/24.04/js/Dockerfile installs that Playwright does not ask for.
# All three come from Puppeteer's Chrome requirements (https://pptr.dev/troubleshooting),
# which is the other browser stack this image serves.
PUPPETEER_EXTRAS=(
  libxss1
  libxtst6
  xdg-utils
)

# --- The Dockerfile's apt block -------------------------------------------

if [ ! -f "$DOCKERFILE" ]; then
  echo "::error title=test-issue121-playwright-deps::$DOCKERFILE is missing" >&2
  exit 2
fi

# The Playwright/Puppeteer block is the apt-get install that follows the
# "system-level dependencies for Playwright and Puppeteer" comment, up to the
# `apt-get clean` that ends it.
BLOCK="$(awk '
  /system-level dependencies for Playwright and Puppeteer/ { inblock = 1 }
  inblock && /apt-get clean/ { exit }
  inblock { print }
' "$DOCKERFILE")"

if [ -z "$BLOCK" ]; then
  echo "::error title=test-issue121-playwright-deps::could not locate the Playwright apt block in $DOCKERFILE" >&2
  exit 2
fi

mapfile -t INSTALLED < <(
  printf '%s\n' "$BLOCK" \
    | sed -n '/apt-get install/,$p' \
    | sed '1d' \
    | sed 's/\\$//' \
    | tr -d ' \t' \
    | grep -v '^$' \
    | grep -v '^#'
)

if [ "${#INSTALLED[@]}" -eq 0 ]; then
  echo "::error title=test-issue121-playwright-deps::parsed zero packages out of $DOCKERFILE" >&2
  exit 2
fi

contains() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

echo "=== Part 1: every package Playwright requires is installed ==="

MISSING=()
declare -A SEEN=()
for pkg in "${PLAYWRIGHT_UBUNTU2404[@]}"; do
  [ -n "${SEEN[$pkg]:-}" ] && continue
  SEEN[$pkg]=1
  if contains "$pkg" "${INSTALLED[@]}"; then
    pass "$pkg installed"
  else
    MISSING+=("$pkg")
    fail "$pkg is in Playwright's ubuntu24.04 list and not in $DOCKERFILE" \
      "Playwright will print a Host validation warning and exit 0."
  fi
done

echo
echo "=== Part 2: the Dockerfile's extras are the known Puppeteer ones ==="

for pkg in "${INSTALLED[@]}"; do
  if contains "$pkg" "${PLAYWRIGHT_UBUNTU2404[@]}"; then
    continue
  fi
  if contains "$pkg" "${PUPPETEER_EXTRAS[@]}"; then
    pass "$pkg is a documented Puppeteer-only addition"
  else
    fail "$pkg is installed but is neither in Playwright's list nor a documented Puppeteer extra" \
      "Add it to PUPPETEER_EXTRAS with a reason, or drop it."
  fi
done

echo
echo "=== Part 3: the block passes --no-install-recommends ==="

# Match the instruction, not the comment above it - the comment explains the
# flag, so grepping the whole block would pass with the flag deleted.
if printf '%s\n' "$BLOCK" | grep -v '^[[:space:]]*#' | grep 'apt-get install' | grep -q -- '--no-install-recommends'; then
  pass "apt-get install passes --no-install-recommends, as Playwright's installer does"
else
  fail "the Playwright apt block does not pass --no-install-recommends" \
    "Upstream dependencies.ts installs this list with the flag; without it the" \
    "list looks complete only because recommends happen to fill the gaps."
fi

echo
echo "=== Part 4: the warning fails the build ==="

# shellcheck source=/dev/null
if ! source "$COMMON" 2>/dev/null; then
  fail "could not source $COMMON"
else
  if ! command -v assert_no_playwright_host_warning >/dev/null 2>&1; then
    fail "$COMMON does not define assert_no_playwright_host_warning"
  else
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    # A verbatim capture of what run 102285690839 printed, box drawing included.
    cat >"$TMP/warned.log" <<'LOG'
Playwright Host validation warning:
╔══════════════════════════════════════════════════════╗
║ Host system is missing dependencies to run browsers. ║
║ Please install them with the following command:      ║
║                                                      ║
║     sudo npx playwright install-deps                 ║
║                                                      ║
║ Alternatively, use apt:                              ║
║     sudo apt-get install libavif16                   ║
║                                                      ║
║ <3 Playwright Team                                   ║
╚══════════════════════════════════════════════════════╝
LOG
    printf 'Downloading Chromium\nChromium downloaded to /home/box/.cache/ms-playwright\n' >"$TMP/clean.log"

    if out="$(assert_no_playwright_host_warning "$TMP/warned.log" 2>&1)"; then
      fail "assert_no_playwright_host_warning returned 0 on a log containing the warning" "$out"
    else
      pass "a Host validation warning fails the build"
      if printf '%s' "$out" | grep -q 'libavif16'; then
        pass "the failure names the missing package (libavif16)"
      else
        fail "the failure does not name the missing package" "$out"
      fi
      if printf '%s' "$out" | grep -q '║'; then
        fail "the package list still carries the box-drawing frame" "$out"
      else
        pass "the package list is stripped of the box-drawing frame"
      fi
    fi

    if assert_no_playwright_host_warning "$TMP/clean.log" >/dev/null 2>&1; then
      pass "a clean install log passes"
    else
      fail "assert_no_playwright_host_warning failed on a log without the warning"
    fi

    if out="$(JS_ALLOW_PLAYWRIGHT_HOST_WARNING=1 assert_no_playwright_host_warning "$TMP/warned.log" 2>&1)"; then
      pass "JS_ALLOW_PLAYWRIGHT_HOST_WARNING=1 downgrades it to a warning"
    else
      fail "the escape hatch does not work" "$out"
    fi

    if assert_no_playwright_host_warning "$TMP/does-not-exist.log" >/dev/null 2>&1; then
      pass "a missing log file is not a failure"
    else
      fail "a missing log file should be tolerated, not fatal"
    fi
  fi
fi

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  if [ "${#MISSING[@]}" -gt 0 ]; then
    echo
    echo "Add to the apt-get install block in $DOCKERFILE:"
    printf '      %s \\\n' "${MISSING[@]}"
  fi
  exit 1
fi

exit 0
