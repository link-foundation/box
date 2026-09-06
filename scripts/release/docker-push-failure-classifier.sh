#!/bin/bash
# docker-push-failure-classifier.sh - Tell permanent registry failures apart
# from the transient ones the retry loop exists for.
#
# Source this file; it defines two functions and runs nothing on its own.
#
#   is_non_retryable_push_failure OUTPUT   -> 0 when retrying is pointless
#   docker_push_failure_guidance TAG       -> actionable text for the log
#
# Why this exists (issue #115). docker-push-with-retry.sh was written for the
# transient GHCR 403 that hits concurrent first-time package creation (issue
# #78), and it treats every failure as that failure. In run 33972074755 the
# Docker Hub token had expired, so each of ~44 build jobs ran three more full
# push attempts with 10s and 20s backoff against a credential that could not
# start working, then reported "All retry attempts failed" — burying the one
# line that explained the run under three copies of a misleading one.
#
# An expired or missing credential is a permanent condition. Backoff does not
# rotate a secret.
#
# Deliberately still retryable, because these genuinely do clear on their own:
#   - 403 / Forbidden ............ the transient GHCR race of issue #78
#   - 5xx, EOF, timeouts, resets . registry or network flake
#   - "TOOMANYREQUESTS" .......... rate limit, backoff is the correct answer
#
# Modelled on the reference template's scripts/publish-failure-classifier.mjs
# (NON_RETRYABLE_PATTERNS / isNonRetryableFailure), which draws the same line
# for npm publishes.
#
# Escape hatch: set DOCKER_PUSH_FORCE_RETRY=1 to retry everything, which
# restores the previous behaviour if a classification ever proves wrong.

# Permanent authentication / authorization / registry-configuration failures.
# Matched case-insensitively as substrings of the combined push output.
DOCKER_PUSH_NON_RETRYABLE_PATTERNS=(
  'personal access token is expired'
  'access token has expired'
  'authentication required'
  'unauthorized: incorrect username or password'
  'invalid username/password'
  'no basic auth credentials'
  'requested access to the resource is denied'
  'insufficient_scope'
  'repository name not known to registry'
  'failed to fetch oauth token'
)

# is_non_retryable_push_failure OUTPUT
# Returns 0 (true) when OUTPUT shows a permanent failure, 1 otherwise.
is_non_retryable_push_failure() {
  local output="$1" pattern lower

  if [ "${DOCKER_PUSH_FORCE_RETRY:-0}" = "1" ]; then
    return 1
  fi

  lower="$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')"
  for pattern in "${DOCKER_PUSH_NON_RETRYABLE_PATTERNS[@]}"; do
    case "$lower" in
      *"$pattern"*) return 0 ;;
    esac
  done
  return 1
}

# docker_push_failure_guidance TAG
# Prints an explanation a human can act on, instead of "attempts exhausted".
docker_push_failure_guidance() {
  local tag="$1" registry
  registry="${tag%%/*}"
  case "$registry" in
    *.* | localhost*) : ;;     # already a registry host
    *) registry="docker.io" ;; # bare namespace/name is Docker Hub
  esac

  cat <<GUIDANCE

=== REGISTRY AUTHENTICATION FAILURE (not retried) ===

Pushing ${tag} failed with an authentication or registry-configuration error.
That is a permanent condition, so it was not retried.

Registry: ${registry}

SOLUTION:
  1. If this is docker.io, the DOCKERHUB_TOKEN repository secret has most
     likely expired. Create a new access token at
     https://app.docker.com/settings/personal-access-tokens with Read & Write
     scope, then update the DOCKERHUB_TOKEN secret in
     Settings -> Secrets and variables -> Actions.
  2. If this is ghcr.io, check that the job requests
     'permissions: packages: write' and that the package's visibility allows
     this repository to push to it.
  3. Confirm the login step actually succeeded — it is tolerant of failure by
     design, so a red push can be the first visible sign of a bad credential.

To retry regardless of classification, set DOCKER_PUSH_FORCE_RETRY=1.

GUIDANCE
}
