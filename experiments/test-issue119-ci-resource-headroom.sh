#!/usr/bin/env bash
# test-issue119-ci-resource-headroom.sh
#
# The two full-chain PR jobs kept dying without leaving a reason behind, and
# this is the fixture for the change that fixes that (issue #119 follow-up,
# PR #120).
#
# What was measured, in run 34259552358 on this branch:
#
#   attempt 1, job 102177680205  pr-test / dind-full  step 7 failed, exit 143
#   attempt 1, job 102184490387  pr-test / full       the runner died mid-step:
#                                step 7 never left `in_progress`, steps 8+ stayed
#                                `pending`, so no `if: always()` step could run
#   attempt 2, job 102215605228  pr-test / dind-full:
#
#       #64 exporting to image
#       #64 exporting layers
#       ...sh: line 51: 122206 Killed  docker build -f ubuntu/24.04/full-box/...
#       ##[error]The runner has received a shutdown signal.
#       ##[error]Process completed with exit code 137.
#
# Those two jobs are the only ones that hold JS + essentials + 11 language
# images + the full box on a single VM, and the only two that fail; the other
# 13 dind variants and all 11 language jobs pass on the same commit. The
# resource that ran out is not in the log, because nothing in the job ever
# sampled one - the last reading is from `Free disk space`, half an hour and
# ~90 GB of image data before the kill.
#
# So the invariants pinned here are the three that change that:
#
#   1. scripts/ci/resource-monitor.sh samples memory, disk and swap onto
#      stdout, one line per sample, and flags a reading that is running out.
#   2. Both full-chain jobs start it inside the step that builds the chain -
#      inside, because a step that is SIGKILLed has no successor to upload a
#      file from, and only what already reached the live log survives.
#   3. Both reclaim the ~8 GB tool cache they never use, and keep the swap
#      that `swap-storage: true` takes away while reclaiming nothing (there is
#      no /mnt filesystem on this runner image for /mnt/swapfile to be on).
#
# Usage: bash experiments/test-issue119-ci-resource-headroom.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONITOR="$ROOT/scripts/ci/resource-monitor.sh"
WORKFLOW="$ROOT/.github/workflows/pr-tests.yml"

PASS=0
FAIL=0
pass() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
}

for required in "$MONITOR" "$WORKFLOW"; do
  [ -f "$required" ] || {
    echo "ERR: $required not found" >&2
    exit 1
  }
done

# --- 1. the sampler itself ----------------------------------------------------

out="$(bash "$MONITOR" sample)"
if [ "$(printf '%s\n' "$out" | grep -c '^\[resources\] ')" = "1" ]; then
  pass "sample mode prints exactly one [resources] line"
else
  fail "sample mode printed: $out"
fi

# Every reading a post-mortem needs has to be on the line, or the line is just
# noise: the failure above is equally consistent with a full disk and with an
# exhausted memory, and the point is to tell them apart.
for field in 'disk /=' 'MB free' 'mem ' 'MB available of' 'swap '; do
  if printf '%s' "$out" | grep -q -- "$field"; then
    pass "sample reports '$field'"
  else
    fail "sample is missing '$field': $out"
  fi
done

# A number that is really a placeholder is worse than no number, so a reading
# that could not be taken must say so rather than print a plausible 0.
out_missing="$(RESOURCE_MONITOR_DISK_PATH=/no/such/filesystem bash "$MONITOR" sample)"
if printf '%s' "$out_missing" | grep -q '?MB used'; then
  pass "an unreadable filesystem is reported as '?', not as 0"
else
  fail "unreadable filesystem produced: $out_missing"
fi

# Loop mode is what actually runs in CI; it must respect its own limits rather
# than run forever in a test.
loop="$(RESOURCE_MONITOR_MAX_SAMPLES=3 RESOURCE_MONITOR_INTERVAL_SECONDS=0 bash "$MONITOR")"
if [ "$(printf '%s\n' "$loop" | grep -c '^\[resources\] ')" = "3" ]; then
  pass "loop mode stops after RESOURCE_MONITOR_MAX_SAMPLES samples"
else
  fail "loop mode printed $(printf '%s\n' "$loop" | grep -c '^\[resources\] ') samples, expected 3"
fi

# The sampler is started with `&` inside the build step, so it must not outlive
# that step: an orphan holds the step's stdout pipe open and the runner waits on
# the pipe. The EXIT trap covers an ordinary failure; only this check covers the
# case that actually happened in run 34259552358, where the caller was SIGKILLed
# and never ran a trap.
orphan="$(RESOURCE_MONITOR_PARENT_PID=999999 RESOURCE_MONITOR_INTERVAL_SECONDS=0 bash "$MONITOR")"
if printf '%s' "$orphan" | grep -q 'caller 999999 is gone: stopping'; then
  pass "loop mode stops once its caller is gone instead of orphaning"
else
  fail "loop mode did not stop for a dead caller: $orphan"
fi

# The warnings are the part a human greps for when the job log is 10k lines.
warn_disk="$(RESOURCE_MONITOR_LOW_DISK_MB=999999999 bash "$MONITOR" sample)"
if printf '%s' "$warn_disk" | grep -q 'LOW-DISK'; then
  pass "a free-space reading below the threshold is flagged LOW-DISK"
else
  fail "no LOW-DISK flag at a threshold of 999999999MB: $warn_disk"
fi

warn_mem="$(RESOURCE_MONITOR_LOW_MEM_MB=999999999 bash "$MONITOR" sample)"
if printf '%s' "$warn_mem" | grep -q 'LOW-MEM'; then
  pass "an available-memory reading below the threshold is flagged LOW-MEM"
else
  fail "no LOW-MEM flag at a threshold of 999999999MB: $warn_mem"
fi

quiet="$(RESOURCE_MONITOR_LOW_DISK_MB=0 RESOURCE_MONITOR_LOW_MEM_MB=0 bash "$MONITOR" sample)"
if printf '%s' "$quiet" | grep -q 'LOW-'; then
  fail "a healthy reading was flagged: $quiet"
else
  pass "a healthy reading carries no warning"
fi

bash "$MONITOR" definitely-not-a-mode >/dev/null 2>&1
if [ "$?" = "2" ]; then
  pass "an unknown mode exits 2 instead of silently sampling"
else
  fail "an unknown mode did not exit 2"
fi

# --- 2/3. the two full-chain jobs ---------------------------------------------

python3 - "$WORKFLOW" <<'PY'
import re, sys

text = open(sys.argv[1]).read()
starts = [(m.start(), m.group(1)) for m in re.finditer(r'^  ([a-zA-Z][a-zA-Z0-9_-]*):\n', text, re.M)]
starts.append((len(text), '__END__'))
jobs = {}
for i in range(len(starts) - 1):
    start, name = starts[i]
    jobs[name] = text[start:starts[i + 1][0]]

failures = 0


def check(ok, label):
    global failures
    if ok:
        print(f"PASS: {label}")
    else:
        print(f"FAIL: {label}", file=sys.stderr)
        failures += 1


# The step that builds the whole chain, per job. Named explicitly: a rename
# that moves the chain into a different step should fail here rather than
# quietly leave the build unmonitored.
CHAIN_STEP = {
    'pr-test-full': 'Build full chain (JS -> essentials -> languages -> full)',
    'pr-test-dind': 'Build base box for dind variant',
}

for job, step_name in CHAIN_STEP.items():
    block = jobs.get(job)
    if block is None:
        check(False, f"job '{job}' is defined")
        continue

    check(
        re.search(r'^ +tool-cache: true$', block, re.M) is not None,
        f"{job} reclaims the tool cache it never uses",
    )
    check(
        re.search(r'^ +swap-storage: false$', block, re.M) is not None,
        f"{job} keeps the runner's swap",
    )
    check(
        re.search(r'^ +tool-cache: false$', block, re.M) is None
        and re.search(r'^ +swap-storage: true$', block, re.M) is None,
        f"{job} has no free-disk-space step still using the old settings",
    )

    # `docker build` in these jobs logs `building with "default" instance using
    # docker driver` on every one of its 14 invocations (run 34259552358), so a
    # buildx builder here is booted, never used, and contradicts this
    # workflow's own documented policy of not using the docker-container driver
    # in pr-test-* (issue #82, commit f3308dd).
    check(
        'setup-buildx-resilient' not in block and 'setup-buildx-action' not in block,
        f"{job} does not boot a buildx builder that `docker build` ignores",
    )

    step = re.search(
        r'\n      - name: ' + re.escape(step_name) + r'\n(.*?)(?=\n      - name: |\Z)',
        block,
        re.S,
    )
    if step is None:
        check(False, f"{job} has a step named '{step_name}'")
        continue
    body = step.group(1)
    check(
        'scripts/ci/resource-monitor.sh &' in body,
        f"{job} samples resources from inside '{step_name}'",
    )
    check(
        'RESOURCE_MONITOR_PID' in body and 'trap ' in body,
        f"{job} stops the sampler when '{step_name}' ends",
    )

sys.exit(1 if failures else 0)
PY
if [ "$?" = "0" ]; then
  PASS=$((PASS + 1))
  echo "PASS: pr-tests.yml full-chain jobs carry the headroom and the sampler"
else
  FAIL=$((FAIL + 1))
  echo "FAIL: pr-tests.yml full-chain jobs do not carry the headroom and the sampler"
fi

echo
echo "================ issue #119 CI resource headroom ================"
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "All checks passed."
