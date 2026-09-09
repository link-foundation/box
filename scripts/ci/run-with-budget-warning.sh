#!/usr/bin/env bash
# run-with-budget-warning.sh
#
# Gives a long CI step its own deadline, so the step - not the job - decides
# when time has run out, and says which deadline it was.
#
# Why this exists (issue #121; a port of scripts/run-with-budget-warning.sh
# from link-foundation/js-ai-driven-development-pipeline-template, which the
# reference template documents in docs/CI-TIMEOUT-BUDGETS.md).
#
# `timeout-minutes` is a backstop, not a deadline, for two reasons.
#
#   1. GitHub reports a job killed by it as *cancelled*, not *failed*. This
#      repository already refuses to let that pass silently -
#      scripts/ci/check-pipeline-status.sh turns a cancelled job into a run
#      failure whenever the run is still the head of its branch - but the gate
#      can only say "pr-test / full was cancelled". It cannot say which step,
#      which deadline, or how far over.
#
#   2. A cancelled job is stopped where it stands. Steps that would have run
#      `if: always()` - the resource summaries, the log uploads - do not run,
#      so the evidence about the overrun dies with the job. A step that fails
#      leaves the rest of the job's reporting intact.
#
# The 46 minutes of headroom in `pr-test / full` are what makes the difference
# concrete: at a 90-minute cap a build that hangs at minute 44 costs 46 minutes
# of runner time before anything is reported, and then reports the wrong thing.
#
# Usage:
#   bash scripts/ci/run-with-budget-warning.sh SECONDS LABEL COMMAND [ARG...]
#
# Environment:
#   BUDGET_WARN_PERCENT   emit a warning at this share of the budget (default 70)
#   BUDGET_GRACE_SECONDS  seconds between SIGTERM and SIGKILL (default 10)
#   BUDGET_POLL_SECONDS   polling interval while the command runs (default 1)
#
# Exit codes: the command's own status, or 124 on timeout (matching timeout(1)).
set -uo pipefail

if [ "$#" -lt 3 ]; then
  echo "Usage: $0 SECONDS LABEL COMMAND [ARG...]" >&2
  exit 2
fi

budget_seconds="$1"
label="$2"
shift 2

case "$budget_seconds" in
  '' | *[!0-9]*)
    echo "Budget must be a whole number of seconds, got '${budget_seconds}'." >&2
    exit 2
    ;;
esac

if [ "$budget_seconds" -le 0 ]; then
  echo "Budget must be greater than zero seconds." >&2
  exit 2
fi

warn_percent="${BUDGET_WARN_PERCENT:-70}"
grace_seconds="${BUDGET_GRACE_SECONDS:-10}"
poll_seconds="${BUDGET_POLL_SECONDS:-1}"
warn_seconds=$((budget_seconds * warn_percent / 100))

# A fractional value is legitimate, but it must be a number: the grace loop
# sleeps on it, and a typo would otherwise sit here undiscovered until the
# first overrun.
case "$poll_seconds" in
  '' | *[!0-9.]* | *.*.*)
    echo "BUDGET_POLL_SECONDS must be a positive number, got: ${poll_seconds}" >&2
    exit 2
    ;;
esac

status_dir="$(mktemp -d "${TMPDIR:-/tmp}/budget-status.XXXXXX")"
status_file="${status_dir}/status"
trap 'rm -rf "${status_dir}"' EXIT

# `set -m` puts the command in its own process group, so the signals below
# reach the whole tree. A `docker build` here leaves a CLI, a BuildKit session
# and whatever the build itself spawned; killing only the direct child leaves
# orphans holding the runner -- which is also why timeout(1) is not sufficient.
#
# Completion is detected through the status file rather than process
# liveness: a finished child stays visible as a zombie until it is reaped,
# so `kill -0` alone would never report it as done.
set -m
{
  "$@"
  command_status=$?
  printf '%s\n' "${command_status}" >"${status_file}.partial"
  mv "${status_file}.partial" "${status_file}"
} &
command_pid=$!
set +m

# Signal the process group when possible, falling back to the direct child
# on platforms without usable process groups (notably Git Bash on Windows).
signal_command() {
  local signal="$1"
  kill "-${signal}" -- "-${command_pid}" 2>/dev/null \
    || kill "-${signal}" "${command_pid}" 2>/dev/null \
    || true
}

# Liveness is tracked on the process group, never on command_pid alone: the
# pid belongs to the wrapper subshell, which dies on SIGTERM as soon as it
# is delivered even when the command itself ignores the signal -- a group
# that still has a live member is the only reliable "still running" answer.
command_is_running() {
  [ ! -f "${status_file}" ] \
    && kill -0 -- "-${command_pid}" 2>/dev/null
}

terminate_over_budget() {
  echo "::error title=${label} exceeded its execution budget::${label} did not finish within its ${budget_seconds}s budget and was terminated. Shorten the step or raise its budget (keeping it below the job's timeout-minutes backstop)."
  signal_command TERM

  # The step's own SECONDS clock, not an accumulation of the (possibly
  # fractional) poll interval: bash arithmetic is integer-only, so summing
  # poll_seconds would abort this function before the SIGKILL escalation.
  local grace_deadline=$((SECONDS + grace_seconds))
  while command_is_running && [ "${SECONDS}" -lt "${grace_deadline}" ]; do
    sleep "${poll_seconds}"
  done

  if command_is_running; then
    echo "${label} ignored SIGTERM after ${grace_seconds}s; sending SIGKILL."
    signal_command KILL
  fi

  wait "${command_pid}" 2>/dev/null || true
  exit 124
}

echo "Running ${label} with a ${budget_seconds}s budget (warning at ${warn_seconds}s)."

SECONDS=0
warned=false

while command_is_running; do
  if [ "${warned}" = false ] && [ "${SECONDS}" -ge "${warn_seconds}" ]; then
    warned=true
    echo "::warning title=${label} is approaching its execution budget::${label} has run for ${SECONDS}s of its ${budget_seconds}s budget."
  fi

  if [ "${SECONDS}" -ge "${budget_seconds}" ]; then
    terminate_over_budget
  fi

  sleep "${poll_seconds}"
done

wait "${command_pid}" 2>/dev/null
wait_status=$?

# The status file is authoritative: the wrapper subshell's own exit status is
# that of the bookkeeping it does after the command returns.
if [ -f "${status_file}" ]; then
  status="$(cat "${status_file}")"
else
  status="${wait_status}"
fi
echo "${label} finished in ${SECONDS}s of its ${budget_seconds}s budget (exit ${status})."
exit "${status}"
