#!/usr/bin/env bash
# Turn timeout cancellations into visible failures on the release branch.
set -euo pipefail

: "${NEEDS_JSON:?NEEDS_JSON is required (pass toJSON(needs))}"
IS_MAIN="${IS_MAIN:-false}"

# Answers "is a newer run already testing this branch?". Workflows whose
# concurrency groups cancel in progress unconditionally cancel the first
# run's jobs by design when two pushes land in quick succession, and that
# supersede must not read as a timeout. An unresolvable head is treated as
# "not superseded": a missed supersede costs one noisy error, a missed
# overrun costs a silent failure on main.
run_is_superseded() {
  local branch="${MAIN_BRANCH:-main}"
  local head="${BRANCH_HEAD_SHA:-}"

  if [ -z "${RUN_SHA:-}" ]; then
    echo "RUN_SHA is unset; cannot compare this run with the head of ${branch}; assuming it is current." >&2
    return 1
  fi

  if [ -z "$head" ]; then
    head="$(git ls-remote "${GIT_REMOTE:-origin}" "refs/heads/${branch}" 2>/dev/null | awk 'NR == 1 { print $1 }')"
  fi

  if [ -z "$head" ]; then
    echo "Could not resolve the head of ${branch}; assuming this run is current." >&2
    return 1
  fi

  echo "This run tests ${RUN_SHA}; ${branch} is at ${head}."
  [ "$head" != "$RUN_SHA" ]
}

select_by_result() {
  NEEDS_JSON="$NEEDS_JSON" WANT_RESULT="$1" node --input-type=module -e '
    const needs = JSON.parse(process.env.NEEDS_JSON);
    const jobs = Object.entries(needs)
      .filter(([, value]) => value.result === process.env.WANT_RESULT)
      .map(([name]) => name);
    console.log(jobs.join(", "));
  '
}

failed="$(select_by_result failure)"
cancelled="$(select_by_result cancelled)"

echo "Failed jobs:    ${failed:-<none>}"
echo "Cancelled jobs: ${cancelled:-<none>}"

status=0

if [ -n "$failed" ]; then
  echo "::error::Pipeline failed. Failing jobs: ${failed}"
  status=1
fi

if [ -n "$cancelled" ]; then
  if [ "$IS_MAIN" = "true" ] && ! run_is_superseded; then
    echo "::error::Pipeline has cancelled jobs on main: ${cancelled}. A job killed by 'timeout-minutes' is reported as cancelled, which would otherwise hide the failure."
    status=1
  else
    echo "::warning::Cancelled jobs: ${cancelled}. This run is not the current head of its branch, or is not a push to the default branch, so the cancellation reads as a superseded run. A genuine overrun should surface as a step budget failure instead (see docs/CI-TIMEOUT-BUDGETS.md)."
  fi
fi

if [ "$status" -eq 0 ]; then
  echo "All required jobs succeeded or were legitimately skipped."
fi

exit "$status"
