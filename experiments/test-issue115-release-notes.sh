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

# RC-17: a GHCR package page is a 404 until that package has been pushed, and
# these notes used to emit one per image - 28 dead links per release, on top of
# the 85 the README carried. The GHCR references are code spans now; `docker
# pull` is the real test and Part 5 is what runs it.
if ! grep -q 'pkgs/container' "$NOTES"; then
  pass "the notes link no GHCR package page (404 until the package exists)"
else
  fail "the notes link no GHCR package page (404 until the package exists)"
  grep -n 'pkgs/container' "$NOTES" | head -3 | sed 's/^/      /' >&2
fi

BAD_LINKS="$(grep -o '(https://[^)]*)' "$NOTES" | grep -v "$VERSION" | grep -v 'hub.docker.com/r/[^)]*)$' | grep -v 'github.com/orgs/[^)]*/packages' | grep -v 'case-studies' || true)"
if [ -z "$BAD_LINKS" ]; then
  pass "every tag link carries the released version"
else
  fail "every tag link carries the released version"
  printf '%s\n' "$BAD_LINKS" | head -5 | sed 's/^/      /' >&2
fi

# Every table row names the released version, and nothing else in the notes
# starts with a pipe, so this counts rows without depending on whether a row's
# tags are links (Docker Hub) or code spans (GHCR).
ROWS="$(grep -c "^| .*:${VERSION}" "$NOTES")"
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
echo "== Part 5: the release is not gated on the image push, and says what shipped =="

# hive-mind principle #13, "never gate the release on an image push". The
# outside view of this repository (RC-3, RC-17): 28 GHCR references advertised
# per release for packages that had never been pushed, while a Docker Hub
# token expiry could stop the GitHub Release from being created at all. The
# release now comes from the source state and the notes report, per reference,
# what the registry actually answered.

CREATE_RELEASE_IF="$(awk '/^  create-release:$/ {injob=1; next}
                          injob && /^    if: \|$/ {inif=1; next}
                          inif && /^    [a-z]/ {exit}
                          inif {print}' "$WORKFLOW")"

if [ -n "$CREATE_RELEASE_IF" ]; then
  pass "read create-release's if: condition"
else
  fail "read create-release's if: condition"
fi

if ! printf '%s' "$CREATE_RELEASE_IF" | grep -q "docker-manifest.result == 'success'"; then
  pass "create-release does not require the image push to have succeeded"
else
  fail "create-release still requires docker-manifest to succeed; a registry outage means no release"
fi

if printf '%s' "$CREATE_RELEASE_IF" | grep -q "detect-changes.result == 'success'"; then
  pass "create-release still requires detect-changes (it decides there is a release at all)"
else
  fail "create-release no longer requires detect-changes"
fi

if grep -q "VERIFY_IMAGES: '1'" "$WORKFLOW"; then
  pass "the workflow turns the publication check on"
else
  fail "the workflow does not set VERIFY_IMAGES; the notes would claim images it never checked"
fi

# Offline default: without VERIFY_IMAGES the generator must not touch a
# registry, or every local run and this suite would need the network.
if ! grep -q 'Image publication' "$NOTES"; then
  pass "no publication section without VERIFY_IMAGES (the generator stays offline)"
else
  fail "the generator queried a registry without being asked to"
fi

# A fake docker on PATH, so the three registry answers can be tested without
# one. $TMP/bin/docker prints what FAKE_DOCKER_MODE says and exits accordingly.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'FAKE'
#!/usr/bin/env bash
case "${FAKE_DOCKER_MODE}" in
  ok)      exit 0 ;;
  missing) echo "manifest unknown" >&2; exit 1 ;;
  ratelimited) echo "toomanyrequests: rate limit exceeded" >&2; exit 1 ;;
esac
FAKE
chmod +x "$TMP/bin/docker"

# verified MODE - regenerate the notes with the fake registry answering MODE.
verified() {
  PATH="$TMP/bin:$PATH" FAKE_DOCKER_MODE="$1" VERIFY_IMAGES=1 \
    VERSION="$VERSION" REPO="$REPO" GHCR_IMAGE="$GHCR_IMAGE" \
    DOCKERHUB_IMAGE="$DOCKERHUB_IMAGE" RELEASE_DATE="2026-01-01" \
    bash "$SCRIPT"
}

TOTAL_REFS="$EXPECTED"

verified ok > "$TMP/ok.md" 2>"$TMP/ok.err"
if grep -q "^${TOTAL_REFS} of ${TOTAL_REFS} image references resolve" "$TMP/ok.md"; then
  pass "every reference is checked, and a full push reports $TOTAL_REFS of $TOTAL_REFS"
else
  fail "a full push does not report $TOTAL_REFS of $TOTAL_REFS"
  grep -n 'image references resolve' "$TMP/ok.md" | sed 's/^/      /' >&2
fi

if ! grep -q 'not published' "$TMP/ok.md"; then
  pass "a full push lists nothing as missing"
else
  fail "a full push lists something as missing"
fi

verified missing > "$TMP/missing.md" 2>"$TMP/missing.err"
if grep -q "^0 of ${TOTAL_REFS} image references resolve" "$TMP/missing.md"; then
  pass "an unpushed release reports 0 of $TOTAL_REFS, instead of advertising them all"
else
  fail "an unpushed release does not report 0 of $TOTAL_REFS"
fi

if grep -q 'are \*\*not published\*\*' "$TMP/missing.md" \
   && grep -qF "\`${GHCR_IMAGE}:${VERSION}\`" "$TMP/missing.md"; then
  pass "the missing references are named, so the notes do not promise a pull that fails"
else
  fail "the missing references are not named"
fi

# The distinction that keeps the check honest: a registry that will not answer
# is not evidence that the image is absent.
verified ratelimited > "$TMP/unknown.md" 2>"$TMP/unknown.err"
if grep -q 'state is unknown' "$TMP/unknown.md" && ! grep -q 'not published' "$TMP/unknown.md"; then
  pass "a rate-limited registry is reported as unknown, never as missing"
else
  fail "a rate-limited registry is reported as missing; the notes would libel a published image"
fi

if grep -q "^0 of ${TOTAL_REFS} image references resolve" "$TMP/unknown.md"; then
  pass "the unknown references still count towards the total"
else
  fail "the unknown references are dropped from the total"
fi

echo ""
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
