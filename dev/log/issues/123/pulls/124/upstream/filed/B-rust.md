`run-with-budget-warning.sh` reports a command as finished while its own children keep running, and the survivors hold the step open until `timeout-minutes` cancels the job

### Summary

Two defects, one measurement. Both make the wrapper produce the outcome it exists to prevent: a job reported `cancelled` by `timeout-minutes` instead of a step reported `failure` by its own budget.

1. **Liveness is asked of the wrapper, not of the work.** The poll loop watches a pid that dies when the *root* of the command returns. `npm test`, `pytest -n`, `cargo nextest`, `docker build` and every `sudo`-wrapped script leave workers behind; the wrapper reports "finished in Ns of its Ns budget (exit 0)" while they are still running.
2. **The survivors own the step's stdout.** The wrapper lends the command its own stdout, so anything left behind inherits it. Under `run: … | tee log` — or any pipeline, which is how a CI step gets a log file — the pipe never reaches EOF, so the *step* does not end when the wrapper does. The job's `timeout-minutes` backstop kills it, and GitHub reports that as `cancelled`.

There is a third case inside the first, which is what we actually hit: **`kill -0` cannot distinguish "alive, not yours to signal" from "gone"**. Both are exit status 1 (EPERM and ESRCH). A `sudo`-started child has real uid 0, so the wrapper — running as `runner` — reads a live root process as dead, skips the SIGKILL escalation, and exits 124 believing it terminated the command.

### The code

`scripts/run-with-budget-warning.sh:83-106` @ `f63a061f`

```bash
set -m
"$@" &
command_pid=$!
set +m

# Signal the whole process group when possible, and fall back to the direct
# child on platforms where the group is not addressable (Git Bash on Windows).
signal_tree() {
  kill "-$1" -- "-${command_pid}" 2>/dev/null || kill "-$1" "${command_pid}" 2>/dev/null || true
}

forward() {
  signal_tree TERM
  exit 143
}
trap forward TERM INT

# Elapsed time comes from the shell's own $SECONDS clock, not from counting
# poll iterations: a fractional or variable poll interval must not change when
# the budget expires, and it cannot make the count drift from real time.
started=$SECONDS
warned=false
timed_out=false
while kill -0 "${command_pid}" 2>/dev/null; do
```

`set -m` does give the command its own process group, but liveness is then asked of `$command_pid` alone — the **root** of the command. When the root returns while its workers keep going, `kill -0 "$command_pid"` fails and the loop ends: the group the `set -m` was for is never polled. And `kill -0` could not answer for a root-owned survivor anyway — EPERM ("alive, not yours to signal") and ESRCH ("gone") are both exit status 1.

### Reproduction

No CI, no Docker, 5-second budget. `experiments/issue-123/repro-budget-survivor.sh` (attached below, ~45 lines) wraps a command that returns immediately and leaves one worker behind — the shape of every test runner and every build tool:

```bash
cat > command.sh <<'CMD'
#!/usr/bin/env bash
sh -c 'sleep 60' $marker &          # the worker
echo "root of the command is exiting while its worker keeps running"
exit 0
CMD

# 1. what the wrapper reports
BUDGET_POLL_SECONDS=1 bash scripts/run-with-budget-warning.sh 5 "worker probe" bash command.sh
pgrep -f "$marker"                  # the worker, still running

# 2. the same command in a pipeline, which is how a CI step is written
timeout 20 bash -c "bash scripts/run-with-budget-warning.sh 5 'worker probe' bash command.sh 2>&1 | tee step.log >/dev/null"
echo "exit=$?"                      # 124: the step never ended
```

Measured against `rust` at `f63a061fb3e23e647de0455886528a121b997678`:

```
### /tmp/templates/rust/scripts/run-with-budget-warning.sh, budget 5s
wrapper exit=0 after 1s
    root of the command is exiting while its worker keeps running
surviving worker pids: 165331 
### the same command in a pipeline, which is how a CI step is written
pipeline exit=124 after 20s (124 = the step never ended)
```

Read the second half as the CI outcome: the step is still open 20 s after a command with a 5 s budget was declared finished. In a job it stays open until `timeout-minutes` fires, and the run goes grey.

For contrast, the same script against our fixed wrapper, same fixture, same fictional worker:

```
### scripts/ci/run-with-budget-warning.sh, budget 5s
wrapper exit=0 after 0s
    Running worker probe with a 5s budget (warning at 3s).
    root of the command is exiting while its worker keeps running
    worker probe finished in 0s of its 5s budget (exit 0).
surviving worker pids: 165381 
### the same command in a pipeline, which is how a CI step is written
pipeline exit=0 after 0s (124 = the step never ended)
```

The worker still survives — that is the fixture's job — but it no longer holds the step, so the pipeline closes at once and the step's own exit status is what the job sees.

### What it looks like in production

`link-foundation/box` run [34366975927](https://github.com/link-foundation/box/actions/runs/34366975927), job `Measure Component Disk Space`, 14:56:53 → 15:57:09. The tree was

```
wrapper (uid runner) -> sudo (real uid runner) -> measure-disk-space.sh (root) -> apt-get (root)
```

and the annotations were:

```
15:37:47  error    disk space measurement did not finish within its 2400s budget and was terminated.
15:57:08  failure  The job has exceeded the maximum execution time of 1h0m0s
15:57:09  failure  The operation was canceled.
```

The wrapper announced a termination at 2400 s that it had not performed — `sudo` relayed its SIGTERM to the script it started, but that script's children have real uid 0 and are neither `sudo`'s to relay to nor the wrapper's to signal — and the job then ran on for another **19m21s** because `apt-get` had inherited the step's stdout, which was the pipe into `tee`. A step that owns its budget produced a grey run 19 minutes late.

### Workaround

Give the command a stdout that is not the step's, so a survivor cannot hold the step open. This costs live log streaming and nothing else:

```yaml
- name: Long step
  run: |
    status=0
    bash scripts/run-with-budget-warning.sh 2400 "label" ./work.sh >step.log 2>&1 || status=$?
    cat step.log
    exit "$status"
```

A survivor then inherits the file descriptor for `step.log`, not the pipe the runner is reading, so the step ends when the wrapper does. It does not fix the liveness half — the budget can still report a termination it did not perform — for which there is no cheap workaround; that needs the fix below.

### Suggested fix

Three changes, all of which we now run in `link-foundation/box` ([`scripts/ci/run-with-budget-warning.sh`](https://github.com/link-foundation/box/blob/main/scripts/ci/run-with-budget-warning.sh)):

**1. Ask the process table, not `kill -0`.** Permission and existence are different questions; `ps` answers the second one for processes you cannot signal. Zombies are excluded — an exit status waiting to be collected is not work still being done:

```bash
group_members() {
  ps -eo pgid=,pid=,stat=,user=,args= 2>/dev/null \
    | awk -v group="${command_pid}" '$1 == group && $3 !~ /^Z/ {
        pid = $2; user = $4
        $1 = ""; $2 = ""; $3 = ""; $4 = ""
        sub(/^ +/, "")
        printf "%s %s %s\n", pid, user, $0
      }'
}

group_is_populated() {
  if [ "${have_ps}" = true ]; then
    [ -n "$(group_members)" ]
  else
    kill -0 -- "-${command_pid}" 2>/dev/null   # Git Bash on Windows: no usable ps
  fi
}
```

**2. Escalate with the privilege a runner can borrow, and name what survived.** A GitHub-hosted runner has passwordless `sudo`, which is exactly the privilege needed to signal the root children `sudo` left behind. When survivors remain after a signal, send it again as root; if any are still there at the end, say so in an `::error` instead of claiming a termination:

```bash
signal_command() {
  local signal="$1"
  kill "-${signal}" -- "-${command_pid}" 2>/dev/null || kill "-${signal}" "${command_pid}" 2>/dev/null || true
  if group_is_populated && can_sudo_kill; then
    sudo -n kill "-${signal}" -- "-${command_pid}" 2>/dev/null || sudo -n kill "-${signal}" "${command_pid}" 2>/dev/null || true
  fi
}

report_survivors() {
  local survivors; survivors="$(group_members)"
  [ -n "${survivors}" ] || return 0
  echo "::error title=${label} left processes running::${label} could not be terminated. Still running: $(echo "${survivors}" | tr '\n' ';')"
}
```

**3. Relay the command's output instead of lending it the step's stdout.** This is the part that makes a survivor harmless: whatever it holds open, it is not the runner's pipe. Capture to two files, and copy new bytes out on each poll:

```bash
{ "$@"; printf '%s\n' "$?" >"${status_file}.partial"; mv "${status_file}.partial" "${status_file}"; } \
  >"${stdout_file}" 2>"${stderr_file}" &

relay_output() {
  local size
  size="$(stream_size "${stdout_file}")"
  if [ "${size}" -gt "${stdout_offset}" ]; then
    emit_range "${stdout_file}" "${stdout_offset}" "${size}"
    stdout_offset="${size}"
  fi
  … the same for stderr, to stderr …
}
```

Worth keeping in mind while implementing it:

- **stdout and stderr have to be relayed separately**, so a caller redirecting one of them still gets what it asked for. Interleaving between the two streams can shift by up to one poll interval; order *within* each stream stays exact.
- **Read a bounded range, not to end of file** (`tail -c +N | head -c M`), so the offset advances to exactly what was emitted.
- **Make it switchable** (we use `BUDGET_CAPTURE_OUTPUT`, default on) for a command that needs the real descriptor — a progress bar calling `isatty`, say, though nothing in CI has a tty to begin with.
- **Completion still has to come from a status file**, not from the process table: a finished child stays visible as a zombie until it is reaped.

### Relation to earlier work

Follow-up to [rust#153](https://github.com/link-foundation/rust-ai-driven-development-pipeline-template/issues/153). That fix moved liveness from `wait` to a poll on the process group and is a genuine improvement; what it does not cover is a command whose root *exits* while its children continue, and the output inheritance that turns any survivor into a hung step.

Found while auditing every CI/CD false positive and false negative in `link-foundation/box` ([box#123](https://github.com/link-foundation/box/issues/123)), which compares this template's full workflow and script tree against ours. Reproduced identically in the js, python, rust and php templates — all four report `exit=124 after 20s` on the pipeline case — and reported in each.
