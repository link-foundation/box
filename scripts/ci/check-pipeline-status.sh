#!/usr/bin/env bash
#
# Terminal status gate: turn a job that did not succeed into a red run.
#
# Why this exists (issue #121, template best practice "every workflow gets a
# terminal status gate"; see
# https://github.com/link-foundation/js-ai-driven-development-pipeline-template
# scripts/check-pipeline-status.sh, which this is a shell port of).
#
# GitHub derives a run's conclusion from its jobs, and one cancellation
# outranks any number of failures. So a run can contain a job that failed and
# still report itself grey rather than red - and everything that reads the run
# instead of its jobs (the status badge, `gh run list`, the list of recent runs
# quoted in issue #121 itself) then sees "no verdict" where it should see
# "something broke".
#
# That shape is measured here, not hypothesised. Run 34259552358 ("Build and
# Release Docker Image", PR for issue #119, attempt 2) finished with
#
#   run conclusion                     cancelled
#   pr-tests / pr-test / dind-full     failure     (20:34:56Z, on its own)
#   pr-tests / pr-test / full          cancelled   (21:00:52Z, with the run)
#
# It is the only such run in the last 200 (survey in
# dev/log/issues/121/pulls/122/), and it was superseded, so grey was defensible
# *that* time. What makes it worth a gate is that nothing in the colour said so:
# a job cancelled on its own - a `timeout-minutes` overrun, or one of this
# repository's 14 per-job `concurrency: cancel-in-progress` groups firing -
# produces exactly the same grey with no such excuse.
#
# A gate job fixes that because its own conclusion is a job conclusion: when it
# errors, the run is a failure regardless of what else was cancelled.
#
# Hence the two halves. A `failure` is always an error. A `cancelled` is an
# error only when this run is still the head of its branch, and a warning
# otherwise, because that is the difference between an overrun and a supersede
# (scripts/ci/supersede.sh). An unresolvable head counts as "not superseded": a
# missed supersede costs one noisy error, a missed overrun costs a silent
# failure.
#
# The gate job is gated on `!cancelled()`, never `always()` - the repository
# invariant checked by experiments/test-issue115-ci-policy.sh, from hive-mind
# issue #1278. `cancelled()` is a *run*-level predicate: when a whole run is
# cancelled somebody decided to stop it, and repainting that red is a false
# positive, so this job is skipped and the run stays grey. A job cancelled by
# itself does not set it, so those still arrive here.
#
# Usage (from a job with `if: !cancelled()` that `needs:` every other job):
#   NEEDS_JSON='${{ toJSON(needs) }}' \
#   RUN_SHA='${{ github.event.pull_request.head.sha || github.sha }}' \
#   BRANCH_NAME='${{ github.head_ref || github.ref_name }}' \
#     bash scripts/ci/check-pipeline-status.sh
#
# Environment:
#   NEEDS_JSON       required; `toJSON(needs)` from the calling job
#   RUN_SHA          commit this run tests; empty means "assume current"
#   BRANCH_NAME      branch to compare against    (default: main)
#   BRANCH_HEAD_SHA  skips the `git ls-remote` when already known
#   GIT_REMOTE       remote to resolve the head from (default: origin)
#   PIPELINE_STATUS_VERBOSE=1  print the parsed job/result table (default: off)

set -euo pipefail

: "${NEEDS_JSON:?NEEDS_JSON is required (pass toJSON(needs))}"

BRANCH_NAME="${BRANCH_NAME:-main}"
GIT_REMOTE="${GIT_REMOTE:-origin}"
VERBOSE="${PIPELINE_STATUS_VERBOSE:-0}"

trace() { [ "$VERBOSE" = "1" ] && echo "[pipeline-status] $*" >&2 || true; }

# Answers "has this branch moved past the commit this run tests?". Workflows
# that cancel superseded runs cancel their jobs by design; that must not read
# as an overrun.
run_is_superseded() {
  local head="${BRANCH_HEAD_SHA:-}"

  if [ -z "${RUN_SHA:-}" ]; then
    echo "RUN_SHA is unset; cannot compare this run with the head of ${BRANCH_NAME}; assuming it is current." >&2
    return 1
  fi

  if [ -z "$head" ]; then
    head="$(git ls-remote "$GIT_REMOTE" "refs/heads/${BRANCH_NAME}" 2>/dev/null | awk 'NR == 1 { print $1 }')"
  fi

  if [ -z "$head" ]; then
    echo "Could not resolve the head of ${BRANCH_NAME}; assuming this run is current." >&2
    return 1
  fi

  echo "This run tests ${RUN_SHA}; ${BRANCH_NAME} is at ${head}."
  [ "$head" != "$RUN_SHA" ]
}

# python3 rather than jq: jq is not guaranteed on every runner image this
# repository uses, python3 is (scripts/ci/summarize-measurements.py relies on
# the same assumption).
#
# `cancelled` is selected by name because it is the one result this script
# reasons about. Everything else is selected by *exclusion* - anything that is
# not `success` and not `skipped` counts as a failure - so the gate does not
# depend on knowing the full set of result strings. GitHub documents four for
# `needs.<id>.result` but reports `timed_out` and `action_required` on the jobs
# API, and a spelling this script had never heard of must not be read as
# "nothing wrong".
select_by_result() {
  NEEDS_JSON="$NEEDS_JSON" WANT_RESULT="$1" python3 -c '
import json, os
needs = json.loads(os.environ["NEEDS_JSON"])
want = os.environ["WANT_RESULT"]


def matches(result):
    if want == "cancelled":
        return result == "cancelled"
    return result not in ("success", "skipped", "cancelled")


print(", ".join(name for name, value in needs.items()
                if matches((value or {}).get("result"))))
'
}

if [ "$VERBOSE" = "1" ]; then
  trace "needs:"
  NEEDS_JSON="$NEEDS_JSON" python3 -c '
import json, os
for name, value in json.loads(os.environ["NEEDS_JSON"]).items():
    print("  %-40s %s" % (name, (value or {}).get("result")))
' >&2
fi

failed="$(select_by_result not-success)"
cancelled="$(select_by_result cancelled)"

echo "Failed jobs:    ${failed:-<none>}"
echo "Cancelled jobs: ${cancelled:-<none>}"

status=0

if [ -n "$failed" ]; then
  echo "::error title=Pipeline failed::Failing jobs: ${failed}"
  status=1
fi

if [ -n "$cancelled" ]; then
  if run_is_superseded; then
    echo "::warning title=Cancelled jobs in a superseded run::${cancelled}. This run is no longer the head of ${BRANCH_NAME}, so the cancellation reads as a supersede rather than an overrun."
  else
    echo "::error title=Pipeline has cancelled jobs::${cancelled}. This run is still the head of ${BRANCH_NAME}, so the cancellation is not a supersede. A job killed by 'timeout-minutes' is reported as cancelled, which would otherwise leave the run grey instead of red."
    status=1
  fi
fi

if [ "$status" -eq 0 ]; then
  echo "All required jobs succeeded or were legitimately skipped."
fi

exit "$status"
