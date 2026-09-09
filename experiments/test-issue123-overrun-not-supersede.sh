#!/usr/bin/env bash
# test-issue123-overrun-not-supersede.sh
#
# Issue #123: "Check for all false positives, false negatives, warnings and
# errors in CI/CD and fix them all."
#
# The false negative this covers is measured, not hypothesised. Run
# 34366975927 of this repository ("Measure Disk Space and Update README", main,
# 1d9fb3e) carried these five annotations
# (dev/log/issues/123/pulls/124/annotations/34366975927.annotations.json):
#
#   failure  The job has exceeded the maximum execution time of 1h0m0s
#   failure  The operation was canceled.
#   failure  disk space measurement did not finish within its 2400s budget ...
#   warning  disk space measurement has run for 1680s of its 2400s budget.
#   warning  measure-disk-space. This run is no longer the head of main, so the
#            cancellation reads as a supersede rather than an overrun.
#
# The last one is scripts/ci/check-pipeline-status.sh, and it is wrong. The job
# it excused declares
#
#   timeout-minutes: 60
#   concurrency:
#     group: measure-disk-space-${{ github.ref }}
#     cancel-in-progress: false
#
# - a job that, in the workflow's own words, "queues instead of cancelling".
# No supersede can cancel it, so its cancellation could only have been the
# 1h0m0s overrun the run's own first annotation names. The gate answered the
# wrong question: it asked whether the *run* had been overtaken, and excused
# every cancellation in it. The gate job concluded `success`.
#
# The rule this suite pins: a cancelled job may be excused as a supersede only
# when the run is no longer the head of its branch AND that job could actually
# have been cancelled by one - its effective `concurrency.cancel-in-progress`
# (job-level, else workflow-level) is `true`. Anything the gate cannot read
# fails closed, which is the bias the script was already written with: a missed
# supersede costs one noisy error, a missed overrun costs a silent failure.
#
# What it asserts:
#   Part 1  the measured run: an overrun on a `cancel-in-progress: false` job
#           is an error, not a warning
#   Part 2  the supersede the rule must keep: `cancel-in-progress: true`
#   Part 3  everything unreadable fails closed
#   Part 4  the effective value is job-level first, workflow-level second
#   Part 5  GITHUB_WORKFLOW_REF locates the workflow without being told
#   Part 6  the shipped workflows, read as the gate reads them
#
# Usage: bash experiments/test-issue123-overrun-not-supersede.sh

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

# run_gate <expected exit> <label> <needs json> [env assignments...]
#
# The output lands in a file rather than on stdout: a helper read with $(...)
# runs in a subshell, and every pass/fail counted there would be discarded.
run_gate() {
  local expected="$1" label="$2" needs="$3"
  shift 3
  local rc
  env NEEDS_JSON="$needs" "$@" bash "$GATE" >"$TMP/gate.out" 2>&1
  rc=$?
  if [ "$rc" -eq "$expected" ]; then
    pass "$label (exit $rc)"
  else
    fail "$label" "expected exit $expected, got $rc" "$(cat "$TMP/gate.out")"
  fi
}

says() {
  if grep -qF -- "$1" "$TMP/gate.out"; then
    pass "$2"
  else
    fail "$2" "$(cat "$TMP/gate.out")"
  fi
}

says_not() {
  if grep -qF -- "$1" "$TMP/gate.out"; then
    fail "$2" "$(cat "$TMP/gate.out")"
  else
    pass "$2"
  fi
}

echo "=== Part 1: the measured run - an overrun is not a supersede ==="
echo

# The two jobs of .github/workflows/measure-disk-space.yml, with the
# concurrency each of them really declares.
QUEUES="$TMP/measure-disk-space.yml"
cat >"$QUEUES" <<'YAML'
name: Measure Disk Space and Update README
on:
  push:
    branches: [main]
jobs:
  validate:
    runs-on: ubuntu-24.04
    concurrency:
      group: measure-disk-space-validate-${{ github.ref }}
      cancel-in-progress: true
    steps:
      - run: 'true'

  measure-disk-space:
    name: Measure Component Disk Space
    runs-on: ubuntu-24.04
    timeout-minutes: 60
    # This job commits to main. Cancelling it mid-`git push` is worse than
    # letting a superseded run finish, so it queues instead of cancelling.
    concurrency:
      group: measure-disk-space-${{ github.ref }}
      cancel-in-progress: false
    steps:
      - run: 'true'

  pipeline-status:
    runs-on: ubuntu-24.04
    needs: [validate, measure-disk-space]
    if: ${{ !cancelled() }}
    steps:
      - run: 'true'
YAML

# The shape run 34366975927 handed the gate: `validate` succeeded, the
# measurement was cancelled by its own timeout-minutes, and main had moved on
# by the time the gate asked.
RUN_34366975927='{"validate":{"result":"success"},"measure-disk-space":{"result":"cancelled"}}'

run_gate 1 "an overrun on a job that queues instead of cancelling fails the gate" \
  "$RUN_34366975927" \
  RUN_SHA=1d9fb3e1 BRANCH_HEAD_SHA=99887766 BRANCH_NAME=main \
  WORKFLOW_FILE="$QUEUES"
says "::error title=Pipeline has cancelled jobs" "it annotates the cancellation as an error"
says "measure-disk-space" "it names the job that overran"
says "cancel-in-progress: false" "it says why a supersede cannot explain it"
says_not "::warning title=Cancelled jobs in a superseded run" \
  "it no longer excuses the run as superseded"

# The same input with the gate blind to the workflow is the behaviour before
# the fix - kept as a live contrast rather than a comment, because it is the
# exact reading that produced the annotation on run 34366975927.
run_gate 1 "the same cancellation with no workflow to read still fails closed" \
  "$RUN_34366975927" \
  RUN_SHA=1d9fb3e1 BRANCH_HEAD_SHA=99887766 BRANCH_NAME=main
says "::error title=Pipeline has cancelled jobs" "an unreadable workflow is an error, not an excuse"

echo
echo "=== Part 2: the supersede the rule must keep ==="
echo

CANCELS="$TMP/cancels.yml"
cat >"$CANCELS" <<'YAML'
name: Cancels in progress
on:
  push:
jobs:
  link-checker:
    runs-on: ubuntu-24.04
    concurrency:
      group: links-${{ github.ref }}
      cancel-in-progress: true
    steps:
      - run: 'true'

  pipeline-status:
    runs-on: ubuntu-24.04
    needs: [link-checker]
    if: ${{ !cancelled() }}
    steps:
      - run: 'true'
YAML

CANCELLED_LINKS='{"link-checker":{"result":"cancelled"}}'

run_gate 0 "a cancel-in-progress job in a superseded run is still only a warning" \
  "$CANCELLED_LINKS" \
  RUN_SHA=aaaa BRANCH_HEAD_SHA=bbbb BRANCH_NAME=main \
  WORKFLOW_FILE="$CANCELS"
says "::warning title=Cancelled jobs in a superseded run" "the supersede stays a warning"
says "link-checker" "the warning names the job"

# The other half of the same rule: cancel-in-progress: true explains nothing
# while the run is still the head of its branch. Nothing overtook it.
run_gate 1 "a cancel-in-progress job in a current run still fails the gate" \
  "$CANCELLED_LINKS" \
  RUN_SHA=aaaa BRANCH_HEAD_SHA=aaaa BRANCH_NAME=main \
  WORKFLOW_FILE="$CANCELS"
says "still the head of main" "it says the run was never overtaken"

# Mixed: one job that a supersede could have cancelled and one that it could
# not. Excusing the pair because one of them is explicable is the defect in
# miniature, so both verdicts have to appear.
MIXED="$TMP/mixed.yml"
cat >"$MIXED" <<'YAML'
name: Mixed
on:
  push:
jobs:
  quick:
    runs-on: ubuntu-24.04
    concurrency:
      group: quick-${{ github.ref }}
      cancel-in-progress: true
    steps:
      - run: 'true'

  slow:
    runs-on: ubuntu-24.04
    timeout-minutes: 60
    concurrency:
      group: slow-${{ github.ref }}
      cancel-in-progress: false
    steps:
      - run: 'true'

  pipeline-status:
    runs-on: ubuntu-24.04
    needs: [quick, slow]
    if: ${{ !cancelled() }}
    steps:
      - run: 'true'
YAML

run_gate 1 "a supersede next to an overrun does not excuse the overrun" \
  '{"quick":{"result":"cancelled"},"slow":{"result":"cancelled"}}' \
  RUN_SHA=aaaa BRANCH_HEAD_SHA=bbbb BRANCH_NAME=main \
  WORKFLOW_FILE="$MIXED"
says "::warning title=Cancelled jobs in a superseded run::quick" "the supersede is reported as a warning"
says "::error title=Pipeline has cancelled jobs::slow" "the overrun beside it is reported as an error"

echo
echo "=== Part 3: everything unreadable fails closed ==="
echo

# A job the workflow does not declare. Reading "absent" as "cancellable" is how
# a rename would silently restore the defect.
run_gate 1 "a job the workflow does not declare fails closed" \
  '{"ghost":{"result":"cancelled"}}' \
  RUN_SHA=aaaa BRANCH_HEAD_SHA=bbbb BRANCH_NAME=main \
  WORKFLOW_FILE="$CANCELS"
says "ghost" "it names the job it could not find"

# No concurrency at all: GitHub has no group to supersede this job with, so a
# cancellation cannot be one.
NOCONC="$TMP/no-concurrency.yml"
cat >"$NOCONC" <<'YAML'
name: No concurrency
on:
  push:
jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - run: 'true'

  pipeline-status:
    runs-on: ubuntu-24.04
    needs: [build]
    if: ${{ !cancelled() }}
    steps:
      - run: 'true'
YAML

run_gate 1 "a job with no concurrency group at all fails closed" \
  '{"build":{"result":"cancelled"}}' \
  RUN_SHA=aaaa BRANCH_HEAD_SHA=bbbb BRANCH_NAME=main \
  WORKFLOW_FILE="$NOCONC"
says "no concurrency" "it says there was no group to supersede the job with"

# The scalar form - `concurrency: some-group` - is a group with no
# cancel-in-progress, which defaults to false.
SCALAR="$TMP/scalar.yml"
cat >"$SCALAR" <<'YAML'
name: Scalar concurrency
on:
  push:
jobs:
  build:
    runs-on: ubuntu-24.04
    concurrency: build-group
    steps:
      - run: 'true'

  pipeline-status:
    runs-on: ubuntu-24.04
    needs: [build]
    if: ${{ !cancelled() }}
    steps:
      - run: 'true'
YAML

run_gate 1 "a bare concurrency group defaults to cancel-in-progress: false" \
  '{"build":{"result":"cancelled"}}' \
  RUN_SHA=aaaa BRANCH_HEAD_SHA=bbbb BRANCH_NAME=main \
  WORKFLOW_FILE="$SCALAR"
says "cancel-in-progress: false" "it says the default is not to cancel"

# An expression the gate cannot evaluate offline is unknown, not true.
EXPR="$TMP/expression.yml"
cat >"$EXPR" <<'YAML'
name: Expression
on:
  push:
jobs:
  build:
    runs-on: ubuntu-24.04
    concurrency:
      group: build-${{ github.ref }}
      cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}
    steps:
      - run: 'true'

  pipeline-status:
    runs-on: ubuntu-24.04
    needs: [build]
    if: ${{ !cancelled() }}
    steps:
      - run: 'true'
YAML

run_gate 1 "an expression for cancel-in-progress is unknown, not true" \
  '{"build":{"result":"cancelled"}}' \
  RUN_SHA=aaaa BRANCH_HEAD_SHA=bbbb BRANCH_NAME=main \
  WORKFLOW_FILE="$EXPR"
says "could not read" "it says it could not decide the value"

# A workflow path that does not exist at all.
run_gate 1 "a missing workflow file fails closed" \
  '{"build":{"result":"cancelled"}}' \
  RUN_SHA=aaaa BRANCH_HEAD_SHA=bbbb BRANCH_NAME=main \
  WORKFLOW_FILE="$TMP/nowhere.yml"
says "$TMP/nowhere.yml" "it names the file it could not read"

echo
echo "=== Part 4: job-level first, workflow-level second ==="
echo

# release.yml declares concurrency once, at workflow scope, and none of its
# jobs override it. A job with no block of its own inherits that.
INHERIT="$TMP/inherit.yml"
cat >"$INHERIT" <<'YAML'
name: Inherit
on:
  push:

concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - run: 'true'

  measure:
    runs-on: ubuntu-24.04
    concurrency:
      group: measure-${{ github.ref }}
      cancel-in-progress: false
    steps:
      - run: 'true'

  pipeline-status:
    runs-on: ubuntu-24.04
    needs: [build, measure]
    if: ${{ !cancelled() }}
    steps:
      - run: 'true'
YAML

run_gate 0 "a job with no block of its own inherits the workflow's" \
  '{"build":{"result":"cancelled"}}' \
  RUN_SHA=aaaa BRANCH_HEAD_SHA=bbbb BRANCH_NAME=main \
  WORKFLOW_FILE="$INHERIT"
says "::warning title=Cancelled jobs in a superseded run" "the inherited true is honoured"

run_gate 1 "a job-level block overrides the workflow's" \
  '{"measure":{"result":"cancelled"}}' \
  RUN_SHA=aaaa BRANCH_HEAD_SHA=bbbb BRANCH_NAME=main \
  WORKFLOW_FILE="$INHERIT"
says "cancel-in-progress: false" "the job's own false wins over the workflow's true"

echo
echo "=== Part 5: GITHUB_WORKFLOW_REF locates the workflow ==="
echo

# In a real run nothing passes WORKFLOW_FILE. The runner sets
# GITHUB_WORKFLOW_REF to owner/repo/.github/workflows/<file>@<ref>, which is
# the only thing that says which file the gate is running inside.
REF_ROOT="$TMP/checkout"
mkdir -p "$REF_ROOT/.github/workflows"
cp "$QUEUES" "$REF_ROOT/.github/workflows/measure-disk-space.yml"
mkdir -p "$REF_ROOT/scripts/ci"
cp scripts/ci/check-pipeline-status.sh scripts/ci/read-job-cancel-in-progress.sh "$REF_ROOT/scripts/ci/"

(
  cd "$REF_ROOT" || exit 1
  env NEEDS_JSON="$RUN_34366975927" \
    RUN_SHA=1d9fb3e1 BRANCH_HEAD_SHA=99887766 BRANCH_NAME=main \
    GITHUB_WORKFLOW_REF='link-foundation/box/.github/workflows/measure-disk-space.yml@refs/heads/main' \
    bash scripts/ci/check-pipeline-status.sh
) >"$TMP/gate.out" 2>&1
if [ "$?" -eq 1 ]; then
  pass "GITHUB_WORKFLOW_REF alone is enough to find the workflow (exit 1)"
else
  fail "GITHUB_WORKFLOW_REF alone is enough to find the workflow" "$(cat "$TMP/gate.out")"
fi
says "cancel-in-progress: false" "and the file it found is the one that says the job queues"

echo
echo "=== Part 6: the shipped workflows, read as the gate reads them ==="
echo

# Every entry-point workflow, every job its gate needs: the value the gate
# would compute. This is a survey rather than a policy - a job is allowed to
# set cancel-in-progress: false, and measure-disk-space deliberately does - but
# an unknown here would mean the gate cannot read a file this repository ships.
SURVEY="$TMP/survey.txt"
: >"$SURVEY"
for wf in .github/workflows/*.yml; do
  grep -qE '^  (push|pull_request|schedule|workflow_dispatch):' "$wf" || continue
  jobs="$(
    WORKFLOW_FILE="$wf" python3 - <<'PY'
import os, re, sys
sys.path.insert(0, "scripts/ci")
lines = open(os.environ["WORKFLOW_FILE"], encoding="utf-8").read().splitlines()
inside = False
for line in lines:
    if re.match(r"^jobs:\s*$", line):
        inside = True
        continue
    if inside and re.match(r"^[A-Za-z_]", line):
        break
    if inside:
        m = re.match(r"^  ([A-Za-z_][A-Za-z0-9_.-]*):", line)
        if m and m.group(1) != "pipeline-status":
            print(m.group(1))
PY
  )"
  for job in $jobs; do
    value="$(WORKFLOW_FILE="$wf" JOB_NAMES="$job" bash scripts/ci/read-job-cancel-in-progress.sh | cut -f2)"
    printf '%s\t%s\t%s\n' "$(basename "$wf")" "$job" "$value" >>"$SURVEY"
  done
done

SURVEYED="$(wc -l <"$SURVEY")"
if [ "$SURVEYED" -ge 15 ]; then
  pass "read the concurrency of $SURVEYED jobs across the entry-point workflows"
else
  fail "read the concurrency of $SURVEYED jobs across the entry-point workflows" \
    "expected at least 15; the discovery above is probably broken" "$(cat "$SURVEY")"
fi

if grep -qP '\tunknown$' "$SURVEY"; then
  fail "no shipped job is unreadable to the gate" "$(grep -P '\tunknown$' "$SURVEY")"
else
  pass "no shipped job is unreadable to the gate"
fi

# The job the annotation was about, read out of the file it is really in.
MDS="$(grep -P '^measure-disk-space\.yml\tmeasure-disk-space\t' "$SURVEY" | cut -f3)"
if [ "$MDS" = false ]; then
  pass "measure-disk-space still queues instead of cancelling, so an overrun there is an error"
else
  fail "measure-disk-space still queues instead of cancelling" "read: ${MDS:-<nothing>}"
fi

# ...and the jobs that do cancel in progress are still excusable, so the fix
# did not simply turn every cancellation red.
CANCELLING="$(grep -cP '\ttrue$' "$SURVEY")"
if [ "$CANCELLING" -ge 12 ]; then
  pass "$CANCELLING shipped jobs still cancel in progress and can still be excused"
else
  fail "$CANCELLING shipped jobs still cancel in progress" "expected at least 12" "$(cat "$SURVEY")"
fi

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
