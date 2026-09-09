#!/bin/bash
# capture-and-stream.sh - Run a command, stream its output as it is produced,
# and keep a copy for the caller to classify.
#
# Usage (sourced):
#   source scripts/ci/capture-and-stream.sh
#   if capture_and_stream git push origin main; then ... fi
#   is_non_fast_forward_rejection "$CAPTURED_OUTPUT"
#
# The function returns the command's own exit status, not the pipeline's, and
# leaves the merged stdout+stderr in CAPTURED_OUTPUT with trailing newlines
# stripped - the same value `output="$(cmd 2>&1 | ...)"` used to produce.
#
# Why this exists (issue #123)
# ----------------------------
# Four scripts in this repository needed the same two things from one command:
# the output has to be inspectable, because a retry loop that cannot classify a
# failure retries an expired credential three times; and it has to be visible
# while it is produced, because a silent twenty-minute push is not debuggable.
# All four wrote it the same way:
#
#   output="$(docker push "$tag" 2>&1 | tee /dev/stderr)"
#
# `/dev/stderr` is not the caller's file descriptor 2. On Linux it is a symlink
# to /proc/self/fd/2, so opening it *reopens the file behind* fd 2 - and `tee`
# opens its operands with O_TRUNC. When fd 2 is a pipe or a terminal, which is
# what it is inside a GitHub Actions step, nothing happens. When fd 2 is a
# regular file, the file is truncated to zero and everything the script had
# already written is gone:
#
#   $ cat s.sh
#   echo "line one that must survive"
#   out="$(printf 'pushed\n' 2>&1 | tee /dev/stderr)"
#   $ bash s.sh >log 2>&1; cat log
#   pushed
#
# fd 2 is a regular file in two places this repository actually uses:
#
#   * scripts/ci/run-with-budget-warning.sh runs the wrapped command with
#     `2>"${stderr_file}"` so it can relay the stream and still detect the
#     child's completion. A wrapped command that truncated that file would not
#     only lose its own earlier output; the relay tracks a byte offset, so
#     everything written after the truncation is skipped too, until the file
#     grows back past the stale offset. That is a silent log loss in CI.
#   * Any local reproduction that follows this repository's own guidance to
#     redirect a long command's output to a file - which is how this was found:
#     experiments/test-issue123-log-command-injection.sh captured
#     apply-changesets.sh into a log, and the commit lines it was asserting on
#     had been replaced by NUL bytes by the time the push returned.
#
# `tee -a /dev/stderr` is not the fix: O_APPEND stops the truncation but the
# reopened description still has its own file offset, so the appended bytes sit
# past where the caller's fd 2 is pointing and the caller's next write
# overwrites them. The fix is to never reopen: `tee "$tmp" >&2` writes through a
# *duplicate* of the caller's fd 2, which shares its file description and its
# offset, and the copy for the caller comes from the temporary file.
#
# See: https://github.com/link-foundation/box/issues/123

# Set by capture_and_stream; the merged output of the last command it ran.
CAPTURED_OUTPUT=""

capture_and_stream() {
  local __tmp __status=0

  if [ $# -eq 0 ]; then
    echo "capture_and_stream: a command is required" >&2
    return 2
  fi

  __tmp="$(mktemp "${TMPDIR:-/tmp}/capture-and-stream.XXXXXX")" || {
    echo "capture_and_stream: could not create a temporary file" >&2
    return 125
  }

  # The group is the left operand of `||`, so `set -e` is suspended inside it
  # and the status assignment runs even when the command fails. PIPESTATUS is
  # read immediately, while it still describes this pipeline.
  {
    "$@" 2>&1 | tee "$__tmp" >&2
    __status="${PIPESTATUS[0]}"
  } || true

  CAPTURED_OUTPUT="$(cat "$__tmp")"
  rm -f "$__tmp"
  return "$__status"
}

# Running this file directly is a convenience for reproducing the behaviour by
# hand; the output is streamed and then echoed back as the captured copy.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  capture_and_stream "$@"
  status=$?
  printf '%s\n' "--- captured ---"
  printf '%s\n' "$CAPTURED_OUTPUT"
  exit "$status"
fi
