#!/usr/bin/env bash
# test-issue119-manifest-media-type.sh
#
# Issue #119(a): the Docker Hub multi-arch manifests of 2.7.0 were never
# published, and no retry could have published them.
#
# `scripts/release/mirror-to-dockerhub.sh` copies with `docker buildx imagetools
# create`, which always wraps its result in an OCI index - even for a single
# platform. `scripts/release/create-multiarch-manifest.sh` then tried to combine
# those mirrored tags with `docker manifest create`, which refuses an index as a
# source. From release run 34056619231:
#
#   docker.io/***/box:2.7.0-amd64 is a manifest list
#   ==> ***/box:2.7.0: attempt 1 failed; retrying in 10s
#
# The media types, measured anonymously on 2026-09-08, show the asymmetry is the
# mirror's doing rather than the builder's:
#
#   ghcr.io/link-foundation/box-dind:2.7.0-amd64  application/vnd.oci.image.manifest.v1+json
#   docker.io/konard/box-dind:2.7.0-amd64         application/vnd.oci.image.index.v1+json
#
# So the same script worked on one registry and could not work on the other, and
# three attempts at a deterministically wrong input cost 40 seconds and produced
# a warning.
#
# This suite drives the script against a fake `docker` that reproduces the real
# refusal: `docker manifest create` fails on an index source, exactly like the
# CLI does.
#
# What it asserts:
#   Part 1  the manifest is built with a tool that accepts index sources
#   Part 2  the mirrored (index) tags of Docker Hub are consumable
#   Part 3  publishing verifies the architectures it just published
#   Part 4  a manifest that came out single-arch is a failure, not a success
#   Part 5  verification cannot be fooled by the tool that wrote the manifest
#
# Usage: bash experiments/test-issue119-manifest-media-type.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

SCRIPT="scripts/release/create-multiarch-manifest.sh"
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
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN"

# A fake docker that behaves like the real one on the point at issue:
#
#   * `docker manifest create` refuses a source listed in $FAKE_STATE/indexes,
#     with the CLI's own wording ("... is a manifest list");
#   * `docker buildx imagetools create` accepts anything and records the tag it
#     wrote, together with the platforms of its sources;
#   * `docker buildx imagetools inspect --raw` serves back what was written.
#
# Platforms per reference are read from $FAKE_STATE/platforms ("REF PLATFORM..."),
# so a test can say "the arm64 source does not exist" and see what the script
# does about it.
cat >"$BIN/docker" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOCKER_LOG"

platforms_of() {
  local ref="$1"
  grep "^${ref} " "$FAKE_STATE/platforms" 2>/dev/null | head -1 | cut -d' ' -f2-
}

raw_index() {
  local platforms="$1" p out=""
  for p in $platforms; do
    out="${out}{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"sha256:${p//\//-}\",\"platform\":{\"architecture\":\"${p#*/}\",\"os\":\"${p%%/*}\"}},"
  done
  printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[%s]}' "${out%,}"
}

case "$1 $2" in
  "manifest create")
    shift 2
    for arg in "$@"; do
      case "$arg" in
        --amend) continue ;;
      esac
      if grep -qx "$arg" "$FAKE_STATE/indexes" 2>/dev/null; then
        echo "$arg is a manifest list" >&2
        exit 1
      fi
    done
    exit 0
    ;;
  "manifest push") exit 0 ;;
  "buildx imagetools")
    shift 2
    case "$1" in
      create)
        shift
        tag=""
        sources=()
        while [ $# -gt 0 ]; do
          case "$1" in
            --tag | -t)
              tag="$2"
              shift 2
              ;;
            *)
              sources+=("$1")
              shift
              ;;
          esac
        done
        if [ -s "$FAKE_STATE/fail-creates" ] && [ "$(cat "$FAKE_STATE/fail-creates")" -gt 0 ]; then
          echo $(($(cat "$FAKE_STATE/fail-creates") - 1)) >"$FAKE_STATE/fail-creates"
          cat "$FAKE_STATE/fail-output" >&2
          exit 1
        fi
        merged=""
        for src in ${sources[@]+"${sources[@]}"}; do
          merged="$merged $(platforms_of "$src")"
        done
        # imagetools always writes an index, whatever it was handed.
        printf '%s %s\n' "$tag" "$(echo $merged | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//')" >>"$FAKE_STATE/platforms"
        echo "$tag" >>"$FAKE_STATE/indexes"
        echo "==> pushed $tag"
        exit 0
        ;;
      inspect)
        shift
        raw=0
        ref=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --raw) raw=1 ;;
            *) ref="$1" ;;
          esac
          shift
        done
        found="$(grep -c "^${ref} " "$FAKE_STATE/platforms" 2>/dev/null || true)"
        if [ "${found:-0}" -eq 0 ]; then
          echo "${ref}: not found" >&2
          exit 1
        fi
        [ "$raw" = "1" ] || echo "Name: $ref"
        raw_index "$(grep "^${ref} " "$FAKE_STATE/platforms" | tail -1 | cut -d' ' -f2-)"
        exit 0
        ;;
    esac
    ;;
esac
exit 0
FAKE
chmod +x "$BIN/docker"

DOCKER_LOG="$TMP/docker.log"
OUT=""
STATUS=0

# reset_registry - forget every reference the fake registry knows.
reset_registry() {
  : >"$TMP/platforms"
  : >"$TMP/indexes"
  : >"$TMP/fail-creates"
  : >"$TMP/fail-output"
  : >"$DOCKER_LOG"
}

# publish REF PLATFORM... - pretend a build job pushed REF.
publish() {
  local ref="$1"
  shift
  printf '%s %s\n' "$ref" "$*" >>"$TMP/platforms"
}

# publish_index REF PLATFORM... - the same, served as an index (what the Docker
# Hub mirror writes for every tag it touches, including single-arch ones).
publish_index() {
  publish "$@"
  echo "$1" >>"$TMP/indexes"
}

run() {
  local overrides=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    overrides+=("$1")
    shift
  done
  shift || true
  : >"$DOCKER_LOG"
  OUT="$(
    env PATH="$BIN:$PATH" DOCKER_LOG="$DOCKER_LOG" FAKE_STATE="$TMP" \
      INITIAL_DELAY=0 GITHUB_STEP_SUMMARY="$TMP/summary.md" \
      ${overrides[@]+"${overrides[@]}"} \
      bash "$SCRIPT" "$@" 2>&1
  )"
  STATUS=$?
}

echo "== Part 1: the manifest is built with a tool that accepts index sources =="

reset_registry
publish_index docker.io/example/box:2.7.0-amd64 linux/amd64
publish_index docker.io/example/box:2.7.0-arm64 linux/arm64
run -- docker.io/example/box 2.7.0

if [ "$STATUS" -eq 0 ]; then
  pass "assembling from mirrored (index) tags succeeds"
else
  fail "assembling from mirrored (index) tags succeeds (got $STATUS)" "$OUT"
fi

if ! grep -q '^manifest create' "$DOCKER_LOG"; then
  pass "'docker manifest create' - which refuses an index source - is not used"
else
  fail "'docker manifest create' is not used" "$(cat "$DOCKER_LOG")"
fi

case "$OUT" in
  *"is a manifest list"*)
    fail "the run 34056619231 failure does not reproduce" "$OUT"
    ;;
  *) pass "the run 34056619231 failure ('is a manifest list') does not reproduce" ;;
esac

echo ""
echo "== Part 2: the plain manifests of GHCR are consumable too =="

reset_registry
publish ghcr.io/link-foundation/box:2.7.0-amd64 linux/amd64
publish ghcr.io/link-foundation/box:2.7.0-arm64 linux/arm64
publish ghcr.io/link-foundation/box:latest-amd64 linux/amd64
publish ghcr.io/link-foundation/box:latest-arm64 linux/arm64
run -- ghcr.io/link-foundation/box 2.7.0 latest

if [ "$STATUS" -eq 0 ] && grep -c 'imagetools create' "$DOCKER_LOG" | grep -qx 2; then
  pass "one imagetools create per tag, from the per-architecture sources"
else
  fail "one imagetools create per tag" "$OUT" "$(cat "$DOCKER_LOG")"
fi

if grep -q 'imagetools create --tag ghcr.io/link-foundation/box:2.7.0 ghcr.io/link-foundation/box:2.7.0-amd64 ghcr.io/link-foundation/box:2.7.0-arm64' "$DOCKER_LOG"; then
  pass "every architecture is a source of the published tag"
else
  fail "every architecture is a source of the published tag" "$(cat "$DOCKER_LOG")"
fi

echo ""
echo "== Part 3: publishing verifies the architectures it published =="

if grep -q 'imagetools inspect' "$DOCKER_LOG"; then
  pass "the published manifest is read back"
else
  fail "the published manifest is read back" "$(cat "$DOCKER_LOG")"
fi

echo ""
echo "== Part 4: a manifest that came out single-arch is a failure =="

# The arm64 job's tag never arrived - the shape of the box-dind mirror in the
# issue. `imagetools create` is perfectly happy to write an index with one
# child, and that index resolves. Resolving is not the check.
reset_registry
publish ghcr.io/link-foundation/box:2.7.0-amd64 linux/amd64
run -- ghcr.io/link-foundation/box 2.7.0

if [ "$STATUS" -eq 1 ]; then
  pass "a tag that ends up carrying one architecture exits 1"
else
  fail "a tag that ends up carrying one architecture exits 1 (got $STATUS)" "$OUT"
fi

case "$OUT" in
  *"linux/arm64"*) pass "the missing architecture is named" ;;
  *) fail "the missing architecture is named" "$OUT" ;;
esac

# The mirror keeps its #115 policy: Docker Hub failing must not fail a job whose
# GHCR manifest is already published.
reset_registry
publish docker.io/example/box:2.7.0-amd64 linux/amd64
: >"$TMP/summary.md"
run MANIFEST_REQUIRED=0 -- docker.io/example/box 2.7.0

if [ "$STATUS" -eq 0 ] && grep -q 'linux/arm64' "$TMP/summary.md"; then
  pass "MANIFEST_REQUIRED=0 degrades the same finding to a summary warning"
else
  fail "MANIFEST_REQUIRED=0 degrades the same finding to a summary warning (got $STATUS)" \
    "$OUT" "$(cat "$TMP/summary.md")"
fi

echo ""
echo "== Part 5: verification reads the registry, not the local tool's word =="

# A verification that trusts the exit status of the command it is verifying
# checks nothing. The fake registry answers `imagetools inspect` from what was
# actually written, so removing the read-back below fails Part 4.
reset_registry
publish ghcr.io/link-foundation/box:2.7.0-amd64 linux/amd64
publish ghcr.io/link-foundation/box:2.7.0-arm64 linux/arm64
run -- ghcr.io/link-foundation/box 2.7.0
INSPECTED="$(grep -c 'imagetools inspect' "$DOCKER_LOG" || true)"
if [ "$INSPECTED" -ge 1 ] && grep -q 'imagetools inspect --raw ghcr.io/link-foundation/box:2.7.0' "$DOCKER_LOG"; then
  pass "the tag that was published is the tag that is read back"
else
  fail "the tag that was published is the tag that is read back" "$(cat "$DOCKER_LOG")"
fi

# MANIFEST_VERIFY=0 exists for a registry that cannot be read back by the
# publishing job; it must be opt-out, never the default.
reset_registry
publish ghcr.io/link-foundation/box:2.7.0-amd64 linux/amd64
run MANIFEST_VERIFY=0 -- ghcr.io/link-foundation/box 2.7.0
if [ "$STATUS" -eq 0 ] && ! grep -q 'imagetools inspect' "$DOCKER_LOG"; then
  pass "MANIFEST_VERIFY=0 skips the read-back, and nothing else does"
else
  fail "MANIFEST_VERIFY=0 skips the read-back" "$OUT" "$(cat "$DOCKER_LOG")"
fi

echo ""
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
