# What actually happened on 2026-09-09

Issue #123 names nine CI/CD runs on `main` at commit `1d9fb3e` and asks for the
false positives, false negatives, warnings and errors in them. Reconstructing
the sequence is not decoration here: **one of the false positives (RC-2) is
caused by the order of two events 21 seconds apart**, and no reading of the
scripts alone would have shown it.

Every timestamp below is read out of the evidence in this directory —
`../runs/*.run.json`, `../runs/*.jobs.json`, `../annotations/*.annotations.json`
and the gzipped step logs under `../ci-logs/` — not out of the web UI. All times
are UTC on 2026-09-09 unless stated.

## The outer bounds

| time | event |
|---|---|
| 14:56:47 | `1d9fb3e` — "Merge pull request #122 from link-foundation/issue-121-545308eb324d" — committed |
| 14:56:51 | all **nine** runs created, every one of them at `1d9fb3e` |
| 14:57:11 | `1e202f5` — the 2.9.0 version bump — committed **by one of those nine runs** |
| **14:57:12.641** | `1e202f5` pushed to `main`: `1d9fb3e..1e202f5  HEAD -> main` |
| 15:57:09 | `Measure Component Disk Space` cancelled by `timeout-minutes: 60` |
| 16:42:01 | the last of the nine runs finishes |
| 21:28:28 | issue #123 opened |
| 21:29:23 | PR #124 opened (draft) |

So the whole subject of this issue is a **1 h 45 m 10 s** window, and the commit
the nine runs were testing stopped being the head of `main` **21 seconds** into
it.

## The nine runs

All nine were created in the same second by the same push. Eight concluded
`success`; one concluded `cancelled`.

| run | workflow | conclusion | finished | wall |
|---|---|---|---|---|
| 34366975852 | Docs | success | 14:57:09 | 18 s |
| 34366975992 | File sizes | success | 14:57:12 | 21 s |
| 34366976068 | Links | success | 14:57:26 | 35 s |
| 34366975873 | Workflows | success | 14:57:29 | 38 s |
| 34366975962 | Dockerfiles | success | 14:57:30 | 39 s |
| 34366975942 | Security | success | 14:58:22 | 1 m 31 s |
| 34366975837 | Scripts | success | 14:59:18 | 2 m 27 s |
| **34366975927** | **Measure Disk Space and Update README** | **cancelled** | 15:57:19 | **1 h 0 m 28 s** |
| 34366976358 | Build and Release Docker Image | success | 16:42:01 | 1 h 45 m 10 s |

**Eight of the nine were green, and six of the twenty root causes are in those
eight** (RC-3, RC-5, RC-6, RC-7, RC-8, RC-10). A red run tells you where to
look. A green run does not, which is why the census
(`warnings-errors.census.md`) reads all 804 `warn`/`error` lines in all nine
rather than the failing one.

## The 21 seconds that produced a false positive

This is the causal chain behind RC-2, and it is entirely inside the release run.

| time | run/job | event |
|---|---|---|
| 14:56:51 | — | nine runs created at `1d9fb3e`; `main` is at `1d9fb3e` |
| 14:56:53 | 34366975927 / `Measure Component Disk Space` (102518097809) | starts |
| 14:56:54 | 34366976358 / `preflight` (102518099116) | starts, ends 14:57:03 |
| 14:57:06 | 34366976358 / **`Apply Changesets`** (102518168976) | starts |
| 14:57:10.957 | `apply-changesets.sh` | `Committing version bump...` |
| 14:57:11.232 | the runner | **`##[error]` annotation** — RC-3, `git commit` echoing a changeset body that quotes `##[error]` |
| 14:57:11.238 | `apply-changesets.sh` | `Pushing to main...` |
| **14:57:12.641** | `git push` | **`1d9fb3e..1e202f5  HEAD -> main`** |
| 14:57:14 | 102518168976 | job ends `success` — carrying one `failure` annotation |
| 14:57:16 | 34366976358 / `detect-changes` | starts; the release proceeds normally |
| 15:37:47 | 34366975927 / the same measurement step | `##[error]…did not finish within its 2400s budget and was terminated` — RC-1, and it had not been |
| 15:57:09 | 34366975927 / 102518097809 | cancelled by the runner's own `timeout-minutes: 60`, 19 m 21 s after the budget said it was dead |
| 15:57:12 | 34366975927 / `pipeline-status` (102540700828) | starts, reads `main`, finds `1e202f5` |
| 15:57:18 | 34366975927 / `pipeline-status` | concludes **`success`**: "This run is no longer the head of main, so the cancellation reads as a supersede rather than an overrun" — RC-2 |

The run really was not the head of `main`. It was displaced by **a sibling job
of its own push**, 21 seconds after being created — and every release does this,
because applying changesets is what the release workflow is *for*. The supersede
excuse #121 added was not defeated by an unlucky race; it was defeated by the
ordinary operation of the pipeline it guards.

`measure-disk-space.yml` makes that visible in its own text:

```yaml
concurrency:
  group: measure-disk-space-${{ github.ref }}
  cancel-in-progress: false
```

No supersede could reach that job. The gate never read that line, because it
asked its question of the run instead of the job. RC-2's fix reads it.

## The seven annotations

The API reports **7** annotations across the nine runs — five on the cancelled
run, one on the release, one on Links. Six of the seven are on the two runs
above; one is benign.

| time | run | level | annotation | verdict |
|---|---|---|---|---|
| 14:57:11 | 34366976358 | failure | `` ` while explaining a fix. `docker/setup-buildx-action` creates …`` | **false positive** — RC-3, a commit message read as a command |
| 14:57:10.570 | 34366976068 | notice | `Summary report available at: …#summary-102518098621` | benign — lychee saying where its report is |
| 15:25:47.393 | 34366975927 | warning | `disk space measurement has run for 1680s of its 2400s budget.` | true, and the last true thing that run said |
| 15:37:47.616 | 34366975927 | failure | `…did not finish within its 2400s budget and was terminated.` | **false** — RC-1, it was not terminated; it ran 19 more minutes |
| 15:57:08.279 | 34366975927 | failure | `The operation was canceled.` | true |
| 15:57:08 | 34366975927 | failure | `The job has exceeded the maximum execution time of 1h0m0s` | true — the only annotation that named the real outcome |
| 15:57:18 | 34366975927 | warning | `measure-disk-space. This run is no longer the head of main…` | **false positive** — RC-2, excusing an overrun as a supersede |

Three of the seven were wrong, and the two wrong ones on the cancelled run are
what let a **60-minute overrun conclude `success`**.

## Inside the release run

99 jobs, 1 h 45 m of wall time, all green. Where the time went, from
`../runs/34366976358.jobs.json`:

| stage | window | duration |
|---|---|---|
| `preflight` → `Apply Changesets` → `detect-changes` | 14:56:54 → 14:57:22 | 28 s |
| `js` builds | 14:57:25 → 15:12:10 | 14 m 45 s |
| `essentials` | → 15:20:15 | 8 m 5 s |
| `languages` | → 15:43:12 | 22 m 57 s (`rocq` amd64 the long pole at 21 m 22 s; `perl` amd64 15:22:37 → 15:42:13) |
| `full` | → 16:28:06 | 44 m 54 s (`docker-build-push` 23 m 36 s, arm64 20 m 35 s) |
| `dind` | → 16:41:25 | 13 m 19 s |
| `create-release` | 16:41:29 → 16:41:51 | 22 s |
| `pipeline-status` | 16:41:54 → 16:42:01 | 7 s |

This run is where RC-3 (14:57:11), RC-6's `grep`/`tr: write error: Broken pipe`
(in `full / docker-build-push`), RC-8's `npm warn using --force` (every JS build
job) and RC-10's `useradd: warning: the home directory /home/box already exists.`
(both JS build jobs) were all recorded — on a run that concluded `success` and
published release 2.9.0.

## The measurement job, minute by minute

The 60 minutes that RC-1 and RC-2 are both about:

| time | event |
|---|---|
| 14:56:53 | `Measure Component Disk Space` starts |
| 14:57:47.541 | the wrapped step begins: `Running disk space measurement with a 2400s budget (warning at 1680s).` — every budget time below is counted from here |
| 14:58:45.886 | `Get:4 … dotnet-runtime-10.0 amd64 … [25.6 MB]` — and in the same minute this job's `apt-get update` had reported `Fetched 9435 kB in 1s (8809 kB/s)` |
| 15:20:09.398 | `Get:5 … aspnetcore-runtime-10.0 amd64 … [8453 kB]` — **25.6 MB in 21 m 24 s, ≈20 kB/s** from `azure.archive.ubuntu.com` (`../annotations/README.md`, `../apt/README.md`) |
| 15:25:47.393 | `##[warning]disk space measurement has run for 1680s of its 2400s budget.` — accurate |
| 15:37:47.616 | the budget wrapper declares the command terminated (RC-1) — 2400 s to the second. `kill -0` had answered "gone" for a group of root-owned survivors it could not signal |
| 15:37:47–15:57:08 | the step keeps running for **19 m 21 s**, because `apt-get` still holds the step's stdout — the pipe into `tee`, which therefore never sees EOF |
| 15:57:08.279 | `##[error]The operation was canceled.` — `timeout-minutes: 60` |
| 15:57:18 | `pipeline-status` excuses it (RC-2) and the run's own gate concludes `success` |

The mirror is not a repository defect and no apt option covers it —
`Acquire::http::Timeout` bounds an *idle* connection, and this one was
delivering, slowly. That is why the apt-hardening candidate is declined with a
measurement in `../apt/README.md` and `ROOT-CAUSES.md` rather than shipped.

## What the sequence establishes

1. **RC-2 is systematic, not a race.** The displacing push comes from the same
   push's own release run, every time.
2. **RC-1's report was false for 19 minutes and nobody could see it**, because
   the run that would have shown the contradiction concluded `success`.
3. **The green runs carry most of the defects.** Six of twenty, found only by
   reading all 804 lines of a passing pipeline.
4. **Two independent false verdicts stacked into a silent failure.** RC-1 said
   it had handled the overrun; RC-2 said the overrun was somebody else's push.
   Either one alone would have left a red run. Together they produced a green
   one.

## Where to look next

* the annotations, with their surrounding log lines: `../annotations/README.md`
* all 804 `warn`/`error` lines, classified: `warnings-errors.census.md`
* the mechanism behind each: `ROOT-CAUSES.md`
* what the issue asked for, and where each ask is discharged: `REQUIREMENTS.md`
