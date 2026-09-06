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

# create-release lives in the entry workflow; the build matrices moved into
# release-<family>.yml when release.yml was split (issue #115, RC-8). Resolving
# the matrix file by job id keeps an "awk found nothing" from reading as "the
# matrix is empty", which would make Part 1 check no images at all.
WORKFLOW=".github/workflows/release.yml"
LANGUAGES_WORKFLOW="$(bash scripts/ci/list-release-workflows.sh --job build-languages-amd64)" || exit 1
PASS=0
FAIL=0

pass() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

VERSION="9.9.9"
REPO="link-foundation/box"
GHCR_IMAGE="ghcr.io/link-foundation/box"
DOCKERHUB_IMAGE="konard/box"
NOTES="$TMP/notes.md"

if VERSION="$VERSION" REPO="$REPO" GHCR_IMAGE="$GHCR_IMAGE" \
  DOCKERHUB_IMAGE="$DOCKERHUB_IMAGE" RELEASE_DATE="2026-01-01" \
  bash "$SCRIPT" >"$NOTES" 2>"$TMP/err"; then
  pass "the generator runs"
else
  fail "the generator runs"
  sed 's/^/      /' "$TMP/err" >&2
  echo "passed: $PASS"
  echo "failed: $FAIL"
  exit 1
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
                    injob && /^        language: \[/ {print; exit}' "$LANGUAGES_WORKFLOW")"
LANGUAGES="$(printf '%s\n' "$MATRIX_LINE" | sed 's/.*\[//; s/\].*//; s/,//g')"

if [ -n "$LANGUAGES" ]; then
  pass "read the language matrix from $LANGUAGES_WORKFLOW"
else
  fail "read the language matrix from $LANGUAGES_WORKFLOW"
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
EXPECTED=$(((3 + $(echo "$LANGUAGES" | wc -w)) * 4))
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

# Two spellings of the same gate: `docker-manifest` was the job before the
# split, `full` is the caller job that now stands for it (and js/essentials/
# languages/dind for the other families). Requiring any of them reintroduces
# the defect, so all of them are checked.
gate=""
for job in docker-manifest js essentials languages full dind; do
  printf '%s' "$CREATE_RELEASE_IF" | grep -q "needs\.${job}\.result == 'success'" \
    && gate="${gate} ${job}"
done
if [ -z "$gate" ]; then
  pass "create-release does not require the image push to have succeeded"
else
  fail "create-release requires${gate} to succeed; a registry outage means no release"
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

# The registry answers are stubbed, not faked with a `docker` binary on PATH:
# the generator asks the registry over HTTP now, through
# scripts/release/registry-probe.sh, because a `docker manifest inspect` run
# inside create-release measures the publisher's access and not the reader's
# (issue #117). The stub is a sibling of a sandboxed copy of the generator, so
# it is picked up by the same `source "${SCRIPT_DIR}/registry-probe.sh"` line
# production uses - no test seam in the shipped script.
SANDBOX="$TMP/sandbox"
mkdir -p "$SANDBOX/scripts/release"
cp "$SCRIPT" "$SANDBOX/scripts/release/"
cat >"$SANDBOX/scripts/release/registry-probe.sh" <<'STUB'
#!/usr/bin/env bash
# Stub probe: answers every reference with $STUB_STATE, or with the per-prefix
# override in $STUB_GHCR_STATE / $STUB_DOCKERHUB_STATE when they are set.
REGISTRY_PROBE_STATE=""
REGISTRY_PROBE_DETAIL=""
registry_probe_pull() {
  case "$1" in
    ghcr.io/*) REGISTRY_PROBE_STATE="${STUB_GHCR_STATE:-$STUB_STATE}" ;;
    *) REGISTRY_PROBE_STATE="${STUB_DOCKERHUB_STATE:-$STUB_STATE}" ;;
  esac
  REGISTRY_PROBE_DETAIL="stub answered ${REGISTRY_PROBE_STATE}"
}
STUB

# verified STATE [GHCR_STATE DOCKERHUB_STATE] - regenerate the notes with the
# registries answering STATE.
verified() {
  STUB_STATE="$1" STUB_GHCR_STATE="${2:-}" STUB_DOCKERHUB_STATE="${3:-}" \
    VERIFY_IMAGES=1 \
    VERSION="$VERSION" REPO="$REPO" GHCR_IMAGE="$GHCR_IMAGE" \
    DOCKERHUB_IMAGE="$DOCKERHUB_IMAGE" RELEASE_DATE="2026-01-01" \
    bash "$SANDBOX/scripts/release/build-release-notes.sh"
}

TOTAL_REFS="$EXPECTED"
PER_REGISTRY=$((TOTAL_REFS / 2))

verified published >"$TMP/ok.md" 2>"$TMP/ok.err"
if grep -q "${TOTAL_REFS} of ${TOTAL_REFS} image references can be pulled" "$TMP/ok.md"; then
  pass "every reference is checked, and a full push reports $TOTAL_REFS of $TOTAL_REFS"
else
  fail "a full push does not report $TOTAL_REFS of $TOTAL_REFS"
  grep -n 'image references' "$TMP/ok.md" | sed 's/^/      /' >&2
  sed 's/^/      /' "$TMP/ok.err" >&2
fi

if ! grep -q 'not published' "$TMP/ok.md"; then
  pass "a full push lists nothing as missing"
else
  fail "a full push lists something as missing"
fi

verified missing >"$TMP/missing.md" 2>"$TMP/missing.err"
if grep -q "0 of ${TOTAL_REFS} image references can be pulled" "$TMP/missing.md"; then
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
verified unknown >"$TMP/unknown.md" 2>"$TMP/unknown.err"
if grep -q 'state is unknown' "$TMP/unknown.md" && ! grep -q 'not published' "$TMP/unknown.md"; then
  pass "a rate-limited registry is reported as unknown, never as missing"
else
  fail "a rate-limited registry is reported as missing; the notes would libel a published image"
fi

if grep -q "0 of ${TOTAL_REFS} image references can be pulled" "$TMP/unknown.md"; then
  pass "the unknown references still count towards the total"
else
  fail "the unknown references are dropped from the total"
fi

echo ""
echo "== Part 6 (issue #117): the notes report the reader's view, per registry =="

# The v2.6.0 notes said "28 of 56 image references resolve" while both GHCR
# packages were private and Docker Hub had received nothing: 0 of 56 for every
# reader. Two defects, and this part pins both. First, a private package is
# its own state - an image that exists and cannot be pulled is not published,
# and calling it "missing" would be the same false claim in the other
# direction.
verified private >"$TMP/private.md" 2>"$TMP/private.err"
if grep -q "0 of ${TOTAL_REFS} image references can be pulled" "$TMP/private.md"; then
  pass "a private package counts as unreachable, not as published"
else
  fail "a private package is counted as published; this is the v2.6.0 false positive"
fi

if grep -q 'not readable anonymously' "$TMP/private.md" \
  && ! grep -q 'are \*\*not published\*\*' "$TMP/private.md"; then
  pass "a private package is named as private, not as missing"
else
  fail "a private package is not distinguished from a missing one"
fi

# Second, the per-registry split. "28 of 56" was true of no reader and hid
# which half was gone; the exact shape of v2.6.0 - GHCR private, Docker Hub
# empty - has to be legible from the notes alone.
verified '' private missing >"$TMP/v260.md" 2>"$TMP/v260.err"
if grep -q "0 of ${TOTAL_REFS} image references can be pulled" "$TMP/v260.md" \
  && grep -q "^| GitHub Container Registry (registry of record) | 0 | ${PER_REGISTRY} |" "$TMP/v260.md" \
  && grep -q "^| Docker Hub (mirror) | 0 | ${PER_REGISTRY} |" "$TMP/v260.md"; then
  pass "the v2.6.0 shape (GHCR private, Docker Hub empty) reports 0 in both registries"
else
  fail "the v2.6.0 shape is not reported per registry"
  grep -n '^| ' "$TMP/v260.md" | head -5 | sed 's/^/      /' >&2
fi

if grep -q 'Nothing in this release can be pulled from the registry of record' "$TMP/v260.md"; then
  pass "a release with nothing pullable says so at the top, not only in a table"
else
  fail "a release with nothing pullable does not say so"
fi

# A mirror that lagged is not the same failure as a release that reached
# nobody, and the notes must not flatten them together.
verified '' published missing >"$TMP/mirror.md" 2>"$TMP/mirror.err"
if grep -q "${PER_REGISTRY} of ${TOTAL_REFS} image references can be pulled" "$TMP/mirror.md" \
  && grep -q "^| GitHub Container Registry (registry of record) | ${PER_REGISTRY} | ${PER_REGISTRY} |" "$TMP/mirror.md" \
  && ! grep -q 'Nothing in this release can be pulled' "$TMP/mirror.md"; then
  pass "a lagging Docker Hub mirror does not read as a failed release"
else
  fail "a lagging mirror is reported as a failed release"
fi

# Quick Start told everyone to `docker pull konard/box:VERSION` - the registry
# that had nothing. GHCR is the registry of record (issue #115, RC-3), so it
# is what the first command pulls.
FIRST_PULL="$(sed -n '/^## Quick Start/,$p' "$NOTES" | grep -m1 'docker pull ')"
if [ "$FIRST_PULL" = "docker pull ${GHCR_IMAGE}:${VERSION}" ]; then
  pass "the first pull command in Quick Start names the registry of record"
else
  fail "the first pull command in Quick Start is not the registry of record"
  echo "      got: ${FIRST_PULL}" >&2
fi

# And the check must not be the publisher checking itself: create-release is
# where the authenticated `docker login` used to sit, and its presence there is
# the whole root cause of issue #117 claim 4.
CREATE_RELEASE_BLOCK="$(awk '/^  create-release:$/ {injob=1}
                             injob && /^  [a-z][a-z0-9-]*:$/ && !/^  create-release:$/ {exit}
                             injob {print}' "$WORKFLOW")"
if printf '%s' "$CREATE_RELEASE_BLOCK" | grep -q 'docker/login-action'; then
  fail "create-release logs in to a registry before checking publication; it would measure its own access"
else
  pass "create-release holds no registry credential, so the publication check is the reader's view"
fi

if printf '%s' "$CREATE_RELEASE_BLOCK" | grep -q 'scripts/release/check-publication.sh'; then
  pass "create-release asserts, after publishing, that the release is reachable"
else
  fail "nothing asserts that the published release can be pulled"
fi

echo ""
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
