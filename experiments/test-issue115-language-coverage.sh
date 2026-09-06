#!/usr/bin/env bash
# test-issue115-language-coverage.sh
#
# Issue #115. ubuntu/24.04/ held nineteen directories; CI built fifteen of them.
# cpp, assembly, dotnet and r each shipped a Dockerfile and an install.sh, were
# documented in README ("Each install script can be run standalone... curl -fsSL
# .../install.sh | bash"), and no job had ever built or run either file. Worse,
# detect-changes.sh emitted cpp-changed and assembly-changed that no job read,
# and emitted nothing at all for dotnet and r - so the workflow *looked* like it
# tracked them.
#
# A per-directory coverage gap cannot be caught by any check that restates the
# list of languages, because the restated list is exactly what goes stale. So
# every assertion here derives the expected set from the filesystem.
#
# Usage: bash experiments/test-issue115-language-coverage.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

WORKFLOW=".github/workflows/release.yml"
DETECT="scripts/ci/detect-changes.sh"
TEST_BOX="scripts/ci/test-box.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# The composed images and dind are not languages: js and essentials-box are the
# base layers every language box is built on, full-box merges them all, and dind
# layers Docker onto an existing box. Everything else under ubuntu/24.04/ is a
# standalone language box.
NOT_A_LANGUAGE="js essentials-box full-box dind"

is_language() {
  local candidate="$1" excluded
  for excluded in $NOT_A_LANGUAGE; do
    [ "$candidate" = "$excluded" ] && return 1
  done
  return 0
}

DIRS=""
for dockerfile in ubuntu/24.04/*/Dockerfile; do
  dir="$(basename "$(dirname "$dockerfile")")"
  is_language "$dir" || continue
  DIRS="$DIRS $dir"
done
DIRS="$(printf '%s\n' $DIRS | sort | tr '\n' ' ')"

echo "=== Language directories on disk ==="
echo "$DIRS"
echo

if [ -n "${DIRS// /}" ]; then
  pass "found standalone language directories under ubuntu/24.04/"
else
  fail "found standalone language directories under ubuntu/24.04/ (glob is wrong)"
fi

echo "=== Part 1: detect-changes.sh classifies every language ==="

DETECT_LANGS="$(grep -m1 '^LANGUAGES=' "$DETECT" | sed 's/^LANGUAGES="//; s/"$//' | tr ' ' '\n' | sort | tr '\n' ' ')"
if [ "$DETECT_LANGS" = "$DIRS" ]; then
  pass "detect-changes.sh LANGUAGES equals the directory listing"
else
  fail "detect-changes.sh LANGUAGES ($DETECT_LANGS) != directory listing ($DIRS)"
fi

# Behavioural, not textual: touching a language's directory must set its output.
for language in $DIRS; do
  OUT="$(CHANGED_FILES_OVERRIDE="ubuntu/24.04/${language}/install.sh" \
         GITHUB_EVENT_NAME=pull_request bash "$DETECT" 2>&1)"
  if printf '%s\n' "$OUT" | grep -qx "${language}=true"; then
    pass "a change under ubuntu/24.04/$language/ sets ${language}=true"
  else
    fail "a change under ubuntu/24.04/$language/ sets ${language}=true (got: $(printf '%s\n' "$OUT" | grep -c .) lines)"
  fi
done

echo
echo "=== Part 2: every detect-changes language is exported by the workflow ==="

for language in $DIRS; do
  if grep -q "^      ${language}-changed: \${{ steps.detect.outputs.${language} }}$" "$WORKFLOW"; then
    pass "detect-changes job exports ${language}-changed"
  else
    fail "detect-changes job exports ${language}-changed"
  fi
done

echo
echo "=== Part 3: every language is built and tested on pull requests ==="

MATRIX_LINE="$(grep -m1 '^        language: \[' "$WORKFLOW")"
MATRIX_LANGS="$(printf '%s\n' "$MATRIX_LINE" | sed 's/.*\[//; s/\].*//; s/,//g' | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' ')"
if [ "$MATRIX_LANGS" = "$DIRS" ]; then
  pass "the pr-test matrix equals the directory listing"
else
  fail "the pr-test matrix ($MATRIX_LANGS) != directory listing ($DIRS)"
fi

echo
echo "=== Part 4: every language has acceptance checks ==="

# A profile that fell through to the catch-all would exit 1, so this is a real
# check of scripts/ci/test-box.sh rather than a grep for a case label.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$TMP/bin/docker"

for language in $DIRS; do
  if PATH="$TMP/bin:$PATH" BOX_CHECK_FRESHNESS=0 \
       bash "$TEST_BOX" "$language" "box-$language" >/dev/null 2>&1; then
    pass "test-box.sh has checks for $language"
  else
    fail "test-box.sh has checks for $language"
  fi
done

echo
echo "=== Part 5: the published-image matrices are a documented subset ==="

# cpp, assembly, dotnet and r are compiled into the full box from apt but are
# not published as standalone images, so the release matrices are allowed to be
# smaller than the pr-test matrix - but never larger, which would mean
# publishing an image nothing tested.
RELEASE_LINES="$(grep -n '^        language: \[' "$WORKFLOW" | tail -n +2 | cut -d: -f1)"
for line in $RELEASE_LINES; do
  langs="$(sed -n "${line}p" "$WORKFLOW" | sed 's/.*\[//; s/\].*//; s/,//g')"
  extra=""
  for language in $langs; do
    printf '%s ' "$MATRIX_LANGS" | grep -q " $language " || extra="$extra $language"
  done
  if [ -z "$extra" ]; then
    pass "release matrix on line $line publishes only tested languages"
  else
    fail "release matrix on line $line publishes untested languages:$extra"
  fi
done

echo
echo "=== Summary ==="
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
