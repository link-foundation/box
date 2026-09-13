#!/usr/bin/env bash
# test-issue127-release-inventory.sh
#
# Issue #127: the post-release gate sampled four of the 28 image families.
# A healthy base image therefore hid a missing or private language image, and
# the run stayed green even though GHCR (the registry of record) did not carry
# the complete release.
#
# This suite is offline. It runs the real publication checker and release-note
# generator from a sandbox, replacing only their HTTP registry probe and image
# inventory. The tiny injected inventory proves both consumers read the same
# source, while the production inventory is compared with the workflow
# matrices so a newly published family cannot drift out of the gate.

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
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/scripts/release"
cp scripts/release/check-publication.sh "$WORK/scripts/release/"
cp scripts/release/build-release-notes.sh "$WORK/scripts/release/"
cp scripts/release/registry-probe.sh "$WORK/scripts/release/registry-probe-real.sh"

# Deliberately different from production. If either consumer keeps its own
# hard-coded list, it will ignore Canary and this suite will fail on behavior,
# without inspecting that consumer's source text.
cat >"$WORK/scripts/release/image-inventory.sh" <<'INVENTORY'
#!/usr/bin/env bash
COMBO_IMAGES=(
  "Full Box|"
  "Canary|-canary"
)
LANGUAGE_IMAGES=()
DIND_IMAGES=()
image_inventory_entries() {
  printf '%s\n' "${COMBO_IMAGES[@]}" "${LANGUAGE_IMAGES[@]}" "${DIND_IMAGES[@]}"
}
image_inventory_suffixes() {
  local entry=""
  while IFS= read -r entry; do
    printf '%s\n' "${entry#*|}"
  done < <(image_inventory_entries)
}
INVENTORY

cat >"$WORK/scripts/release/registry-probe.sh" <<'STUB'
#!/usr/bin/env bash
# Keep the real platform comparison. Only the external registry request is
# replaced, because network state is not the behavior under test.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/registry-probe-real.sh"
registry_probe_platforms() {
  local ref="$1"
  : "${STUB_LOG:?must be passed when the registry is probed}"
  printf '%s\n' "$ref" >>"$STUB_LOG"
  REGISTRY_PROBE_DETAIL="fixture answered for $ref"
  REGISTRY_PROBE_PLATFORMS="linux/amd64 linux/arm64"
  case "$ref" in
    ghcr.io/link-foundation/box-canary:9.9.9)
      REGISTRY_PROBE_STATE="missing"
      REGISTRY_PROBE_PLATFORMS=""
      ;;
    *) REGISTRY_PROBE_STATE="published" ;;
  esac
}
registry_probe_pull() { registry_probe_platforms "$1"; }
STUB

OUT="$WORK/check.out"
PROBED="$WORK/probed"
SUMMARY="$WORK/summary.md"
: >"$PROBED"
: >"$SUMMARY"

env -i \
  PATH="$PATH" HOME="$HOME" \
  VERSION="9.9.9" \
  GHCR_IMAGE="ghcr.io/link-foundation/box" \
  DOCKERHUB_IMAGE="konard/box" \
  STUB_LOG="$PROBED" \
  GITHUB_STEP_SUMMARY="$SUMMARY" \
  bash "$WORK/scripts/release/check-publication.sh" >"$OUT" 2>&1
STATUS=$?

echo "== Part 1: every GHCR family is required =="

if [ "$STATUS" -eq 1 ]; then
  pass "one unavailable GHCR family fails the publication gate"
else
  fail "one unavailable GHCR family exits $STATUS; a healthy sample hid it"
  sed 's/^/      /' "$OUT" >&2
fi

if grep -qF '::error title=Release v9.9.9 is incomplete on the registry of record::1 of 4 checked GHCR references' "$OUT" \
  && grep -qF 'ghcr.io/link-foundation/box-canary:9.9.9 is missing' "$OUT"; then
  pass "the failure names the unavailable reference and the incomplete count"
else
  fail "the failure does not explain which GHCR reference is unavailable"
  sed 's/^/      /' "$OUT" >&2
fi

if grep -qxF 'ghcr.io/link-foundation/box-canary:9.9.9' "$PROBED"; then
  pass "the gate probes an inventory family outside its old sample"
else
  fail "the gate never probes the unavailable Canary family"
fi

# Two inventory families x two registries x version/latest. A consumer that
# falls back to the former base/essentials/js/dind sample asks 16 questions.
if [ "$(wc -l <"$PROBED")" -eq 8 ]; then
  pass "the gate probes every inventory family in both registries at both tags"
else
  fail "the gate made $(wc -l <"$PROBED") probes instead of the inventory's 8"
fi

echo
echo "== Part 2: release notes use the same inventory =="

NOTES="$WORK/notes.md"
: >"$PROBED"
if VERSION="9.9.9" REPO="link-foundation/box" \
  GHCR_IMAGE="ghcr.io/link-foundation/box" DOCKERHUB_IMAGE="konard/box" \
  RELEASE_DATE="2026-09-12" \
  bash "$WORK/scripts/release/build-release-notes.sh" >"$NOTES" 2>"$WORK/notes.err"; then
  pass "release notes render with the injected inventory"
else
  fail "release notes reject the shared inventory"
  sed 's/^/      /' "$WORK/notes.err" >&2
fi

if grep -qF '`ghcr.io/link-foundation/box-canary:9.9.9`' "$NOTES" \
  && ! grep -qF 'box-js:9.9.9' "$NOTES"; then
  pass "release notes render exactly the families from the shared inventory"
else
  fail "release notes still use a private hard-coded family list"
fi

echo
echo "== Part 3: production inventory matches what workflows publish =="

INVENTORY="scripts/release/image-inventory.sh"
ACTUAL="$WORK/actual-suffixes"
EXPECTED="$WORK/expected-suffixes"

if [ -f "$INVENTORY" ] && bash -c '
  source "$1"
  image_inventory_suffixes
' _ "$INVENTORY" >"$ACTUAL"; then
  pass "the production inventory is sourceable"
else
  fail "the production inventory is missing or invalid"
  : >"$ACTUAL"
fi

LANGUAGE_LINE="$(awk '/^  build-languages-amd64:$/ {injob=1}
                      injob && /^        language: \[/ {print; exit}' \
  .github/workflows/release-languages.yml)"
DIND_LINE="$(awk '/^  build-dind-amd64:$/ {injob=1}
                  injob && /^        variant: \[/ {print; exit}' \
  .github/workflows/release-dind.yml)"

{
  printf '\n-essentials\n-js\n'
  printf '%s\n' "$LANGUAGE_LINE" \
    | sed 's/.*\[//; s/\].*//; s/,/ /g' \
    | tr ' ' '\n' \
    | sed '/^$/d; s/^/-/'
  printf '%s\n' "$DIND_LINE" \
    | sed 's/.*\[//; s/\].*//; s/,/ /g' \
    | tr ' ' '\n' \
    | sed '/^$/d; s/^full$/-dind/; /-dind$/! s/$/-dind/; s/^/-/' \
    | sed 's/^--/-/'
} >"$EXPECTED"

if cmp -s <(LC_ALL=C sort "$EXPECTED") <(LC_ALL=C sort "$ACTUAL"); then
  pass "the inventory equals the combo, language, and dind workflow matrices"
else
  fail "the inventory drifted from the workflows"
  diff -u "$EXPECTED" "$ACTUAL" | sed 's/^/      /' >&2 || true
fi

echo
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
