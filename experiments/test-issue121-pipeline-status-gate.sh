#!/usr/bin/env bash
# test-issue121-pipeline-status-gate.sh
#
# Issue #121: "Check for all false positives, false negatives, warnings and
# errors in CI/CD and fix them all."
#
# The false negative this covers is a run that is not red when something in it
# broke. GitHub derives a run's conclusion from its jobs and a cancellation
# outranks a failure, so run 34259552358 of this repository finished
#
#   run conclusion                     cancelled
#   pr-tests / pr-test / dind-full     failure
#   pr-tests / pr-test / full          cancelled
#
# - grey, not red, with a genuine job failure inside it. Everything that reads
# the run rather than each of its jobs (the badge, `gh run list`, the run list
# quoted in issue #121 itself) reads that as "no verdict".
#
# The fix is the reference template's terminal status gate, ported here:
# scripts/ci/check-pipeline-status.sh runs in a job that `needs:` every other
# job in its workflow, and errors on any `failure`, so the run's conclusion is
# a failure regardless of what else was cancelled.
#
# The second half is not erroring on the cancellations that are correct. A job
# killed by `timeout-minutes` is reported as cancelled, and so is every job of
# a run this repository deliberately supersedes (scripts/ci/supersede.sh), and
# those must not read the same way - a gate that cries wolf on every supersede
# gets ignored, which is how a check stops being a check.
#
# What it asserts:
#   Part 1  check-pipeline-status.sh's verdicts, driven by fixture NEEDS_JSON
#   Part 2  every workflow that starts a run of its own has a gate covering
#           every job in it, and the coverage checker catches a hole
#   Part 3  the gate jobs are wired the way the script needs them to be
#
# Usage: bash experiments/test-issue121-pipeline-status-gate.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

PASS=0
FAIL=0

pass() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
  [ $# -gt 1 ] && printf '      %s\n' "${@:2}" >&2
  return 0
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

GATE="scripts/ci/check-pipeline-status.sh"
COVERAGE="scripts/ci/check-status-gate-covers-all-jobs.mjs"

echo "=== Part 1: what the gate calls a failure ==="
echo

# run_status <expected exit> <label> <needs json> [env assignments...]
#
# The captured output goes to $TMP/status.out rather than to stdout: a helper
# whose result is read with $(...) runs in a subshell, so every pass/fail it
# counted there would be discarded - which is how a suite reports "Failed: 0"
# for assertions it never made.
run_status() {
  local expected="$1" label="$2" needs="$3"
  shift 3
  local rc
  env NEEDS_JSON="$needs" "$@" bash "$GATE" >"$TMP/status.out" 2>&1
  rc=$?
  if [ "$rc" -eq "$expected" ]; then
    pass "$label (exit $rc)"
  else
    fail "$label" "expected exit $expected, got $rc" "$(cat "$TMP/status.out")"
  fi
}

# says <pattern> <label> - assert on the output of the last run_status call.
says() {
  if grep -qF -- "$1" "$TMP/status.out"; then
    pass "$2"
  else
    fail "$2" "$(cat "$TMP/status.out")"
  fi
}

# Since issue #123 the gate excuses a cancellation only when the job could
# actually have been superseded - `concurrency.cancel-in-progress: true` -
# so the cases below that expect an excuse have to say which workflow the jobs
# come from. This fixture declares every job name they use, all of them
# cancelling in progress; the overrun that cannot be excused this way has its
# own suite in experiments/test-issue123-overrun-not-supersede.sh.
CANCELS_IN_PROGRESS="$TMP/cancels-in-progress.yml"
cat >"$CANCELS_IN_PROGRESS" <<'YAML'
name: Cancels in progress
on:
  push:

concurrency:
  group: fixture-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - run: 'true'
  manifest:
    runs-on: ubuntu-24.04
    steps:
      - run: 'true'
  pr-test-dind-full:
    runs-on: ubuntu-24.04
    steps:
      - run: 'true'
  pr-test-full:
    runs-on: ubuntu-24.04
    steps:
      - run: 'true'
  pr-test-js:
    runs-on: ubuntu-24.04
    steps:
      - run: 'true'
  pipeline-status:
    runs-on: ubuntu-24.04
    needs: [build, manifest, pr-test-dind-full, pr-test-full, pr-test-js]
    if: ${{ !cancelled() }}
    steps:
      - run: 'true'
YAML

ALL_GREEN='{"build":{"result":"success"},"manifest":{"result":"success"}}'
WITH_SKIP='{"build":{"result":"success"},"manifest":{"result":"skipped"}}'
WITH_FAILURE='{"build":{"result":"failure"},"manifest":{"result":"skipped"}}'
WITH_CANCEL='{"build":{"result":"cancelled"},"manifest":{"result":"skipped"}}'
# The measured shape of run 34259552358: one failure, one cancellation, and a
# run that GitHub concluded as `cancelled`.
RUN_34259552358='{"pr-test-dind-full":{"result":"failure"},"pr-test-full":{"result":"cancelled"},"pr-test-js":{"result":"success"}}'

run_status 0 "all jobs green is not a failure" "$ALL_GREEN"
says "All required jobs succeeded" "it says so rather than saying nothing"

run_status 0 "a skipped job is not a failure" "$WITH_SKIP"

run_status 1 "one failed job fails the gate" "$WITH_FAILURE"
says "::error title=Pipeline failed" "it annotates the failure"
says "Failing jobs: build" "it names the job that failed"

# A cancellation is an error only when this run is still the head of its
# branch. BRANCH_HEAD_SHA short-circuits the `git ls-remote`, so these cases are
# offline and deterministic.
run_status 1 "a cancellation in a current run fails the gate" \
  "$WITH_CANCEL" RUN_SHA=aaaa BRANCH_HEAD_SHA=aaaa BRANCH_NAME=main
says "::error title=Pipeline has cancelled jobs" "it says the cancellation is not a supersede"

run_status 0 "a cancellation in a superseded run only warns" \
  "$WITH_CANCEL" RUN_SHA=aaaa BRANCH_HEAD_SHA=bbbb BRANCH_NAME=main \
  WORKFLOW_FILE="$CANCELS_IN_PROGRESS"
says "::warning title=Cancelled jobs in a superseded run" "it says the run was superseded"

# An unresolvable head must not silently downgrade an overrun to a warning:
# a missed supersede costs one noisy error, a missed overrun costs a silent
# failure. GIT_REMOTE points at a path that is not a repository, so the
# ls-remote fails the way it would in a checkout without a usable remote.
run_status 1 "an unresolvable branch head is treated as current" \
  "$WITH_CANCEL" RUN_SHA=aaaa BRANCH_NAME=main GIT_REMOTE="$TMP/not-a-repo"
says "Could not resolve the head of main" "it says why it assumed the run is current"

# An unset RUN_SHA is the same decision by a different route.
run_status 1 "an unset RUN_SHA is treated as current" \
  "$WITH_CANCEL" BRANCH_NAME=main
says "RUN_SHA is unset" "it says which input was missing"

# The measured run. Its failure must reach the gate whatever the cancellation
# does, which is the whole point: run 34259552358 was concluded `cancelled`.
run_status 1 "the shape of run 34259552358 fails the gate" \
  "$RUN_34259552358" RUN_SHA=aaaa BRANCH_HEAD_SHA=bbbb BRANCH_NAME=issue-119 \
  WORKFLOW_FILE="$CANCELS_IN_PROGRESS"
says "Failing jobs: pr-test-dind-full" "it names the job that actually failed"
says "::warning title=Cancelled jobs in a superseded run" "the supersede stays a warning next to it"

# A result spelling the script does not know must fail, not pass. GitHub
# documents four values for `needs.<id>.result` and reports others on the jobs
# API (`timed_out`, `action_required`); treating an unknown one as "fine" is how
# a gate ends up certifying a job it could not read.
run_status 1 "an unrecognised result is treated as a failure" \
  '{"build": {"result": "timed_out"}}'
says "Failing jobs: build" "it names the job whose result it could not vouch for"

run_status 1 "a null result is treated as a failure" \
  '{"build": {"result": null}}'
says "Failing jobs: build" "it names the job with no result at all"

# Refusing to run without NEEDS_JSON matters more than it looks: a gate that
# defaulted to an empty object would pass every run.
if NEEDS_JSON='' bash "$GATE" >/dev/null 2>&1; then
  fail "an empty NEEDS_JSON is refused rather than read as 'nothing failed'"
else
  pass "an empty NEEDS_JSON is refused rather than read as 'nothing failed'"
fi

echo
echo "=== Part 2: every workflow's gate covers every job in it ==="
echo

if node "$COVERAGE" .github/workflows/*.yml >"$TMP/coverage.log" 2>&1; then
  pass "the shipped workflows all pass the coverage check"
else
  fail "the shipped workflows all pass the coverage check" "$(cat "$TMP/coverage.log")"
fi

# Mutation: a job the gate does not name must be reported, because that is
# exactly the drift the check exists to catch.
MUT="$TMP/mutation.yml"
cat >"$MUT" <<'YAML'
name: Mutation
on:
  push:
jobs:
  first:
    runs-on: ubuntu-24.04
    steps:
      - run: 'true'
  second:
    runs-on: ubuntu-24.04
    steps:
      - run: 'true'
  pipeline-status:
    runs-on: ubuntu-24.04
    needs: [first]
    if: ${{ !cancelled() }}
    steps:
      - run: 'true'
YAML
if node "$COVERAGE" "$MUT" >"$TMP/mutation.log" 2>&1; then
  fail "a job missing from the gate's needs is reported" "$(cat "$TMP/mutation.log")"
else
  if grep -q "job 'second' is not in pipeline-status.needs" "$TMP/mutation.log"; then
    pass "a job missing from the gate's needs is reported by name"
  else
    fail "a job missing from the gate's needs is reported by name" "$(cat "$TMP/mutation.log")"
  fi
fi

# Mutation: an entry-point workflow with no gate at all.
NOGATE="$TMP/no-gate.yml"
cat >"$NOGATE" <<'YAML'
name: No gate
on:
  push:
jobs:
  only:
    runs-on: ubuntu-24.04
    steps:
      - run: 'true'
YAML
node "$COVERAGE" "$NOGATE" >"$TMP/no-gate.log" 2>&1
if [ $? -eq 2 ] && grep -q "no terminal status gate" "$TMP/no-gate.log"; then
  pass "an entry-point workflow with no gate exits 2"
else
  fail "an entry-point workflow with no gate exits 2" "$(cat "$TMP/no-gate.log")"
fi

# ...and the exemption that keeps that from being a lie: a workflow_call file
# reports through the job that calls it, in a workflow that does have a gate.
CALLED="$TMP/called.yml"
cat >"$CALLED" <<'YAML'
name: Called only
on:
  workflow_call:
jobs:
  only:
    runs-on: ubuntu-24.04
    steps:
      - run: 'true'
YAML
if node "$COVERAGE" "$CALLED" >"$TMP/called.log" 2>&1; then
  pass "a workflow_call-only file is not required to carry its own gate"
else
  fail "a workflow_call-only file is not required to carry its own gate" "$(cat "$TMP/called.log")"
fi

echo
echo "=== Part 3: the gate jobs are wired the way the script needs ==="
echo

# Discovery, not a list: any workflow with its own trigger must be here, so a
# workflow added later cannot quietly skip the gate.
ENTRY_POINTS=()
for wf in .github/workflows/*.yml; do
  if grep -qE '^  (push|pull_request|schedule|workflow_dispatch):' "$wf"; then
    ENTRY_POINTS+=("$wf")
  fi
done

if [ "${#ENTRY_POINTS[@]}" -ge 8 ]; then
  pass "found ${#ENTRY_POINTS[@]} workflows that start runs of their own"
else
  fail "found ${#ENTRY_POINTS[@]} workflows that start runs of their own" \
    "expected at least 8; the discovery above is probably broken"
fi

for wf in "${ENTRY_POINTS[@]}"; do
  block="$(awk '/^  pipeline-status:/{f=1} f{print} f && /^  [a-zA-Z0-9_-]+:$/ && !/^  pipeline-status:/{exit}' "$wf")"

  if [ -z "$block" ]; then
    fail "$(basename "$wf"): has a pipeline-status job"
    continue
  fi

  # `!cancelled()` and never `always()`: cancelling a whole run is a decision
  # somebody made, and a gate that repainted it red would be a false positive.
  # `cancelled()` is run-level, so a job cancelled on its own still gets here.
  # experiments/test-issue115-ci-policy.sh holds the same line repo-wide; this
  # asserts it for the gate specifically, where the temptation is strongest.
  case "$block" in
    *'if: ${{ !cancelled() }}'*) pass "$(basename "$wf"): the gate runs with if: !cancelled()" ;;
    *) fail "$(basename "$wf"): the gate runs with if: !cancelled()" "$block" ;;
  esac

  case "$block" in
    *"NEEDS_JSON: \${{ toJSON(needs) }}"*) pass "$(basename "$wf"): the gate is handed toJSON(needs)" ;;
    *) fail "$(basename "$wf"): the gate is handed toJSON(needs)" "$block" ;;
  esac

  case "$block" in
    *"bash scripts/ci/check-pipeline-status.sh"*) pass "$(basename "$wf"): the gate runs the shared script" ;;
    *) fail "$(basename "$wf"): the gate runs the shared script" "$block" ;;
  esac

  # Without a checkout there is no script to run and no remote to resolve the
  # branch head from.
  case "$block" in
    *"actions/checkout@"*) pass "$(basename "$wf"): the gate checks the repository out" ;;
    *) fail "$(basename "$wf"): the gate checks the repository out" "$block" ;;
  esac

  # On a pull request `github.sha` is the merge preview, which is never the head
  # of any branch: comparing it would report every run as superseded and
  # downgrade every cancellation to a warning.
  case "$block" in
    *"github.event.pull_request.head.sha || github.sha"*)
      pass "$(basename "$wf"): the gate compares the branch head, not the merge preview"
      ;;
    *) fail "$(basename "$wf"): the gate compares the branch head, not the merge preview" "$block" ;;
  esac
done

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
