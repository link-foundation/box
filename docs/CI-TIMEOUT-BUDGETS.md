# CI Timeout Budgets

`timeout-minutes` is a backstop, never the deadline.

Adapted from the reference template's
[docs/CI-TIMEOUT-BUDGETS.md](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/blob/main/docs/CI-TIMEOUT-BUDGETS.md),
with the numbers re-measured against this repository and one addition the
template does not need — [per matrix leg](#per-leg-sizing).

## Why a backstop is not enough

GitHub reports a job killed by `timeout-minutes` as **cancelled**, not
**failed**. Three things follow, and each of them is a way for a real failure
to go unreported:

1. **A cancelled run is grey, not red.** One cancellation outranks any number
   of failures in a run's conclusion, so anything reading the run rather than
   its jobs — the badge, `gh run list` — sees "no verdict" where it should see
   "something broke". Measured here: run
   [34259552358](https://github.com/link-foundation/box/actions/runs/34259552358)
   finished `cancelled` while `pr-test / dind-full` inside it had `failure`.
2. **A cancelled job stops where it stands.** The steps that would have run
   `if: always()` or `if: !cancelled()` — the resource summaries, the log
   uploads, `links.yml`'s recovery pass that tells a false positive from a real
   broken link — do not run. The evidence about the overrun dies with the job.
3. **The annotation names nothing.** "The job has exceeded the maximum
   execution time of 90m0s" does not say which step, which deadline, or by how
   much.

[`scripts/ci/check-pipeline-status.sh`](../scripts/ci/check-pipeline-status.sh)
already fixes the first of those, and more strictly than the template does: a
cancelled job turns the run red whenever the run is still the head of its
branch. But a gate can only report what it was told, and what it is told is
"`pr-test / full` was cancelled". Points 2 and 3 need the deadline to belong to
the step.

## The rule

Every long step owns an explicit budget, and every budget expires before the
job's backstop fires.

- **`run:` steps** wrap their command in
  [`scripts/ci/run-with-budget-warning.sh`](../scripts/ci/run-with-budget-warning.sh):

  ```yaml
  - name: Test JS box
    run: |
      bash scripts/ci/run-with-budget-warning.sh 180 "JS box tests" \
        bash scripts/ci/test-box.sh js box-js
  ```

  A step has to *be* a command for this to be possible, which is why the five
  inline build blocks in `pr-tests.yml` became
  [`scripts/ci/build-chain.sh`](../scripts/ci/build-chain.sh). A seventy-line
  inline block cannot own a budget; it also drifts, and those five copies had
  already disagreed about what to call the image they built.

- **`uses:` steps** cannot be wrapped, so they declare a step-level
  `timeout-minutes`. An exhausted *step* budget fails the step and names it;
  only an exhausted *job* cap cancels the job.

  ```yaml
  - name: Build and push
    timeout-minutes: 20
    uses: docker/build-push-action@v7
  ```

  A step made of a dozen short commands with no single command to wrap — the
  dind smoke tests — takes the same treatment.

## What the wrapper does

`bash scripts/ci/run-with-budget-warning.sh SECONDS LABEL COMMAND [ARG...]`

- Runs the command in its own **process group** (`set -m`). A `docker build`
  leaves a CLI, a BuildKit session and whatever the build spawned; killing only
  the direct child leaves those holding the runner, which is also why
  `timeout(1)` is not sufficient.
- Emits `::warning` at 70% of the budget, while the overrun can still be acted
  on rather than only reported.
- On expiry emits `::error title=<label> exceeded its execution budget::…`,
  sends `SIGTERM` to the group, waits a grace period, then `SIGKILL`.
- Exits **124** on termination, matching `timeout(1)`; otherwise passes the
  command's own exit status through unchanged.

Overrides: `BUDGET_WARN_PERCENT` (70), `BUDGET_GRACE_SECONDS` (10),
`BUDGET_POLL_SECONDS` (1).

## The invariant

A budget only reports the overrun if it expires *before* the job cap cancels
the job. A budget equal to its cap is a check that can never fire — the run
goes grey again, and the check that was supposed to prevent that reports
nothing. So
[`scripts/ci/check-timeout-budgets.mjs`](../scripts/ci/check-timeout-budgets.mjs)
asserts, for every job in every workflow, that

- each individual budget is at most **70%** (`MAX_BUDGET_SHARE_PERCENT`) of the
  job's `timeout-minutes`, and
- the budgets that can run **together** in one job total at most 70% of that
  cap, leaving headroom for the unbudgeted work on the same clock — checkout,
  the free-disk-space reclaim, the swap file, the image pulls.

"Together" is the concurrent total, not a plain sum: steps under mutually
exclusive `if:` conditions cannot both run, and charging `pr-test-dind` for all
fourteen variants at once would be a failure no run can produce. The check adds
the unconditional budgets and the largest single condition group. It is
deliberately an under-approximation — see the comment at the summing step for
what it can miss and why the 30% headroom covers it.

Two more rules the same check enforces:

- **A job with no `timeout-minutes` at all fails**, except a job whose only
  content is `uses:` — GitHub rejects the key on a reusable-workflow caller, so
  flagging it would be a finding nobody could act on. Those jobs' budgets live
  in the called workflow, which is checked on its own.
- **A budget the check cannot read is a failure of the check** (exit 2), not a
  pass. "I could not find a number" must never be recorded as "the number is
  fine".

### Per-leg sizing

This repository sizes caps *and* budgets per matrix leg — the full box gets 90
minutes where a language box gets 60:

```yaml
timeout-minutes: ${{ matrix.variant == 'full' && 90 || 60 }}
env:
  BUDGET_SECONDS: ${{ matrix.variant == 'full' && 3000 || 1350 }}
```

A checker that could only take a worst case would read 3000s against a
60-minute cap and report a violation no leg can incur. So the check enumerates
`strategy.matrix`, substitutes each leg, and evaluates the expression — the
same restricted grammar for `timeout-minutes` and for step `if:` conditions.
The failure then names the leg: `pr-test-dind [variant=js]`.

## Current budgets

Every cap below is sized from measurement, not from caution. `Slowest` is the
longest that job has ever taken to succeed, from
`scripts/ci/measure-job-durations.sh`; `Was` is the cap it carried before issue
#121.

### Pull-request tests (`pr-tests.yml`)

| Job                      | Slowest | Was | Cap | Step budgets                     | Share |
| ------------------------ | ------- | --- | --- | -------------------------------- | ----- |
| `pr-test-version-policy` | 1.1 min | 15  | 10  | —                                | —     |
| `pr-test-js`             | 7.9     | 30  | 20  | build 600s, test 180s            | 65%   |
| `pr-test-essentials`     | 6.5     | 30  | 20  | build 600s, test 180s            | 65%   |
| `pr-test-language`       | 20.4    | 45  | 45  | build 1500s, test 300s           | 67%   |
| `pr-test-full`           | 43.0    | 90  | 90  | build 3000s, test 600s           | 67%   |
| `pr-test-dind` (full)    | 43.4    | 90  | 90  | chain 3000s, image 300s, test 5m | 67%   |
| `pr-test-dind` (other)   | 20.2    | 60  | 60  | chain 1350s, image 300s, test 5m | 54%   |

The two 90-minute caps stay: `full` and `dind-full` build JS, essentials,
eleven language images and the full box on one runner, and at 43 minutes
measured they have the least headroom of anything here. What changed is that
their long steps now report their own overruns.

### Release (`release-*.yml`)

| Job                       | Slowest  | Was | Cap | Step budget | Share |
| ------------------------- | -------- | --- | --- | ----------- | ----- |
| `build-js-amd64`          | 16.1 min | 120 | 45  | 20 min      | 44%   |
| `build-js-arm64`          | 5.4      | 120 | 45  | 20 min      | 44%   |
| `build-essentials-amd64`  | 10.3     | 120 | 45  | 20 min      | 44%   |
| `build-essentials-arm64`  | 5.4      | 120 | 45  | 20 min      | 44%   |
| `build-languages-amd64`   | 18.5     | 45  | 45  | 25 min      | 56%   |
| `build-languages-arm64`   | 13.2     | 45  | 45  | 25 min      | 56%   |
| `docker-build-push`       | 35.6     | 120 | 90  | 40 min      | 56%   |
| `docker-build-push-arm64` | 30.8     | 120 | 90  | 40 min      | 44%   |
| `build-dind-amd64`        | 19.2     | 30  | 40  | 20 min      | 50%   |
| `build-dind-arm64`        | 13.7     | 45  | 45  | 20 min      | 44%   |
| every `*-manifest`        | < 1      | 15  | 10  | —           | —     |

`build-dind-amd64` is the one cap that went **up**. Its slowest leg, the `full`
variant at 19.2 minutes, was already at 64% of the 30-minute cap it carried —
close enough that a slower-than-usual run would have been cancelled and
reported as a mystery rather than as a slow build.

### Everything else

| Job                              | Slowest  | Was | Cap | Step budget          | Share |
| -------------------------------- | -------- | --- | --- | -------------------- | ----- |
| `security / codeql`              | 1.3 min  | 30  | 15  | analyze 10 min       | 67%   |
| `security / secretlint`          | 0.3      | 10  | 10  | 180s + 120s          | 50%   |
| `links / link-checker`           | 0.7      | 10  | 10  | lychee 5 min         | 50%   |
| `scripts / experiments`          | 1.9      | 20  | 20  | every suite 600s     | 50%   |
| `measure-disk-space`             | 23.3     | 180 | 60  | measurement 2400s    | 67%   |

`measure-disk-space` carried `timeout-minutes: 180  # 3 hours max for full
installation measurement` — a number with a justification attached that nobody
had ever checked against a run. No successful run in the workflow's history has
taken longer than 23.3 minutes.

## Re-measuring

Before changing a cap, measure the job:

```bash
bash scripts/ci/measure-job-durations.sh pr-tests.yml 50
```

Only successful jobs are sampled: a cancelled job's duration says how long
something waited, and a failed job usually stopped early. The tables above were
produced this way and the raw samples are in
`dev/log/issues/121/pulls/122/analysis/`.

## Testing

`experiments/test-issue121-timeout-budgets.sh` — 39 offline assertions covering
the wrapper (overrun reported as a failure with the label and the budget,
process-group kill, exit-status pass-through, the 70% warning, usage errors),
the checker (each fixture in a passing and a failing form), per-leg evaluation,
and `build-chain.sh`.
