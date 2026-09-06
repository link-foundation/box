#!/usr/bin/env bash
# test-issue117-preflight.sh
#
# Issue #117: release 2.5.0 and 2.6.0 were built and never published. The
# Docker Hub credential had expired before the run started, the login step is
# tolerant of failure by design, and the mirror steps were `skipped` - which
# every gate downstream read as "fine". About forty build jobs produced images
# that went nowhere, and the run was green.
#
# scripts/release/preflight-credentials.sh is the gate that stops that run in
# its first ten seconds. This suite pins its decisions without touching the
# network: the script finds registry-probe.sh next to itself, so the tests copy
# it into a sandbox with a stub probe beside it and drive every state the real
# probe can return.
#
# What it asserts:
#   Part 1  misconfiguration exits 2, and is never confused with a bad token
#   Part 2  release mode fails on anything that is not a proven write
#   Part 3  report mode warns instead, and never claims it verified anything
#   Part 4  an optional Docker Hub mirror is not probed at all
#   Part 5  a private or unreachable GHCR package blocks the release
#   Part 6  a credential left by `docker login` (OIDC) is checked like a PAT
#   Part 7  the machine-readable outputs, and that no secret is echoed
#
# Usage: bash experiments/test-issue117-preflight.sh

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

# --- the sandbox -------------------------------------------------------------
#
# preflight-credentials.sh sources "${SCRIPT_DIR}/registry-probe.sh", where
# SCRIPT_DIR comes from its own BASH_SOURCE. Copying the script into a
# directory that holds a stub of that name replaces the network layer whole,
# without a test-only hook in the production script.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/scripts/release"
cp scripts/release/preflight-credentials.sh "$WORK/scripts/release/"

PREFLIGHT="$WORK/scripts/release/preflight-credentials.sh"
FIXTURES="$WORK/fixtures"
STUB_LOG="$WORK/probe.log"

cat >"$WORK/scripts/release/registry-probe.sh" <<'STUB'
# Stub registry-probe.sh: answers from $STUB_FIXTURES, logs to $STUB_LOG.
#
# Fixture lines are "push REGISTRY/REPOSITORY STATE DETAIL..." or
# "pull REFERENCE STATE DETAIL...". A request with no fixture is a test bug and
# says so, rather than defaulting to a state that might accidentally pass.
REGISTRY_PROBE_STATE=""
REGISTRY_PROBE_DETAIL=""
REGISTRY_PROBE_REPOSITORY=""

_stub_lookup() {
  local kind="$1" key="$2" line
  while IFS= read -r line; do
    case "$line" in
      "$kind $key "*)
        line="${line#"$kind $key "}"
        REGISTRY_PROBE_STATE="${line%% *}"
        REGISTRY_PROBE_DETAIL="${line#* }"
        return 0
        ;;
    esac
  done <"${STUB_FIXTURES}"
  REGISTRY_PROBE_STATE="test-bug"
  REGISTRY_PROBE_DETAIL="no fixture for '$kind $key'"
  return 0
}

registry_probe_push() {
  local registry="$1" repository="$2"
  printf 'push %s/%s user=[%s] secret=[%s]\n' "$registry" "$repository" \
    "${REGISTRY_PROBE_USERNAME:-}" "${REGISTRY_PROBE_PASSWORD:-}" >>"${STUB_LOG}"
  REGISTRY_PROBE_REPOSITORY="$repository"
  _stub_lookup push "$registry/$repository"
}

registry_probe_pull() {
  local ref="$1"
  printf 'pull %s\n' "$ref" >>"${STUB_LOG}"
  REGISTRY_PROBE_REPOSITORY="${ref#*/}"
  REGISTRY_PROBE_REPOSITORY="${REGISTRY_PROBE_REPOSITORY%%:*}"
  _stub_lookup pull "$ref"
}
STUB

fixtures() {
  printf '%s\n' "$@" >"$FIXTURES"
}

# Both packages public and both credentials good - the state a release needs.
HAPPY=(
  "push ghcr.io/link-foundation/box ok ghcr.io accepted a blob upload session"
  "push docker.io/konard/box ok docker.io accepted a blob upload session"
  "pull ghcr.io/link-foundation/box:latest published anonymous pull works"
  "pull ghcr.io/link-foundation/box-dind:latest published anonymous pull works"
)

OUT=""
STATUS=0

# run_preflight [VAR=VALUE...] [-- ARGS...] - run the script in the sandbox.
run_preflight() {
  local env_pairs=() args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --)
        shift
        args=("$@")
        break
        ;;
      *)
        env_pairs+=("$1")
        shift
        ;;
    esac
  done
  : >"$STUB_LOG"
  OUT="$(env -i \
    PATH="$PATH" HOME="$HOME" \
    STUB_FIXTURES="$FIXTURES" STUB_LOG="$STUB_LOG" \
    GHCR_IMAGE_NAME="link-foundation/box" \
    DOCKERHUB_IMAGE_NAME="konard/box" \
    GHCR_USERNAME="box-ci" GITHUB_TOKEN="ghcr-secret" \
    DOCKERHUB_USERNAME="konard" DOCKERHUB_TOKEN="hub-secret" \
    "${env_pairs[@]}" \
    bash "$PREFLIGHT" ${args[@]+"${args[@]}"} 2>&1)"
  STATUS=$?
}

contains() { printf '%s' "$OUT" | grep -qF -- "$1"; }
log_has() { grep -qF -- "$1" "$STUB_LOG"; }

echo "=== Part 1: misconfiguration is not the same as a bad credential ==="

fixtures "${HAPPY[@]}"

run_preflight -- --mode nonsense
if [ "$STATUS" -eq 2 ]; then
  pass "an unknown --mode exits 2, not 1"
else
  fail "an unknown --mode exits 2, not 1" "exit=$STATUS" "$OUT"
fi

run_preflight -- --gibberish
if [ "$STATUS" -eq 2 ]; then
  pass "an unknown option exits 2"
else
  fail "an unknown option exits 2" "exit=$STATUS"
fi

run_preflight GHCR_IMAGE_NAME=
if [ "$STATUS" -eq 2 ] && contains "GHCR_IMAGE_NAME is required"; then
  pass "a missing image name exits 2 and says which variable"
else
  fail "a missing image name exits 2 and says which variable" "exit=$STATUS" "$OUT"
fi

run_preflight
if [ "$STATUS" -eq 0 ]; then
  pass "the happy path exits 0"
else
  fail "the happy path exits 0" "exit=$STATUS" "$OUT"
fi

if contains "2 registry credential(s) accepted a write"; then
  pass "the happy path reports how many writes it actually proved"
else
  fail "the happy path reports how many writes it actually proved" "$OUT"
fi

echo ""
echo "=== Part 2: release mode fails on anything short of a proven write ==="

# The failure that shipped 2.5.0 and 2.6.0 into nowhere: an expired token.
fixtures \
  "push ghcr.io/link-foundation/box ok fine" \
  "push docker.io/konard/box invalid-credentials docker.io rejected the credential (HTTP 401)" \
  "pull ghcr.io/link-foundation/box:latest published fine" \
  "pull ghcr.io/link-foundation/box-dind:latest published fine"

run_preflight
if [ "$STATUS" -eq 1 ]; then
  pass "an expired Docker Hub token fails the run before any build"
else
  fail "an expired Docker Hub token fails the run before any build" "exit=$STATUS" "$OUT"
fi
if contains "::error title=Docker Hub credential rejected::"; then
  pass "and annotates it as an error, naming the registry"
else
  fail "and annotates it as an error, naming the registry" "$OUT"
fi
if contains "Stopping here rather than building images this run cannot publish"; then
  pass "and says why it is stopping"
else
  fail "and says why it is stopping" "$OUT"
fi

fixtures \
  "push ghcr.io/link-foundation/box insufficient-scope ghcr.io denied write (HTTP 403)" \
  "push docker.io/konard/box ok fine" \
  "pull ghcr.io/link-foundation/box:latest published fine" \
  "pull ghcr.io/link-foundation/box-dind:latest published fine"
run_preflight
if [ "$STATUS" -eq 1 ] && contains "::error title=GHCR credential cannot write::"; then
  pass "a token that authenticates but cannot write is a failure"
else
  fail "a token that authenticates but cannot write is a failure" "exit=$STATUS" "$OUT"
fi

fixtures \
  "push ghcr.io/link-foundation/box ok fine" \
  "push docker.io/konard/box unknown docker.io answered HTTP 503" \
  "pull ghcr.io/link-foundation/box:latest published fine" \
  "pull ghcr.io/link-foundation/box-dind:latest published fine"
run_preflight
if [ "$STATUS" -eq 1 ] && contains "::error title=Docker Hub could not be checked::"; then
  pass "a registry that did not answer blocks the release (unknown is not a pass)"
else
  fail "a registry that did not answer blocks the release (unknown is not a pass)" "exit=$STATUS" "$OUT"
fi

fixtures \
  "push ghcr.io/link-foundation/box ok fine" \
  "push docker.io/konard/box ok fine" \
  "pull ghcr.io/link-foundation/box:latest published fine" \
  "pull ghcr.io/link-foundation/box-dind:latest published fine"
run_preflight DOCKERHUB_TOKEN= DOCKERHUB_USERNAME= HOME="$WORK/empty-home"
if [ "$STATUS" -eq 1 ] && contains "::error title=Docker Hub credential missing::"; then
  pass "a credential that is simply absent fails too, and says so distinctly"
else
  fail "a credential that is simply absent fails too, and says so distinctly" "exit=$STATUS" "$OUT"
fi
if ! log_has "push docker.io/konard/box"; then
  pass "and no write is attempted with an empty credential"
else
  fail "and no write is attempted with an empty credential" "$(cat "$STUB_LOG")"
fi

echo ""
echo "=== Part 3: report mode warns, and never overstates what it checked ==="

fixtures \
  "push ghcr.io/link-foundation/box invalid-credentials rejected" \
  "push docker.io/konard/box invalid-credentials rejected" \
  "pull ghcr.io/link-foundation/box:latest private no anonymous pull token" \
  "pull ghcr.io/link-foundation/box-dind:latest private no anonymous pull token"

run_preflight -- --mode report
if [ "$STATUS" -eq 0 ]; then
  pass "report mode exits 0 with everything broken (a PR is not a release)"
else
  fail "report mode exits 0 with everything broken" "exit=$STATUS" "$OUT"
fi
if ! contains "::error"; then
  pass "report mode emits no error annotations"
else
  fail "report mode emits no error annotations" "$OUT"
fi
if [ "$(printf '%s' "$OUT" | grep -c '::warning')" -eq 4 ]; then
  pass "report mode emits one warning per problem it found (4)"
else
  fail "report mode emits one warning per problem it found (4)" "$OUT"
fi
if contains "Nothing was verified"; then
  pass "and does not report 'accepted a write' when it verified nothing"
else
  fail "and does not report 'accepted a write' when it verified nothing" "$OUT"
fi

run_preflight PREFLIGHT_MODE=report
if [ "$STATUS" -eq 0 ] && contains "(report mode)"; then
  pass "PREFLIGHT_MODE=report is equivalent to --mode report"
else
  fail "PREFLIGHT_MODE=report is equivalent to --mode report" "exit=$STATUS" "$OUT"
fi

echo ""
echo "=== Part 4: an optional mirror is not probed at all ==="

fixtures \
  "push ghcr.io/link-foundation/box ok fine" \
  "pull ghcr.io/link-foundation/box:latest published fine" \
  "pull ghcr.io/link-foundation/box-dind:latest published fine"
run_preflight DOCKERHUB_REQUIRED=0
if [ "$STATUS" -eq 0 ]; then
  pass "DOCKERHUB_REQUIRED=0 releases on GHCR alone"
else
  fail "DOCKERHUB_REQUIRED=0 releases on GHCR alone" "exit=$STATUS" "$OUT"
fi
if ! log_has "push docker.io"; then
  pass "and sends no request to Docker Hub"
else
  fail "and sends no request to Docker Hub" "$(cat "$STUB_LOG")"
fi

echo ""
echo "=== Part 5: an unreachable GHCR package blocks the release ==="

fixtures \
  "push ghcr.io/link-foundation/box ok fine" \
  "push docker.io/konard/box ok fine" \
  "pull ghcr.io/link-foundation/box:latest private no anonymous pull token (HTTP 401)" \
  "pull ghcr.io/link-foundation/box-dind:latest published fine"

run_preflight
if [ "$STATUS" -eq 1 ] && contains "::error title=GHCR package is private::"; then
  pass "a private registry-of-record package is a blocking failure"
else
  fail "a private registry-of-record package is a blocking failure" "exit=$STATUS" "$OUT"
fi
if contains "Package settings -> Change visibility -> Public"; then
  pass "and the annotation carries the manual runbook (there is no API for it)"
else
  fail "and the annotation carries the manual runbook" "$OUT"
fi

run_preflight ALLOW_PRIVATE_GHCR=1
if [ "$STATUS" -eq 0 ] && contains "::warning title=GHCR package is private::"; then
  pass "ALLOW_PRIVATE_GHCR=1 downgrades it to a warning"
else
  fail "ALLOW_PRIVATE_GHCR=1 downgrades it to a warning" "exit=$STATUS" "$OUT"
fi

fixtures \
  "push ghcr.io/link-foundation/box ok fine" \
  "push docker.io/konard/box ok fine" \
  "pull ghcr.io/link-foundation/box:latest missing manifest unknown (HTTP 404)" \
  "pull ghcr.io/link-foundation/box-dind:latest missing manifest unknown (HTTP 404)"
run_preflight
if [ "$STATUS" -eq 0 ]; then
  pass "a package that does not exist yet is not a visibility failure"
else
  fail "a package that does not exist yet is not a visibility failure" "exit=$STATUS" "$OUT"
fi

fixtures \
  "push ghcr.io/link-foundation/box ok fine" \
  "push docker.io/konard/box ok fine" \
  "pull ghcr.io/link-foundation/box:latest unknown ghcr.io answered HTTP 429" \
  "pull ghcr.io/link-foundation/box-dind:latest published fine"
run_preflight
if [ "$STATUS" -eq 0 ] && contains "::warning title=GHCR visibility unknown::"; then
  pass "a rate-limited visibility check warns instead of claiming 'private'"
else
  fail "a rate-limited visibility check warns instead of claiming 'private'" "exit=$STATUS" "$OUT"
fi

echo ""
echo "=== Part 6: a credential left by docker login (OIDC) is checked too ==="

# Trusted publishing never puts a PAT in the environment: docker/login-action
# writes a short-lived credential into the Docker CLI config and that is all
# there is to check. Without this the preflight would block every OIDC release
# with "no credential configured".
mkdir -p "$WORK/docker-config"
cat >"$WORK/docker-config/config.json" <<'JSON'
{
  "auths": {
    "https://index.docker.io/v1/": {
      "auth": "a29uYXJkOm9pZGMtc2hvcnQtbGl2ZWQ="
    }
  }
}
JSON

fixtures "${HAPPY[@]}"
run_preflight DOCKERHUB_TOKEN= DOCKERHUB_USERNAME= DOCKER_CONFIG="$WORK/docker-config"
if [ "$STATUS" -eq 0 ]; then
  pass "an OIDC login with no PAT in the environment passes the preflight"
else
  fail "an OIDC login with no PAT in the environment passes the preflight" "exit=$STATUS" "$OUT"
fi
if log_has "push docker.io/konard/box user=[konard] secret=[oidc-short-lived]"; then
  pass "and the credential from the Docker config is what gets probed"
else
  fail "and the credential from the Docker config is what gets probed" "$(cat "$STUB_LOG")"
fi
if ! contains "oidc-short-lived"; then
  pass "and the secret is never echoed into the log"
else
  fail "and the secret is never echoed into the log" "$OUT"
fi

mkdir -p "$WORK/other-config"
cat >"$WORK/other-config/config.json" <<'JSON'
{ "auths": { "ghcr.io": { "auth": "Ym94OmdoY3ItdG9rZW4=" } } }
JSON
run_preflight DOCKERHUB_TOKEN= DOCKERHUB_USERNAME= DOCKER_CONFIG="$WORK/other-config"
if [ "$STATUS" -eq 1 ] && contains "::error title=Docker Hub credential missing::"; then
  pass "a config holding some other registry's credential is not mistaken for one"
else
  fail "a config holding some other registry's credential is not mistaken for one" "exit=$STATUS" "$OUT"
fi

echo ""
echo "=== Part 7: machine-readable outputs ==="

fixtures \
  "push ghcr.io/link-foundation/box invalid-credentials rejected" \
  "push docker.io/konard/box ok fine" \
  "pull ghcr.io/link-foundation/box:latest published fine" \
  "pull ghcr.io/link-foundation/box-dind:latest published fine"

GH_OUTPUT="$WORK/github-output"
GH_SUMMARY="$WORK/step-summary"
: >"$GH_OUTPUT"
: >"$GH_SUMMARY"
run_preflight GITHUB_OUTPUT="$GH_OUTPUT" GITHUB_STEP_SUMMARY="$GH_SUMMARY"

if grep -qx 'failures=1' "$GH_OUTPUT" && grep -qx 'ok=false' "$GH_OUTPUT"; then
  pass "GITHUB_OUTPUT carries failures= and ok= for downstream jobs"
else
  fail "GITHUB_OUTPUT carries failures= and ok= for downstream jobs" "$(cat "$GH_OUTPUT")"
fi
if grep -q '| GHCR | ghcr.io/link-foundation/box | rejected |' "$GH_SUMMARY"; then
  pass "the step summary states each target's verified state"
else
  fail "the step summary states each target's verified state" "$(cat "$GH_SUMMARY")"
fi
if grep -q 'GHCR visibility' "$GH_SUMMARY"; then
  pass "the step summary covers visibility as well as write access"
else
  fail "the step summary covers visibility as well as write access" "$(cat "$GH_SUMMARY")"
fi

echo ""
echo "=========================================="
echo "Passed: $PASS"
echo "Failed: $FAIL"
echo "=========================================="
[ "$FAIL" -eq 0 ]
