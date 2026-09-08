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
# The sampler then reported, in run 34278116323 (job 102247036552), during the
# full box's `#64 exporting layers`:
#
#   [resources] 22:13:04 disk /=59711MB used /  87993MB free | mem  2323MB used ... swap    0MB used of 3071MB
#   [resources] 22:17:34 disk /=59769MB used /  87934MB free | mem 15723MB used /  265MB available of 15989MB | swap 3071MB used of 3071MB LOW-MEM
#   ##[error]Process completed with exit code 143.
#
# 11 MB of disk consumed and 88 GB still free, against 2.3 GB -> 18.8 GB of
# committed memory still climbing when the runner went down: the export runs
# out of memory, not disk (docker/buildx#1606, open since Docker 23.0). So two
# more invariants, which are the fix rather than the diagnosis:
#
#   4. scripts/ci/ensure-swap.sh turns idle disk into swap, decides out loud,
#      refuses to eat the disk the build itself needs, and never fails the job
#      for a headroom it could not get.
#   5. Both full-chain builds run it first - the dind matrix only for the
#      `full` variant, the one that builds the full box - and the `full`
#      variant gets a timeout that fits an export that is paging.
#
# Usage: bash experiments/test-issue119-ci-resource-headroom.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONITOR="$ROOT/scripts/ci/resource-monitor.sh"
ENSURE_SWAP="$ROOT/scripts/ci/ensure-swap.sh"
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

for required in "$MONITOR" "$ENSURE_SWAP" "$WORKFLOW"; do
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
for field in 'disk /=' 'MB free' 'mem ' 'MB available of' 'swap ' 'top '; do
  if printf '%s' "$out" | grep -q -- "$field"; then
    pass "sample reports '$field'"
  else
    fail "sample is missing '$field': $out"
  fi
done

# "Memory ran out" and "this process took it" are different findings, and only
# the second one points at anything: the sample has to name the consumer, with
# a size, or the next post-mortem is back to guessing between dockerd, the
# build client and the runner agent.
top_one="$(RESOURCE_MONITOR_TOP_PROCESSES=1 bash "$MONITOR" sample)"
if printf '%s' "$top_one" | grep -qE '\| top [^ ,]+=[0-9]+MB'; then
  pass "sample names the biggest process by resident memory, with a size"
else
  fail "sample does not name a process: $top_one"
fi

# Count inside the `top` field only: the rest of the line is full of megabytes
# too, and a check that counts those would pass on a field that names nobody.
named() {
  printf '%s' "$1" | sed 's/.*| top //; s/ .*//' | tr ',' '\n' | grep -c '=[0-9]*MB'
}

if [ "$(named "$top_one")" = "1" ]; then
  pass "RESOURCE_MONITOR_TOP_PROCESSES bounds how many processes are named"
else
  fail "asked for 1 process, got: $top_one"
fi

top_three="$(RESOURCE_MONITOR_TOP_PROCESSES=3 bash "$MONITOR" sample)"
if [ "$(named "$top_three")" = "3" ]; then
  pass "three processes are named when three are asked for"
else
  fail "asked for 3 processes, got: $top_three"
fi

# The list must stay a single field: a process name carrying a space or a comma
# would otherwise split the line and break every log grep built on it.
if [ "$(printf '%s\n' "$top_three" | grep -c '^\[resources\] ')" = "1" ]; then
  pass "the process list stays on the one [resources] line"
else
  fail "the process list broke the line: $top_three"
fi

off="$(RESOURCE_MONITOR_TOP_PROCESSES=0 bash "$MONITOR" sample)"
if printf '%s' "$off" | grep -q '| top ?'; then
  pass "RESOURCE_MONITOR_TOP_PROCESSES=0 reports '?' rather than an empty field"
else
  fail "disabling the process list produced: $off"
fi

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

# --- 4. the swap the export grows into -----------------------------------------

# `plan` exists so this can be checked at all: provisioning needs root, and a
# test that needs root is a test that does not run. Every input and the decision
# taken from it are on the output, because a plan that hides what it acted on is
# not reviewable after the fact.
plan="$(ENSURE_SWAP_TARGET_MB=32768 ENSURE_SWAP_RESERVE_MB=0 bash "$ENSURE_SWAP" plan)"
if printf '%s' "$plan" | grep -q '^\[ensure-swap\] plan: current=[0-9]*MB target=32768MB'; then
  pass "plan mode prints the reading it decided on"
else
  fail "plan mode printed: $plan"
fi

if printf '%s' "$plan" | grep -qE '^\[ensure-swap\] decision: allocate [0-9]+MB at '; then
  pass "plan mode names the size and the file it would allocate"
else
  fail "plan mode took no decision: $plan"
fi

# The whole point is to spend disk on memory, and the build needs ~60 GB of
# that disk for the chain plus ~25 GB more to export the full box into. A
# swapfile that takes the disk the build needs would trade one SIGKILL for a
# `no space left on device`, so the reserve is not advice.
guard="$(ENSURE_SWAP_RESERVE_MB=999999999 bash "$ENSURE_SWAP" plan)"
if printf '%s' "$guard" | grep -q '^\[ensure-swap\] decision: skip'; then
  pass "a reserve that cannot be met means no swapfile, not a smaller disk"
else
  fail "the reserve guard did not hold: $guard"
fi

ENSURE_SWAP_RESERVE_MB=999999999 bash "$ENSURE_SWAP" plan >/dev/null 2>&1
if [ "$?" = "0" ]; then
  pass "declining to provision is not a job failure"
else
  fail "the reserve guard failed the caller instead of declining"
fi

# Called twice - which is what a re-run does - it must not stack a second
# swapfile on top of the first.
enough="$(ENSURE_SWAP_TARGET_MB=1 bash "$ENSURE_SWAP" plan)"
if printf '%s' "$enough" | grep -q 'already meets the 1MB target'; then
  pass "swap that already meets the target is left alone"
else
  fail "a met target still produced: $enough"
fi

# `provision` is the default because the workflow calls it with no argument; a
# typo must not silently become one of the two real modes.
bash "$ENSURE_SWAP" definitely-not-a-mode >/dev/null 2>&1
if [ "$?" = "2" ]; then
  pass "an unknown ensure-swap mode exits 2 instead of provisioning"
else
  fail "an unknown ensure-swap mode did not exit 2"
fi

if grep -q 'ENSURE_SWAP_TARGET_MB:-32768' "$ENSURE_SWAP"; then
  pass "the default target is the 32 GB the measured 18.8 GB peak needs room above"
else
  fail "the default swap target changed without this fixture noticing"
fi

# --- 4b. what ensure-swap.sh actually does, with the privileged parts stubbed --
#
# `plan` covers the arithmetic; this covers the sequence, which is where an
# unattended script goes wrong. mkswap on a file that was never allocated,
# swapon on a file that was never mkswap-ed, or a `sudo` that prompts and hangs
# are all silent in `plan` mode and fatal in a job. The stubs below are the only
# way to see them without root, so they record what the script called, in order.

make_swap_stubs() {
  local dir="$1"
  mkdir -p "$dir"

  cat >"$dir/free" <<'STUB'
#!/usr/bin/env bash
echo "              total        used        free      shared  buff/cache   available"
echo "Mem:           15989        2323        1000          18        12666       13665"
echo "Swap:          ${STUB_SWAP_TOTAL_MB:-3071}           0        ${STUB_SWAP_TOTAL_MB:-3071}"
STUB

  cat >"$dir/df" <<'STUB'
#!/usr/bin/env bash
echo "Filesystem 1048576-blocks Used Available Capacity Mounted on"
echo "/dev/root 147703 29000 ${STUB_FREE_MB:-118000} 20% /"
STUB

  # `sudo -n` is what the script uses; the stub strips it so the rest of the
  # command line is checked exactly as it will run on the runner.
  cat >"$dir/sudo" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "-n" ] && shift
exec "$@"
STUB

  cat >"$dir/fallocate" <<'STUB'
#!/usr/bin/env bash
echo "fallocate $*" >>"$STUB_LOG"
[ "${STUB_FALLOCATE_RC:-0}" = "0" ] || exit "$STUB_FALLOCATE_RC"
: >"${!#}"
STUB

  cat >"$dir/dd" <<'STUB'
#!/usr/bin/env bash
echo "dd $*" >>"$STUB_LOG"
for arg in "$@"; do
  case "$arg" in of=*) : >"${arg#of=}" ;; esac
done
STUB

  cat >"$dir/mkswap" <<'STUB'
#!/usr/bin/env bash
echo "mkswap $*" >>"$STUB_LOG"
[ -f "${!#}" ] || echo "mkswap-on-missing-file" >>"$STUB_LOG"
exit "${STUB_MKSWAP_RC:-0}"
STUB

  # Two jobs in one binary, exactly as util-linux has it: report what is active,
  # and activate. The counter is what lets a run refuse the first swapon and
  # accept the second, which is the case the dd fallback exists for.
  cat >"$dir/swapon" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  --show*)
    [ "${STUB_ACTIVE:-0}" = "1" ] && echo "$ENSURE_SWAP_FILE"
    exit 0
    ;;
esac
echo "swapon $*" >>"$STUB_LOG"
count=0
[ -f "$STUB_LOG.swapons" ] && count="$(cat "$STUB_LOG.swapons")"
count=$((count + 1))
echo "$count" >"$STUB_LOG.swapons"
if [ "${STUB_SWAPON_REFUSALS:-0}" -ge "$count" ]; then
  echo "swapon: swapfile has holes" >&2
  exit 255
fi
exit 0
STUB

  chmod +x "$dir"/*
}

STUB_DIR="$(mktemp -d)"
make_swap_stubs "$STUB_DIR/bin"
trap 'rm -rf "$STUB_DIR"' EXIT

# Every scenario gets its own log and its own swapfile path, so one scenario
# cannot make the next one pass.
run_ensure_swap() {
  local name="$1"
  shift
  STUB_LOG="$STUB_DIR/$name.log"
  : >"$STUB_LOG"
  rm -f "$STUB_LOG.swapons"
  env PATH="$STUB_DIR/bin:$PATH" STUB_LOG="$STUB_LOG" \
    ENSURE_SWAP_FILE="$STUB_DIR/$name.swap" \
    "$@" bash "$ENSURE_SWAP" 2>&1
}

calls() { tr '\n' ' ' <"$STUB_DIR/$1.log"; }

out="$(run_ensure_swap happy)"
if printf '%s' "$out" | grep -q 'decision: allocate 29697MB'; then
  pass "3071MB of swap and 118000MB free means a 29697MB swapfile"
else
  fail "sizing against the runner's measured readings produced: $out"
fi

# mkswap before a successful allocation, or swapon before mkswap, is a swapfile
# the kernel refuses - and the script would still exit 0 and report nothing.
if [ "$(calls happy | sed 's/ [^ ]*swap / /g; s/-l [0-9]*M//; s/  */ /g')" = "fallocate mkswap swapon " ]; then
  pass "the happy path allocates, formats and enables, in that order, once each"
else
  fail "the happy path called: $(calls happy)"
fi

if printf '%s' "$out" | grep -q 'active: 3071MB of swap total'; then
  pass "the result is reported from the kernel, not assumed from the plan"
else
  fail "no post-swapon reading: $out"
fi

if ! printf '%s' "$out" | grep -q '::warning'; then
  pass "a successful provision warns about nothing"
else
  fail "the happy path warned: $out"
fi

# fallocate is instant and dd is not, which is why dd is the fallback rather
# than the default - but a fallback that is never exercised is not a fallback.
out="$(run_ensure_swap fallback STUB_FALLOCATE_RC=1)"
if printf '%s' "$(calls fallback)" | grep -q 'dd if=/dev/zero'; then
  pass "a filesystem without fallocate falls back to dd"
else
  fail "fallocate failure did not fall back: $(calls fallback)"
fi
if printf '%s' "$(calls fallback)" | grep -q 'mkswap' && ! printf '%s' "$(calls fallback)" | grep -q 'mkswap-on-missing-file'; then
  pass "the dd fallback produces a file mkswap can work on"
else
  fail "the dd fallback left nothing to format: $(calls fallback)"
fi

# The documented reason dd is kept at all: swapon rejects a preallocated file on
# some filesystems, and the answer is to rewrite it, not to give up the headroom.
out="$(run_ensure_swap refuse-once STUB_SWAPON_REFUSALS=1)"
if [ "$(printf '%s\n' "$(calls refuse-once)" | grep -o 'swapon' | wc -l)" = "2" ]; then
  pass "a swapon that refuses the preallocated file is retried"
else
  fail "swapon was not retried: $(calls refuse-once)"
fi
if printf '%s' "$(calls refuse-once)" | grep -q 'dd if=/dev/zero'; then
  pass "the retry rewrites the file with dd rather than repeating fallocate"
else
  fail "the retry did not rewrite the file: $(calls refuse-once)"
fi
if ! printf '%s' "$out" | grep -q '::warning'; then
  pass "a retry that works is not reported as a problem"
else
  fail "the successful retry still warned: $out"
fi

# And when the headroom really cannot be had, the job must still run the build:
# the failure belongs on the build, whose log explains itself, not here.
out="$(run_ensure_swap refuse-always STUB_SWAPON_REFUSALS=9)"
if printf '%s' "$out" | grep -q '::warning title=ensure-swap::'; then
  pass "swap that cannot be enabled is a warning on the job's log"
else
  fail "an unusable swapfile was silent: $out"
fi
if [ ! -e "$STUB_DIR/refuse-always.swap" ]; then
  pass "a swapfile that could not be enabled does not keep the disk it took"
else
  fail "an unusable swapfile was left on disk"
fi

# A re-run, or a second job step, must not stack a second swapfile on the first.
out="$(run_ensure_swap already STUB_ACTIVE=1)"
if printf '%s' "$out" | grep -q 'decision: skip (.*is already active)'; then
  pass "an already-active swapfile is left exactly as it is"
else
  fail "a second call did not recognise its own swapfile: $out"
fi
if [ ! -s "$STUB_DIR/already.log" ]; then
  pass "recognising it costs no fallocate, mkswap or swapon"
else
  fail "a second call still called: $(calls already)"
fi

# --- 2/3/5. the two full-chain jobs -------------------------------------------

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

    # Measuring the shortage was step one; this is the step that fixes it. It
    # has to run before the chain, because swap added after the export has
    # started is swap the export was already killed without.
    swap_step = re.search(
        r'\n      - name: [^\n]*swap[^\n]*\n(.*?)(?=\n      - name: |\Z)',
        block,
        re.S | re.I,
    )
    check(
        swap_step is not None and 'scripts/ci/ensure-swap.sh' in swap_step.group(1),
        f"{job} provisions swap before it builds the chain",
    )
    if swap_step is not None:
        check(
            block.index(swap_step.group(0)) < block.index(step.group(0)),
            f"{job} provisions that swap before, not after, '{step_name}'",
        )

# 13 of the 14 dind variants never build the full box, so the swapfile is
# gated on the one that does - and that one now spends its export paging,
# which the timeout has to allow for. A `full` variant killed at 60 minutes
# reports a timeout for a build that is making progress.
dind = jobs['pr-test-dind']
check(
    re.search(r"- name: [^\n]*swap[^\n]*\n +if: matrix\.variant == 'full'", dind) is not None,
    "pr-test-dind provisions swap only for the variant that builds the full box",
)
check(
    re.search(r"timeout-minutes: \$\{\{ matrix\.variant == 'full' && 90 \|\| 60 \}\}", dind)
    is not None,
    "pr-test-dind gives the full variant 90 minutes and the other 13 sixty",
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
