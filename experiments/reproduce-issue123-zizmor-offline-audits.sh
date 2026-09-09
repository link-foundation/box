#!/usr/bin/env bash
# reproduce-issue123-zizmor-offline-audits.sh
#
# Measures what zizmor's offline default costs: the same analyser, the same
# version, the same fixture, run twice - once the way the Workflows job ran it
# before issue #123, and once with a GitHub API token - and the difference
# between the two finding sets.
#
# Why (issue #123). Run 34366975873 on 1d9fb3e was green and printed, twice:
#
#   WARN audit: zizmor: zizmor is running in offline mode by default; some
#   audits and auto-fixes will not be available.
#
# Both passes were `docker run` invocations with no `-e GH_TOKEN`, so the
# container held no token and zizmor took its offline default. This shows which
# audit that removed, against `tj-actions/changed-files@v44` - the action
# compromised in CVE-2025-30066, and one of the most widely used actions on
# GitHub, so "an action we already trust" is not hypothetical.
#
# This is a measurement, not an assertion: it needs docker, a network and a
# token, so scripts/ci/run-experiments.sh skips it. Its offline twin -
# experiments/test-issue123-zizmor-token.sh - asserts what this repository does
# with the answer, and runs everywhere.
#
# Usage:
#   GH_TOKEN="$(gh auth token)" bash experiments/reproduce-issue123-zizmor-offline-audits.sh
#
# Environment:
#   GH_TOKEN / GITHUB_TOKEN   the token for the online pass (required)
#   ZIZMOR_IMAGE              analyser image, default: the one the CI job pins

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

IMAGE="${ZIZMOR_IMAGE:-$(sed -n 's|^IMAGE="${ZIZMOR_IMAGE:-\(.*\)}"$|\1|p' scripts/ci/run-zizmor.sh | head -1)}"
IMAGE="${IMAGE:-ghcr.io/zizmorcore/zizmor:1.30.0}"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker is not available, and this measurement runs the analyser twice."
  exit 0
fi

if [ -z "$TOKEN" ]; then
  echo "SKIP: no GH_TOKEN/GITHUB_TOKEN, so the online half of the comparison cannot run."
  exit 0
fi

FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/.github/workflows"

# One workflow, one finding that only the online audit set can report. The
# version is pinned by tag on purpose: that is how the compromise was delivered.
cat >"$FIXTURE/.github/workflows/vulnerable.yml" <<'YAML'
name: Vulnerable
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: tj-actions/changed-files@v44
YAML

echo "== analyser: $IMAGE =="
echo

run_pass() {
  local label="$1"
  shift
  echo "== $label =="
  docker run --rm -v "$FIXTURE:/repo" -w /repo "$@" "$IMAGE" \
    --min-confidence low --min-severity low --no-progress --format plain \
    .github/workflows 2>&1 | tee "$FIXTURE/$label.log" | sed 's/^/  /'
  echo
}

export GH_TOKEN="$TOKEN"

# The command the job used to run: no environment forwarded.
run_pass offline
# The command it runs now.
run_pass online -e GH_TOKEN

echo "== difference =="
for label in offline online; do
  known="$(grep -c 'known-vulnerable-actions' "$FIXTURE/$label.log" || true)"
  banner="$(grep -c 'running in offline mode' "$FIXTURE/$label.log" || true)"
  totals="$(grep -E '^[0-9]+ findings' "$FIXTURE/$label.log" | head -1)"
  printf '  %-7s  known-vulnerable-actions: %s   offline banner: %s   %s\n' \
    "$label" "$known" "$banner" "${totals:-<no totals line>}"
done

echo
if grep -q 'known-vulnerable-actions' "$FIXTURE/online.log" \
  && ! grep -q 'known-vulnerable-actions' "$FIXTURE/offline.log"; then
  echo "Reproduced: the offline default skips known-vulnerable-actions, and reports success without it."
  exit 0
fi

echo "Not reproduced here: both passes agree. Check the token and the network before concluding the gap is closed."
exit 1
