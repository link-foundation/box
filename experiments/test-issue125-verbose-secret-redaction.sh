#!/usr/bin/env bash
# test-issue125-verbose-secret-redaction.sh
#
# BOX_VERBOSE is intended to make a failed CI check diagnosable.  It must not
# make credentials diagnosable too.  Issue #125's final verification found a
# live GitHub token in the verbose zizmor log; the same raw `set -x` pattern was
# present in the registry preflight and probe scripts.  Use inert canaries and
# offline stubs to pin all three entry points.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

passed=0
failed=0

pass() {
  echo "PASS: $1"
  passed=$((passed + 1))
}

fail() {
  echo "FAIL: $1" >&2
  failed=$((failed + 1))
}

assert_hidden() {
  local label="$1" secret="$2" output="$3"
  if grep -Fq -- "${secret}" <<<"${output}"; then
    fail "${label} verbose output contains its credential"
  else
    pass "${label} verbose output redacts its credential"
  fi
}

# Zizmor needs only a container-runtime stub.  The production wrapper forwards
# GH_TOKEN by name, so the stub does not need or print its value.
cat >"${work}/zizmor" <<'STUB'
#!/usr/bin/env bash
echo "zizmor stub completed"
STUB
chmod +x "${work}/zizmor"

zizmor_secret='private-zizmor-value-125'
zizmor_output="$(
  BOX_VERBOSE=1 GH_TOKEN="${zizmor_secret}" GITHUB_TOKEN='' \
    ZIZMOR_DOCKER="${work}/zizmor" \
    bash scripts/ci/run-zizmor.sh regular 2>&1
)"
zizmor_status=$?
if [ "${zizmor_status}" -eq 0 ]; then
  pass "zizmor still succeeds in verbose mode"
else
  fail "zizmor still succeeds in verbose mode (exit ${zizmor_status})"
fi
assert_hidden "zizmor" "${zizmor_secret}" "${zizmor_output}"

# An unsupported registry takes the real probe through credential validation
# without making a request.  That is enough to prove whether tracing expands
# REGISTRY_PROBE_PASSWORD.
probe_secret='private-registry-value-125'
probe_output="$(
  BOX_VERBOSE=1 REGISTRY_PROBE_USERNAME='probe-user' \
    REGISTRY_PROBE_PASSWORD="${probe_secret}" \
    bash -c \
    'source scripts/release/registry-probe.sh; registry_probe_push example.invalid a/b' \
    2>&1
)"
probe_status=$?
if [ "${probe_status}" -eq 0 ]; then
  pass "registry probe still answers in verbose mode"
else
  fail "registry probe still answers in verbose mode (exit ${probe_status})"
fi
assert_hidden "registry probe" "${probe_secret}" "${probe_output}"

# Preflight finds registry-probe.sh beside itself.  Pair a copied preflight
# with an offline stub that returns successful states without inspecting or
# printing either credential.
mkdir -p "${work}/preflight"
cp scripts/release/preflight-credentials.sh "${work}/preflight/"
cat >"${work}/preflight/registry-probe.sh" <<'STUB'
REGISTRY_PROBE_STATE=''
REGISTRY_PROBE_DETAIL=''
REGISTRY_PROBE_REPOSITORY=''
registry_probe_push() {
  REGISTRY_PROBE_STATE='ok'
  REGISTRY_PROBE_DETAIL='stub accepted write'
  REGISTRY_PROBE_REPOSITORY="$2"
}
registry_probe_pull() {
  REGISTRY_PROBE_STATE='published'
  REGISTRY_PROBE_DETAIL='stub serves anonymously'
  REGISTRY_PROBE_REPOSITORY="${1#*/}"
  REGISTRY_PROBE_REPOSITORY="${REGISTRY_PROBE_REPOSITORY%%:*}"
}
STUB

preflight_secret='private-preflight-value-125'
preflight_output="$(
  BOX_VERBOSE=1 GHCR_IMAGE_NAME='link-foundation/box' \
    DOCKERHUB_IMAGE_NAME='konard/box' GHCR_USERNAME='box-ci' \
    GITHUB_TOKEN="${preflight_secret}" DOCKERHUB_REQUIRED=0 \
    bash "${work}/preflight/preflight-credentials.sh" 2>&1
)"
preflight_status=$?
if [ "${preflight_status}" -eq 0 ]; then
  pass "credential preflight still succeeds in verbose mode"
else
  fail "credential preflight still succeeds in verbose mode (exit ${preflight_status})"
fi
assert_hidden "credential preflight" "${preflight_secret}" "${preflight_output}"

echo
echo "Passed: ${passed}"
echo "Failed: ${failed}"
exit "${failed}"
