#!/usr/bin/env bash
# run-zizmor.sh
#
# Runs zizmor over this repository's workflows and composite actions, in the
# one mode where the audits it is being paid for are actually available.
#
# Usage:
#   bash scripts/ci/run-zizmor.sh regular    # default persona, medium/medium
#   bash scripts/ci/run-zizmor.sh pedantic   # pedantic persona, high/high
#   bash scripts/ci/run-zizmor.sh --print regular   # print the command, run nothing
#
# Environment:
#   GH_TOKEN / GITHUB_TOKEN   GitHub API token. Required - see below.
#   ZIZMOR_IMAGE              override the pinned image
#   ZIZMOR_DOCKER             the container runtime to invoke (default: docker)
#   ZIZMOR_ALLOW_OFFLINE=1    downgrade the missing token and the offline
#                             banner from an error to a notice, for a local
#                             run without a token. CI must never set it, and
#                             experiments/test-issue123-zizmor-token.sh asserts
#                             that no workflow does.
#   BOX_VERBOSE=1             trace commands without exposing token values
#
# Exit code 0 = zizmor reported nothing at or above the pass's floors *and* it
# ran with its full audit set.
#
# Why this exists (issue #123)
# ----------------------------
# The Workflows run on 1d9fb3e was green, and printed this twice - once per
# zizmor pass (run 34366975873, log lines 729 and 767):
#
#   WARN audit: zizmor: zizmor is running in offline mode by default; some
#   audits and auto-fixes will not be available. see
#   https://docs.zizmor.sh/usage/#operating-modes for details
#
# Since 1.0 zizmor is offline unless it is given a GitHub API token, and the
# two `docker run` invocations passed none: `docker run` does not forward the
# environment, so even a job holding GITHUB_TOKEN hands the container nothing.
# The audits that need the API - `known-vulnerable-actions`, which asks the
# GitHub Advisory Database whether a pinned action has a published advisory -
# were therefore never running. The job reported "No findings to report" about
# a question it had not asked: a false negative, and the expensive kind, since
# it is the only audit here that can catch a supply-chain compromise of an
# action this repository already trusts.
#
# Measured against a fixture pinning `tj-actions/changed-files@v44` - the
# action compromised in CVE-2025-30066 - with zizmor 1.30.0:
#
#   offline: 7 findings (3 suppressed): 0 informational, 0 low, 2 medium, 2 high
#   online:  8 findings (3 suppressed): 0 informational, 0 low, 2 medium, 3 high
#            error[known-vulnerable-actions]: action has a known vulnerability
#
# experiments/reproduce-issue123-zizmor-offline-audits.sh is that measurement.
#
# So this script does two things the inline `docker run` could not. It passes
# the token into the container, and it treats the offline banner as a failure
# rather than a line in the log - because the banner is the audit set silently
# shrinking, and a check that reports success about audits it did not run is
# worse than no check at all. Both passes go through here, so neither can drift
# from the other or lose the token again.
#
# See: https://github.com/link-foundation/box/issues/123
#      https://docs.zizmor.sh/usage/#operating-modes

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=scripts/ci/capture-and-stream.sh
source "$SCRIPT_DIR/capture-and-stream.sh"

if [ "${BOX_VERBOSE:-0}" = "1" ]; then
  set -x
fi

IMAGE="${ZIZMOR_IMAGE:-ghcr.io/zizmorcore/zizmor:1.30.0}"
DOCKER="${ZIZMOR_DOCKER:-docker}"
ALLOW_OFFLINE="${ZIZMOR_ALLOW_OFFLINE:-0}"

# The banner zizmor prints when it has no token. Matched on the stable part of
# the sentence; the URL after it moves between releases.
OFFLINE_MARKER='running in offline mode'

# Both passes scan the composite actions as well as the workflows: a composite
# action runs inside the calling job with the calling job's credentials, and
# leaving it unaudited was hiding a High-confidence template-injection
# (issue #121).
TARGETS=(.github/workflows .github/actions)
COMMON_ARGS=(--no-progress --format plain --config .github/zizmor.yml)

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \?//'
}

PRINT_ONLY=0
PASS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --print)
      PRINT_ONLY=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    regular | pedantic)
      PASS="$1"
      shift
      ;;
    *)
      echo "run-zizmor.sh: unknown argument $1 (want 'regular' or 'pedantic')" >&2
      exit 2
      ;;
  esac
done

if [ -z "$PASS" ]; then
  echo "run-zizmor.sh: a pass is required: 'regular' or 'pedantic'" >&2
  exit 2
fi

case "$PASS" in
  regular)
    # --min-severity medium: the remaining low findings are `self-repository`
    # (a `./.github/actions/...` reference style) and template expansions of
    # `matrix.language` or this repository's own step outputs, none of which
    # are attacker-controllable. Everything at medium and above is fixed and
    # must stay fixed.
    PASS_ARGS=(--min-confidence medium --min-severity medium)
    ;;
  pedantic)
    # The audits covering container image references - `unpinned-images` among
    # them - are Pedantic-only, so the `'*': hash-pin` policy declared in
    # .github/zizmor.yml was never enforced against `uses: docker://` or
    # `container:` at all (issue #121). Narrowing this pass to high severity
    # *and* high confidence restores the enforcement without the noise.
    PASS_ARGS=(--persona pedantic --min-severity high --min-confidence high)
    ;;
esac

# `--print` always shows the token-bearing form, because that is the command
# CI runs and the one worth reproducing locally.
CMD=("$DOCKER" run --rm -v "$REPO_ROOT:/repo" -w /repo -e GH_TOKEN
  "$IMAGE" "${PASS_ARGS[@]}" "${COMMON_ARGS[@]}" "${TARGETS[@]}")

if [ "$PRINT_ONLY" = "1" ]; then
  printf '%s\n' "${CMD[*]}"
  exit 0
fi

# xtrace expands assignment and test operands.  Passing the token to Docker by
# environment *name* keeps it out of argv, but it does not keep a preceding
# `set -x` from printing `TOKEN=...`, `[ -z ... ]`, and `export GH_TOKEN=...`.
# Suspend tracing for the whole secret-dependent branch and discard the local
# copy before restoring it.  The command traced afterwards contains only
# `-e GH_TOKEN`, never its value (issue #125).
if [ "${BOX_VERBOSE:-0}" = "1" ]; then
  { set +x; } 2>/dev/null
fi

TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

if [ -z "$TOKEN" ]; then
  if [ "$ALLOW_OFFLINE" = "1" ]; then
    echo "::notice title=zizmor is running offline::No GH_TOKEN, and ZIZMOR_ALLOW_OFFLINE=1, so the online audits (known-vulnerable-actions among them) are skipped. This is for local runs; CI must supply a token."
  else
    echo "::error title=zizmor has no GitHub token::Set GH_TOKEN (in CI: env: GH_TOKEN: \${{ secrets.GITHUB_TOKEN }}). Without one zizmor runs offline and silently skips every audit that needs the API, including known-vulnerable-actions, while still reporting success." >&2
    exit 1
  fi
fi

if [ -n "$TOKEN" ]; then
  # The token is passed by name, never on the command line: an argument is
  # visible in `ps` and in `set -x` output, and BOX_VERBOSE=1 turns the latter
  # on.
  export GH_TOKEN="$TOKEN"
else
  # Only reachable with ZIZMOR_ALLOW_OFFLINE=1. `-e GH_TOKEN` with nothing
  # behind it forwards an empty value, and zizmor rejects that outright -
  # "invalid value '' for '--gh-token <GH_TOKEN>': GitHub token cannot be
  # empty" - so an allowed offline run has to omit the flag rather than pass an
  # empty one.
  CMD=("$DOCKER" run --rm -v "$REPO_ROOT:/repo" -w /repo
    "$IMAGE" "${PASS_ARGS[@]}" "${COMMON_ARGS[@]}" "${TARGETS[@]}")
fi

unset TOKEN
if [ "${BOX_VERBOSE:-0}" = "1" ]; then
  set -x
fi

cd "$REPO_ROOT" || exit 2

echo "==> zizmor (${PASS} pass): ${CMD[*]}"

# Captured while still streaming, so the banner can be classified without the
# run going silent. Not `tee /dev/stderr`, which truncates the caller's stderr
# when it is a regular file (issue #123, scripts/ci/capture-and-stream.sh).
capture_and_stream "${CMD[@]}"
STATUS=$?

if printf '%s' "$CAPTURED_OUTPUT" | grep -qF "$OFFLINE_MARKER"; then
  if [ "$ALLOW_OFFLINE" = "1" ]; then
    echo "::notice title=zizmor ran offline::ZIZMOR_ALLOW_OFFLINE=1, so the shrunken audit set is not an error here."
  else
    echo "::error title=zizmor ran offline::zizmor printed its offline banner, so the audits that need the GitHub API - known-vulnerable-actions among them - did not run, and the findings below are not the full set. The token this job passed is missing, empty, or was not accepted." >&2
    exit 1
  fi
fi

exit "$STATUS"
