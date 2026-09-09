#!/usr/bin/env bash
# test-issue121-provenance-metadata-leak.sh
#
# The end-to-end half of issue #121's largest false positive. Its offline twin,
# experiments/test-issue121-log-injection.sh, models the runner's parser and
# checks the workflows; this one drives a real `docker buildx build` and shows
# that the thing being modelled is real:
#
#   * with the defaults a build under GitHub Actions writes the *whole push
#     event payload* into `--metadata-file`, commit messages included, even
#     though `--provenance=false` is on the command line;
#   * with BUILDX_METADATA_PROVENANCE=disabled the same build writes only
#     `buildx.build.ref`.
#
# docker/build-push-action prints that file with `core.info`, and the runner
# reads `##[error]` from anywhere in a line, so a commit message that quotes one
# becomes a failure annotation on a job that succeeded. Release run 34293699247
# collected 56 of them that way.
#
# This needs Docker with a working buildx and it pulls a BuildKit image, so
# scripts/ci/run-experiments.sh skips it by default. Run it directly, or set
# BOX_RUN_DOCKER_SUITES=1.
#
# Usage: bash experiments/test-issue121-provenance-metadata-leak.sh

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
  [ $# -gt 1 ] && printf '      %s\n' "${@:2}" >&2
  return 0
}
skip_all() {
  echo "SKIP: $1"
  echo
  echo "=== Summary ==="
  echo "Passed: 0"
  echo "Failed: 0"
  echo "Skipped: this suite needs Docker with buildx"
  exit 0
}

command -v docker >/dev/null 2>&1 || skip_all "docker is not installed"
docker buildx version >/dev/null 2>&1 || skip_all "docker buildx is not available"
docker info >/dev/null 2>&1 || skip_all "the docker daemon is not reachable"

BUILDX_VERSION="$(docker buildx version 2>/dev/null | awk '{print $2}')"
echo "buildx: ${BUILDX_VERSION:-unknown}"

TMP="$(mktemp -d)"
BUILDER="box-issue121-$$"
cleanup() {
  docker buildx rm "$BUILDER" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

# A build context small enough that the build itself proves nothing and costs
# nothing; the subject is the metadata file, not the image.
printf 'hi\n' >"$TMP/hello.txt"
cat >"$TMP/Dockerfile" <<'DOCKERFILE'
FROM scratch
COPY hello.txt /hello.txt
DOCKERFILE

# The push event that release run 34293699247 was started by, reduced to the one
# commit that mattered: a2e6420, whose body quotes the runner's own error lines
# while explaining a fix for jobs killed with exit code 143.
cat >"$TMP/event.json" <<'EVENT'
{"after": "deadbeef", "commits": [{"id": "a2e6420", "message": "ci: spend the idle disk (issue #119)\n\n##[error]Process completed with exit code 143.\n  ##[error]The runner has received a shutdown signal.\n\nrest of the body"}], "repository": {"full_name": "link-foundation/box"}}
EVENT

# The payload is read at builder *create* time and baked into the container as
# provenance.d/github_actions_context.json (driver/docker-container/driver.go),
# not at build time. A builder created without these variables produces no
# github_event_payload at all and the suite would pass for the wrong reason.
export GITHUB_ACTIONS=true
export GITHUB_EVENT_NAME=push
export GITHUB_EVENT_PATH="$TMP/event.json"

echo "creating builder $BUILDER (docker-container driver, as setup-buildx-action does)"
if ! docker buildx create --name "$BUILDER" --driver docker-container >"$TMP/create.log" 2>&1; then
  cat "$TMP/create.log" >&2
  skip_all "could not create a docker-container builder"
fi

# --provenance=false is passed on every build here, exactly as the release
# workflows pass it, so nothing below can be blamed on the attestation setting.
build() {
  local metadata_file="$1"
  shift
  docker buildx build \
    --builder "$BUILDER" \
    --file "$TMP/Dockerfile" \
    --provenance=false \
    --metadata-file "$metadata_file" \
    "$TMP" >"$TMP/build.log" 2>&1
}

echo
echo "=== Part 1: the defaults, which is what the release ran with ==="

if build "$TMP/md-default.json"; then
  pass "a build with --provenance=false succeeds"
else
  cat "$TMP/build.log" >&2
  fail "a build with --provenance=false succeeds" "see the build log above"
  echo
  echo "=== Summary ==="
  echo "Passed: $PASS"
  echo "Failed: $FAIL"
  exit 1
fi

if grep -q 'resolving provenance for metadata file' "$TMP/build.log"; then
  pass "buildx resolves provenance for the metadata file anyway - --provenance=false governs the attestation, not this"
else
  fail "buildx resolves provenance for the metadata file anyway" \
    "the build log no longer shows the step; the mechanism may have changed upstream"
fi

if grep -q 'buildx.build.provenance' "$TMP/md-default.json"; then
  pass "the metadata file carries buildx.build.provenance"
else
  fail "the metadata file carries buildx.build.provenance" \
    "keys: $(python3 -c 'import json,sys; print(sorted(json.load(open(sys.argv[1])))) ' "$TMP/md-default.json" 2>/dev/null)"
fi

if grep -q 'github_event_payload' "$TMP/md-default.json"; then
  pass "and inside it the entire push event payload, commit messages and all"
else
  fail "and inside it the entire push event payload, commit messages and all" \
    "the payload is absent - either buildx stopped recording it, or the builder was created without GITHUB_EVENT_PATH"
fi

# docker/build-push-action prints the file as `JSON.stringify(metadata, null, 2)`,
# which is what turns one JSON string value into one physical log line.
python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), indent=2))' \
  "$TMP/md-default.json" >"$TMP/printed-default.txt" 2>/dev/null

if grep -q '##\[error\]' "$TMP/printed-default.txt"; then
  pass "printed the way build-push-action prints it, the log contains a literal ##[error]"
else
  fail "printed the way build-push-action prints it, the log contains a literal ##[error]" \
    "no ##[error] in the printed metadata"
fi

echo
echo "=== Part 2: the fix ==="

if BUILDX_METADATA_PROVENANCE=disabled build "$TMP/md-disabled.json"; then
  pass "the same build succeeds with BUILDX_METADATA_PROVENANCE=disabled"
else
  cat "$TMP/build.log" >&2
  fail "the same build succeeds with BUILDX_METADATA_PROVENANCE=disabled" "see the build log above"
fi

if ! grep -q 'resolving provenance for metadata file' "$TMP/build.log"; then
  pass "buildx does not even resolve provenance any more"
else
  fail "buildx does not even resolve provenance any more" \
    "the step still ran; disabled is not being honoured by buildx ${BUILDX_VERSION:-unknown}"
fi

if [ -f "$TMP/md-disabled.json" ] && ! grep -q 'buildx.build.provenance' "$TMP/md-disabled.json"; then
  pass "no provenance is written to the metadata file"
else
  fail "no provenance is written to the metadata file" \
    "contents: $(cat "$TMP/md-disabled.json" 2>/dev/null)"
fi

if [ -f "$TMP/md-disabled.json" ] && ! grep -q 'github_event_payload' "$TMP/md-disabled.json"; then
  pass "no push event payload, so nothing for the runner to misread"
else
  fail "no push event payload, so nothing for the runner to misread"
fi

# The point of `disabled` over `min`: `min` strips BuildConfig and Metadata and
# keeps invocation.environment, which is precisely where the payload lives.
if BUILDX_METADATA_PROVENANCE=min build "$TMP/md-min.json" \
  && grep -q 'github_event_payload' "$TMP/md-min.json"; then
  pass "min - the default - would not have been enough: it keeps invocation.environment"
else
  fail "min - the default - would not have been enough: it keeps invocation.environment" \
    "min no longer carries the payload; re-check whether disabled is still required"
fi

# The metadata file is still produced and still usable, which is why the
# workflows can keep asking for one.
if [ -f "$TMP/md-disabled.json" ] && grep -q 'buildx.build.ref' "$TMP/md-disabled.json"; then
  pass "the metadata file still carries buildx.build.ref, so nothing downstream loses an input"
else
  fail "the metadata file still carries buildx.build.ref, so nothing downstream loses an input"
fi

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
