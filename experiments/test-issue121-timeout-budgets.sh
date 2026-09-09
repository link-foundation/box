#!/usr/bin/env bash
# test-issue121-timeout-budgets.sh
#
# Issue #121: "a step that runs out of time should say so."
#
# `timeout-minutes` is the only deadline this repository's long steps had, and
# it reports the wrong thing in the wrong place: GitHub marks a job it kills as
# *cancelled*, stops it where it stands - so the `if: always()` and
# `if: !cancelled()` reporting steps never run - and names neither the step nor
# the number that was exceeded. Measured shape, run 34259552358: the run's
# conclusion was `cancelled` while a job inside it had `failure`.
#
# The fix has three parts and this suite covers all three:
#
#   scripts/ci/run-with-budget-warning.sh   a step owns its deadline, warns at
#                                           70% of it, and *fails* at 100%
#   scripts/ci/check-timeout-budgets.mjs    every budget stays strictly inside
#                                           the job cap that backs it up, or
#                                           the budget could never fire
#   scripts/ci/build-chain.sh               the inline build blocks became one
#                                           command, which is what a budget can
#                                           be wrapped around
#
# What it asserts:
#   Part 1  the wrapper reports an overrun as a failure, and says which budget
#   Part 2  the wrapper is transparent when the command finishes in time
#   Part 3  the checker fails a budget that cannot fire, and passes one that can
#   Part 4  the checker evaluates each matrix leg on its own terms
#   Part 5  build-chain.sh builds the chain each variant needs, and only that
#   Part 6  the checks are wired into CI and this repository passes them
#
# Every checker fixture is mutation-checked: the passing form and the failing
# form differ by one number, so a fixture that stopped being parsed at all
# would fail this suite rather than pass it vacuously.
#
# Usage: bash experiments/test-issue121-timeout-budgets.sh

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
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

WRAPPER="scripts/ci/run-with-budget-warning.sh"
CHECKER="scripts/ci/check-timeout-budgets.mjs"

# The wrapper polls; at the default one-second interval every timing assertion
# below would cost a second of slack it does not need.
export BUDGET_POLL_SECONDS=0.2
export BUDGET_GRACE_SECONDS=2

# run_wrapper LOGFILE ARGS... - runs the wrapper, captures both streams, and
# returns its exit status without tripping `set -e` in the caller.
run_wrapper() {
  local log="$1"
  shift
  bash "$WRAPPER" "$@" >"$log" 2>&1
}

echo "=== Part 1: an overrun is a failure that names its budget ==="

start=$SECONDS
run_wrapper "$TMP/overrun.log" 1 "slow step" sleep 60
status=$?
elapsed=$((SECONDS - start))

if [ "$status" -eq 124 ]; then
  pass "a command that outlasts its budget exits 124, the same status timeout(1) uses"
else
  fail "a command that outlasts its budget exits 124, the same status timeout(1) uses" \
    "exit status was ${status}" "$(cat "$TMP/overrun.log")"
fi

if [ "$elapsed" -lt 20 ]; then
  pass "the budget is enforced when it expires, not when the command would have ended (${elapsed}s, not 60s)"
else
  fail "the budget is enforced when it expires, not when the command would have ended" \
    "the wrapper took ${elapsed}s to stop a 60s command with a 1s budget"
fi

# The whole point of the exercise: the message must be actionable on its own,
# because the job log is all anyone has after the fact.
if grep -q '^::error title=slow step exceeded its execution budget::' "$TMP/overrun.log"; then
  pass "the overrun is an ::error annotation naming the step, so the job fails instead of being cancelled"
else
  fail "the overrun is an ::error annotation naming the step" "$(cat "$TMP/overrun.log")"
fi

if grep -q '1s budget' "$TMP/overrun.log"; then
  pass "the message quotes the budget that was exceeded"
else
  fail "the message quotes the budget that was exceeded" "$(cat "$TMP/overrun.log")"
fi

# A `docker build` leaves a CLI, a BuildKit session and the build's own
# children. Killing the direct child alone leaves those holding the runner,
# which is the failure mode `set -m` and the group signal exist for.
cat >"$TMP/spawns-a-child.sh" <<'CHILD'
#!/usr/bin/env bash
sleep 60 &
echo "$!" >"$1"
sleep 60
CHILD

# Liveness is read from the process state, not from `kill -0`. A killed child
# whose parent is already gone stays visible as a zombie until init reaps it,
# and `kill -0` succeeds on a zombie - it would answer "still running" for a
# process that is definitively dead, intermittently, depending on how quickly
# the reap happened. That is the same distinction run-with-budget-warning.sh
# makes for its own completion check, and it has to be made here too.
process_is_running() {
  local state
  state="$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')"
  [ -n "$state" ] && [ "${state#Z}" = "$state" ]
}

run_wrapper "$TMP/group.log" 2 "step with a child" bash "$TMP/spawns-a-child.sh" "$TMP/child.pid"
child_pid="$(cat "$TMP/child.pid" 2>/dev/null || echo '')"

if [ -z "$child_pid" ]; then
  fail "the grandchild of an over-budget command is killed with it" \
    "the fixture never recorded a child pid, so this assertion would pass vacuously"
elif process_is_running "$child_pid"; then
  kill -9 "$child_pid" 2>/dev/null || true
  fail "the grandchild of an over-budget command is killed with it" \
    "pid ${child_pid} was still running after the wrapper returned:" \
    "$(ps -o pid=,pgid=,stat=,args= -p "$child_pid" 2>/dev/null)"
else
  pass "the grandchild of an over-budget command is killed with it, not orphaned onto the runner"
fi

echo
echo "=== Part 2: the wrapper is transparent below its budget ==="

run_wrapper "$TMP/ok.log" 30 "quick step" true
status=$?

if [ "$status" -eq 0 ]; then
  pass "a command that succeeds inside its budget still exits 0"
else
  fail "a command that succeeds inside its budget still exits 0" "exit ${status}" "$(cat "$TMP/ok.log")"
fi

# A wrapper that swallowed a failure would be worse than no wrapper: it would
# turn a red step green, which is the false negative this issue is about.
run_wrapper "$TMP/failing.log" 30 "failing step" bash -c 'exit 7'
status=$?

if [ "$status" -eq 7 ]; then
  pass "the command's own exit status is passed through unchanged (7)"
else
  fail "the command's own exit status is passed through unchanged" "exit ${status}" "$(cat "$TMP/failing.log")"
fi

if ! grep -q '::error' "$TMP/ok.log" && ! grep -q '::warning' "$TMP/ok.log"; then
  pass "a step well inside its budget produces no annotation"
else
  fail "a step well inside its budget produces no annotation" "$(cat "$TMP/ok.log")"
fi

# The early warning is the half of this that acts before anything breaks: a
# step drifting towards its budget is the notice that the budget needs revising.
BUDGET_WARN_PERCENT=50 run_wrapper "$TMP/warn.log" 4 "drifting step" sleep 3
status=$?

if [ "$status" -eq 0 ] && grep -q '^::warning title=drifting step is approaching its execution budget::' "$TMP/warn.log"; then
  pass "a step past the warning threshold warns and still succeeds"
else
  fail "a step past the warning threshold warns and still succeeds" \
    "exit ${status}" "$(cat "$TMP/warn.log")"
fi

if [ "$(grep -c '::warning' "$TMP/warn.log")" -eq 1 ]; then
  pass "the warning is emitted once, not once per poll"
else
  fail "the warning is emitted once, not once per poll" "$(cat "$TMP/warn.log")"
fi

for bad_usage in "" "0" "abc"; do
  # shellcheck disable=SC2086 # deliberate: an empty budget means "no arguments"
  bash "$WRAPPER" $bad_usage ${bad_usage:+"label" true} >"$TMP/usage.log" 2>&1
  status=$?
  if [ "$status" -eq 2 ]; then
    pass "a budget of '${bad_usage:-<missing>}' is a usage error (exit 2), not a silent zero"
  else
    fail "a budget of '${bad_usage:-<missing>}' is a usage error (exit 2)" \
      "exit ${status}" "$(cat "$TMP/usage.log")"
  fi
done

BUDGET_POLL_SECONDS=1.2.3 bash "$WRAPPER" 10 "bad poll" true >"$TMP/poll.log" 2>&1
status=$?
if [ "$status" -eq 2 ]; then
  pass "a malformed BUDGET_POLL_SECONDS is rejected before the command starts"
else
  fail "a malformed BUDGET_POLL_SECONDS is rejected before the command starts" \
    "exit ${status}" "$(cat "$TMP/poll.log")"
fi

echo
echo "=== Part 3: a budget must be able to fire before the job cap ==="

# fixture NAME BUDGET_SECONDS [CAP_MINUTES] - one job, one wrapped step.
fixture() {
  local name="$1" budget="$2" cap="${3:-10}"
  cat >"$TMP/${name}.yml" <<YAML
name: Fixture
on: workflow_dispatch
jobs:
  build:
    runs-on: ubuntu-24.04
    timeout-minutes: ${cap}
    steps:
      - name: Long step
        run: |
          bash scripts/ci/run-with-budget-warning.sh ${budget} "long step" \\
            bash -c 'true'
YAML
}

check() {
  node "$CHECKER" "$@" >"$TMP/check.log" 2>&1
}

# 300s of a 600s cap: half, so the budget expires with five minutes to spare
# and the step reports the overrun itself.
fixture fits 300
check "$TMP/fits.yml"
if [ $? -eq 0 ]; then
  pass "a budget at 50% of its job cap passes"
else
  fail "a budget at 50% of its job cap passes" "$(cat "$TMP/check.log")"
fi

# 500s of the same 600s cap. It is under the cap, so it looks safe, and it is
# not: the job cap can still win the race, and then the run is grey again.
fixture cannot-fire 500
check "$TMP/cannot-fire.yml"
if [ $? -eq 1 ]; then
  pass "a budget at 83% of its job cap fails: too close to the cap to be sure of firing first"
else
  fail "a budget at 83% of its job cap fails" "$(cat "$TMP/check.log")"
fi

if grep -q '83.3% of the 600s cap' "$TMP/check.log"; then
  pass "the failure quotes the measured share and the cap it was measured against"
else
  fail "the failure quotes the measured share and the cap it was measured against" "$(cat "$TMP/check.log")"
fi

# Two steps that both run, so their budgets accumulate against one cap even
# though neither exceeds it alone.
cat >"$TMP/total.yml" <<'YAML'
name: Fixture
on: workflow_dispatch
jobs:
  build:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - name: Build
        run: |
          bash scripts/ci/run-with-budget-warning.sh 300 "build" bash -c 'true'
      - name: Test
        run: |
          bash scripts/ci/run-with-budget-warning.sh 200 "test" bash -c 'true'
YAML
check "$TMP/total.yml"
if [ $? -eq 1 ] && grep -q 'budgets total 500s' "$TMP/check.log"; then
  pass "two budgets in one job are added together against the one cap that bounds both"
else
  fail "two budgets in one job are added together against the one cap that bounds both" \
    "$(cat "$TMP/check.log")"
fi

# ...but only when they can actually run together. Steps under mutually
# exclusive conditions cannot, and summing them would invent a violation no run
# could produce - a false positive, in the check written to remove them.
cat >"$TMP/conditional.yml" <<'YAML'
name: Fixture
on: workflow_dispatch
jobs:
  build:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    strategy:
      matrix:
        variant: [a, b]
    steps:
      - name: Build a
        if: matrix.variant == 'a'
        run: |
          bash scripts/ci/run-with-budget-warning.sh 400 "a" bash -c 'true'
      - name: Build b
        if: matrix.variant == 'b'
        run: |
          bash scripts/ci/run-with-budget-warning.sh 400 "b" bash -c 'true'
YAML
check "$TMP/conditional.yml"
if [ $? -eq 0 ]; then
  pass "steps under mutually exclusive conditions are not charged to the same run"
else
  fail "steps under mutually exclusive conditions are not charged to the same run" \
    "$(cat "$TMP/check.log")"
fi

# A `uses:` step cannot be wrapped, so its deadline is a step-level
# `timeout-minutes` - a budget in every sense that matters, and counted as one.
cat >"$TMP/step-timeout.yml" <<'YAML'
name: Fixture
on: workflow_dispatch
jobs:
  build:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - name: Build and push
        uses: docker/build-push-action@v7
        timeout-minutes: 8
YAML
check "$TMP/step-timeout.yml"
if [ $? -eq 1 ] && grep -q '480s' "$TMP/check.log"; then
  pass "a step-level timeout-minutes counts as that step's budget"
else
  fail "a step-level timeout-minutes counts as that step's budget" "$(cat "$TMP/check.log")"
fi

# A job with no cap has nothing backing its budgets up at all.
cat >"$TMP/no-cap.yml" <<'YAML'
name: Fixture
on: workflow_dispatch
jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - run: echo hello
YAML
check "$TMP/no-cap.yml"
if [ $? -eq 1 ] && grep -q 'declares no timeout-minutes' "$TMP/check.log"; then
  pass "a job with no timeout-minutes at all is a failure"
else
  fail "a job with no timeout-minutes at all is a failure" "$(cat "$TMP/check.log")"
fi

# ...except the one kind of job GitHub forbids the key on. Flagging it would be
# a finding nobody could act on, which is how a check gets ignored.
cat >"$TMP/reusable.yml" <<'YAML'
name: Fixture
on: workflow_dispatch
jobs:
  js:
    uses: ./.github/workflows/release-js.yml
    secrets: inherit
YAML
check "$TMP/reusable.yml"
if [ $? -eq 0 ]; then
  pass "a job that calls a reusable workflow is exempt: GitHub rejects timeout-minutes there"
else
  fail "a job that calls a reusable workflow is exempt" "$(cat "$TMP/check.log")"
fi

# A budget the checker cannot read is not a budget it may assume is fine: that
# is the silent pass this whole exercise removes. Exit 2 - "could not run" -
# rather than 0 or 1.
cat >"$TMP/unresolvable.yml" <<'YAML'
name: Fixture
on: workflow_dispatch
jobs:
  build:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - name: Long step
        run: |
          bash scripts/ci/run-with-budget-warning.sh "$MYSTERY_BUDGET" "x" bash -c 'true'
YAML
check "$TMP/unresolvable.yml"
if [ $? -eq 2 ] && grep -q 'no env value for \$MYSTERY_BUDGET' "$TMP/check.log"; then
  pass "a budget the checker cannot resolve stops the check instead of passing it"
else
  fail "a budget the checker cannot resolve stops the check instead of passing it" \
    "$(cat "$TMP/check.log")"
fi

# The same budget, declared where the workflow actually declares it.
cat >"$TMP/env-budget.yml" <<'YAML'
name: Fixture
on: workflow_dispatch
jobs:
  build:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - name: Long step
        env:
          BUDGET_SECONDS: 500
        run: |
          bash scripts/ci/run-with-budget-warning.sh "$BUDGET_SECONDS" "x" bash -c 'true'
YAML
check "$TMP/env-budget.yml"
if [ $? -eq 1 ] && grep -q 'budgets total 500s' "$TMP/check.log"; then
  pass "a budget passed through the step's env is resolved and counted"
else
  fail "a budget passed through the step's env is resolved and counted" "$(cat "$TMP/check.log")"
fi

# The wrapper is named in prose more often than it is called. Reading a comment
# as an invocation would fail a workflow that is correct.
cat >"$TMP/comment.yml" <<'YAML'
name: Fixture
on: workflow_dispatch
jobs:
  build:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      # scripts/ci/run-with-budget-warning.sh (issue #121) explains the rule.
      - name: Short step
        run: echo hello
YAML
check "$TMP/comment.yml"
if [ $? -eq 0 ]; then
  pass "the wrapper named in a comment is documentation, not a budget"
else
  fail "the wrapper named in a comment is documentation, not a budget" "$(cat "$TMP/check.log")"
fi

echo
echo "=== Part 4: every matrix leg is sized on its own ==="

# This repository sizes both the cap and the budget per leg - the full box gets
# 90 minutes where a language box gets 60 - so a checker that could only take a
# worst case would report violations no leg can incur.
matrix_fixture() {
  cat >"$TMP/matrix.yml" <<YAML
name: Fixture
on: workflow_dispatch
jobs:
  build:
    runs-on: ubuntu-24.04
    timeout-minutes: \${{ matrix.variant == 'full' && 20 || 10 }}
    strategy:
      matrix:
        variant: [js, full]
    steps:
      - name: Build
        env:
          BUDGET_SECONDS: \${{ matrix.variant == 'full' && 800 || $1 }}
        run: |
          bash scripts/ci/run-with-budget-warning.sh "\$BUDGET_SECONDS" "build" bash -c 'true'
YAML
}

# js: 300s of a 600s cap. full: 800s of a 1200s cap. Both fit; a worst-case
# reading (800s against 600s) would not.
matrix_fixture 300
check "$TMP/matrix.yml"
if [ $? -eq 0 ]; then
  pass "a per-leg budget under a per-leg cap passes on both legs"
else
  fail "a per-leg budget under a per-leg cap passes on both legs" "$(cat "$TMP/check.log")"
fi

# One leg broken, the other untouched.
matrix_fixture 500
check "$TMP/matrix.yml"
if [ $? -eq 1 ]; then
  pass "a leg whose budget outgrows its own cap fails"
else
  fail "a leg whose budget outgrows its own cap fails" "$(cat "$TMP/check.log")"
fi

if grep -q 'variant=js' "$TMP/check.log" && ! grep -q 'variant=full' "$TMP/check.log"; then
  pass "the failure names the leg that broke, and only that leg"
else
  fail "the failure names the leg that broke, and only that leg" "$(cat "$TMP/check.log")"
fi

echo
echo "=== Part 5: build-chain.sh builds the chain, and only the chain ==="

cat >"$TMP/docker-recorder" <<'RECORDER'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOCKER_LOG"
RECORDER
chmod +x "$TMP/docker-recorder"

# build_chain VARIANT - runs the chain against the recorder and leaves the
# commands it would have run in $TMP/docker.log.
build_chain() {
  : >"$TMP/docker.log"
  DOCKER_LOG="$TMP/docker.log" BUILD_CHAIN_DOCKER="$TMP/docker-recorder" \
    bash scripts/ci/build-chain.sh "$1" >"$TMP/chain.log" 2>&1
}

build_chain js
status=$?
if [ "$status" -eq 0 ] && [ "$(wc -l <"$TMP/docker.log")" -eq 1 ] \
  && grep -q -- '-f ubuntu/24.04/js/Dockerfile -t box-js' "$TMP/docker.log"; then
  pass "the js variant builds exactly one image, tagged box-js"
else
  fail "the js variant builds exactly one image, tagged box-js" "$(cat "$TMP/docker.log")"
fi

build_chain essentials
if grep -q -- '-t box-js' "$TMP/docker.log" \
  && grep -q -- '--build-arg JS_IMAGE=box-js -t box-essentials' "$TMP/docker.log"; then
  pass "the essentials variant builds box-js first and layers box-essentials onto it"
else
  fail "the essentials variant builds box-js first and layers box-essentials onto it" \
    "$(cat "$TMP/docker.log")"
fi

build_chain python
if [ "$(wc -l <"$TMP/docker.log")" -eq 3 ] \
  && grep -q -- '--build-arg ESSENTIALS_IMAGE=box-essentials -t box-python' "$TMP/docker.log"; then
  pass "a language variant builds js, essentials and itself - three images, not the whole matrix"
else
  fail "a language variant builds js, essentials and itself" "$(cat "$TMP/docker.log")"
fi

build_chain no-such-language
status=$?
if [ "$status" -eq 2 ] && grep -q "No Dockerfile for variant 'no-such-language'" "$TMP/chain.log"; then
  pass "an unknown variant is a usage error naming the path that was looked for"
else
  fail "an unknown variant is a usage error naming the path that was looked for" \
    "exit ${status}" "$(cat "$TMP/chain.log")"
fi

# The full box's language list is derived from its own Dockerfile, so a
# language added to that image is built here without editing build-chain.sh.
# Asserting against the Dockerfile rather than a hard-coded list is what keeps
# that true.
build_chain full
EXPECTED_LANGUAGES="$(sed -n 's/^ARG \([A-Z0-9_]*\)_IMAGE=.*/\1/p' ubuntu/24.04/full-box/Dockerfile \
  | grep -v '^ESSENTIALS$' | tr '[:upper:]' '[:lower:]' | sort)"

if [ "$(printf '%s\n' "$EXPECTED_LANGUAGES" | wc -l)" -ge 5 ]; then
  pass "the full box's Dockerfile still declares a language list to derive ($(printf '%s\n' "$EXPECTED_LANGUAGES" | wc -l) stages)"
else
  fail "the full box's Dockerfile still declares a language list to derive" \
    "found: ${EXPECTED_LANGUAGES}"
fi

MISSING=""
for language in $EXPECTED_LANGUAGES; do
  grep -q -- "-t box-${language} " "$TMP/docker.log" || MISSING="${MISSING} ${language}"
done

if [ -z "$MISSING" ]; then
  pass "the full chain builds every language stage the full box copies from"
else
  fail "the full chain builds every language stage the full box copies from" \
    "never built:${MISSING}" "$(cat "$TMP/docker.log")"
fi

if grep -q -- '-f ubuntu/24.04/full-box/Dockerfile' "$TMP/docker.log" \
  && grep -q -- '-t box-full' "$TMP/docker.log"; then
  pass "the full chain's last image is box-full - one name, where the workflows used to disagree"
else
  fail "the full chain's last image is box-full" "$(cat "$TMP/docker.log")"
fi

echo
echo "=== Part 6: the repository is held to this ==="

if grep -q 'node scripts/ci/check-timeout-budgets.mjs' .github/workflows/workflows.yml; then
  pass "the budget check runs in CI, not only on a developer's machine"
else
  fail "the budget check runs in CI, not only on a developer's machine"
fi

node "$CHECKER" .github/workflows/*.yml >"$TMP/self.log" 2>&1
if [ $? -eq 0 ]; then
  pass "every budget in this repository's workflows fits inside its job cap"
else
  fail "every budget in this repository's workflows fits inside its job cap" "$(cat "$TMP/self.log")"
fi

# A check that found nothing would also exit 0. The workflows must actually
# carry budgets for the previous assertion to mean anything.
BUDGETED_STEPS="$(grep -c 'run-with-budget-warning.sh' .github/workflows/*.yml | awk -F: '{ total += $2 } END { print total }')"
if [ "${BUDGETED_STEPS:-0}" -ge 10 ]; then
  pass "the workflows carry ${BUDGETED_STEPS} budgeted steps, so the check above is not passing vacuously"
else
  fail "the workflows carry enough budgeted steps for the check above to mean something" \
    "found ${BUDGETED_STEPS:-0}"
fi

# The inline chains are what build-chain.sh replaced, and a returning copy
# would be a step no budget can wrap. The dind image's own `docker build` is
# not one of those: it is a single command, wrapped, layered on the chain the
# previous step built - so the rule is about the chain's own stages.
INLINE_CHAINS="$(grep -n 'docker build -f ubuntu/24.04/\(js\|essentials-box\|full-box\)/' \
  .github/workflows/pr-tests.yml || true)"
if [ -z "$INLINE_CHAINS" ]; then
  pass "no pr-tests job has grown its own copy of the build chain back"
else
  fail "no pr-tests job has grown its own copy of the build chain back" "$INLINE_CHAINS"
fi

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
