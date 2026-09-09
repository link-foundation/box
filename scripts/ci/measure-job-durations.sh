#!/usr/bin/env bash
# measure-job-durations.sh - the longest each job has actually taken.
#
# Why this exists (issue #121). Every `timeout-minutes` in this repository had
# been chosen by guessing, and the guesses were not close: the disk-space job
# carried `timeout-minutes: 180  # 3 hours max for full installation
# measurement` against a slowest-ever run of 23.3 minutes, and the release
# builds carried 120 against measured maxima of 10.3 to 35.6. A cap far above
# the work it bounds is not free caution - it is the number of minutes a hung
# job burns before anyone hears about it.
#
# So the caps and budgets in docs/CI-TIMEOUT-BUDGETS.md are sized from this,
# and this exists so the next person can re-derive them rather than inherit
# them. Run it before changing a cap.
#
# Only successful jobs are sampled. A cancelled job's duration says how long
# something waited, not how long the work takes, and a failed job usually
# stopped early - averaging either into the number that has to accommodate the
# slowest legitimate run is how a cap ends up too tight.
#
# Usage:
#   bash scripts/ci/measure-job-durations.sh [WORKFLOW_FILE] [RUN_LIMIT]
#
#     WORKFLOW_FILE   a file in .github/workflows (default: every workflow)
#     RUN_LIMIT       runs to sample per workflow    (default: 50)
#
# Requires `gh` authenticated against the repository. The jq expressions run
# inside `gh --jq`, so no jq binary is needed on the machine.
#
# Output: one line per job, longest first within each workflow:
#   security / CodeQL (actions)                        1.3 min

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

REPO="${REPO:-link-foundation/box}"
WORKFLOW="${1:-}"
RUN_LIMIT="${2:-50}"

measure_workflow() {
  local workflow="$1"

  echo "=== ${workflow} (last ${RUN_LIMIT} runs) ==="

  gh run list --repo "$REPO" --workflow "$workflow" --limit "$RUN_LIMIT" \
    --json databaseId --jq '.[].databaseId' \
    | while read -r run_id; do
      gh api "repos/${REPO}/actions/runs/${run_id}/jobs?per_page=100" --paginate \
        --jq '.jobs[] | select(.conclusion == "success")
              | [.name, ((.completed_at | fromdateiso8601) - (.started_at | fromdateiso8601)) / 60]
              | @tsv'
    done \
    | sort -t"$(printf '\t')" -k1,1 -k2,2gr \
    | awk -F"$(printf '\t')" '!seen[$1]++ { printf "%-50s %6.1f min\n", $1, $2 }' \
    | sort -k2 -gr
  echo
}

if [ -n "$WORKFLOW" ]; then
  measure_workflow "$(basename "$WORKFLOW")"
else
  for workflow in .github/workflows/*.yml; do
    measure_workflow "$(basename "$workflow")"
  done
fi
