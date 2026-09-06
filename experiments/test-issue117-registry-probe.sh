#!/usr/bin/env bash
# test-issue117-registry-probe.sh
#
# Issue #117: the release notes for v2.6.0 claimed "28 of 56 image references
# resolve", and anonymously none of them did. The check ran `docker manifest
# inspect` inside a job that had just authenticated to ghcr.io, so it measured
# the publisher's view of the world and printed it as the consumer's.
#
# scripts/release/registry-probe.sh answers the consumer's question instead.
# This suite pins its behaviour without touching the network: every probe goes
# through registry_probe_http, so replacing that one function with a fixture
# table drives the whole state machine offline.
#
# What it asserts:
#   Part 1  reference parsing follows `docker pull` rules
#   Part 2  the anonymous pull probe maps registry answers to the four states
#   Part 3  the anonymous probe really is anonymous
#   Part 4  the push probe attempts a write and classifies the refusal
#   Part 5  probes answer through globals, not stdout (the reason survives)
#
# Usage: bash experiments/test-issue117-registry-probe.sh

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

# --- the fixture registry ----------------------------------------------------
#
# Keyed by "METHOD URL", value is the HTTP status; FIXTURE_BODY and
# FIXTURE_HEADERS hold the optional rest. An unlisted request is a test bug,
# not a 404: answering "404" for a request nobody meant to make would let a
# broken URL pass as a missing image, which is the confusion this whole file
# exists to prevent.
declare -A FIXTURE=()
declare -A FIXTURE_BODY=()
declare -A FIXTURE_HEADERS=()

# The request log is a file, not a variable. Every probe captures its HTTP
# response with `$(...)`, so the fake runs in a subshell and an assignment
# there would vanish - the same subshell trap Part 5 guards the probes against.
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
  printf '%s %s user=[%s]\n' "$method" "$url" "${REGISTRY_PROBE_USERNAME:-}" >>"$REQUESTS_LOG"

  if [ -z "${FIXTURE[$key]:-}" ]; then
    echo "TEST BUG: no fixture for '$key'" >&2
    printf '000\n'
    return 0
  fi

  # Status, headers, blank line, body - the document the real one returns.
  printf '%s\n' "${FIXTURE[$key]}"
  [ -n "${FIXTURE_HEADERS[$key]:-}" ] && printf '%s\n' "${FIXTURE_HEADERS[$key]}"
  printf '\n%s' "${FIXTURE_BODY[$key]:-}"
}

GHCR_TOKEN='https://ghcr.io/token?service=ghcr.io'
DH_TOKEN='https://auth.docker.io/token?service=registry.docker.io'
DH_API='https://registry-1.docker.io'

echo "== Part 1: reference parsing follows docker pull rules =="

check_parse() {
  local ref="$1" want="$2" got
  registry_probe_parse_ref "$ref"
  got="${REGISTRY_PROBE_REGISTRY}|${REGISTRY_PROBE_REPOSITORY}|${REGISTRY_PROBE_TAG}"
  if [ "$got" = "$want" ]; then
    pass "$ref -> $want"
  else
    fail "$ref -> $want" "got: $got"
  fi
}

# A bare name is Docker Hub's library namespace, exactly as `docker pull ubuntu`
# resolves it. Getting this wrong would probe library/konard/box and report a
# published image as missing.
check_parse 'ubuntu:24.04' 'docker.io|library/ubuntu|24.04'
check_parse 'ubuntu' 'docker.io|library/ubuntu|latest'
check_parse 'konard/box:2.6.0' 'docker.io|konard/box|2.6.0'
check_parse 'konard/box-dind:2.6.0-amd64' 'docker.io|konard/box-dind|2.6.0-amd64'
check_parse 'ghcr.io/link-foundation/box:2.6.0' 'ghcr.io|link-foundation/box|2.6.0'
check_parse 'ghcr.io/link-foundation/box' 'ghcr.io|link-foundation/box|latest'
check_parse 'localhost:5000/box:1' 'localhost:5000|box|1'
check_parse 'ghcr.io/a/b@sha256:abc' 'ghcr.io|a/b|sha256:abc'

echo ""
echo "== Part 2: the four states an anonymous consumer can be in =="

check_pull() {
  local ref="$1" want="$2"
  reset_requests
  registry_probe_pull "$ref"
  if [ "$REGISTRY_PROBE_STATE" = "$want" ]; then
    pass "$ref -> $want"
  else
    fail "$ref -> $want" "got: ${REGISTRY_PROBE_STATE} (${REGISTRY_PROBE_DETAIL})"
  fi
}

# A public GHCR package: a token for anyone, and a manifest.
fixture GET "${GHCR_TOKEN}&scope=repository:astral-sh/uv:pull" 200 '{"token":"t"}'
fixture GET 'https://ghcr.io/v2/astral-sh/uv/manifests/0.9.0' 200 '{}'
check_pull 'ghcr.io/astral-sh/uv:0.9.0' published

# Same package, a tag that was never pushed.
fixture GET 'https://ghcr.io/v2/astral-sh/uv/manifests/0.0.0-nope' 404 '{"errors":[{"code":"MANIFEST_UNKNOWN"}]}'
check_pull 'ghcr.io/astral-sh/uv:0.0.0-nope' missing

# The defect in issue #117 point 3: the package exists and was pushed, and
# ghcr.io will not name it to an anonymous caller. "private", not "missing" -
# the fix for one is a visibility change, for the other a rebuild.
fixture GET "${GHCR_TOKEN}&scope=repository:link-foundation/box:pull" 401 '{"errors":[{"code":"UNAUTHORIZED"}]}'
check_pull 'ghcr.io/link-foundation/box:2.6.0' private

# Docker Hub hands out an anonymous token for names that do not exist, so there
# the manifest request is what settles it.
fixture GET "${DH_TOKEN}&scope=repository:konard/box:pull" 200 '{"token":"t"}'
fixture GET "${DH_API}/v2/konard/box/manifests/2.6.0" 404 '{"errors":[{"code":"MANIFEST_UNKNOWN"}]}'
check_pull 'konard/box:2.6.0' missing

fixture GET "${DH_API}/v2/konard/box/manifests/2.4.0" 200 '{}'
check_pull 'konard/box:2.4.0' published

# Rate limiting and 5xx are "I could not look". Reporting them as "missing"
# would turn a Docker Hub pull-limit into a release-notes claim that the image
# was never published.
fixture GET "${DH_API}/v2/konard/box/manifests/2.5.0" 429 '{"errors":[{"code":"TOOMANYREQUESTS"}]}'
check_pull 'konard/box:2.5.0' unknown

fixture GET "${DH_API}/v2/konard/box/manifests/2.3.0" 503 ''
check_pull 'konard/box:2.3.0' unknown

fixture GET "${GHCR_TOKEN}&scope=repository:x/y:pull" 500 ''
check_pull 'ghcr.io/x/y:1' unknown

# A registry the probe does not know is "unknown" too, and it costs no request:
# a guessed endpoint that 404s is indistinguishable from a missing image.
reset_requests
registry_probe_pull 'example.invalid/x:1'
if [ "$REGISTRY_PROBE_STATE" = "unknown" ] && [ -z "$(requests)" ]; then
  pass "an unknown registry is 'unknown', and is not guessed at"
else
  fail "an unknown registry is 'unknown', and is not guessed at" \
    "state=$REGISTRY_PROBE_STATE requests=[$(requests)]"
fi

echo ""
echo "== Part 3: the anonymous probe is anonymous =="

# The whole point of issue #117: the old check ran inside a logged-in job. If a
# credential ever leaks into the pull path, the probe starts reporting the
# publisher's view again and the false positive comes straight back.
REGISTRY_PROBE_USERNAME="someone"
REGISTRY_PROBE_PASSWORD="secret"
reset_requests
registry_probe_pull 'konard/box:2.4.0'
REGISTRY_PROBE_USERNAME=""
REGISTRY_PROBE_PASSWORD=""

if [ "$REGISTRY_PROBE_STATE" = "published" ] && ! requests | grep -q 'user=\[someone\]'; then
  pass "no credential reaches the registry on the pull path"
else
  fail "no credential reaches the registry on the pull path" "$(requests)"
fi

# Both requests, not just the manifest one: a credential on the token request
# is what makes a private package look public.
if [ "$(requests | grep -c 'user=\[\]')" = "2" ]; then
  pass "both the token and the manifest request are unauthenticated"
else
  fail "both the token and the manifest request are unauthenticated" "$(requests)"
fi

echo ""
echo "== Part 4: the push probe attempts a write =="

check_push() {
  local registry="$1" repository="$2" want="$3"
  reset_requests
  registry_probe_push "$registry" "$repository"
  if [ "$REGISTRY_PROBE_STATE" = "$want" ]; then
    pass "push $registry/$repository -> $want"
  else
    fail "push $registry/$repository -> $want" "got: ${REGISTRY_PROBE_STATE} (${REGISTRY_PROBE_DETAIL})"
  fi
}

REGISTRY_PROBE_USERNAME=""
REGISTRY_PROBE_PASSWORD=""
check_push docker.io konard/box missing-credentials

REGISTRY_PROBE_USERNAME="konard"
REGISTRY_PROBE_PASSWORD="pat"

# Docker Hub is the one registry whose token endpoint does reject a bad
# credential, and it is the failure that broke release 2.5.0 and 2.6.0.
fixture GET "${DH_TOKEN}&scope=repository:konard/box:pull,push" 401 '{"details":"incorrect username or password"}'
check_push docker.io konard/box invalid-credentials

# ghcr.io answers 200 with base64 of the credential for any scope, so the token
# request proves nothing and the blob upload session is the real check. This
# fixture is the transcript recorded in
# dev/log/issues/117/pulls/118/token-endpoint-is-not-a-credential-check.log.
fixture GET "${GHCR_TOKEN}&scope=repository:link-foundation/box:pull,push" 200 '{"token":"Z2hvXw=="}'
fixture POST 'https://ghcr.io/v2/link-foundation/box/blobs/uploads/' 403 \
  '{"errors":[{"code":"DENIED","message":"permission_denied: The token provided does not match expected scopes."}]}'
check_push ghcr.io link-foundation/box insufficient-scope

# The same request, answered by a credential that can write.
fixture POST 'https://ghcr.io/v2/link-foundation/box/blobs/uploads/' 202 '' \
  'Location: /v2/link-foundation/box/blobs/uploads/session-1'
fixture DELETE 'https://ghcr.io/v2/link-foundation/box/blobs/uploads/session-1' 204 ''
check_push ghcr.io link-foundation/box ok

# Nothing may be left behind. An upload session that is never cancelled holds
# registry storage, and a probe that litters is a probe people switch off.
if requests | grep -q '^DELETE https://ghcr.io/v2/link-foundation/box/blobs/uploads/session-1 '; then
  pass "the upload session is cancelled, so the probe publishes nothing"
else
  fail "the upload session is cancelled, so the probe publishes nothing" "$(requests)"
fi

# A 401 on the write is a rejected credential; a 403 is a credential without
# the scope. Collapsing them would send someone to rotate a working token.
fixture POST 'https://ghcr.io/v2/link-foundation/box/blobs/uploads/' 401 ''
check_push ghcr.io link-foundation/box invalid-credentials

fixture POST 'https://ghcr.io/v2/link-foundation/box/blobs/uploads/' 500 ''
check_push ghcr.io link-foundation/box unknown

fixture GET "${GHCR_TOKEN}&scope=repository:link-foundation/box:pull,push" 200 '{"expires_in":300}'
check_push ghcr.io link-foundation/box unknown

fixture GET "${GHCR_TOKEN}&scope=repository:link-foundation/box:pull,push" 502 ''
check_push ghcr.io link-foundation/box unknown

check_push example.invalid a/b unknown

REGISTRY_PROBE_USERNAME=""
REGISTRY_PROBE_PASSWORD=""

echo ""
echo "== Part 5: the answer and the reason both reach the caller =="

# Regression guard for a bug this suite was written against: the probes used to
# print their state, so `state="$(registry_probe_pull ref)"` ran them in a
# subshell and every REGISTRY_PROBE_DETAIL assignment was discarded with it.
# The state survived and the reason did not, which is the worse half to lose.
fixture GET "${DH_API}/v2/konard/box/manifests/2.4.0" 200 '{}'
STDOUT="$(registry_probe_pull 'konard/box:2.4.0')"
if [ -z "$STDOUT" ]; then
  pass "the pull probe prints nothing, so it is never called in a subshell"
else
  fail "the pull probe prints nothing, so it is never called in a subshell" "stdout: $STDOUT"
fi

registry_probe_pull 'konard/box:2.4.0'
if [ -n "$REGISTRY_PROBE_DETAIL" ]; then
  pass "the reason reaches the caller alongside the state"
else
  fail "the reason reaches the caller alongside the state"
fi

REGISTRY_PROBE_USERNAME="konard"
# shellcheck disable=SC2034  # read by registry_probe_push in the sourced file
REGISTRY_PROBE_PASSWORD="pat"
STDOUT="$(registry_probe_push ghcr.io link-foundation/box)"
if [ -z "$STDOUT" ]; then
  pass "the push probe prints nothing either"
else
  fail "the push probe prints nothing either" "stdout: $STDOUT"
fi

echo ""
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
