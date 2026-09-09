#!/usr/bin/env bash
# Reproduce the overrun that made run 34366975927 ("Measure Disk Space", main,
# 1d9fb3e) spend 19.5 minutes past its own budget and then be killed by the
# job's timeout-minutes backstop - which GitHub reports as *cancelled*, which
# scripts/ci/check-pipeline-status.sh then excused as a supersede.
#
# The step is
#
#   bash scripts/ci/run-with-budget-warning.sh 2400 "disk space measurement" \
#     sudo env ... ./scripts/measure-disk-space.sh ... 2>&1 | tee measurement.log
#
# so the wrapper runs as `runner` and its child runs as root. A runner-owned
# `kill` on a root-owned process fails with EPERM, and `kill -0`'s exit status
# cannot tell EPERM ("there, but not yours to signal") from ESRCH ("gone").
#
# This needs an unprivileged user with passwordless sudo, which is what a
# GitHub runner is and what this development box is not, so the whole thing
# runs in a container.
#
# Usage:
#   bash experiments/issue-123/repro-budget-privileged-child.sh
#       asserts that the wrapper in the working tree enforces its budget, both
#       where it can borrow root and where it cannot.
#   bash experiments/issue-123/repro-budget-privileged-child.sh --old
#       runs the same thing against the wrapper as of 2.9.0 (git HEAD~ of this
#       change) and asserts that the defect is there.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
image="${REPRO_IMAGE:-ubuntu:24.04}"

if ! docker info >/dev/null 2>&1; then
  echo "docker is required for this reproduction" >&2
  exit 2
fi

expect=fixed
mount=("-v" "${repo}:/repo:ro")
if [ "${1:-}" = "--old" ]; then
  expect=defect
  old_dir="$(mktemp -d)"
  trap 'rm -rf "${old_dir}"' EXIT
  git -C "${repo}" show "${OLD_REF:-HEAD}:scripts/ci/run-with-budget-warning.sh" \
    >"${old_dir}/run-with-budget-warning.sh" \
    || {
      echo "cannot read the previous wrapper from ${OLD_REF:-HEAD}" >&2
      exit 2
    }
  mount+=("-v" "${old_dir}/run-with-budget-warning.sh:/repo/scripts/ci/run-with-budget-warning.sh:ro")
fi

docker run --rm \
  "${mount[@]}" \
  -e "EXPECT=${expect}" \
  -e "BUDGET=${BUDGET:-3}" \
  -e "CHILD_LIFETIME=${CHILD_LIFETIME:-120}" \
  -e "STEP_TIMEOUT=${STEP_TIMEOUT:-30}" \
  "${image}" \
  bash /repo/experiments/issue-123/repro-budget-privileged-child-inner.sh
