`check-pipeline-status.sh` excuses every cancellation in a superseded run, including jobs whose `cancel-in-progress` is `false` and which no supersede could have reached

### Summary

The gate asks one question about the whole run — "is this run still the head of its branch?" — and lets the answer excuse **every** cancelled job in it. A supersede cannot cancel a job that declares `concurrency.cancel-in-progress: false`; GitHub queues the new run behind it instead. So for those jobs the run-level answer is not evidence of anything, and a job killed by its own `timeout-minutes` is reported as a `::warning::` on a green run.

The two states are indistinguishable in `needs.*.result`: GitHub reports both a supersede and a `timeout-minutes` kill as `cancelled`. That is why the gate exists. But the question it asks cannot separate them, and it fails **open**.

### The code

`scripts/check-pipeline-status.sh:59-66` @ `c3a6d23b`

```bash
if [ -n "$cancelled" ]; then
  if [ "$IS_MAIN" = "true" ] && ! run_is_superseded; then
    echo "::error::Pipeline has cancelled jobs on main: ${cancelled}. A job killed by 'timeout-minutes' is reported as cancelled, which would otherwise hide the failure."
    status=1
  else
    echo "::warning::Cancelled jobs: ${cancelled}. This run is not the current head of its branch, or is not a push to the default branch, so the cancellation reads as a superseded run. A genuine overrun should surface as a step budget failure instead (see docs/CI-TIMEOUT-BUDGETS.md)."
  fi
fi
```

`run_is_superseded` compares `RUN_SHA` with the branch head (`line 14`). Nothing in it, or around it, looks at the cancelled job.

### Why the run-level question is the wrong one

`release.yml` in this template gives its release jobs a concurrency group that does **not** cancel in progress — deliberately, because a half-finished publish must not be interrupted. On the default branch the expression form (`cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}`) evaluates to `false` for exactly the same reason. For any such job:

- a supersede **cannot** produce a `cancelled` result — GitHub queues the newer run instead;
- therefore every `cancelled` result on that job is something else: `timeout-minutes`, a manual cancel, or a runner failure;
- and "the branch moved on" is true of almost any run that took longer than the interval between two pushes, so the excuse fires routinely.

The result is a false negative in the one place the gate was added to remove one.

### Reproduction

No CI needed — the gate reads its inputs from the environment. `experiments/issue-123/repro-supersede.sh` (attached below, ~30 lines) drives it directly:

```bash
export NEEDS_JSON='{"build":{"result":"success"},"measure":{"result":"cancelled"}}'
export IS_MAIN=true MAIN_BRANCH=main BRANCH_REF=main
export RUN_SHA=1111111111111111111111111111111111111111

echo "### Case A: this run is still the head of main"
BRANCH_HEAD_SHA=1111111111111111111111111111111111111111 bash scripts/check-pipeline-status.sh; echo "exit=$?"

echo "### Case B: a later commit landed while the job was timing out"
BRANCH_HEAD_SHA=2222222222222222222222222222222222222222 bash scripts/check-pipeline-status.sh; echo "exit=$?"
```

Measured against `js` at `c3a6d23b693972a70097430f01e69fcee5a51ad2`:

```
### Case A: this run is still the head of main
Failed jobs:    <none>
Cancelled jobs: measure
This run tests 1111111111111111111111111111111111111111; main is at 1111111111111111111111111111111111111111.
::error::Pipeline has cancelled jobs on main: measure. A job killed by 'timeout-minutes' is reported as cancelled, which would otherwise hide the failure.
exit=1

### Case B: a later commit landed on main while the job was timing out
Failed jobs:    <none>
Cancelled jobs: measure
This run tests 1111111111111111111111111111111111111111; main is at 2222222222222222222222222222222222222222.
::warning::Cancelled jobs: measure. This run is not the current head of its branch, or is not a push to the default branch, so the cancellation reads as a superseded run. A genuine overrun should surface as a step budget failure instead (see docs/CI-TIMEOUT-BUDGETS.md).
All required jobs succeeded or were legitimately skipped.
exit=0
```

`measure` was killed by `timeout-minutes` in both cases. In Case B the only thing that changed is that somebody else pushed, and the overrun stops being reported.

### What it looks like in production

We hit this in `link-foundation/box`, run [34366975927](https://github.com/link-foundation/box/actions/runs/34366975927). The job `Measure Component Disk Space` ran 14:56:53 → 15:57:09 and carried:

```
failure  The job has exceeded the maximum execution time of 1h0m0s
failure  The operation was canceled.
warning  (pipeline-status) measure-disk-space. This run is no longer the head of main,
         so the cancellation reads as a supersede rather than an overrun.
```

A 1h0m0s overrun, correctly annotated by the runner, and then excused by the gate — on a job whose workflow says `cancel-in-progress: false`, i.e. a job no supersede could have touched. The run concluded grey and nothing failed.

### Workaround

Until the gate can tell the two apart, make the excuse conditional on the workflow you are actually gating. If none of the gated jobs cancel in progress, delete the excuse — a `cancelled` job is then always a real failure:

```diff
-  if [ "$IS_MAIN" = "true" ] && ! run_is_superseded; then
+  if [ "$IS_MAIN" = "true" ]; then
```

That is strictly safe for `release.yml`, and it is the version we would ship if we had to pick one. For a workflow that *does* cancel in progress it trades a false negative for a false positive, which is the reason for the real fix below rather than this.

### Suggested fix: ask the question per job

The question "could a supersede have cancelled *this* job?" is answerable offline, from the workflow file the gate is running inside: read the job's effective `concurrency.cancel-in-progress`, falling back to the workflow-level `concurrency:` block, and treat everything unreadable as "no".

A cancellation is then excused only when **both** hold:

1. the run is no longer the head of its branch, **and**
2. that job's own effective `cancel-in-progress` is `true`.

We implemented this in box as `scripts/ci/read-job-cancel-in-progress.sh`, which prints one `<job><TAB><value>` line per job with `value` in `true | false | none | missing | unknown`:

```
true      the job cancels in progress, so a supersede can cancel it
false     it does not - either it says so, or it has a group with no
          cancel-in-progress key, which defaults to false
none      no concurrency at job level and none at workflow level: GitHub
          has no group to supersede this job with at all
missing   the workflow does not declare a job by that name
unknown   the value is there but is an expression this cannot evaluate
```

The two details that matter:

- **An expression is not a value.** `cancel-in-progress: ${{ ... }}` is decided by the run, not by the file, so it reads as `unknown` — and `unknown` fails closed. Guessing `true` would restore exactly the excuse this withdraws.
- **`none` is not `true`.** A job with no concurrency group at all cannot be superseded; that is the strongest case for calling the cancellation an overrun, and a naive "no `cancel-in-progress: false` found → assume cancellable" reading gets it backwards.

The gate then reports per job, and says *why* for each one:

```bash
if [ -n "$cancelled" ]; then
  superseded=no
  run_is_superseded && superseded=yes

  while IFS=$'\t' read -r job verdict reason; do
    echo "  ${job}: ${reason}"
    [ "$verdict" = supersede ] && superseded_jobs+=... || overrun_jobs+=...
  done < <(classify_cancellations "$cancelled_lines" "$superseded")

  [ -n "$superseded_jobs" ] && echo "::warning title=Cancelled jobs in a superseded run::${superseded_jobs}. …"
  if [ -n "$overrun_jobs" ]; then
    echo "::error title=Pipeline has cancelled jobs::${overrun_jobs}. No supersede accounts for these cancellations (see the reasons above)."
    status=1
  fi
fi
```

Parsing is by indentation and regex rather than through a YAML library on purpose: this runs in a gate job on a bare runner, and a gate that needs an install to answer is a gate that can fail for reasons of its own.

Full implementation, with 72 offline assertions covering every `true/false/none/missing/unknown` path and both decision halves: [`scripts/ci/read-job-cancel-in-progress.sh`](https://github.com/link-foundation/box/blob/main/scripts/ci/read-job-cancel-in-progress.sh) and [`scripts/ci/check-pipeline-status.sh`](https://github.com/link-foundation/box/blob/main/scripts/ci/check-pipeline-status.sh).

### Relation to earlier work

This is a follow-up to [js#167](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/167), which added the gate and the supersede test. That issue was right that a cancellation on `main` needs a second question before it can be excused; this one is that the second question has to be asked of the job, not of the run.

Found while auditing every CI/CD false positive and false negative in `link-foundation/box` ([box#123](https://github.com/link-foundation/box/issues/123)), which compares this template's full workflow and script tree against ours. The same defect is present in the js, python, rust and php templates, all four of which share this script; it is reported in each.
