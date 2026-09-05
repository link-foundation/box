#!/usr/bin/env bash
# test-issue115-push-retry-classifier.sh
#
# Issue #115. In run 33972074755 the DOCKERHUB_TOKEN had expired. Every build
# job's push then failed, and docker-push-with-retry.sh — written for the
# transient GHCR 403 of issue #78 — retried each one three times with 10s and
# 20s backoff before reporting "All retry attempts failed". Backoff cannot
# rotate a secret, so the retries only buried the real cause.
#
# This suite pins the classification boundary in both directions:
#   Part 1: permanent auth/config failures are NOT retried.
#   Part 2: the transient failures the retry loop exists for ARE still retried.
#   Part 3: the retry loop actually consults the classifier, streams output
#           while capturing it, and honours the DOCKER_PUSH_FORCE_RETRY escape
#           hatch.
#
# Runs offline: docker push is stubbed on PATH, nothing is pushed anywhere.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

pass=0; fail=0
ok()   { echo "  PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

CLASSIFIER="scripts/release/docker-push-failure-classifier.sh"
RETRY="scripts/release/docker-push-with-retry.sh"

# shellcheck source=scripts/release/docker-push-failure-classifier.sh
source "$CLASSIFIER"

classify() {  # classify TEXT -> "non-retryable" | "retryable"
  if is_non_retryable_push_failure "$1"; then echo "non-retryable"; else echo "retryable"; fi
}

echo "== Part 1: permanent failures are not retried =="
# Verbatim from the run 33972074755 log.
check "expired PAT (the observed login error)" \
  "$(classify 'Error response from daemon: Get "https://registry-1.docker.io/v2/": unauthorized: personal access token is expired')" \
  "non-retryable"
check "oauth token fetch (the observed push error)" \
  "$(classify 'ERROR: failed to push ***/box-js:latest-arm64: failed to authorize: failed to fetch oauth token')" \
  "non-retryable"
check "authentication required" \
  "$(classify 'denied: requested access to the resource is denied
unauthorized: authentication required')" "non-retryable"
check "no basic auth credentials" \
  "$(classify 'errors: denied: no basic auth credentials')" "non-retryable"
check "insufficient_scope" \
  "$(classify 'unauthorized: insufficient_scope: authorization failed')" "non-retryable"
check "unknown repository" \
  "$(classify 'repository name not known to registry')" "non-retryable"
check "matching is case-insensitive" \
  "$(classify 'UNAUTHORIZED: Personal Access Token Is Expired')" "non-retryable"

echo "== Part 2: transient failures stay retryable =="
# The 403 this script was written for (issue #78) must never be classified as
# permanent, or the original bug comes back.
check "transient GHCR 403 (issue #78)" \
  "$(classify 'denied: 403 Forbidden')" "retryable"
check "first-time package creation 403" \
  "$(classify 'unexpected status from PUT request to https://ghcr.io/v2/...: 403 Forbidden')" \
  "retryable"
check "registry 500" \
  "$(classify 'received unexpected HTTP status: 500 Internal Server Error')" "retryable"
check "rate limit" \
  "$(classify 'toomanyrequests: You have reached your pull rate limit')" "retryable"
check "connection reset" \
  "$(classify 'net/http: TLS handshake timeout')" "retryable"
check "EOF" "$(classify 'unexpected EOF')" "retryable"
check "empty output" "$(classify '')" "retryable"

echo "== Part 3: the retry loop uses the classifier =="
check "retry script sources the classifier" \
  "$(grep -c 'source .*docker-push-failure-classifier.sh' "$RETRY")" "1"
check "retry script consults is_non_retryable_push_failure" \
  "$(grep -c 'is_non_retryable_push_failure' "$RETRY")" "1"
check "push output is captured, not just echoed" \
  "$(grep -cE 'output="\$\(docker push .* \| tee /dev/stderr\)"' "$RETRY")" "1"
check "an actionable annotation is emitted" \
  "$(grep -c '::error title=Registry authentication failed::' "$RETRY")" "1"

# End-to-end, with docker stubbed out.
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
cat > "$STUB_DIR/docker" << 'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
echo "The push refers to repository [docker.io/konard/box-js]"
echo "$STUB_ERROR"
exit 1
STUB
chmod +x "$STUB_DIR/docker"

run_retry() {  # run_retry ERROR_TEXT [ENV=VAL ...]
  : > "$STUB_DIR/calls"
  env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_DIR/calls" STUB_ERROR="$1" \
      INITIAL_DELAY=0 "${@:2}" bash "$RETRY" konard/box-js:latest \
      > "$STUB_DIR/out" 2>&1
  echo "$?"
}

status="$(run_retry 'unauthorized: personal access token is expired')"
check "permanent failure still exits non-zero" "$status" "1"
check "permanent failure pushes exactly once" "$(wc -l < "$STUB_DIR/calls" | tr -d ' ')" "1"
check "permanent failure explains how to rotate the token" \
  "$(grep -qc 'DOCKERHUB_TOKEN' "$STUB_DIR/out" && echo 1 || echo 0)" "1"
check "permanent failure does not claim attempts were exhausted" \
  "$(grep -c 'after 3 attempts' "$STUB_DIR/out")" "0"

status="$(run_retry 'denied: 403 Forbidden')"
check "transient failure exits non-zero after retrying" "$status" "1"
check "transient failure uses every attempt" "$(wc -l < "$STUB_DIR/calls" | tr -d ' ')" "3"

status="$(run_retry 'unauthorized: personal access token is expired' DOCKER_PUSH_FORCE_RETRY=1)"
check "DOCKER_PUSH_FORCE_RETRY restores the old behaviour" \
  "$(wc -l < "$STUB_DIR/calls" | tr -d ' ')" "3"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "RESULT: FAIL"; exit 1; }
echo "RESULT: PASS - permanent registry failures are no longer retried"
