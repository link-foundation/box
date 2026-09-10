#!/usr/bin/env bash
# Reproduce two defects in run-with-budget-warning.sh:
#
#   1. Liveness is probed with `kill -0`, so a command whose root exits while
#      its own children keep working is reported as finished, inside its
#      budget, exit 0.
#   2. Those survivors inherited the step's stdout, so the *step* does not end
#      when the wrapper does. Under `run: ... | tee log` (or any pipeline) the
#      step hangs until the job's timeout-minutes backstop kills it, which
#      GitHub reports as `cancelled` -- the exact state this wrapper exists to
#      prevent.
#
# Usage: bash repro-budget-survivor.sh /path/to/run-with-budget-warning.sh
set -uo pipefail
wrapper="${1:?path to run-with-budget-warning.sh}"

marker="budget-repro-$$"
work="$(mktemp -d)"
cleanup() {
  pkill -f "$marker" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

# A command that returns at once and leaves a worker behind, which is what
# `npm test`, `pytest -n` and every `docker build` do.
cat >"$work/command.sh" <<CMD
#!/usr/bin/env bash
sh -c 'sleep 60' $marker &
echo "root of the command is exiting while its worker keeps running"
exit 0
CMD
chmod +x "$work/command.sh"

echo "### $wrapper, budget 5s"
start=$SECONDS
BUDGET_POLL_SECONDS=1 bash "$wrapper" 5 "worker probe" bash "$work/command.sh" \
  >"$work/out" 2>&1
echo "wrapper exit=$? after $((SECONDS - start))s"
sed 's/^/    /' "$work/out"
echo "surviving worker pids: $(pgrep -f "$marker" | tr '\n' ' ' || true)"

echo "### the same command in a pipeline, which is how a CI step is written"
start=$SECONDS
timeout 20 bash -c "BUDGET_POLL_SECONDS=1 bash '$wrapper' 5 'worker probe' bash '$work/command.sh' 2>&1 | tee '$work/step.log' >/dev/null"
echo "pipeline exit=$? after $((SECONDS - start))s (124 = the step never ended)"
