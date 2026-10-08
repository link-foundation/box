#!/usr/bin/env bash
# Issue #129: essentials must install file, and image checks must reject a
# missing utility, an unusable magic database, and HTML disguised as a PNG.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
assert() {
  if "$@"; then
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s\n' "$*" >&2
    FAIL=$((FAIL + 1))
  fi
}

# Execute the actual core package request with a recording sudo wrapper.
sed -n '/^# Core system tools$/,/^# Common development libraries/{ /^# Common development libraries/d; p; }' \
  ubuntu/24.04/essentials-box/install.sh >"$TMP/packages.sh"
PACKAGES="$(bash -c 'maybe_sudo() { printf "%s\n" "$@"; }; source "$1"' _ "$TMP/packages.sh")"
assert grep -qx file <<<"$PACKAGES"

mkdir -p "$TMP/bin"
export DOCKER_LOG="$TMP/docker.log" FILE_LOG="$TMP/file.log"
export PATH="$TMP/bin:$PATH"
cat >"$TMP/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$DOCKER_LOG"
case "$*" in
  *--entrypoint=/bin/bash*)
    # Execute the real in-container acceptance code, with only file mocked.
    exec bash -euc "${!#}"
    ;;
  *'rustup toolchain list'*) echo 'stable-x86_64-unknown-linux-gnu (default)' ;;
esac
DOCKER
cat >"$TMP/bin/file" <<'FILE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FILE_LOG"
if [ "${FILE_MODE:-ok}" = missing ]; then
  echo 'file: command not found' >&2
  exit 127
fi
if [ "${1:-}" = --version ]; then
  echo 'file-5.45'
  exit 0
fi
if [ "${FILE_MODE:-ok}" = broken-magic ]; then
  echo application/octet-stream
elif [ "${FILE_MODE:-ok}" = html-as-png ]; then
  echo image/png
elif [ "$(head -c 4 "${!#}")" = $'\x89PNG' ]; then
  echo image/png
else
  echo text/html
fi
FILE
chmod +x "$TMP/bin/docker" "$TMP/bin/file"

run() {
  : >"$DOCKER_LOG"
  : >"$FILE_LOG"
  STATUS=0
  FILE_MODE="$2" BOX_CHECK_FRESHNESS=0 \
    bash scripts/ci/test-box.sh "$1" box-test >"$TMP/output" 2>&1 || STATUS=$?
}

for profile in essentials full attachments; do
  run "$profile" ok
  assert test "$STATUS" -eq 0
  assert grep -qx -- --version "$FILE_LOG"
  assert grep -q -- '--mime-type' "$FILE_LOG"
  assert test "$(wc -l <"$FILE_LOG")" -eq 3
  assert grep -q -- '--network none --entrypoint=/bin/bash' "$DOCKER_LOG"

  for failure in missing broken-magic html-as-png; do
    run "$profile" "$failure"
    assert test "$STATUS" -ne 0
  done
done

# JS is below essentials in the image chain; this is not its dependency.
run js missing
assert test "$STATUS" -eq 0
assert test ! -s "$FILE_LOG"

# The DinD matrix must run the same acceptance code without starting dockerd.
assert grep -q 'bash scripts/ci/test-box.sh attachments "$IMG"' .github/workflows/pr-tests.yml

printf 'passed: %s\nfailed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
