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
# error unless a supersede explains it, and two things have to be true before
# one does: this run is no longer the head of its branch, and the cancelled job
# could actually have been cancelled by that - its effective
# `concurrency.cancel-in-progress` (its own, else the workflow's) is `true`.
# Anything unresolvable - an unreadable head, a workflow file the gate cannot
# find, an expression it cannot evaluate - counts as "not explained": a missed
# supersede costs one noisy error, a missed overrun costs a silent failure.
#
# The second half of that test is issue #123, and it is measured too. Run
# 34366975927 ("Measure Disk Space and Update README", main, 1d9fb3e) carried
#
#   failure  The job has exceeded the maximum execution time of 1h0m0s
#   warning  measure-disk-space. This run is no longer the head of main, so the
#            cancellation reads as a supersede rather than an overrun.
#
# in the same run, and this gate concluded `success`. The job it excused
# declares `timeout-minutes: 60` beside `cancel-in-progress: false` - in the
# workflow's own words it "queues instead of cancelling", so no supersede could
# have touched it and the 1h0m0s overrun was the only thing left. Asking
# whether the *run* was overtaken excuses every job in it, including the ones
# that a supersede cannot reach. scripts/ci/read-job-cancel-in-progress.sh
# answers it per job instead.
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
#   WORKFLOW_FILE    workflow to read job concurrency from; defaults to the one
#                    GITHUB_WORKFLOW_REF names
#   PIPELINE_STATUS_VERBOSE=1  print the parsed job/result table (default: off)

set -euo pipefail

: "${NEEDS_JSON:?NEEDS_JSON is required (pass toJSON(needs))}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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


for name, value in needs.items():
    if matches((value or {}).get("result")):
        print(name)
'
}

# One name per line is what the classification below needs; the comma form is
# only for the annotations, and is built from it.
join_names() {
  local out="" name
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    if [ -z "$out" ]; then out="$name"; else out="$out, $name"; fi
  done <<<"$1"
  printf '%s' "$out"
}

# Which workflow file is this gate running inside? The runner answers it in
# GITHUB_WORKFLOW_REF, as `owner/repo/.github/workflows/<file>@<ref>`. Nothing
# else in the job says so - `github.workflow` is the display name, which is not
# a path and need not be unique.
resolve_workflow_file() {
  local ref path

  if [ -n "${WORKFLOW_FILE:-}" ]; then
    printf '%s' "$WORKFLOW_FILE"
    return 0
  fi

  ref="${GITHUB_WORKFLOW_REF:-}"
  [ -z "$ref" ] && return 1
  ref="${ref%%@*}"
  path="${ref#*/.github/}"
  [ "$path" = "$ref" ] && return 1
  printf '.github/%s' "$path"
}

# Why each cancelled job is or is not explained by a supersede. Prints one
# `<job><TAB><verdict><TAB><reason>` line, verdict `supersede` or `overrun`.
classify_cancellations() {
  local names="$1" superseded="$2"
  local workflow reason name value
  local -A cancel_in_progress=()

  workflow="$(resolve_workflow_file || true)"

  if [ -z "$workflow" ]; then
    reason="the gate could not tell which workflow file it is running inside (GITHUB_WORKFLOW_REF is unset), so it could not read the job's concurrency"
  elif [ ! -f "$workflow" ]; then
    reason="the gate could not read ${workflow} from this checkout, so it could not read the job's concurrency"
  else
    reason=""
    local table=""
    if ! table="$(WORKFLOW_FILE="$workflow" JOB_NAMES="$names" \
      bash "$SCRIPT_DIR/read-job-cancel-in-progress.sh" 2>&1)"; then
      reason="the gate could not read the job concurrency out of ${workflow}: ${table}"
      table=""
    fi
    while IFS=$'\t' read -r name value; do
      [ -z "$name" ] && continue
      cancel_in_progress["$name"]="$value"
    done <<<"$table"
  fi

  while IFS= read -r name; do
    [ -z "$name" ] && continue
    value="${cancel_in_progress[$name]:-unreadable}"
    trace "cancelled job ${name}: cancel-in-progress=${value}, superseded=${superseded}"

    if [ "$superseded" != yes ]; then
      printf '%s\t%s\t%s\n' "$name" overrun \
        "the run is still the head of ${BRANCH_NAME}, so nothing overtook it"
      continue
    fi

    case "$value" in
      true)
        printf '%s\t%s\t%s\n' "$name" supersede \
          "it sets cancel-in-progress: true, so a supersede can cancel it"
        ;;
      false)
        printf '%s\t%s\t%s\n' "$name" overrun \
          "it sets cancel-in-progress: false, so a supersede queues behind it rather than cancelling it"
        ;;
      none)
        printf '%s\t%s\t%s\n' "$name" overrun \
          "it declares no concurrency group, at job or workflow level, so there is nothing for a supersede to cancel it through"
        ;;
      missing)
        printf '%s\t%s\t%s\n' "$name" overrun \
          "${workflow} declares no job by that name, so the gate could not read its concurrency"
        ;;
      *)
        printf '%s\t%s\t%s\n' "$name" overrun \
          "${reason:-the gate could not read its cancel-in-progress, which is an expression rather than a value}"
        ;;
    esac
  done <<<"$names"
}

if [ "$VERBOSE" = "1" ]; then
  trace "needs:"
  NEEDS_JSON="$NEEDS_JSON" python3 -c '
import json, os
for name, value in json.loads(os.environ["NEEDS_JSON"]).items():
    print("  %-40s %s" % (name, (value or {}).get("result")))
' >&2
fi

failed_lines="$(select_by_result not-success)"
cancelled_lines="$(select_by_result cancelled)"

failed="$(join_names "$failed_lines")"
cancelled="$(join_names "$cancelled_lines")"

echo "Failed jobs:    ${failed:-<none>}"
echo "Cancelled jobs: ${cancelled:-<none>}"

status=0

if [ -n "$failed" ]; then
  echo "::error title=Pipeline failed::Failing jobs: ${failed}"
  status=1
fi

if [ -n "$cancelled" ]; then
  superseded=no
  if run_is_superseded; then
    superseded=yes
  fi

  superseded_lines=""
  overrun_lines=""
  while IFS=$'\t' read -r job verdict reason; do
    [ -z "$job" ] && continue
    echo "  ${job}: ${reason}"
    if [ "$verdict" = supersede ]; then
      superseded_lines+="${job}"$'\n'
    else
      overrun_lines+="${job}"$'\n'
    fi
  done < <(classify_cancellations "$cancelled_lines" "$superseded")

  superseded_jobs="$(join_names "$superseded_lines")"
  overrun_jobs="$(join_names "$overrun_lines")"

  if [ -n "$superseded_jobs" ]; then
    echo "::warning title=Cancelled jobs in a superseded run::${superseded_jobs}. This run is no longer the head of ${BRANCH_NAME} and these jobs cancel in progress, so the cancellation reads as a supersede rather than an overrun."
  fi

  if [ -n "$overrun_jobs" ]; then
    echo "::error title=Pipeline has cancelled jobs::${overrun_jobs}. No supersede accounts for these cancellations (see the reasons above). A job killed by 'timeout-minutes' is reported as cancelled, which would otherwise leave the run grey instead of red."
    status=1
  fi
fi

if [ "$status" -eq 0 ]; then
  echo "All required jobs succeeded or were legitimately skipped."
fi

exit "$status"
