#!/usr/bin/env bash
# run-with-commands-stopped.sh
#
# Run a command whose output the repository does not control, with the runner's
# workflow-command processing switched off for exactly that output.
#
# Why this exists (issue #123)
# ----------------------------
#
# Release run 34366976358 finished with the job "Apply Changesets" concluding
# `success` and carrying a `failure` annotation. Nothing failed. The step ran
#
#   git commit -m "$NEW_VERSION: $DESCRIPTIONS"
#
# and git echoes the new commit's subject line:
#
#   [main 1e202f5] 2.9.0: Make every CI annotation mean what it says ... quotes
#   `##[error]` while explaining a fix. `docker/setup-buildx-action` creates ...
#
# `$DESCRIPTIONS` is the body of the changesets a pull request added, so it is
# whatever a contributor wrote - and that release note was *about* issue #121's
# log injection, so it quoted the string. One physical line, and the runner
# reads it: ActionCommand.TryParse takes `message.IndexOf("##[")`, so the
# legacy form is a command anywhere in a line, not only at its start
# (src/Runner.Common/ActionCommand.cs; TryParseV2 requires `::` at the start,
# TryParse does not, and ActionCommandManager.cs:70-71 tries both). The whole
# annotation - level, title, body - came out of a commit message.
#
# Annotations are the mild case. `stop-commands` is in the same registered set
# (ActionCommandManager.cs:34), so a commit subject can also switch command
# processing off for the rest of a step, and `add-mask` can replace an
# arbitrary substring of every later line with `***`. Issue #121 fixed the path
# that carried commit messages through buildx provenance; this is the shorter
# path, where git prints the subject itself.
#
# Why stop-commands rather than rewriting the text
# ------------------------------------------------
#
# Editing `##[` out of the text would make the log disagree with the commit,
# and it would have to be done to every stream of every command that might echo
# a subject line. `::stop-commands::<token>` is the runner's own answer: while
# it is in force every line is logged verbatim and none of them is a command.
#
# Three properties of the runner's implementation shape what is below.
#
#   * The token must be unpredictable. While processing is stopped the resume
#     token is itself added to the registered set, and it is matched by the
#     same lenient `##[<token>]` rule, so text that can guess the token can
#     resume command processing and inject after all. 128 bits from
#     /dev/urandom, fresh per call.
#
#   * The token must not be a registered command name, must be non-empty, and
#     must not be `pause-logging` - ActionCommandManager.ValidateStopToken
#     throws otherwise, which fails the step. Hex digits satisfy all three.
#
#   * The state is per step and shared between the two streams. A step's
#     handler creates its own manager (Handler.cs:172,
#     `CreateService<IActionCommandManager>()`), and ScriptHandler.cs:331-336
#     gives the stdout and stderr OutputManagers that one manager. So a token
#     left unresumed cannot leak into a later step - and markers written to one
#     stream do govern the other. The ordering *between* the two streams is not
#     guaranteed, though, so a caller whose untrusted text goes to stderr
#     should send the markers there too (see `git-push-with-retry.sh`).
#
# Usage
# -----
#
#   As a command:
#     bash scripts/ci/run-with-commands-stopped.sh git commit -m "$MESSAGE"
#
#   Sourced, for callers that cannot express the untrusted part as one command
#   (a pipeline whose output is also captured, for instance):
#     source scripts/ci/run-with-commands-stopped.sh
#     run_with_commands_stopped git pull --rebase origin main
#     # or, when the brackets cannot be a single command:
#     stop_log_commands >&2
#     ...
#     resume_log_commands >&2
#
#   The bracket form is the one to avoid where a single command will do: an
#   `exit` or a `set -e` abort between the two calls leaves the rest of that
#   step unable to annotate. `run_with_commands_stopped` always resumes,
#   including when the command fails or is killed by a signal.
#
# Environment:
#   BOX_LOG_COMMANDS_VERBOSE=1  trace the token to stderr (default: off)

# Not `set -e`: this file is sourced into scripts with their own error
# handling, and a sourced `set -e` would change theirs.

BOX_LOG_STOP_TOKEN="${BOX_LOG_STOP_TOKEN:-}"

_log_commands_trace() {
  [ "${BOX_LOG_COMMANDS_VERBOSE:-0}" = "1" ] && echo "[log-commands] $*" >&2
  return 0
}

# 32 hex digits. `od` is POSIX and present on every image this repository uses;
# $RANDOM is the fallback for a host without a readable /dev/urandom, and is
# marked as such in the token so a log makes the difference visible.
new_stop_token() {
  local token=''
  if [ -r /dev/urandom ]; then
    token="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  fi
  case "${token}" in
    [0-9a-f][0-9a-f]*) ;;
    *) token='' ;;
  esac
  if [ "${#token}" -lt 32 ]; then
    token="fallback$(printf '%04x%04x%04x%04x' "${RANDOM}" "${RANDOM}" "${RANDOM}" "$$")$(date +%s 2>/dev/null || echo 0)"
  fi
  printf '%s' "${token}"
}

# Suspend workflow-command processing. Writes the marker to stdout; redirect
# the call when the text it has to cover is written to stderr.
stop_log_commands() {
  BOX_LOG_STOP_TOKEN="$(new_stop_token)"
  _log_commands_trace "stopping command processing with token ${BOX_LOG_STOP_TOKEN}"
  printf '::stop-commands::%s\n' "${BOX_LOG_STOP_TOKEN}"
}

# Resume it. A no-op when nothing was stopped, so it is safe in a trap.
resume_log_commands() {
  [ -n "${BOX_LOG_STOP_TOKEN:-}" ] || return 0
  printf '::%s::\n' "${BOX_LOG_STOP_TOKEN}"
  _log_commands_trace "resumed command processing"
  BOX_LOG_STOP_TOKEN=''
}

# Run one command with processing stopped, and resume whatever it does -
# including exiting non-zero or dying on a signal, which is why the status is
# captured rather than left to `set -e`.
run_with_commands_stopped() {
  local status=0
  stop_log_commands
  "$@" || status=$?
  resume_log_commands
  return "${status}"
}

# Executed rather than sourced: run the arguments.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  if [ $# -eq 0 ]; then
    echo "run-with-commands-stopped.sh: a command is required" >&2
    echo "usage: run-with-commands-stopped.sh <command> [args...]" >&2
    exit 2
  fi
  # The command form is the safe one precisely because this trap exists: an
  # interrupted wrapper still writes the resume marker.
  trap 'resume_log_commands' EXIT
  run_with_commands_stopped "$@"
  exit $?
fi
