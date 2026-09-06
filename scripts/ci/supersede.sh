#!/usr/bin/env bash
#
# Stop CI from spending runners on commits a pull request has already moved past.
#
# Why this exists (measured on PR #113, issue #112):
#
#   run 33959630651  commit 53c4258  created 10:03  in_progress at 10:29
#   run 33959814682  commit 4f06a6c  created 10:07  pending -> cancelled 10:12
#   run 33960020799  commit 981b61e  created 10:12  pending -> cancelled 10:15
#   run 33960152379  commit f07e411  created 10:15  pending
#
#   The workflow already declared `concurrency: { group: <workflow>-<ref>,
#   cancel-in-progress: true }`, and every one of those commits carried an
#   identical stanza. GitHub nevertheless kept the run for the OLDEST commit
#   going — its `pr-test / full` job *started* at 10:29:39, twenty-two minutes
#   after that commit had been superseded — while each newer run sat in the
#   `pending` state (blocked on the concurrency group) only to be cancelled by
#   the next one. Net effect: the whole expensive matrix ran for a commit
#   nobody was waiting for, and the commit everybody was waiting for never ran.
#
#   The deadlock is inherent to relying on the shared group alone: a run that is
#   `pending` cannot execute a single step, so it cannot clean up after its
#   predecessors either. release.yml therefore gives pull_request runs a unique
#   concurrency group (they never block each other) and supersession is handled
#   explicitly, here, by two modes:
#
#     cancel-older        Runs once per run, early. Cancels every still-live run
#                         of this workflow that belongs to an EARLIER commit of
#                         the same pull request.
#
#     stop-if-superseded  Runs as the first step of every expensive job. A matrix
#                         job can sit queued for half an hour before a runner
#                         frees up (see `pr-test / full` above), so by the time
#                         it starts its commit may be long gone. It re-checks the
#                         pull request head and cancels its own run if so.

#     watch               Started in the background by those same jobs. Cancelling
#                         from the outside needs a free runner, and a superseded
#                         run is usually the reason there is none; a job that is
#                         already running can cancel the run from the inside.
#
#   Both modes fail open: a lookup or cancel that does not work (a fork PR gets a
#   read-only token and cannot cancel anything) logs a warning and lets CI
#   proceed. Losing a cancellation wastes runner minutes; a false cancellation
#   would lose test coverage, so the bias is deliberate.
#
# Inputs (environment, all provided by GitHub Actions):
#   GITHUB_EVENT_NAME    - only 'pull_request' does anything; anything else no-ops
#   GITHUB_REPOSITORY    - owner/repo
#   GITHUB_RUN_ID        - this run (the cancel target of stop-if-superseded)
#   GITHUB_RUN_NUMBER    - this run's number; only LOWER numbers are superseded
#   GITHUB_WORKFLOW_REF  - owner/repo/.github/workflows/<file>@<ref>
#   PR_NUMBER            - github.event.pull_request.number
#   PR_HEAD_SHA          - github.event.pull_request.head.sha (the commit THIS run is for)
#   PR_HEAD_BRANCH       - github.event.pull_request.head.ref
#   PR_HEAD_REPO_ID      - github.event.pull_request.head.repo.id (fork disambiguation)
#
# Testability (experiments/test-issue112-supersede.sh):
#   SUPERSEDE_API            - command used instead of `gh api` (raw JSON on stdout)
#   SUPERSEDE_WAIT_SECONDS   - how long to wait to be terminated after self-cancel
#   SUPERSEDE_FORCE_AFTER_SECONDS - grace period before escalating to force-cancel
#   SUPERSEDE_WATCH_INTERVAL_SECONDS / SUPERSEDE_WATCH_MAX_SECONDS - watch cadence
#
# JSON is parsed with python3 (as scripts/measure-disk-space.sh and
# scripts/update-readme-sizes.sh already do) rather than jq, so the filter itself
# is exercised by the unit test on any machine.

set -euo pipefail

MODE="${1:-}"

# Optional inputs get an explicit default so `set -u` stays on for the rest.
GITHUB_EVENT_NAME="${GITHUB_EVENT_NAME:-}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
GITHUB_RUN_ID="${GITHUB_RUN_ID:-}"
GITHUB_RUN_NUMBER="${GITHUB_RUN_NUMBER:-0}"
PR_NUMBER="${PR_NUMBER:-}"
PR_HEAD_SHA="${PR_HEAD_SHA:-}"
PR_HEAD_BRANCH="${PR_HEAD_BRANCH:-}"
PR_HEAD_REPO_ID="${PR_HEAD_REPO_ID:-}"
export GITHUB_RUN_ID GITHUB_RUN_NUMBER PR_HEAD_SHA PR_HEAD_REPO_ID

log() { echo "[supersede] $*"; }
warn() { echo "[supersede] WARNING: $*" >&2; }

API_CMD="${SUPERSEDE_API:-gh api}"

# GET a REST path, printing the raw response body. Returns non-zero on failure.
api_get() {
  local path="$1" out
  # Word splitting on $API_CMD is intentional: it is a command, not a filename.
  # shellcheck disable=SC2086
  if ! out="$($API_CMD "$path" 2>/dev/null)"; then
    warn "GET $path failed"
    return 1
  fi
  printf '%s' "$out"
}

# Ask a run to stop. Never fatal: a read-only token (fork PR) cannot cancel, and
# a run that finished on its own answers 409.
request_cancel() {
  local run_id="$1"
  # shellcheck disable=SC2086
  if $API_CMD --method POST "repos/${GITHUB_REPOSITORY}/actions/runs/${run_id}/cancel" >/dev/null 2>&1; then
    log "cancel requested for run ${run_id}"
  else
    warn "could not request a cancel for run ${run_id} (read-only token, or the run already finished)"
  fi
}

# The status of a run ('queued' / 'in_progress' / 'completed' / ...).
run_status() {
  local run_id="$1" payload
  payload="$(api_get "repos/${GITHUB_REPOSITORY}/actions/runs/${run_id}")" || return 1
  printf '%s' "$payload" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("status") or "")
except Exception:
    sys.exit(1)
'
}

# Make sure a cancel actually happened.
#
# A graceful cancel is a request, not a guarantee, and on this repository it is
# routinely ignored: run 33959630651 accepted `POST /actions/runs/{id}/cancel` at
# 10:40:57 and its `pr-test / dind-full` job still ran to a green finish at
# 10:49:25, with `pr-test / full` building on past that. (Same platform
# behaviour that made `concurrency: cancel-in-progress` a no-op here — the
# original bug.) `POST .../force-cancel` ended the very same run within seconds,
# so that is the fallback once the polite request has had its grace period.
ensure_cancelled() {
  local run_id="$1" waited=0 grace="${SUPERSEDE_FORCE_AFTER_SECONDS:-45}" status
  while :; do
    status="$(run_status "$run_id")" || return 0 # cannot tell: leave it alone
    if [ "$status" = "completed" ]; then
      log "run ${run_id} has stopped"
      return 0
    fi
    [ "$waited" -ge "$grace" ] && break
    sleep 5
    waited=$((waited + 5))
  done
  # shellcheck disable=SC2086
  if $API_CMD --method POST "repos/${GITHUB_REPOSITORY}/actions/runs/${run_id}/force-cancel" >/dev/null 2>&1; then
    log "run ${run_id} was still ${status} ${grace}s after the cancel: force-cancelled"
  else
    warn "could not force-cancel run ${run_id}"
  fi
}

# The workflow file name, e.g. release.yml, from GITHUB_WORKFLOW_REF
# (owner/repo/.github/workflows/release.yml@refs/pull/113/merge).
workflow_file() {
  local ref="${GITHUB_WORKFLOW_REF:-}"
  ref="${ref%%@*}"
  [ -n "$ref" ] || return 1
  basename "$ref"
}

# Read `.head.sha` out of a pull request payload on stdin.
pull_head_sha() {
  python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
print((data.get("head") or {}).get("sha") or "")
'
}

# Print "<id> <short sha> <status>" for every run in the payload on stdin that is
# still consuming (or waiting for) runners on behalf of an earlier commit of this
# same pull request.
superseded_runs() {
  python3 -c '
import json, os, sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

my_id = str(os.environ.get("GITHUB_RUN_ID", ""))
try:
    my_number = int(os.environ.get("GITHUB_RUN_NUMBER", "0"))
except ValueError:
    my_number = 0
my_sha = os.environ.get("PR_HEAD_SHA", "")
head_repo_id = os.environ.get("PR_HEAD_REPO_ID", "")

# States in which a run still holds, or is waiting to hold, runner capacity.
LIVE = {"queued", "in_progress", "pending", "waiting", "requested"}

for run in data.get("workflow_runs") or []:
    if str(run.get("id")) == my_id:
        continue                      # never cancel ourselves here
    if run.get("status") not in LIVE:
        continue                      # already finished: nothing to reclaim
    try:
        number = int(run.get("run_number", 0))
    except (TypeError, ValueError):
        continue
    if number >= my_number:
        continue                      # same or newer: not superseded by us
    if run.get("head_sha") == my_sha:
        continue                      # same commit, just a second run of it
    if head_repo_id:
        other = (run.get("head_repository") or {}).get("id")
        if other is not None and str(other) != str(head_repo_id):
            continue                  # same branch name on a different fork
    print("%s %s %s" % (run.get("id"), (run.get("head_sha") or "")[:7], run.get("status")))
'
}

require_pull_request() {
  if [ "${GITHUB_EVENT_NAME:-}" != "pull_request" ]; then
    log "event is '${GITHUB_EVENT_NAME:-none}', not a pull request: nothing to supersede"
    return 1
  fi
  if [ -z "$PR_NUMBER" ] || [ -z "$GITHUB_REPOSITORY" ]; then
    warn "PR_NUMBER/GITHUB_REPOSITORY missing: skipping"
    return 1
  fi
  return 0
}

# --- Mode: cancel every live run of this workflow for an earlier commit --------
cancel_older() {
  local wf runs targets count=0
  if ! wf="$(workflow_file)"; then
    warn "GITHUB_WORKFLOW_REF is not set: cannot list this workflow's runs"
    return 0
  fi

  local path="repos/${GITHUB_REPOSITORY}/actions/workflows/${wf}/runs?event=pull_request&per_page=100"
  if [ -n "${PR_HEAD_BRANCH:-}" ]; then
    path="${path}&branch=${PR_HEAD_BRANCH}"
  fi

  runs="$(api_get "$path")" || return 0
  targets="$(printf '%s' "$runs" | superseded_runs)" || {
    warn "could not parse the workflow run list"
    return 0
  }

  if [ -z "$targets" ]; then
    log "no superseded runs for PR #${PR_NUMBER} (this is run #${GITHUB_RUN_NUMBER:-?}, commit ${PR_HEAD_SHA:0:7})"
    return 0
  fi

  # Ask them all to stop first, then verify one by one: the grace period before a
  # force-cancel is then paid once, not once per run.
  local ids=""
  while read -r id sha status; do
    [ -n "$id" ] || continue
    log "run ${id} (commit ${sha}, ${status}) is behind ${PR_HEAD_SHA:0:7}: cancelling"
    request_cancel "$id"
    ids="${ids}${id} "
    count=$((count + 1))
  done <<<"$targets"

  for id in $ids; do
    ensure_cancelled "$id"
  done

  log "cancelled ${count} superseded run(s)"
}

# The pull request's head commit right now, or "" when it cannot be determined
# (which every caller treats as "carry on").
current_head() {
  local payload head
  payload="$(api_get "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}")" || return 0
  head="$(printf '%s' "$payload" | pull_head_sha)" || {
    warn "could not read the pull request head"
    return 0
  }
  [ -n "$head" ] || warn "pull request head is empty"
  printf '%s' "$head"
}

# Cancel this run, verifying it actually stops.
cancel_self() {
  local head="$1"
  log "PR #${PR_NUMBER} has moved on: ${PR_HEAD_SHA:0:7} -> ${head:0:7}"
  log "cancelling run ${GITHUB_RUN_ID} instead of building a superseded commit"
  request_cancel "${GITHUB_RUN_ID}"
  # Our own run cannot report 'completed' while this job is alive, so this call
  # ends one of two ways: the graceful cancel works and the runner kills us
  # mid-poll, or it does not and we force-cancel ourselves after the grace period.
  ensure_cancelled "${GITHUB_RUN_ID}"
}

# --- Mode: cancel THIS run if the pull request has moved on --------------------
stop_if_superseded() {
  local head
  head="$(current_head)"

  if [ -z "$head" ]; then
    log "continuing"
    return 0
  fi

  if [ "$head" = "${PR_HEAD_SHA:-}" ]; then
    log "commit ${PR_HEAD_SHA:0:7} is still the head of PR #${PR_NUMBER}: continuing"
    return 0
  fi

  cancel_self "$head"
  # The cancel is asynchronous: the runner tears this job down within seconds.
  # Wait for it rather than starting a build we know is pointless; if the
  # cancellation somehow never lands, fall through and let the job run.
  local waited=0 limit="${SUPERSEDE_WAIT_SECONDS:-120}"
  while [ "$waited" -lt "$limit" ]; do
    sleep 5
    waited=$((waited + 5))
  done
  [ "$limit" -gt 0 ] && warn "still running ${limit}s after the cancel request: continuing"
  return 0
}

# --- Mode: keep watching, from inside a job that is already holding a runner ---
#
# `cancel-older` needs a runner of its own, and a superseded run is usually the
# reason none is free: when it filled the account's job concurrency, the new
# run's `cancel-superseded` job queues behind the very jobs it exists to stop.
# (Measured on PR #113: run 33962058501 sat queued for over ten minutes while its
# predecessor held ~25 slots.) A job that is already running does not have that
# problem, so each expensive job also polls in the background and cancels the
# whole run the moment its commit stops being the pull request head. One
# cancelled run frees every slot it holds at once.
watch_superseded() {
  local interval="${SUPERSEDE_WATCH_INTERVAL_SECONDS:-300}"
  local limit="${SUPERSEDE_WATCH_MAX_SECONDS:-21600}" # a job cannot outlive 6h
  local waited=0 head

  # One poll per job every few minutes keeps well inside GITHUB_TOKEN's REST
  # budget even with the full ~28-job pull request matrix running.
  log "watching PR #${PR_NUMBER} every ${interval}s for commits after ${PR_HEAD_SHA:0:7}"
  while [ "$waited" -lt "$limit" ]; do
    sleep "$interval"
    waited=$((waited + interval))
    head="$(current_head)"
    [ -n "$head" ] || continue # transient failure: try again
    [ "$head" = "${PR_HEAD_SHA:-}" ] && continue
    cancel_self "$head"
    return 0
  done
  log "stopped watching after ${waited}s"
}

case "$MODE" in
  cancel-older)
    require_pull_request || exit 0
    cancel_older
    ;;
  stop-if-superseded)
    require_pull_request || exit 0
    stop_if_superseded
    ;;
  watch)
    require_pull_request || exit 0
    watch_superseded
    ;;
  *)
    echo "usage: $0 {cancel-older|stop-if-superseded|watch}" >&2
    exit 2
    ;;
esac
