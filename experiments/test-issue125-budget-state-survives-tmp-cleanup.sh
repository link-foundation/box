#!/usr/bin/env bash
# test-issue125-budget-state-survives-tmp-cleanup.sh
#
# Run 34455018634 wrapped scripts/measure-disk-space.sh, which deliberately
# clears /tmp before measuring a clean installation.  The budget wrapper kept
# its status and captured streams in /tmp too, so the command erased its
# parent's control files.  This is the minimum reproduction: the wrapped
# command clears TMPDIR and then succeeds.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT

mkdir -p "${test_root}/command-tmp" "${test_root}/runner-tmp" \
  "${test_root}/state-parent"
wrapper="${BUDGET_WRAPPER:-scripts/ci/run-with-budget-warning.sh}"

if TMPDIR="${test_root}/command-tmp" \
  RUNNER_TEMP="${test_root}/runner-tmp" \
  BUDGET_POLL_SECONDS=0.05 \
  bash "${wrapper}" 5 "tmp-cleaning command" \
  bash -c 'rm -rf "${TMPDIR:?}"/*; printf "command completed\n"' \
  >"${test_root}/stdout" 2>"${test_root}/stderr"; then
  status=0
else
  status=$?
fi

fail=0

if [ "${status}" -eq 0 ]; then
  echo "PASS: clearing command temp files does not corrupt the wrapper status"
else
  echo "FAIL: successful command became wrapper exit ${status}" >&2
  fail=1
fi

if grep -qx 'command completed' "${test_root}/stdout"; then
  echo "PASS: output written before tmp cleanup is relayed"
else
  echo "FAIL: command output was lost" >&2
  fail=1
fi

if grep -q 'No such file or directory' "${test_root}/stderr"; then
  echo "FAIL: wrapper tried to read control files erased by its child" >&2
  fail=1
else
  echo "PASS: wrapper emits no missing-control-file noise"
fi

if find "${test_root}/runner-tmp" -mindepth 1 -print -quit | grep -q .; then
  echo "FAIL: wrapper left state behind in RUNNER_TEMP" >&2
  fail=1
else
  echo "PASS: wrapper removes its RUNNER_TEMP state on exit"
fi

if TMPDIR="${test_root}/command-tmp" \
  RUNNER_TEMP="${test_root}/runner-tmp" \
  BUDGET_STATE_PARENT="${test_root}/state-parent" \
  BUDGET_VERBOSE=1 \
  BUDGET_POLL_SECONDS=0.05 \
  bash "${wrapper}" 5 "state override" true \
  >"${test_root}/override-stdout" 2>"${test_root}/override-stderr" \
  && grep -Fq \
    "[budget] control state: ${test_root}/state-parent/budget-status." \
    "${test_root}/override-stderr"; then
  echo "PASS: BUDGET_STATE_PARENT overrides RUNNER_TEMP and is traceable"
else
  echo "FAIL: BUDGET_STATE_PARENT was not used for control state" >&2
  fail=1
fi

exit "${fail}"
