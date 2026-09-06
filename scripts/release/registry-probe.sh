#!/usr/bin/env bash
# registry-probe.sh - Ask a container registry two questions over plain HTTP:
# what an *anonymous* user can see, and whether a credential can actually write.
#
# Source it to get the functions, or run it as a CLI:
#
#   bash scripts/release/registry-probe.sh pull ghcr.io/link-foundation/box:2.6.0
#   REGISTRY_PROBE_PASSWORD="$DOCKERHUB_TOKEN" \
#     bash scripts/release/registry-probe.sh push docker.io/konard/box --username konard
#
# Why this exists (issue #117)
# ---------------------------
# Two of the four defects in that issue are the same defect wearing different
# clothes: *the pipeline asked a question with credentials nobody else has, and
# reported the answer as if it were a fact about the world.*
#
#   1. `create-release` ran `docker manifest inspect` for all 56 published
#      references AFTER `docker/login-action` had authenticated the job to
#      ghcr.io with GITHUB_TOKEN. The release notes for v2.6.0 therefore say
#      "28 of 56 image references resolve". Anonymously the answer was 0 of 56:
#      the GHCR packages are private, and Docker Hub had received nothing at
#      all because the mirror token was expired.
#
#   2. Nothing anywhere asked whether the GHCR packages were public. GHCR makes
#      a package private the first time it is pushed, whatever the visibility
#      of the repository that pushed it, and no REST endpoint flips it back
#      (see docs/case-studies/issue-117/CASE-STUDY.md; the packages REST API
#      has GET/DELETE/restore and no visibility PATCH).
#
# So the probes here deliberately send **no credentials** unless asked to, and
# they distinguish four outcomes where `docker manifest inspect` collapses them
# into "error":
#
#   published  the reference resolves for an anonymous consumer
#   private    the registry knows the repository but will not serve it to an
#              anonymous consumer - a published image nobody can pull
#   missing    the registry says the repository or the tag does not exist
#   unknown    the registry did not answer (network, 5xx, rate limit)
#
# "unknown" is a first-class outcome on purpose. A check that reports "missing"
# when it means "I could not look" trades one false claim for another.
#
# The push probe opens a blob upload session (`POST /v2/<repo>/blobs/uploads/`)
# and immediately cancels it. That is the smallest request a registry answers
# with the actual write decision, and nothing cheaper works:
#
#   - ghcr.io's token endpoint does not check anything. Given a credential it
#     answers HTTP 200 with `{"token": "<base64 of that credential>"}` for any
#     scope you ask for, and the registry then refuses the write with 403
#     "The token provided does not match expected scopes".
#   - docker.io's token endpoint answers HTTP 200 to an *anonymous* request for
#     `pull,push`, because it grants what it is willing to grant - a pull-only
#     `access` claim - rather than refusing. Only a wrong credential is a 401
#     there.
#
# Both verified on 2026-09-06; the transcripts are in
# dev/log/issues/117/pulls/118/token-endpoint-is-not-a-credential-check.log.
#
# Environment:
#   REGISTRY_PROBE_USERNAME  basic-auth user for the push probe
#   REGISTRY_PROBE_PASSWORD  basic-auth secret for the push probe
#   REGISTRY_PROBE_TIMEOUT   per-request timeout in seconds (default 20)
#   BOX_VERBOSE=1            trace every command
#
# Every probe leaves its answer in REGISTRY_PROBE_STATE and its reason in
# REGISTRY_PROBE_DETAIL. Nothing is printed to stdout: `state="$(probe ...)"`
# would run the probe in a subshell and throw the reason away, and the reason
# is what separates "not published" from "I could not look".

set -uo pipefail

if [ "${BOX_VERBOSE:-0}" = "1" ]; then
  set -x
fi

REGISTRY_PROBE_TIMEOUT="${REGISTRY_PROBE_TIMEOUT:-20}"

# Every probe answers through these three globals rather than through stdout.
# A `$(...)` capture runs the function in a subshell, so a probe that printed
# its state could not also hand back the reason for it - and the reason is the
# whole point: "missing" and "I could not look" have to stay distinguishable
# all the way to the caller.
REGISTRY_PROBE_STATE=""
REGISTRY_PROBE_DETAIL=""
REGISTRY_PROBE_TOKEN=""
REGISTRY_PROBE_TOKEN_STATE=""
REGISTRY_PROBE_RESPONSE_HEADERS=""
REGISTRY_PROBE_REGISTRY=""
REGISTRY_PROBE_REPOSITORY=""
REGISTRY_PROBE_TAG=""

# The media types a multi-arch release publishes. Without them a registry may
# answer 404 for an index it would happily serve as an index, which would read
# as "missing" - the exact false negative this file exists to prevent.
REGISTRY_PROBE_ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

# registry_probe_http METHOD URL [HEADER...] - one HTTP request.
#
# Prints the status code on the first line and the body on the rest, and leaves
# the response headers in REGISTRY_PROBE_RESPONSE_HEADERS. This is the single
# choke point every probe goes through, so the test suite can replace it with a
# fixture table and run entirely offline
# (experiments/test-issue117-registry-probe.sh does exactly that).
#
# Credentials go through a curl config file rather than `-u`, because argv is
# world-readable on the runner.
registry_probe_http() {
  local method="$1" url="$2"
  shift 2

  local headers_file
  headers_file="$(mktemp)"

  local -a args=(--silent --show-error --location --max-time "$REGISTRY_PROBE_TIMEOUT"
    --request "$method" --dump-header "$headers_file" --write-out '\n%{http_code}')
  local header
  for header in "$@"; do
    args+=(--header "$header")
  done

  local config=""
  if [ -n "${REGISTRY_PROBE_USERNAME:-}" ] || [ -n "${REGISTRY_PROBE_PASSWORD:-}" ]; then
    config="$(mktemp)"
    chmod 600 "$config"
    printf 'user = "%s:%s"\n' "${REGISTRY_PROBE_USERNAME:-}" "${REGISTRY_PROBE_PASSWORD:-}" >"$config"
    args+=(--config "$config")
  fi

  local response status
  response="$(curl "${args[@]}" "$url" 2>/dev/null)"
  local curl_status=$?
  [ -n "$config" ] && rm -f "$config"
  REGISTRY_PROBE_RESPONSE_HEADERS="$(cat "$headers_file" 2>/dev/null)"
  rm -f "$headers_file"

  if [ "$curl_status" -ne 0 ]; then
    printf '000\n'
    return 0
  fi

  status="${response##*$'\n'}"
  printf '%s\n%s\n' "$status" "${response%$'\n'*}"
}

# registry_probe_header NAME - one header from the last response, or "".
registry_probe_header() {
  printf '%s\n' "${REGISTRY_PROBE_RESPONSE_HEADERS:-}" \
    | tr -d '\r' \
    | awk -v name="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" '
        { line = $0; sub(/:.*/, "", line); if (tolower(line) == name) { sub(/^[^:]*:[[:space:]]*/, "", $0); print; exit } }'
}

# registry_probe_status RESPONSE - the status line of a registry_probe_http result.
registry_probe_status() { printf '%s' "${1%%$'\n'*}"; }

# registry_probe_body RESPONSE - everything after the status line.
registry_probe_body() {
  local response="$1"
  if [ "$response" = "${response#*$'\n'}" ]; then
    printf ''
  else
    printf '%s' "${response#*$'\n'}"
  fi
}

# registry_probe_endpoints REGISTRY - the token and API base URLs, space separated.
#
# Only the two registries this project publishes to are known here. Anything
# else returns non-zero rather than guessing, because a guessed endpoint that
# 404s is indistinguishable from an image that is not there.
registry_probe_endpoints() {
  case "$1" in
    ghcr.io)
      printf 'https://ghcr.io/token?service=ghcr.io https://ghcr.io\n'
      ;;
    docker.io | index.docker.io | registry-1.docker.io)
      printf 'https://auth.docker.io/token?service=registry.docker.io https://registry-1.docker.io\n'
      ;;
    *)
      return 1
      ;;
  esac
}

# registry_probe_parse_ref REF - split a reference into registry, repository, tag.
#
# Sets REGISTRY_PROBE_REGISTRY, REGISTRY_PROBE_REPOSITORY, REGISTRY_PROBE_TAG.
# A reference with no registry means Docker Hub, and a single-segment Docker Hub
# name means the `library/` namespace - the same rules `docker pull` applies.
registry_probe_parse_ref() {
  local ref="$1" registry repository tag="latest" remainder

  if [[ "$ref" == *@* ]]; then
    tag="${ref#*@}"
    ref="${ref%@*}"
  elif [[ "${ref##*/}" == *:* ]]; then
    tag="${ref##*:}"
    ref="${ref%:*}"
  fi

  if [[ "$ref" == */* ]] && [[ "${ref%%/*}" == *.* || "${ref%%/*}" == *:* || "${ref%%/*}" == "localhost" ]]; then
    registry="${ref%%/*}"
    remainder="${ref#*/}"
  else
    registry="docker.io"
    remainder="$ref"
  fi

  if [ "$registry" = "docker.io" ] && [[ "$remainder" != */* ]]; then
    repository="library/$remainder"
  else
    repository="$remainder"
  fi

  REGISTRY_PROBE_REGISTRY="$registry"
  REGISTRY_PROBE_REPOSITORY="$repository"
  REGISTRY_PROBE_TAG="$tag"
}

# registry_probe_anonymous_token REGISTRY REPOSITORY - ask for a pull token.
#
# Sets REGISTRY_PROBE_TOKEN and REGISTRY_PROBE_TOKEN_STATE (public, private or
# unknown). On GHCR this
# call alone answers the visibility question: a public package hands an
# anonymous caller a token, a private one answers UNAUTHORIZED. Docker Hub
# issues an anonymous token for names that do not exist at all, so there the
# state is settled by the manifest request that follows.
registry_probe_anonymous_token() {
  local registry="$1" repository="$2" endpoints auth response status body

  REGISTRY_PROBE_TOKEN=""

  if ! endpoints="$(registry_probe_endpoints "$registry")"; then
    REGISTRY_PROBE_TOKEN_STATE="unknown"
    REGISTRY_PROBE_DETAIL="unsupported registry '$registry'; registry-probe.sh knows ghcr.io and docker.io"
    return 0
  fi
  auth="${endpoints%% *}"

  response="$(REGISTRY_PROBE_USERNAME="" REGISTRY_PROBE_PASSWORD="" \
    registry_probe_http GET "${auth}&scope=repository:${repository}:pull")"
  status="$(registry_probe_status "$response")"
  body="$(registry_probe_body "$response")"

  case "$status" in
    200)
      REGISTRY_PROBE_TOKEN_STATE="public"
      REGISTRY_PROBE_TOKEN="$(printf '%s' "$body" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
      REGISTRY_PROBE_DETAIL="${registry} issued an anonymous pull token for ${repository}"
      ;;
    401 | 403)
      REGISTRY_PROBE_TOKEN_STATE="private"
      REGISTRY_PROBE_DETAIL="${registry}/${repository} does not issue an anonymous pull token (HTTP ${status})"
      ;;
    *)
      REGISTRY_PROBE_TOKEN_STATE="unknown"
      REGISTRY_PROBE_DETAIL="${registry} token endpoint answered HTTP ${status}"
      ;;
  esac
}

# registry_probe_pull REF - what an anonymous consumer gets for REF.
#
# Sets REGISTRY_PROBE_STATE to published, private, missing or unknown, and
# REGISTRY_PROBE_DETAIL to the reason.
registry_probe_pull() {
  local ref="$1" endpoints api response status

  registry_probe_parse_ref "$ref"
  REGISTRY_PROBE_STATE="unknown"
  REGISTRY_PROBE_DETAIL=""

  if ! endpoints="$(registry_probe_endpoints "$REGISTRY_PROBE_REGISTRY")"; then
    REGISTRY_PROBE_DETAIL="unsupported registry '${REGISTRY_PROBE_REGISTRY}'; registry-probe.sh knows ghcr.io and docker.io"
    REGISTRY_PROBE_STATE="unknown"
    return 0
  fi
  api="${endpoints##* }"

  registry_probe_anonymous_token "$REGISTRY_PROBE_REGISTRY" "$REGISTRY_PROBE_REPOSITORY"
  case "$REGISTRY_PROBE_TOKEN_STATE" in
    private)
      REGISTRY_PROBE_STATE="private"
      return 0
      ;;
    unknown)
      REGISTRY_PROBE_STATE="unknown"
      return 0
      ;;
  esac

  response="$(REGISTRY_PROBE_USERNAME="" REGISTRY_PROBE_PASSWORD="" \
    registry_probe_http GET \
    "${api}/v2/${REGISTRY_PROBE_REPOSITORY}/manifests/${REGISTRY_PROBE_TAG}" \
    "Authorization: Bearer ${REGISTRY_PROBE_TOKEN}" \
    "Accept: ${REGISTRY_PROBE_ACCEPT}")"
  status="$(registry_probe_status "$response")"

  case "$status" in
    200)
      REGISTRY_PROBE_DETAIL="anonymous GET of the manifest returned HTTP 200"
      REGISTRY_PROBE_STATE="published"
      ;;
    404)
      REGISTRY_PROBE_DETAIL="the registry has no ${REGISTRY_PROBE_TAG} tag for ${REGISTRY_PROBE_REPOSITORY} (HTTP 404)"
      REGISTRY_PROBE_STATE="missing"
      ;;
    401 | 403)
      REGISTRY_PROBE_DETAIL="the registry refuses to serve ${REGISTRY_PROBE_REPOSITORY}:${REGISTRY_PROBE_TAG} anonymously (HTTP ${status})"
      REGISTRY_PROBE_STATE="private"
      ;;
    429)
      REGISTRY_PROBE_DETAIL="rate limited by ${REGISTRY_PROBE_REGISTRY} (HTTP 429); this is not evidence that the image is missing"
      REGISTRY_PROBE_STATE="unknown"
      ;;
    *)
      REGISTRY_PROBE_DETAIL="${REGISTRY_PROBE_REGISTRY} answered HTTP ${status}"
      REGISTRY_PROBE_STATE="unknown"
      ;;
  esac
}

# registry_probe_push REGISTRY REPOSITORY - can the configured credential write?
#
# Sets REGISTRY_PROBE_STATE to ok, missing-credentials, invalid-credentials,
# insufficient-scope or unknown, and REGISTRY_PROBE_DETAIL to the reason. Reads
# REGISTRY_PROBE_USERNAME / REGISTRY_PROBE_PASSWORD.
#
# It opens a blob upload session and cancels it. Nothing is published: an
# upload session with no bytes and no commit creates no tag, no manifest and no
# package version, and the DELETE below releases it immediately.
registry_probe_push() {
  local registry="$1" repository="$2" endpoints auth api response status body token location

  REGISTRY_PROBE_STATE="unknown"
  REGISTRY_PROBE_DETAIL=""

  if [ -z "${REGISTRY_PROBE_USERNAME:-}" ] || [ -z "${REGISTRY_PROBE_PASSWORD:-}" ]; then
    REGISTRY_PROBE_DETAIL="no username/password configured for ${registry}"
    REGISTRY_PROBE_STATE="missing-credentials"
    return 0
  fi

  if ! endpoints="$(registry_probe_endpoints "$registry")"; then
    REGISTRY_PROBE_DETAIL="unsupported registry '$registry'; registry-probe.sh knows ghcr.io and docker.io"
    REGISTRY_PROBE_STATE="unknown"
    return 0
  fi
  auth="${endpoints%% *}"
  api="${endpoints##* }"

  # Step 1 - exchange the credential for a push-scoped token. A rejected
  # credential is answered here, and only here, with the registry's own words
  # ("incorrect username or password", "personal access token is expired").
  response="$(registry_probe_http GET "${auth}&scope=repository:${repository}:pull,push")"
  status="$(registry_probe_status "$response")"
  body="$(registry_probe_body "$response")"

  case "$status" in
    200) ;;
    401 | 403)
      REGISTRY_PROBE_DETAIL="${registry} rejected the credential (HTTP ${status}): $(printf '%s' "$body" | tr -d '\n' | cut -c1-200)"
      REGISTRY_PROBE_STATE="invalid-credentials"
      return 0
      ;;
    *)
      REGISTRY_PROBE_DETAIL="${registry} token endpoint answered HTTP ${status}"
      REGISTRY_PROBE_STATE="unknown"
      return 0
      ;;
  esac

  token="$(printf '%s' "$body" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  if [ -z "$token" ]; then
    REGISTRY_PROBE_DETAIL="${registry} returned HTTP 200 with no token field"
    REGISTRY_PROBE_STATE="unknown"
    return 0
  fi

  # Step 2 - ask for a write. GHCR hands out a "push"-scoped token to anyone
  # who asks, so step 1 passing is not evidence of anything; this is.
  response="$(REGISTRY_PROBE_USERNAME="" REGISTRY_PROBE_PASSWORD="" \
    registry_probe_http POST "${api}/v2/${repository}/blobs/uploads/" \
    "Authorization: Bearer ${token}" \
    "Content-Length: 0")"
  status="$(registry_probe_status "$response")"
  body="$(registry_probe_body "$response")"

  case "$status" in
    200 | 201 | 202)
      REGISTRY_PROBE_DETAIL="${registry}/${repository} accepted a blob upload session (HTTP ${status})"
      # Best effort: hand the session back rather than leaving it to expire.
      location="$(registry_probe_header Location)"
      case "$location" in
        /*) location="${api}${location}" ;;
      esac
      if [ -n "$location" ]; then
        REGISTRY_PROBE_USERNAME="" REGISTRY_PROBE_PASSWORD="" \
          registry_probe_http DELETE "$location" "Authorization: Bearer ${token}" >/dev/null
      fi
      REGISTRY_PROBE_STATE="ok"
      ;;
    401)
      REGISTRY_PROBE_DETAIL="${registry} rejected the push-scoped token for ${repository} (HTTP 401)"
      REGISTRY_PROBE_STATE="invalid-credentials"
      ;;
    403)
      REGISTRY_PROBE_DETAIL="${registry} authenticated the credential but denied write on ${repository} (HTTP 403): $(printf '%s' "$body" | tr -d '\n' | cut -c1-200)"
      REGISTRY_PROBE_STATE="insufficient-scope"
      ;;
    *)
      REGISTRY_PROBE_DETAIL="${registry} answered HTTP ${status} to a blob upload session on ${repository}"
      REGISTRY_PROBE_STATE="unknown"
      ;;
  esac
}

# --- CLI ---------------------------------------------------------------------
# Sourcing this file must not run anything; only a direct invocation does.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  registry_probe_main() {
    local command="${1:-}"
    shift || true

    case "$command" in
      pull)
        local ref="${1:-}"
        [ -n "$ref" ] || {
          echo "Usage: $0 pull <reference>" >&2
          exit 2
        }
        registry_probe_pull "$ref"
        printf '%s\t%s\t%s\n' "$REGISTRY_PROBE_STATE" "$ref" "$REGISTRY_PROBE_DETAIL"
        [ "$REGISTRY_PROBE_STATE" = "published" ]
        ;;
      push)
        local image="${1:-}"
        shift || true
        [ -n "$image" ] || {
          echo "Usage: $0 push <registry>/<repository> [--username U]" >&2
          exit 2
        }
        while [ $# -gt 0 ]; do
          case "$1" in
            --username)
              REGISTRY_PROBE_USERNAME="$2"
              shift 2
              ;;
            *)
              echo "registry-probe.sh: unknown option $1" >&2
              exit 2
              ;;
          esac
        done
        registry_probe_parse_ref "$image"
        registry_probe_push "$REGISTRY_PROBE_REGISTRY" "$REGISTRY_PROBE_REPOSITORY"
        printf '%s\t%s\t%s\n' "$REGISTRY_PROBE_STATE" "$image" "$REGISTRY_PROBE_DETAIL"
        [ "$REGISTRY_PROBE_STATE" = "ok" ]
        ;;
      *)
        sed -n '2,40p' "$0" | sed 's/^# \?//'
        exit 2
        ;;
    esac
  }

  registry_probe_main "$@"
fi
