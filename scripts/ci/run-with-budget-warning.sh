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
# Enforcing that deadline against a privileged child (issue #123)
# ---------------------------------------------------------------
#
# Run 34366975927 ("Measure Disk Space", main, 1d9fb3e) is what this budget is
# for, and it is also where the first version of it did not hold. The step is
#
#   run-with-budget-warning.sh 2400 "disk space measurement" \
#     sudo env ... ./scripts/measure-disk-space.sh ... 2>&1 | tee measurement.log
#
# so the process tree is
#
#   wrapper (runner)  ->  sudo (real uid runner, effective root)
#                          ->  measure-disk-space.sh (root)
#                               ->  apt-get (root)
#
# At 15:37:47 the budget expired, this script printed "was terminated", and the
# step then ran for a further 19m21s until the job's `timeout-minutes: 60`
# killed it - which GitHub reports as *cancelled*, which the status gate read as
# a supersede, so the run was green. Three separate defects, one process tree:
#
#   * `sudo` keeps the invoking user's real uid, so the wrapper may signal it
#     and sudo relays SIGTERM to the command it started. That command's own
#     children have real uid 0. They are not sudo's to relay to and not the
#     wrapper's to signal, so `apt-get` survived.
#
#   * `kill -0` cannot report that. It fails with EPERM for "running, but not
#     yours to signal" and with ESRCH for "gone", and the exit status is 1 for
#     both. With only root survivors left, the liveness check read "gone", so
#     the SIGKILL escalation was skipped and this script exited 124 believing
#     it had terminated the command. Liveness is a question about the process
#     table, so it is asked of the process table (`group_members`) and not of
#     the signal permission check.
#
#   * `apt-get` inherited the step's stdout, which is the pipe into `tee`, so
#     `tee` never reached EOF and the shell never finished the pipeline. The
#     command's output is captured and relayed by this script now, so the only
#     processes holding the step's own stdout are this script and the shell
#     that started it. A survivor can no longer hold the step open, whether or
#     not it can be killed.
#
# experiments/issue-123/repro-budget-privileged-child.sh rebuilds that tree in
# a container and fails on the version of this script that shipped in 2.9.0.
#
# Usage:
#   bash scripts/ci/run-with-budget-warning.sh SECONDS LABEL COMMAND [ARG...]
#
# Environment:
#   BUDGET_WARN_PERCENT     emit a warning at this share of the budget (default 70)
#   BUDGET_GRACE_SECONDS    seconds between SIGTERM and SIGKILL (default 10)
#   BUDGET_KILL_SECONDS     seconds to wait for SIGKILL to take effect (default 5)
#   BUDGET_POLL_SECONDS     polling interval while the command runs (default 1)
#   BUDGET_SUDO_KILL        borrow root to kill survivors, when sudo needs no
#                           password (default 1; set to 0 to disable)
#   BUDGET_CAPTURE_OUTPUT   relay the command's output instead of handing it the
#                           step's own streams (default 1; set to 0 to disable)
#   BUDGET_VERBOSE          trace the liveness and signalling decisions (default 0)
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
kill_seconds="${BUDGET_KILL_SECONDS:-5}"
poll_seconds="${BUDGET_POLL_SECONDS:-1}"
capture_output="${BUDGET_CAPTURE_OUTPUT:-1}"
sudo_kill="${BUDGET_SUDO_KILL:-1}"
verbose="${BUDGET_VERBOSE:-0}"
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

trace() { [ "${verbose}" = "1" ] && echo "[budget] $*" >&2 || true; }

status_dir="$(mktemp -d "${TMPDIR:-/tmp}/budget-status.XXXXXX")"
status_file="${status_dir}/status"
stdout_file="${status_dir}/stdout"
stderr_file="${status_dir}/stderr"
trap 'rm -rf "${status_dir}"' EXIT

# Relaying the command's output, rather than lending it this step's own stdout,
# is what keeps a survivor from holding the step open (issue #123; see the
# header). It is on by default and can be turned off for a command that needs
# the real thing - a progress bar reading `isatty`, say, though nothing in CI
# has a tty to begin with.
#
# stdout and stderr are relayed separately so that a caller redirecting one of
# them still gets what it asked for. Interleaving between the two streams can
# shift by up to one poll interval; order within each stream is exact.
if [ "${capture_output}" = "1" ]; then
  : >"${stdout_file}"
  : >"${stderr_file}"
fi

stdout_offset=0
stderr_offset=0

stream_size() {
  local size
  size="$(wc -c <"$1" 2>/dev/null || echo 0)"
  size="${size//[![:digit:]]/}"
  echo "${size:-0}"
}

# Bytes [from, to) of a file that is still being written to. Bounded by `to`
# rather than read to the end, so that the offset this advances to is exactly
# what was emitted.
emit_range() {
  tail -c "+$(($2 + 1))" "$1" 2>/dev/null | head -c "$(($3 - $2))"
}

relay_output() {
  [ "${capture_output}" = "1" ] || return 0

  local size
  size="$(stream_size "${stdout_file}")"
  if [ "${size}" -gt "${stdout_offset}" ]; then
    emit_range "${stdout_file}" "${stdout_offset}" "${size}"
    stdout_offset="${size}"
  fi

  size="$(stream_size "${stderr_file}")"
  if [ "${size}" -gt "${stderr_offset}" ]; then
    emit_range "${stderr_file}" "${stderr_offset}" "${size}" >&2
    stderr_offset="${size}"
  fi
}

# `set -m` puts the command in its own process group, so the signals below
# reach the whole tree. A `docker build` here leaves a CLI, a BuildKit session
# and whatever the build itself spawned; killing only the direct child leaves
# orphans holding the runner -- which is also why timeout(1) is not sufficient.
#
# Completion is detected through the status file rather than process
# liveness: a finished child stays visible as a zombie until it is reaped,
# so a process-table scan alone would never report it as done.
set -m
if [ "${capture_output}" = "1" ]; then
  {
    "$@"
    command_status=$?
    printf '%s\n' "${command_status}" >"${status_file}.partial"
    mv "${status_file}.partial" "${status_file}"
  } >"${stdout_file}" 2>"${stderr_file}" &
else
  {
    "$@"
    command_status=$?
    printf '%s\n' "${command_status}" >"${status_file}.partial"
    mv "${status_file}.partial" "${status_file}"
  } &
fi
command_pid=$!
set +m

# Every live process still in the command's process group, one per line, as
# "pid user args". Zombies are excluded: they are exit statuses waiting to be
# collected, not work still being done.
#
# This is asked of `ps` rather than of `kill -0` because permission and
# existence are different questions and `kill -0` answers only the first
# (issue #123). Where there is no usable `ps` - Git Bash on Windows - the old
# answer is better than no answer.
have_ps=false
if ps -eo pgid=,pid=,stat= >/dev/null 2>&1; then
  have_ps=true
fi

group_members() {
  ps -eo pgid=,pid=,stat=,user=,args= 2>/dev/null \
    | awk -v group="${command_pid}" '$1 == group && $3 !~ /^Z/ {
        pid = $2
        user = $4
        $1 = ""; $2 = ""; $3 = ""; $4 = ""
        sub(/^ +/, "")
        printf "%s %s %s\n", pid, user, $0
      }'
}

group_is_populated() {
  if [ "${have_ps}" = true ]; then
    [ -n "$(group_members)" ]
  else
    kill -0 -- "-${command_pid}" 2>/dev/null
  fi
}

# Cached, because it forks and the poll loop asks often.
sudo_kill_available=''
can_sudo_kill() {
  [ "${sudo_kill}" = "1" ] || return 1
  if [ -z "${sudo_kill_available}" ]; then
    if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
      sudo_kill_available=yes
    else
      sudo_kill_available=no
    fi
  fi
  [ "${sudo_kill_available}" = yes ]
}

# Signal the process group when possible, falling back to the direct child
# on platforms without usable process groups (notably Git Bash on Windows).
#
# A `sudo` command's own children have real uid 0, so this script cannot
# signal them however long it waits. When survivors remain and sudo is
# available without a password - which is what a GitHub runner is - the
# signal is sent again with the privilege needed to land.
signal_command() {
  local signal="$1"
  kill "-${signal}" -- "-${command_pid}" 2>/dev/null \
    || kill "-${signal}" "${command_pid}" 2>/dev/null \
    || true

  if group_is_populated && can_sudo_kill; then
    trace "survivors after SIG${signal}; retrying as root"
    sudo -n kill "-${signal}" -- "-${command_pid}" 2>/dev/null \
      || sudo -n kill "-${signal}" "${command_pid}" 2>/dev/null \
      || true
  fi
}

command_is_running() {
  [ -f "${status_file}" ] && return 1
  group_is_populated
}

wait_while_running() {
  local deadline=$((SECONDS + $1))
  while command_is_running && [ "${SECONDS}" -lt "${deadline}" ]; do
    relay_output
    sleep "${poll_seconds}"
  done
}

report_survivors() {
  local survivors
  survivors="$(group_members)"
  [ -n "${survivors}" ] || return 0
  echo "::error title=${label} left processes running::${label} could not be terminated. Still running: $(echo "${survivors}" | tr '\n' ';')"
  echo "${survivors}" >&2
}

terminate_over_budget() {
  echo "::error title=${label} exceeded its execution budget::${label} did not finish within its ${budget_seconds}s budget and was terminated. Shorten the step or raise its budget (keeping it below the job's timeout-minutes backstop)."
  signal_command TERM

  # The step's own SECONDS clock, not an accumulation of the (possibly
  # fractional) poll interval: bash arithmetic is integer-only, so summing
  # poll_seconds would abort this function before the SIGKILL escalation.
  wait_while_running "${grace_seconds}"

  if command_is_running; then
    echo "${label} ignored SIGTERM after ${grace_seconds}s; sending SIGKILL."
    signal_command KILL
    wait_while_running "${kill_seconds}"
  fi

  # A SIGKILL that lands is not survivable, so anything still here is
  # something this script was not permitted to signal. Saying so is the
  # difference between "terminated" and "reported as terminated" - the whole
  # of what went wrong in run 34366975927.
  report_survivors

  wait "${command_pid}" 2>/dev/null || true
  relay_output
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

  relay_output
  sleep "${poll_seconds}"
done

wait "${command_pid}" 2>/dev/null
wait_status=$?
relay_output

# The status file is authoritative: the wrapper subshell's own exit status is
# that of the bookkeeping it does after the command returns.
if [ -f "${status_file}" ]; then
  status="$(cat "${status_file}")"
else
  status="${wait_status}"
fi
echo "${label} finished in ${SECONDS}s of its ${budget_seconds}s budget (exit ${status})."
exit "${status}"
