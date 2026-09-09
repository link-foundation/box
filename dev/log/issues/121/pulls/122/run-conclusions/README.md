# Can a run's colour hide a job that did not succeed?

Collected 2026-09-09 for issue #121, over the 200 most recent workflow runs of
`link-foundation/box` (2026-09-06T01:51:06Z .. 2026-09-09T08:00:53Z).

| run conclusion | count |
| --- | --- |
| success | 174 |
| failure | 16 |
| cancelled | 10 |

Reproduce:

```bash
gh api "repos/link-foundation/box/actions/runs?per_page=100&page=1" \
  --jq '.workflow_runs[] | {id,name,conclusion,head_sha,head_branch,created_at,run_attempt}'
# ... page=2, then fetch /jobs for each run and compare the two levels
```

## What the survey answers

**No run concluded `success` while holding a job that did not succeed.** The
green half of the pipeline does not lie.

**One run in 200 concluded something other than `failure` while holding a
`failure`** (`non-failure-runs-holding-a-failed-job.txt`):

```
RUN 34259552358 concl=cancelled wf='Build and Release Docker Image' branch=issue-119-5b52de22aaee sha=6c05795 attempt=2
   FAILED JOB: pr-tests / pr-test / dind-full
   cancelled : pr-tests / pr-test / full
```

`dind-full` failed at 20:34:56Z on its own; the run was cancelled at 21:00:52Z,
26 minutes later. GitHub ranks a cancellation above a failure when it folds job
conclusions into a run conclusion, so the run came out grey.

That run *was* superseded — `6c05795` was two commits behind the pull request's
head — so grey was a defensible colour for it. The point is that nothing in the
colour said which of the two it was, and the run had already spent a real job
failure to say the other thing.

## Every cancelled job in the sample

`every-cancelled-job.txt` lists all of them. All ten cancelled runs are
supersedes: whole runs stopped at once by `scripts/ci/supersede.sh`, with the
jobs that had already finished keeping their own conclusions. Not one job was
cancelled on its own.

This is the measurement behind the gate's `if: ${{ !cancelled() }}`. A
workflow-level cancellation is somebody's decision — automation's or a human's —
and turning those ten runs red would have been ten false positives, which is the
opposite of what issue #121 asks for. `cancelled()` is a run-level predicate, so
the cases with no such excuse still reach the gate: a job killed by
`timeout-minutes`, or one of this repository's 14 per-job
`concurrency: cancel-in-progress` groups firing. Neither appears in this sample,
which is why the gate is written as a guard rather than as a fix for a
recurring event.
