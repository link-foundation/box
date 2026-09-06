#!/usr/bin/env bash
# list-release-workflows.sh - Print every workflow file the release pipeline is
# made of: .github/workflows/release.yml and, transitively, every workflow it
# calls with `uses: ./.github/workflows/...`.
#
# Why (issue #115, RC-8). release.yml used to be one 3135-line file, and a dozen
# regression suites grepped it by name. Splitting it by image family would have
# turned every one of those greps into a vacuous pass - `grep -c` over a file
# that no longer contains the jobs returns 0, and an assertion that counts
# nothing and finds nothing is green. That is precisely the false negative
# issue #115 is about, so the suites ask this script what to read instead of
# naming a file.
#
# It resolves the graph rather than listing the six files, so the next split
# needs no change here or in the suites.
#
# Usage:
#   bash scripts/ci/list-release-workflows.sh          # paths, one per line
#   bash scripts/ci/list-release-workflows.sh --job build-dind-amd64
#                                                     # the file defining that job
#   ROOT=. bash scripts/ci/list-release-workflows.sh
#
# `--job` exists so a suite can say which job it is about instead of which file
# it used to be in. It exits 3 when no workflow defines the job, so a renamed or
# deleted job fails the suite that checks it rather than silently checking
# nothing.
#
# Environment:
#   ROOT           repository root (default: the repository this script is in)
#   ENTRY          entry workflow (default: .github/workflows/release.yml)
#   BOX_VERBOSE=1  trace resolution to stderr
#
# Exit codes:
#   0  every path printed exists
#   1  a `uses:` points at a workflow file that is not there
#   2  misuse
#   3  --job named a job no workflow in the graph defines

set -uo pipefail

JOB=""
while [ $# -gt 0 ]; do
  case "$1" in
    --job)
      JOB="${2:-}"
      if [ -z "$JOB" ]; then
        echo "list-release-workflows.sh: --job needs a job id" >&2
        exit 2
      fi
      shift 2
      ;;
    -h | --help)
      sed -n '2,30p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "list-release-workflows.sh: unknown option $1" >&2
      exit 2
      ;;
  esac
done

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ENTRY="${ENTRY:-.github/workflows/release.yml}"
BOX_VERBOSE="${BOX_VERBOSE:-0}"

cd "$ROOT" || exit 1

if [ ! -f "$ENTRY" ]; then
  echo "::error title=list-release-workflows::$ENTRY not found (ROOT=$ROOT)" >&2
  exit 1
fi

seen=""
queue="$ENTRY"
status=0
found=0

while [ -n "$queue" ]; do
  current="${queue%%$'\n'*}"
  if [ "$current" = "$queue" ]; then
    queue=""
  else
    queue="${queue#*$'\n'}"
  fi

  case "$seen" in
    *"|$current|"*) continue ;;
  esac
  seen="$seen|$current|"

  if [ ! -f "$current" ]; then
    echo "::error title=list-release-workflows::$current is referenced but does not exist" >&2
    status=1
    continue
  fi

  if [ -z "$JOB" ]; then
    printf '%s\n' "$current"
  elif grep -qE "^  ${JOB}:[[:space:]]*\$" "$current"; then
    printf '%s\n' "$current"
    found=1
  fi

  # `uses: ./.github/workflows/x.yml` - a local reusable workflow. Comments are
  # excluded so that prose naming a file does not pull it in.
  called="$(grep -E '^[[:space:]]*uses:[[:space:]]*\./\.github/workflows/[^[:space:]]+' "$current" \
    | grep -v '^[[:space:]]*#' \
    | sed -E 's#.*uses:[[:space:]]*\./##' \
    | tr -d '\r' || true)"

  for c in $called; do
    [ "$BOX_VERBOSE" = "1" ] && echo "list-release-workflows: $current -> $c" >&2
    queue="${queue:+$queue$'\n'}$c"
  done
done

if [ -n "$JOB" ] && [ "$found" -ne 1 ] && [ "$status" -eq 0 ]; then
  echo "::error title=list-release-workflows::no workflow in the ${ENTRY} graph defines job '${JOB}'" >&2
  exit 3
fi

exit "$status"
