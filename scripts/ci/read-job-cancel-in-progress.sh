#!/usr/bin/env bash
#
# Read the effective `concurrency.cancel-in-progress` of named jobs out of a
# workflow file, and say so in one word per job.
#
# Usage:
#   WORKFLOW_FILE=.github/workflows/measure-disk-space.yml \
#     bash scripts/ci/read-job-cancel-in-progress.sh measure-disk-space
#
#   WORKFLOW_FILE=... JOB_NAMES=$'a\nb' bash scripts/ci/read-job-cancel-in-progress.sh
#
# Output is one `<job><TAB><value>` line per requested job, in the order asked,
# where <value> is one of:
#
#   true      the job cancels in progress, so a supersede can cancel it
#   false     it does not - either it says so, or it has a group with no
#             cancel-in-progress key, which defaults to false
#   none      no concurrency at job level and none at workflow level: GitHub
#             has no group to supersede this job with at all
#   missing   the workflow does not declare a job by that name
#   unknown   the value is there but is an expression this cannot evaluate
#
# Why this exists (issue #123). scripts/ci/check-pipeline-status.sh has to tell
# a job cancelled by a supersede from a job killed by `timeout-minutes`, and
# GitHub reports both as `cancelled`. The run being superseded is not enough to
# tell them apart: run 34366975927 lost `measure-disk-space` to a 1h0m0s
# overrun in a run main had already moved past, and that job declares
# `cancel-in-progress: false` - it queues rather than cancelling, so no
# supersede could have touched it. Asking per job is what separates them.
#
# The parsing is by indentation and regex rather than through a YAML library,
# the same way scripts/ci/check-status-gate-covers-all-jobs.mjs reads these
# files: this runs on a bare runner in a gate job, and a gate that needs an
# install to answer is a gate that can fail for reasons of its own.

set -euo pipefail

: "${WORKFLOW_FILE:?WORKFLOW_FILE is required}"

WORKFLOW_FILE="$WORKFLOW_FILE" JOB_NAMES="${JOB_NAMES:-}" python3 -c '
import os
import re
import sys

path = os.environ["WORKFLOW_FILE"]
names = [n for n in (sys.argv[1:] or os.environ["JOB_NAMES"].split("\n")) if n]

try:
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().splitlines()
except OSError as exc:
    print("read-job-cancel-in-progress: %s" % exc, file=sys.stderr)
    sys.exit(1)


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def is_blank(line):
    stripped = line.strip()
    return not stripped or stripped.startswith("#")


def normalise(raw):
    # An expression is not a value. `cancel-in-progress: ${{ ... }}` is decided
    # by the run, not by the file, and guessing it `true` would restore exactly
    # the excuse this exists to withdraw.
    if "${{" in raw:
        return "unknown"
    raw = re.sub(r"\s+#.*$", "", raw).strip().strip("\x27\"").lower()
    if raw == "true":
        return "true"
    if raw == "false":
        return "false"
    return "unknown"


def read_concurrency(start, indent):
    """The cancel-in-progress of the `concurrency:` block starting at `start`."""
    rest = lines[start].split(":", 1)[1].strip()
    if rest and not rest.startswith("#"):
        # `concurrency: some-group` - the scalar form names a group and takes
        # the default, which is not to cancel.
        return "false"

    value = None
    for line in lines[start + 1:]:
        if is_blank(line):
            continue
        if indent_of(line) <= indent:
            break
        found = re.match(r"\s*cancel-in-progress:\s*(.*)$", line)
        if found:
            value = found.group(1)
    if value is None:
        return "false"
    return normalise(value)


workflow_level = None
for index, line in enumerate(lines):
    if re.match(r"^concurrency:", line):
        workflow_level = read_concurrency(index, 0)
        break

jobs = {}
in_jobs = False
current = None
for index, line in enumerate(lines):
    if re.match(r"^jobs:\s*$", line):
        in_jobs = True
        continue
    if in_jobs and re.match(r"^[A-Za-z_]", line):
        break
    if not in_jobs or is_blank(line):
        continue
    declared = re.match(r"^  ([A-Za-z_][A-Za-z0-9_.-]*):", line)
    if declared:
        current = declared.group(1)
        jobs[current] = None
        continue
    if current is not None and re.match(r"^    concurrency:", line):
        jobs[current] = read_concurrency(index, 4)

for name in names:
    if name not in jobs:
        answer = "missing"
    elif jobs[name] is not None:
        answer = jobs[name]
    elif workflow_level is not None:
        answer = workflow_level
    else:
        answer = "none"
    print("%s\t%s" % (name, answer))
' "$@"
