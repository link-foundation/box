# Every annotation on the nine runs issue #123 lists

Collected with `experiments/issue-123/collect-ci-evidence.mjs` from
`/repos/link-foundation/box/check-runs/{id}/annotations` for every job of every
run, at commit `1d9fb3e`. One file per run, named by run id.

| Run | Workflow | Conclusion | Annotations |
| --- | --- | --- | --- |
| 34366975837 | Scripts | success | 0 |
| 34366975852 | Docs | success | 0 |
| 34366975873 | Workflows | success | 0 |
| 34366975927 | Measure Disk Space and Update README | **cancelled** | 5 — 3 `failure`, 2 `warning` |
| 34366975942 | Security | success | 0 |
| 34366975962 | Dockerfiles | success | 0 |
| 34366975992 | File sizes | success | 0 |
| 34366976068 | Links | success | 1 `notice` |
| 34366976358 | Build and Release Docker Image | success | 1 `failure` |

Seven annotations, against 98 on the eight runs of issue #121 — the difference
being that issue #121's work landed in `1e202f5`, the commit these nine runs
tested. What is left is one real overrun reported four different ways, one
annotation that is a `git commit` summary line, and one that lychee emits about
itself.

## 34366976358 — a `failure` annotation on a green release run

```json
{ "job_id": 102518168976, "job_name": "Apply Changesets",
  "path": ".github", "start_line": 33, "annotation_level": "failure" }
```

The message is the body of the issue-121 release commit, and the line that
produced it is in
`../ci-logs/release-34366976358/102518168976-Apply_Changesets_.log.gz`, line 266
(every log here is gzipped, because `.gitignore` excludes `*.log`; read one with
`zcat`):

```
14:57:10.9574854Z Committing version bump...
14:57:11.2322895Z ##[error]` while explaining a fix. `docker/setup-buildx-action` creates a …
14:57:11.2380481Z  2 files changed, 1 insertion(+), 40 deletions(-)
```

Between "Committing version bump…" and `git commit`'s own diffstat, so this is
`git commit` echoing the subject and body it just recorded. That body quotes
`##[error]` — it is the issue-121 release note, which explains the `##[error]`
defect — and the runner's `ActionCommand.TryParse` accepts `##[` anywhere in a
line, so the runner turned a quoted string into an annotation on a job that
succeeded.

This is the same mechanism as issue #121's 56 annotations with a different
printer: there, `docker/build-push-action` printed the commit message out of a
buildx metadata file; here, `git commit` printed it directly.

**Closed on this branch** by `4139d54`: `scripts/release/apply-changesets.sh`
routes both `git commit` calls through `run_with_commands_stopped`
(lines 162 and 164), which brackets the child's output with
`::stop-commands::<token>` / `::<token>::`. `.github/workflows/release.yml:337`
and `:339` and `.github/workflows/measure-disk-space.yml:321` do the same
through `scripts/ci/run-with-commands-stopped.sh`.

A sweep of the other 98 job logs of this run for `##[error]`, `##[warning]` or
`##[notice]` returns this file and nothing else:

```
$ zgrep -lE '\#\#\[(error|warning|notice)\]' ci-logs/release-34366976358/*.log.gz
ci-logs/release-34366976358/102518168976-Apply_Changesets_.log.gz
```

## 34366975927 — one overrun, four annotations, and an excuse

Job `Measure Component Disk Space` (102518097809) ran 14:56:53 → 15:57:09.

| # | Level | Message |
| --- | --- | --- |
| 1 | failure | `The job has exceeded the maximum execution time of 1h0m0s` |
| 2 | failure | `The operation was canceled.` |
| 3 | failure | `disk space measurement did not finish within its 2400s budget and was terminated. …` |
| 4 | warning | `disk space measurement has run for 1680s of its 2400s budget.` |
| 5 | warning | (job `pipeline-status`) `measure-disk-space. This run is no longer the head of main, so the cancellation reads as a supersede rather than an overrun.` |

The measurement itself is in `../ci-logs/jobs/102518097809.log.gz`, and it is not a
repository defect — it is a mirror that stopped delivering:

```
14:58:45.8856585Z Get:4 … dotnet-runtime-10.0 amd64 … [25.6 MB]
15:20:09.3980909Z Get:5 … aspnetcore-runtime-10.0 amd64 … [8453 kB]
```

25.6 MB in 21m24s is about 20 kB/s, from `azure.archive.ubuntu.com`, on a job
whose first `apt-get update` in the same minute had reported
`Fetched 9435 kB in 1s (8809 kB/s)`. Every subsequent `Get:` line is minutes
apart. No apt option covers this: `Acquire::http::Timeout` bounds an *idle*
connection and this one was delivering, slowly (see `../apt/README.md`).

Two repository defects are visible around it, and both are fixed on this branch.

**The budget that reported a termination it had not performed.** Annotation 3
was printed at 15:37:47, 2400s after the step started, and the job then ran on
for another 19m21s until the runner's own `timeout-minutes: 60` cancelled it at
15:57:08. The tree was `wrapper (runner) -> sudo (real uid runner) ->
measure-disk-space.sh (root) -> apt-get (root)`: `sudo` relayed the wrapper's
SIGTERM to the script it started, but that script's children have real uid 0 and
are neither sudo's to relay to nor the wrapper's to signal, so `apt-get`
survived. `kill -0` cannot report that — EPERM ("alive, not yours to signal")
and ESRCH ("gone") are both exit status 1 — so the wrapper read the survivors as
"finished", skipped its SIGKILL escalation and exited 124 believing it had
terminated the command. And the step outlived the wrapper because `apt-get` had
inherited the step's stdout, which is the pipe into `tee`, so `tee` never
reached EOF. `eacba67` asks the process table about liveness, escalates with the
privilege a runner can borrow, names any survivor in an `::error`, and relays the
child's output so a survivor cannot hold the step open at all.

**The gate that excused the cancellation.** Annotation 5 is
`check-pipeline-status.sh` declining to fail: the run was no longer the head of
`main`, so its rule read the cancellation as a newer push superseding this run.
It was not — nothing superseded it, the job hit its own cap, and
`measure-disk-space.yml` declares `cancel-in-progress: false` for exactly that
job, so in the workflow's own words it "queues instead of cancelling" and no
supersede could have reached it. `6a46916` asks the question at the level where
it can be answered: a cancellation is excused only when the run is no longer the
branch head **and** that job's own effective `cancel-in-progress` is `true`.
Every unreadable case fails closed.

## 34366976068 — the one benign annotation

```
notice | links / lychee | Summary report available at: …/actions/runs/34366976068#summary-102518098621
```

`lycheeverse/lychee-action` emits this itself, with `core.notice`, when
`output:` is set. It reports where the report is, on a job that passed, and is
not actionable: the alternative is to stop asking lychee for a report.
