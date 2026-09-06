#!/usr/bin/env bash
# preflight-credentials.sh - Prove, before the first build starts, that every
# registry this release must publish to will accept a write.
#
# Usage:
#   bash scripts/release/preflight-credentials.sh --mode release
#   bash scripts/release/preflight-credentials.sh --mode report
#
# Why this exists (issue #117)
# ---------------------------
# Release 2.5.0 and 2.6.0 do not exist on Docker Hub. Run 33972074755 logged
# one line about it - `##[warning]Docker Hub login failed (outcome=failure)` -
# and then spent about forty build jobs producing images it could not mirror,
# skipped every mirror step, and finished green. The credential was expired
# before the first byte was built, and every fact needed to know that was
# available in the first ten seconds of the run.
#
#   "In main branch our task is not to test the code, our task is to produce a
#    release, so if any token or auth is not configured or unavailable - and we
#    should be able to check it in advance - there is no need to do any resource
#    intensive calculations. If we are missing any credentials needed to produce
#    any of the planned releases, we should fail immediately."
#
# So this runs first, and the whole build graph is gated on it. It costs two
# HTTP requests per registry and answers the only question that matters:
# **can we publish?**
#
# What it does not do: gate on an image *push* once building has started. That
# is the opposite failure (issue #115, RC-18) - a transient mirror error after
# the artifacts exist must not destroy the GitHub Release. Fail before the
# compute, warn after it.
#
# How a credential is checked. Not by logging in, and not by asking the token
# endpoint: `docker login` against ghcr.io succeeds for a token that cannot
# push anything, and both registries answer HTTP 200 to token requests that
# grant nothing (see registry-probe.sh). The probe opens a blob upload session
# and cancels it, which is the smallest request that returns the registry's
# real write decision. Nothing is published by it.
#
# Modes:
#   release  a required registry that cannot be written to is a hard failure
#   report   the same checks, reported as warnings, exit 0 - for pull requests,
#            which test code rather than produce releases, and for forks, whose
#            runs legitimately have no publishing secrets at all
#
# Environment:
#   GHCR_REGISTRY          default ghcr.io
#   GHCR_IMAGE_NAME        owner/name of the GHCR package (required)
#   GHCR_USERNAME          default $GITHUB_ACTOR, then the owner of the image
#   GITHUB_TOKEN           the per-run token; needs `packages: write`
#   DOCKERHUB_REGISTRY     default docker.io
#   DOCKERHUB_IMAGE_NAME   namespace/name on Docker Hub (required)
#   DOCKERHUB_USERNAME     Docker Hub account
#   DOCKERHUB_TOKEN        Docker Hub personal access token
#   DOCKERHUB_REQUIRED     1 (default) to treat Docker Hub as a release target
#   ALLOW_PRIVATE_GHCR     1 to downgrade a private GHCR package to a warning
#   BOX_VERBOSE=1          trace every command
#
# When DOCKERHUB_TOKEN is empty the credentials are read from the Docker CLI's
# config instead, so a job that logged in through OIDC trusted publishing
# (which leaves a short-lived credential there and never touches a PAT) is
# checked the same way.
#
# Exit codes:
#   0  every required registry accepted a write
#   1  a required registry did not (release mode only)
#   2  the script was misconfigured, or a check could not be performed

set -uo pipefail

if [ "${BOX_VERBOSE:-0}" = "1" ]; then
  set -x
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./registry-probe.sh
source "${SCRIPT_DIR}/registry-probe.sh"

MODE="${PREFLIGHT_MODE:-release}"

while [ $# -gt 0 ]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    -h | --help)
      sed -n '2,68p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "preflight-credentials.sh: unknown option $1" >&2
      exit 2
      ;;
  esac
done

case "$MODE" in
  release | report) ;;
  *)
    echo "preflight-credentials.sh: --mode must be 'release' or 'report', got '${MODE}'" >&2
    exit 2
    ;;
esac

GHCR_REGISTRY="${GHCR_REGISTRY:-ghcr.io}"
DOCKERHUB_REGISTRY="${DOCKERHUB_REGISTRY:-docker.io}"
DOCKERHUB_REQUIRED="${DOCKERHUB_REQUIRED:-1}"
ALLOW_PRIVATE_GHCR="${ALLOW_PRIVATE_GHCR:-0}"

for var in GHCR_IMAGE_NAME DOCKERHUB_IMAGE_NAME; do
  if [ -z "${!var:-}" ]; then
    echo "::error title=Release preflight::${var} is required" >&2
    exit 2
  fi
done

FAILURES=0
WARNINGS=0
WRITABLE=0
SUMMARY=""

# annotate LEVEL TITLE MESSAGE - one GitHub annotation, and one summary row.
#
# In report mode an error becomes a warning: a pull request that cannot publish
# is not a broken pull request. The count it increments changes with it, so the
# exit status follows the annotation rather than being decided separately.
annotate() {
  local level="$1" title="$2" message="$3"
  if [ "$level" = "error" ] && [ "$MODE" = "report" ]; then
    level="warning"
  fi
  case "$level" in
    error) FAILURES=$((FAILURES + 1)) ;;
    warning) WARNINGS=$((WARNINGS + 1)) ;;
  esac
  printf '::%s title=%s::%s\n' "$level" "$title" "$message"
}

row() {
  SUMMARY+="| $1 | $2 | $3 | $4 |"$'\n'
}

# docker_config_credentials REGISTRY - "user<TAB>secret" from the Docker CLI's
# config, or nothing.
#
# This is how an OIDC login is checked. `docker/login-action` with trusted
# publishing writes a short-lived credential here and there is no PAT anywhere
# in the environment to read; without this the preflight would report "no
# credential configured" for the setup we are trying to move to.
docker_config_credentials() {
  local registry="$1" config="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
  [ -f "$config" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$config" "$registry" <<'PY' 2>/dev/null || true
import base64, json, sys

config_path, registry = sys.argv[1], sys.argv[2]
# Docker Hub is stored under its v1 index URL, whatever name was typed at login.
keys = [registry, f"https://{registry}", f"{registry}/"]
if registry in ("docker.io", "index.docker.io", "registry-1.docker.io"):
    keys.insert(0, "https://index.docker.io/v1/")

with open(config_path) as handle:
    auths = json.load(handle).get("auths", {})

for key in keys:
    entry = auths.get(key)
    if not entry:
        continue
    if entry.get("auth"):
        decoded = base64.b64decode(entry["auth"]).decode("utf-8", "replace")
        user, _, secret = decoded.partition(":")
        if secret:
            print(f"{user}\t{secret}")
            break
    elif entry.get("username") and entry.get("password"):
        print(f"{entry['username']}\t{entry['password']}")
        break
PY
}

# check_push LABEL REGISTRY REPOSITORY USERNAME SECRET REQUIRED
#
# REQUIRED=0 means "report what you find and do not fail the run" - the Docker
# Hub mirror when a maintainer has deliberately turned it off.
check_push() {
  local label="$1" registry="$2" repository="$3" username="$4" secret="$5" required="$6"
  local level="error"
  [ "$required" = "1" ] || level="warning"

  if [ -z "$secret" ]; then
    local from_config
    from_config="$(docker_config_credentials "$registry")"
    if [ -n "$from_config" ]; then
      username="${from_config%%$'\t'*}"
      secret="${from_config#*$'\t'}"
      echo "==> ${label}: using the credential left by \`docker login\` (trusted publishing or a prior login step)"
    fi
  fi

  if [ -z "$username" ] || [ -z "$secret" ]; then
    row "$label" "$registry/$repository" "not configured" "no username/token in the environment"
    annotate "$level" "${label} credential missing" \
      "No credential is configured for ${registry}. This run cannot publish ${repository}, so building it would produce nothing releasable."
    return 0
  fi

  REGISTRY_PROBE_USERNAME="$username" REGISTRY_PROBE_PASSWORD="$secret" \
    registry_probe_push "$registry" "$repository"
  local state="$REGISTRY_PROBE_STATE" detail="$REGISTRY_PROBE_DETAIL"

  case "$state" in
    ok)
      WRITABLE=$((WRITABLE + 1))
      row "$label" "$registry/$repository" "writable" "$detail"
      echo "==> ${label}: OK - ${detail}"
      ;;
    invalid-credentials)
      row "$label" "$registry/$repository" "rejected" "$detail"
      annotate "$level" "${label} credential rejected" \
        "${registry} rejected the credential. ${detail} Rotate it before re-running: see the 'Releasing' section of README.md."
      ;;
    insufficient-scope)
      row "$label" "$registry/$repository" "no write access" "$detail"
      annotate "$level" "${label} credential cannot write" \
        "${registry} accepted the credential but refuses to write ${repository}. ${detail}"
      ;;
    missing-credentials)
      row "$label" "$registry/$repository" "not configured" "$detail"
      annotate "$level" "${label} credential missing" "$detail"
      ;;
    *)
      # Not the same as a failure, and not the same as a pass. A registry that
      # did not answer is a reason to stop before spending an hour of compute,
      # but the log has to say which of the two it was.
      row "$label" "$registry/$repository" "unknown" "$detail"
      annotate "$level" "${label} could not be checked" \
        "${registry} did not give a usable answer, so this run cannot show that it is able to publish. ${detail}"
      ;;
  esac
}

# check_public REFERENCE - is this package pullable by someone who is not us?
#
# Issue #117 point 3: the GHCR packages are the registry of record and both are
# private, so every image reference in the 2.6.0 release notes resolves for the
# publishing job and for nobody else. A package that exists and is private is
# checked here rather than after the build, because publishing more versions of
# an unreachable package is exactly the resource-intensive work this preflight
# exists to skip.
check_public() {
  local ref="$1"
  registry_probe_pull "$ref"
  case "$REGISTRY_PROBE_STATE" in
    published)
      row "GHCR visibility" "$ref" "public" "$REGISTRY_PROBE_DETAIL"
      echo "==> ${ref} is public"
      ;;
    missing)
      # Nothing published under this name yet, so there is no visibility to
      # check. GHCR creates the package private on first push, which is what
      # the post-publish assertion in create-release catches.
      row "GHCR visibility" "$ref" "not published yet" "$REGISTRY_PROBE_DETAIL"
      echo "==> ${ref} does not exist yet; nothing to check"
      ;;
    private)
      row "GHCR visibility" "$ref" "private" "$REGISTRY_PROBE_DETAIL"
      local level="error"
      [ "$ALLOW_PRIVATE_GHCR" = "1" ] && level="warning"
      annotate "$level" "GHCR package is private" \
        "${ref} cannot be pulled by an anonymous user, so anything published to it is unreachable. Make it public: https://github.com/orgs/${REGISTRY_PROBE_REPOSITORY%%/*}/packages -> the package -> Package settings -> Change visibility -> Public. GitHub exposes no API for this (the packages REST API is GET/DELETE/restore only), so it is a one-time manual step. Set ALLOW_PRIVATE_GHCR=1 to release into a package nobody can pull."
      ;;
    *)
      row "GHCR visibility" "$ref" "unknown" "$REGISTRY_PROBE_DETAIL"
      annotate "warning" "GHCR visibility unknown" \
        "${ref}: ${REGISTRY_PROBE_DETAIL}. This is not a claim that the package is private."
      ;;
  esac
}

echo "=== Release preflight (${MODE} mode) ==="
echo ""

check_push "GHCR" "$GHCR_REGISTRY" "$GHCR_IMAGE_NAME" \
  "${GHCR_USERNAME:-${GITHUB_ACTOR:-${GHCR_IMAGE_NAME%%/*}}}" "${GITHUB_TOKEN:-}" 1

if [ "$DOCKERHUB_REQUIRED" = "1" ]; then
  check_push "Docker Hub" "$DOCKERHUB_REGISTRY" "$DOCKERHUB_IMAGE_NAME" \
    "${DOCKERHUB_USERNAME:-}" "${DOCKERHUB_TOKEN:-}" 1
else
  echo "==> Docker Hub: DOCKERHUB_REQUIRED=0, mirroring is optional for this run"
  row "Docker Hub" "$DOCKERHUB_REGISTRY/$DOCKERHUB_IMAGE_NAME" "not required" "DOCKERHUB_REQUIRED=0"
fi

# The two package names every family ends up under. The per-language packages
# share their visibility setting with nothing, but they are created by the same
# token in the same run: a credential that can write box can write box-python,
# and a visibility problem shows up on these two first.
check_public "${GHCR_REGISTRY}/${GHCR_IMAGE_NAME}:latest"
check_public "${GHCR_REGISTRY}/${GHCR_IMAGE_NAME}-dind:latest"

echo ""
echo "| Target | Reference | State | Detail |"
echo "|--------|-----------|-------|--------|"
printf '%s' "$SUMMARY"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '## Release preflight (%s mode)\n\n' "$MODE"
    printf '| Target | Reference | State | Detail |\n'
    printf '|--------|-----------|-------|--------|\n'
    printf '%s' "$SUMMARY"
  } >>"$GITHUB_STEP_SUMMARY"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    printf 'failures=%s\n' "$FAILURES"
    printf 'warnings=%s\n' "$WARNINGS"
    printf 'ok=%s\n' "$([ "$FAILURES" -eq 0 ] && echo true || echo false)"
  } >>"$GITHUB_OUTPUT"
fi

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "==> ${FAILURES} blocking problem(s), ${WARNINGS} warning(s)."
  echo "==> Stopping here rather than building images this run cannot publish."
  exit 1
fi

# Two different clean results, said in two different ways. "Nothing failed" is
# not "everything was verified": in report mode, and on a fork, every check can
# come back unconfigured, and reporting that as a pass is the class of false
# positive this whole pull request is about.
if [ "$WRITABLE" -eq 0 ]; then
  echo "==> Nothing was verified: no registry credential in this environment accepted a write."
  echo "==> ${WARNINGS} warning(s). Reported rather than enforced (${MODE} mode)."
  exit 0
fi

echo "==> ${WRITABLE} registry credential(s) accepted a write, ${WARNINGS} warning(s)."
exit 0
