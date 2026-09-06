#!/usr/bin/env bash
# test-issue115-release-notes.sh
#
# Issue #115: the GitHub Release notes were 106 lines of inline heredoc in
# .github/workflows/release.yml with one hand-written table row per image -
# eleven languages x two registries, and fourteen dind variants x two more.
# A hand-written row is a false negative waiting to happen: add a language to
# the build matrix and the notes stay silent about it, with nothing in CI to
# notice. scripts/release/build-release-notes.sh generates the tables from one
# list; this suite pins that list to the matrix that actually builds the images.
#
# Usage: bash experiments/test-issue115-release-notes.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

SCRIPT="scripts/release/build-release-notes.sh"
WORKFLOW=".github/workflows/release.yml"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

VERSION="9.9.9"
REPO="link-foundation/box"
GHCR_IMAGE="ghcr.io/link-foundation/box"
DOCKERHUB_IMAGE="konard/box"
NOTES="$TMP/notes.md"

if VERSION="$VERSION" REPO="$REPO" GHCR_IMAGE="$GHCR_IMAGE" \
   DOCKERHUB_IMAGE="$DOCKERHUB_IMAGE" RELEASE_DATE="2026-01-01" \
   bash "$SCRIPT" > "$NOTES" 2> "$TMP/err"; then
  pass "the generator runs"
else
  fail "the generator runs"
  sed 's/^/      /' "$TMP/err" >&2
  echo "passed: $PASS"; echo "failed: $FAIL"; exit 1
fi

echo "== Part 1: every image the release publishes has a row =="

# The languages that are actually built and pushed, read from the workflow's
# matrix rather than restated here - restating it is the drift this suite
# exists to catch.
#
# Specifically build-languages-amd64's matrix, not the first `language: [` in
# the file: pr-test-language builds every language directory there is,
# including the ones that are tested but never published (cpp, assembly,
# dotnet, r - issue #115), and the notes must list what was pushed.
MATRIX_LINE="$(awk '/^  build-languages-amd64:$/ {injob=1}
                    injob && /^        language: \[/ {print; exit}' "$WORKFLOW")"
LANGUAGES="$(printf '%s\n' "$MATRIX_LINE" | sed 's/.*\[//; s/\].*//; s/,//g')"

if [ -n "$LANGUAGES" ]; then
  pass "read the language matrix from $WORKFLOW"
else
  fail "read the language matrix from $WORKFLOW"
fi

missing=""
for lang in $LANGUAGES; do
  for image in "${DOCKERHUB_IMAGE}-${lang}" "${GHCR_IMAGE}-${lang}" \
               "${DOCKERHUB_IMAGE}-${lang}-dind" "${GHCR_IMAGE}-${lang}-dind"; do
    grep -qF "\`${image}:${VERSION}\`" "$NOTES" || missing="${missing} ${image}"
  done
done
if [ -z "$missing" ]; then
  pass "all $(echo "$LANGUAGES" | wc -w) matrix languages appear in both registries, plain and dind"
else
  fail "all matrix languages appear in both registries, plain and dind"
  echo "      missing:${missing}" >&2
fi

missing=""
for image in "${DOCKERHUB_IMAGE}" "${DOCKERHUB_IMAGE}-essentials" "${DOCKERHUB_IMAGE}-js" \
             "${GHCR_IMAGE}" "${GHCR_IMAGE}-essentials" "${GHCR_IMAGE}-js" \
             "${DOCKERHUB_IMAGE}-dind" "${GHCR_IMAGE}-dind"; do
  grep -qF "\`${image}:${VERSION}\`" "$NOTES" || missing="${missing} ${image}"
done
if [ -z "$missing" ]; then
  pass "the combo boxes (full, essentials, js) appear in both registries"
else
  fail "the combo boxes appear in both registries"
  echo "      missing:${missing}" >&2
fi

# Per-architecture tags are what users pull when they want one platform; the
# multi-arch row alone is not enough.
for suffix in amd64 arm64; do
  if grep -qF "\`${VERSION}-${suffix}\`" "$NOTES"; then
    pass "per-architecture ${suffix} tags are linked"
  else
    fail "per-architecture ${suffix} tags are linked"
  fi
done

echo ""
echo "== Part 2: the generated links are well-formed =="

if ! grep -q '\${' "$NOTES"; then
  pass "no unexpanded shell expression survives into the notes"
else
  fail "no unexpanded shell expression survives into the notes"
  grep -n '\${' "$NOTES" | head -5 | sed 's/^/      /' >&2
fi

# A GHCR package page is addressed by the package name, never by the full
# image reference - `pkgs/container/ghcr.io/...` is a 404.
if ! grep -q 'pkgs/container/ghcr\.io' "$NOTES"; then
  pass "GHCR links address the package, not the full image reference"
else
  fail "GHCR links address the package, not the full image reference"
fi

BAD_LINKS="$(grep -o '(https://[^)]*)' "$NOTES" | grep -v "$VERSION" | grep -v 'hub.docker.com/r/[^)]*)$' | grep -v 'pkgs/container/box)' | grep -v 'case-studies' || true)"
if [ -z "$BAD_LINKS" ]; then
  pass "every tag link carries the released version"
else
  fail "every tag link carries the released version"
  printf '%s\n' "$BAD_LINKS" | head -5 | sed 's/^/      /' >&2
fi

ROWS="$(grep -c '^| .* | \[' "$NOTES")"
EXPECTED=$(( (3 + $(echo "$LANGUAGES" | wc -w)) * 4 ))
if [ "$ROWS" -eq "$EXPECTED" ]; then
  pass "row count is (combos + languages) x (2 registries) x (plain + dind) = $EXPECTED"
else
  fail "row count is $EXPECTED (got $ROWS)"
fi

echo ""
echo "== Part 3: misuse and drift are caught =="

for var in VERSION REPO GHCR_IMAGE DOCKERHUB_IMAGE; do
  # Blank exactly one required variable and keep the rest.
  out="$(env VERSION="$VERSION" REPO="$REPO" GHCR_IMAGE="$GHCR_IMAGE" \
             DOCKERHUB_IMAGE="$DOCKERHUB_IMAGE" "$var=" \
             bash "$SCRIPT" 2>&1)"
  status=$?
  if [ "$status" -eq 2 ] && printf '%s' "$out" | grep -q "::error"; then
    pass "a missing $var is refused with an annotation"
  else
    fail "a missing $var is refused with an annotation (exit $status)"
  fi
done

# The generator's own list must equal the matrix. If a language is added to
# release.yml and not here, the notes would omit it silently.
SCRIPT_LANGS="$(sed -n '/^LANGUAGE_IMAGES=(/,/^)/p' "$SCRIPT" \
  | grep -o '|-[a-z0-9+]*' | sed 's/^|-//' | tr '\n' ' ' | sed 's/ $//')"
MATRIX_LANGS="$(echo "$LANGUAGES" | tr -s ' ' | sed 's/^ //; s/ $//')"
if [ "$SCRIPT_LANGS" = "$MATRIX_LANGS" ]; then
  pass "the generator's language list equals the build matrix, in order"
else
  fail "the generator's language list equals the build matrix, in order"
  echo "      generator: $SCRIPT_LANGS" >&2
  echo "      matrix:    $MATRIX_LANGS" >&2
fi

echo ""
echo "== Part 4: no hand-written rows are left in the workflow =="

LEFTOVER="$(grep -n 'hub.docker.com/r/' "$WORKFLOW" || true)"
if [ -z "$LEFTOVER" ]; then
  pass "release.yml contains no hand-written Docker Hub table row"
else
  fail "release.yml contains no hand-written Docker Hub table row"
  printf '%s\n' "$LEFTOVER" | head -3 | sed 's/^/      /' >&2
fi

if grep -q 'bash scripts/release/build-release-notes.sh' "$WORKFLOW"; then
  pass "release.yml builds its notes with the generator"
else
  fail "release.yml builds its notes with the generator"
fi

echo ""
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
