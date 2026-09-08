#!/usr/bin/env bash
# test-issue119-platform-coverage.sh
#
# Issue #119: `konard/box:latest` answers HTTP 200 to an anonymous manifest GET
# and carries linux/amd64 alone, where 2.4.0 carries both architectures. Every
# check in the pipeline asked "does this reference resolve?", and a
# single-architecture tag resolves perfectly - so the release that dropped arm64
# from the Docker Hub tags was reported green.
#
# Resolvability is therefore not the question. This suite pins the answer to the
# question that is: *what does the reference actually serve?*
#
# What it asserts:
#   Part 1  an index answers with the platforms of its children
#   Part 2  attestation manifests are not architectures
#   Part 3  a plain manifest declares no platform, and is resolved from its config
#   Part 4  the platform probe costs nothing on the states that cannot have one
#   Part 5  missing coverage is computed, not eyeballed
#   Part 6  the platform probe answers through globals, like every other probe
#
# Every request goes through registry_probe_http, so a fixture table drives all
# of it offline. The bodies are the shapes recorded on 2026-09-08 in
# dev/log/issues/119/pulls/120/platform-coverage-2026-09-08.log.
#
# Usage: bash experiments/test-issue119-platform-coverage.sh

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
  [ $# -gt 1 ] && printf '      %s\n' "${@:2}"
}

# shellcheck source=../scripts/release/registry-probe.sh
source scripts/release/registry-probe.sh

declare -A FIXTURE=()
declare -A FIXTURE_BODY=()
declare -A FIXTURE_HEADERS=()

REQUESTS_LOG="$(mktemp)"
trap 'rm -f "$REQUESTS_LOG"' EXIT
requests() { cat "$REQUESTS_LOG"; }
reset_requests() { : >"$REQUESTS_LOG"; }

fixture() {
  local key="$1 $2"
  FIXTURE["$key"]="$3"
  FIXTURE_BODY["$key"]="${4:-}"
  FIXTURE_HEADERS["$key"]="${5:-}"
}

registry_probe_http() {
  local method="$1" url="$2"
  local key="$method $url"
  printf '%s %s\n' "$method" "$url" >>"$REQUESTS_LOG"

  if [ -z "${FIXTURE[$key]:-}" ]; then
    echo "TEST BUG: no fixture for '$key'" >&2
    printf '000\n'
    return 0
  fi

  printf '%s\n' "${FIXTURE[$key]}"
  [ -n "${FIXTURE_HEADERS[$key]:-}" ] && printf '%s\n' "${FIXTURE_HEADERS[$key]}"
  printf '\n%s' "${FIXTURE_BODY[$key]:-}"
}

GHCR_TOKEN='https://ghcr.io/token?service=ghcr.io'
DH_TOKEN='https://auth.docker.io/token?service=registry.docker.io'
GHCR_API='https://ghcr.io'
DH_API='https://registry-1.docker.io'

OCI_INDEX='application/vnd.oci.image.index.v1+json'
OCI_MANIFEST='application/vnd.oci.image.manifest.v1+json'
DOCKER_LIST='application/vnd.docker.distribution.manifest.list.v2+json'

# A two-architecture index, pretty-printed the way ghcr.io serves it. The line
# breaks matter: sed is line-oriented, and an earlier attempt at this parser
# read "architecture" and "os" as if they were on the same line and returned
# nothing at all.
BOTH_ARCHES='{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:aaa",
      "size": 2000,
      "platform": {
        "architecture": "amd64",
        "os": "linux"
      }
    },
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:bbb",
      "size": 2000,
      "platform": {
        "architecture": "arm64",
        "os": "linux"
      }
    }
  ]
}'

# What `docker buildx imagetools create --tag X Y-amd64` writes: an index with
# one child. This is the body konard/box:2.7.0 served on 2026-09-08.
ONE_ARCH='{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:aaa","size":2000,"platform":{"architecture":"amd64","os":"linux"}}]}'

echo "== Part 1: an index answers with the platforms of its children =="

check_platforms() {
  local ref="$1" want="$2"
  registry_probe_platforms "$ref"
  if [ "$REGISTRY_PROBE_PLATFORMS" = "$want" ]; then
    pass "$ref -> [$want]"
  else
    fail "$ref -> [$want]" "got: [$REGISTRY_PROBE_PLATFORMS] state=$REGISTRY_PROBE_STATE"
  fi
}

fixture GET "${GHCR_TOKEN}&scope=repository:link-foundation/box:pull" 200 '{"token":"t"}'
fixture GET "${GHCR_API}/v2/link-foundation/box/manifests/2.7.0" 200 "$BOTH_ARCHES" \
  "Content-Type: ${OCI_INDEX}"
check_platforms 'ghcr.io/link-foundation/box:2.7.0' 'linux/amd64 linux/arm64'

if [ "$REGISTRY_PROBE_MEDIA_TYPE" = "$OCI_INDEX" ]; then
  pass "the media type the registry served is reported alongside the platforms"
else
  fail "the media type the registry served is reported alongside the platforms" \
    "got: $REGISTRY_PROBE_MEDIA_TYPE"
fi

# The defect, exactly as measured: HTTP 200, and one architecture.
fixture GET "${DH_TOKEN}&scope=repository:konard/box:pull" 200 '{"token":"t"}'
fixture GET "${DH_API}/v2/konard/box/manifests/latest" 200 "$ONE_ARCH" \
  "Content-Type: ${OCI_INDEX}"
check_platforms 'konard/box:latest' 'linux/amd64'

if [ "$REGISTRY_PROBE_STATE" = "published" ]; then
  pass "a single-architecture index still resolves - which is why resolving is not the check"
else
  fail "a single-architecture index still resolves" "state=$REGISTRY_PROBE_STATE"
fi

# Docker Hub serves the 2.4.0 manifest list under its own media type. Reading
# platforms only out of OCI indexes would report the last good release as
# single-arch and fail a run over it.
fixture GET "${DH_API}/v2/konard/box/manifests/2.4.0" 200 \
  "${BOTH_ARCHES//application\/vnd.oci.image.index.v1+json/application\/vnd.docker.distribution.manifest.list.v2+json}" \
  "Content-Type: ${DOCKER_LIST}"
check_platforms 'konard/box:2.4.0' 'linux/amd64 linux/arm64'

# No Content-Type header: the body still says what it is.
fixture GET "${DH_API}/v2/konard/box/manifests/2.6.0" 200 "$BOTH_ARCHES"
check_platforms 'konard/box:2.6.0' 'linux/amd64 linux/arm64'
if [ "$REGISTRY_PROBE_MEDIA_TYPE" = "$OCI_INDEX" ]; then
  pass "the media type falls back to the one declared in the manifest body"
else
  fail "the media type falls back to the one declared in the manifest body" \
    "got: $REGISTRY_PROBE_MEDIA_TYPE"
fi

echo ""
echo "== Part 2: attestation manifests are not architectures =="

# buildx attaches provenance and SBOM manifests with platform unknown/unknown.
# Counting them would make a single-arch index look like a two-platform one -
# and "unknown" is exactly the child an amd64-only mirror still carries.
ATTESTED='{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[
  {"digest":"sha256:aaa","platform":{"architecture":"amd64","os":"linux"}},
  {"digest":"sha256:ccc","annotations":{"vnd.docker.reference.type":"attestation-manifest"},"platform":{"architecture":"unknown","os":"unknown"}}]}'
fixture GET "${DH_API}/v2/konard/box/manifests/2.7.0" 200 "$ATTESTED" "Content-Type: ${OCI_INDEX}"
check_platforms 'konard/box:2.7.0' 'linux/amd64'

echo ""
echo "== Part 3: a plain manifest declares no platform =="

# ghcr.io/link-foundation/box:20260907 is served as a plain OCI manifest: the
# unsuffixed date tag was written by the amd64 build job, not by the manifest
# job. A plain manifest has no "platform" field anywhere - the architecture is
# in its config blob, one request further down.
PLAIN='{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"sha256:cfg","size":3000},"layers":[{"digest":"sha256:l1"}]}'
fixture GET "${GHCR_API}/v2/link-foundation/box/manifests/20260907" 200 "$PLAIN" \
  "Content-Type: ${OCI_MANIFEST}"
fixture GET "${GHCR_API}/v2/link-foundation/box/blobs/sha256:cfg" 200 \
  '{"architecture":"amd64","os":"linux","rootfs":{"type":"layers"}}'
check_platforms 'ghcr.io/link-foundation/box:20260907' 'linux/amd64'

# The extra request belongs to registry_probe_platforms alone. check-publication
# sweeps 56 references for their state; doubling that request count to answer a
# question it is not asking is how a probe earns a rate limit.
reset_requests
registry_probe_pull 'ghcr.io/link-foundation/box:20260907'
if ! requests | grep -q '/blobs/'; then
  pass "registry_probe_pull does not fetch config blobs"
else
  fail "registry_probe_pull does not fetch config blobs" "$(requests)"
fi

# An index is answered from the manifest that was already fetched.
reset_requests
registry_probe_platforms 'ghcr.io/link-foundation/box:2.7.0'
if ! requests | grep -q '/blobs/'; then
  pass "an index costs no second request"
else
  fail "an index costs no second request" "$(requests)"
fi

echo ""
echo "== Part 4: states that cannot have a platform cost nothing =="

check_no_platforms() {
  local ref="$1" want_state="$2"
  reset_requests
  registry_probe_platforms "$ref"
  if [ "$REGISTRY_PROBE_STATE" = "$want_state" ] && [ -z "$REGISTRY_PROBE_PLATFORMS" ] \
    && ! requests | grep -q '/blobs/'; then
    pass "$ref -> $want_state, no platforms, no blob request"
  else
    fail "$ref -> $want_state, no platforms, no blob request" \
      "state=$REGISTRY_PROBE_STATE platforms=[$REGISTRY_PROBE_PLATFORMS]" "$(requests)"
  fi
}

fixture GET "${DH_API}/v2/konard/box-dind/manifests/2.7.0" 404 '{"errors":[{"code":"MANIFEST_UNKNOWN"}]}'
fixture GET "${DH_TOKEN}&scope=repository:konard/box-dind:pull" 200 '{"token":"t"}'
check_no_platforms 'konard/box-dind:2.7.0' missing

fixture GET "${GHCR_TOKEN}&scope=repository:link-foundation/private:pull" 401 '{"errors":[{"code":"UNAUTHORIZED"}]}'
check_no_platforms 'ghcr.io/link-foundation/private:2.7.0' private

fixture GET "${GHCR_TOKEN}&scope=repository:link-foundation/limited:pull" 200 '{"token":"t"}'
fixture GET "${GHCR_API}/v2/link-foundation/limited/manifests/2.7.0" 429 ''
check_no_platforms 'ghcr.io/link-foundation/limited:2.7.0' unknown

# A published manifest whose config blob cannot be read is "I could not look",
# not "single-arch": failing a release on it would be the false claim this
# whole file is here to prevent, pointed the other way.
fixture GET "${GHCR_API}/v2/link-foundation/box/manifests/fd4742b" 200 "$PLAIN" \
  "Content-Type: ${OCI_MANIFEST}"
fixture GET "${GHCR_API}/v2/link-foundation/box/blobs/sha256:cfg" 500 ''
registry_probe_platforms 'ghcr.io/link-foundation/box:fd4742b'
if [ -z "$REGISTRY_PROBE_PLATFORMS" ] && [ "$REGISTRY_PROBE_STATE" = "published" ]; then
  pass "an unreadable config blob leaves the platforms unknown, not wrong"
else
  fail "an unreadable config blob leaves the platforms unknown, not wrong" \
    "platforms=[$REGISTRY_PROBE_PLATFORMS] state=$REGISTRY_PROBE_STATE"
fi

echo ""
echo "== Part 5: missing coverage is computed, not eyeballed =="

check_missing() {
  local want="$1" got="$2" expect="$3" result
  result="$(registry_probe_missing_platforms "$want" "$got")"
  if [ "$result" = "$expect" ]; then
    pass "want [$want] got [$got] -> missing [$expect]"
  else
    fail "want [$want] got [$got] -> missing [$expect]" "got: [$result]"
  fi
}

check_missing 'linux/amd64 linux/arm64' 'linux/amd64 linux/arm64' ''
check_missing 'linux/amd64 linux/arm64' 'linux/amd64' 'linux/arm64'
check_missing 'linux/amd64 linux/arm64' '' 'linux/amd64 linux/arm64'
# A superset is not a failure: an image that also serves riscv64 covers what
# was asked for.
check_missing 'linux/amd64' 'linux/amd64 linux/arm64' ''
# Substring matching would report linux/arm64 as covered by linux/arm64/v8's
# absence - or worse, "arm64" as covered by "linux/amd64,linux/arm64" text.
check_missing 'linux/arm64' 'linux/amd64' 'linux/arm64'

echo ""
echo "== Part 6: the platform probe answers through globals =="

fixture GET "${GHCR_API}/v2/link-foundation/box/manifests/2.7.0" 200 "$BOTH_ARCHES" \
  "Content-Type: ${OCI_INDEX}"
STDOUT="$(registry_probe_platforms 'ghcr.io/link-foundation/box:2.7.0')"
if [ -z "$STDOUT" ]; then
  pass "registry_probe_platforms prints nothing, so it is never run in a subshell"
else
  fail "registry_probe_platforms prints nothing" "stdout: $STDOUT"
fi

echo ""
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
