#!/usr/bin/env bash
# test-issue123-budget-enforcement.sh
#
# Issue #123: "a budget that reports termination should have terminated
# something."
#
# Measured shape, run 34366975927 ("Measure Disk Space", main, 1d9fb3e). The
# step is
#
#   run-with-budget-warning.sh 2400 "disk space measurement" \
#     sudo env ... ./scripts/measure-disk-space.sh ... 2>&1 | tee measurement.log
#
# At 15:37:47 the 2400s budget expired and the wrapper printed "was
# terminated". The step then ran for another 19m21s, until `timeout-minutes:
# 60` killed the job at 15:57:08 - which GitHub reports as *cancelled*, which
# the status gate read as a supersede, so the run was green. `apt-get`, a root
# grandchild of a `sudo` the wrapper could signal but whose children it could
# not, was still holding the step's stdout, which is the pipe into `tee`.
#
# Two defects in the wrapper, both asserted here:
#
#   Part 1  liveness is a question about the process table, and `kill -0`
#           answers a different one - it fails identically for "not yours to
#           signal" (EPERM) and "gone" (ESRCH), so a group of root survivors
#           read as "finished" and the SIGKILL escalation was skipped
#   Part 2  a survivor must not be able to hold the step open: the command's
#           output is relayed by the wrapper now, so the only holders of the
#           step's own stdout are the wrapper and the shell that started it
#
# and the behaviour that has to survive both:
#
#   Part 3  SIGTERM, then SIGKILL, and the escalation actually happens
#   Part 4  the relay is transparent - stream, order and exit status
#   Part 5  the repository is held to this
#
# The privileged half of the reproduction needs root and a container, so it
# lives in experiments/issue-123/repro-budget-privileged-child.sh, which also
# runs itself against the pre-fix wrapper to show the defect. Everything here
# is offline and unprivileged.
#
# Usage: bash experiments/test-issue123-budget-enforcement.sh

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

WRAPPER="scripts/ci/run-with-budget-warning.sh"

export BUDGET_POLL_SECONDS=0.2
export BUDGET_GRACE_SECONDS=1
export BUDGET_KILL_SECONDS=1

# Detaches a process from the wrapper's process group, so that the wrapper
# cannot reach it with a group signal however hard it tries - the unprivileged
# stand-in for the root grandchild of run 34366975927. It keeps whatever stdout
# it inherited open for the whole of its life.
cat >"$TMP/escape.sh" <<'ESCAPE'
#!/usr/bin/env bash
# Usage: escape.sh SECONDS - leave the process group, then hold on.
if command -v setsid >/dev/null 2>&1; then
  setsid sleep "$1" &
else
  python3 -c 'import os, sys, time
if os.fork() == 0:
    os.setsid()
    time.sleep(float(sys.argv[1]))
    os._exit(0)
' "$1" &
fi
ESCAPE
chmod +x "$TMP/escape.sh"

echo "=== Part 1: liveness is asked of the process table, not of kill(2) ==="

# A `ps` that reports one member of the command's process group which this
# suite is certainly not able to signal: pid 1, owned by root. `kill -0` on it
# fails with EPERM, exactly as it did on the root `apt-get` in the measured
# run, so the old liveness check would call the command finished. `stat` is a
# column the wrapper reads, and `Ss` is not a zombie.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/ps" <<'FAKEPS'
#!/usr/bin/env bash
# Real output first, so everything the wrapper genuinely started is still seen.
/usr/bin/ps "$@"
if [ -n "${FAKE_PS_GROUP:-}" ]; then
  echo "${FAKE_PS_GROUP} 1 Ss root /sbin/init fake-survivor"
fi
FAKEPS
chmod +x "$TMP/bin/ps"

if [ ! -x /usr/bin/ps ]; then
  fail "this suite needs /usr/bin/ps"
else
  # The wrapper resolves the process group id of its command; it is the pid of
  # the subshell it backgrounds, which is one more than the wrapper's own pid
  # in practice but must not be guessed. Instead the fake reports its line for
  # *every* group, which makes every group look populated - the same lie, told
  # unconditionally.
  cat >"$TMP/bin/ps" <<'FAKEPS'
#!/usr/bin/env bash
/usr/bin/ps "$@"
if [ -n "${FAKE_PS_GROUP:-}" ]; then
  /usr/bin/ps -eo pgid=,pid= | awk -v want="${FAKE_PS_GROUP}" '
    { if (!seen[$1]++) groups[++n] = $1 }
    END { for (i = 1; i <= n; i++) print groups[i] " 1 Ss root /sbin/init fake-survivor" }
  '
fi
FAKEPS
  chmod +x "$TMP/bin/ps"

  # `true` finishes immediately, so nothing real is left in the group; only the
  # fake survivor is. The wrapper must still finish, because completion is
  # decided by the status file rather than by liveness.
  FAKE_PS_GROUP=any PATH="$TMP/bin:$PATH" \
    timeout 20 bash "$WRAPPER" 5 "fake survivors" true >"$TMP/fake.log" 2>&1
  status=$?
  if [ "$status" -eq 0 ]; then
    pass "a command that finished is finished, whatever else is in its process group"
  else
    fail "a command that finished is finished, whatever else is in its process group" \
      "exit $status" "$(cat "$TMP/fake.log")"
  fi

  # An overrun with a survivor the wrapper cannot signal has to be reported as
  # such, rather than reported as a termination that did not happen.
  FAKE_PS_GROUP=any PATH="$TMP/bin:$PATH" \
    timeout 30 bash "$WRAPPER" 1 "unkillable step" sleep 25 >"$TMP/unkillable.log" 2>&1
  status=$?
  if [ "$status" -eq 124 ]; then
    pass "an overrun with survivors still exits 124"
  else
    fail "an overrun with survivors still exits 124" "exit $status" "$(cat "$TMP/unkillable.log")"
  fi
  if grep -q 'ignored SIGTERM' "$TMP/unkillable.log"; then
    pass "a survivor that outlives SIGTERM is escalated to SIGKILL"
  else
    fail "a survivor that outlives SIGTERM is escalated to SIGKILL" "$(cat "$TMP/unkillable.log")"
  fi
  if grep -q '::error title=unkillable step left processes running::' "$TMP/unkillable.log"; then
    pass "a survivor that outlives SIGKILL is reported, not silently called terminated"
  else
    fail "a survivor that outlives SIGKILL is reported, not silently called terminated" \
      "$(cat "$TMP/unkillable.log")"
  fi
  if grep -q 'fake-survivor' "$TMP/unkillable.log"; then
    pass "the report names the process that survived"
  else
    fail "the report names the process that survived" "$(cat "$TMP/unkillable.log")"
  fi

  # The mutation: without the fake, the same run leaves nothing behind, so the
  # report must not appear. A gate that fires either way is not a gate.
  PATH="$TMP/bin:$PATH" \
    timeout 30 bash "$WRAPPER" 1 "killable step" sleep 25 >"$TMP/killable.log" 2>&1
  if grep -q 'left processes running' "$TMP/killable.log"; then
    fail "an overrun the wrapper does terminate reports no survivors" "$(cat "$TMP/killable.log")"
  else
    pass "an overrun the wrapper does terminate reports no survivors"
  fi
fi

echo
echo "=== Part 2: a survivor cannot hold the step open ==="

# The shape of the step that broke: the wrapper's output goes through a pipe,
# and the wrapped command leaves something behind that holds the write end.
# Whoever wins, the pipeline has to end when the budget says so.
# (a) the command finishes on its own and leaves the survivor behind.
start=$SECONDS
timeout 60 bash -c "bash '$WRAPPER' 30 'leaky step' bash '$TMP/escape.sh' 30 2>&1 | cat >'$TMP/piped.log'"
piped_status=$?
piped_elapsed=$((SECONDS - start))

if [ "$piped_status" -eq 0 ] && [ "$piped_elapsed" -lt 15 ]; then
  pass "a piped step ends when its command does, even though a survivor holds the pipe (${piped_elapsed}s)"
else
  fail "a piped step ends when its command does, even though a survivor holds the pipe" \
    "took ${piped_elapsed}s, status ${piped_status}"
fi

# (b) the command overruns, is terminated, and leaves the survivor behind -
# the shape of run 34366975927 exactly.
start=$SECONDS
timeout 60 bash -c "bash '$WRAPPER' 1 'leaky overrun' bash -c '\"$TMP/escape.sh\" 30; sleep 40' 2>&1 | cat >'$TMP/piped-overrun.log'"
overrun_elapsed=$((SECONDS - start))

if [ "$overrun_elapsed" -lt 15 ]; then
  pass "a piped step that overruns ends with its budget, not with its survivor (${overrun_elapsed}s)"
else
  fail "a piped step that overruns ends with its budget, not with its survivor" \
    "took ${overrun_elapsed}s"
fi

if grep -q 'exceeded its execution budget' "$TMP/piped-overrun.log"; then
  pass "and the overrun is still reported through the relay"
else
  fail "and the overrun is still reported through the relay" "$(cat "$TMP/piped-overrun.log")"
fi

# The mutation: hand the command the step's own stdout, as the wrapper used to,
# and the same survivor keeps the pipeline open until it exits on its own. This
# is the 19m21s of run 34366975927, reproduced in 30 seconds and without root.
start=$SECONDS
BUDGET_CAPTURE_OUTPUT=0 \
  timeout 60 bash -c "bash '$WRAPPER' 1 'leaky step' bash '$TMP/escape.sh' 25 2>&1 | cat >'$TMP/piped-nocapture.log'"
nocapture_elapsed=$((SECONDS - start))

if [ "$nocapture_elapsed" -ge 15 ]; then
  pass "the defect is still reachable with BUDGET_CAPTURE_OUTPUT=0 (${nocapture_elapsed}s), so the assertion above is not vacuous"
else
  fail "the defect is still reachable with BUDGET_CAPTURE_OUTPUT=0" \
    "took only ${nocapture_elapsed}s"
fi

echo
echo "=== Part 3: SIGTERM first, SIGKILL second ==="

cat >"$TMP/stubborn.sh" <<'STUBBORN'
#!/usr/bin/env bash
trap 'echo "ignoring SIGTERM"' TERM
while true; do sleep 0.2; done
STUBBORN
chmod +x "$TMP/stubborn.sh"

start=$SECONDS
timeout 40 bash "$WRAPPER" 1 "stubborn step" bash "$TMP/stubborn.sh" >"$TMP/stubborn.log" 2>&1
stubborn_status=$?
stubborn_elapsed=$((SECONDS - start))

if [ "$stubborn_status" -eq 124 ] && [ "$stubborn_elapsed" -lt 20 ]; then
  pass "a command that ignores SIGTERM is killed anyway, and within the grace period (${stubborn_elapsed}s)"
else
  fail "a command that ignores SIGTERM is killed anyway" \
    "took ${stubborn_elapsed}s, status ${stubborn_status}" "$(cat "$TMP/stubborn.log")"
fi

if grep -q 'ignoring SIGTERM' "$TMP/stubborn.log"; then
  pass "the command's own output survives the termination it is being terminated by"
else
  fail "the command's own output survives the termination it is being terminated by" \
    "$(cat "$TMP/stubborn.log")"
fi

echo
echo "=== Part 4: the relay is transparent ==="

timeout 30 bash "$WRAPPER" 30 "streams" bash -c 'echo out-1; echo err-1 >&2; echo out-2; echo err-2 >&2; exit 7' \
  >"$TMP/out.log" 2>"$TMP/err.log"
status=$?

if [ "$status" -eq 7 ]; then
  pass "the command's exit status is the wrapper's exit status"
else
  fail "the command's exit status is the wrapper's exit status" "exit $status"
fi

if grep -q '^out-1$' "$TMP/out.log" && grep -q '^out-2$' "$TMP/out.log" \
  && ! grep -q 'err-' "$TMP/out.log"; then
  pass "stdout is relayed to stdout, and nothing else is"
else
  fail "stdout is relayed to stdout, and nothing else is" "$(cat "$TMP/out.log")"
fi

if grep -q '^err-1$' "$TMP/err.log" && grep -q '^err-2$' "$TMP/err.log" \
  && ! grep -q 'out-' "$TMP/err.log"; then
  pass "stderr is relayed to stderr, and nothing else is"
else
  fail "stderr is relayed to stderr, and nothing else is" "$(cat "$TMP/err.log")"
fi

if [ "$(grep -c 'out-' "$TMP/out.log")" -eq 2 ] \
  && [ "$(sed -n '/out-1/=' "$TMP/out.log" | head -1)" -lt "$(sed -n '/out-2/=' "$TMP/out.log" | head -1)" ]; then
  pass "order within a stream is preserved, and nothing is relayed twice"
else
  fail "order within a stream is preserved, and nothing is relayed twice" "$(cat "$TMP/out.log")"
fi

# Output larger than a pipe buffer, to catch a relay that reads a fixed amount
# or loses the tail when the command ends between two polls.
timeout 60 bash "$WRAPPER" 45 "bulk" bash -c 'i=0; while [ $i -lt 20000 ]; do echo "line-$i"; i=$((i + 1)); done' \
  >"$TMP/bulk.log" 2>&1
bulk_lines="$(grep -c '^line-' "$TMP/bulk.log")"
if [ "$bulk_lines" -eq 20000 ] && grep -q '^line-19999$' "$TMP/bulk.log"; then
  pass "20000 lines are relayed exactly once each, last line included"
else
  fail "20000 lines are relayed exactly once each, last line included" "got ${bulk_lines}"
fi

echo
echo "=== Part 5: the repository is held to this ==="

if grep -q 'BUDGET_CAPTURE_OUTPUT' "$WRAPPER" && grep -q 'group_members' "$WRAPPER"; then
  pass "the wrapper in the tree is the one this suite describes"
else
  fail "the wrapper in the tree is the one this suite describes"
fi

# The call site that broke. It is the only one that pipes, and the reason the
# relay is on by default is that the next one to pipe should not have to know.
if grep -A3 'run-with-budget-warning.sh 2400 "disk space measurement"' .github/workflows/measure-disk-space.yml \
  | grep -q 'tee measurement.log'; then
  pass "the step from run 34366975927 is still wrapped, and still pipes - which is now safe"
else
  fail "the step from run 34366975927 is still wrapped, and still pipes"
fi

if grep -q 'BUDGET_CAPTURE_OUTPUT=0' .github/workflows/*.yml; then
  fail "no workflow opts out of the relay" "$(grep -l 'BUDGET_CAPTURE_OUTPUT=0' .github/workflows/*.yml)"
else
  pass "no workflow opts out of the relay"
fi

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
