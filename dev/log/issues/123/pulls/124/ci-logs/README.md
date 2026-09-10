# Run and job logs for the nine runs issue #123 lists

Every run listed in the issue, at commit `1d9fb3e` on `main`. Collected with
`experiments/issue-123/collect-ci-evidence.mjs` (run-level logs) and
`gh run view --job <job-id> --log` (the per-job directories).

Named `ci-logs/` and gzipped, which is issue #121's convention and not an
aesthetic one: `.gitignore` ignores a directory named `logs` (line 2) *and*
`*.log` (line 3), so a `logs/*.log` tree is dropped twice over -- it needs
`git add -f`, and it never appears in `git status`, so it is committed by accident
or not at all. This set is also **19.9 MB raw against 2.8 MB stored**, almost all
of it docker build output. The analysis was done against the uncompressed copies.
Read one with `zcat`, search a directory with `zgrep -lE … <dir>/*.log.gz` (gzip's `zgrep` has no
`-r`, which is worth knowing before you conclude a pattern is absent).

## Run-level logs, one per run

`gh run view <run-id> --log`, so each line is `job<TAB>step<TAB>timestamp text`.

| File | Workflow | Conclusion | Jobs | Lines | Raw | Stored |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| `34366975837.log.gz` | Scripts | success | 8 | 1997 | 234 kB | 28 kB |
| `34366975852.log.gz` | Docs | success | 2 | 406 | 47 kB | 6 kB |
| `34366975873.log.gz` | Workflows | success | 3 | 977 | 104 kB | 16 kB |
| `34366975927.log.gz` | Measure Disk Space and Update README | **cancelled** | 3 | 987 | 119 kB | 18 kB |
| `34366975942.log.gz` | Security | success | 5 | 5603 | 801 kB | 87 kB |
| `34366975962.log.gz` | Dockerfiles | success | 2 | 421 | 48 kB | 6 kB |
| `34366975992.log.gz` | File sizes | success | 2 | 680 | 75 kB | 11 kB |
| `34366976068.log.gz` | Links | success | 2 | 531 | 58 kB | 10 kB |
| `34366976358.log.gz` | Build and Release Docker Image | success | 99 | 3 | 196 B | 196 B |

The last one is not a log. `gh` declines to assemble a run log of that size:

```
LOG UNAVAILABLE: Command failed: gh run view 34366976358 --repo link-foundation/box --log
too many API requests needed to fetch logs; try narrowing down to a specific job with the `--job` option
```

which is why the next directory exists. The collector records the refusal instead
of writing nothing, so a missing log is never mistaken for an empty one.

## `release-34366976358/` — all 99 jobs of the release run

One file per job, `<job-id>-<job-name>_.log.gz`, each `gh run view --job <id> --log`.
18.3 MB raw, 2.6 MB stored; the four largest are the language build jobs
(`js / build-js-amd64` 624 kB, `js / build-js-arm64` 594 kB,
`full / docker-build-push-arm64` 483 kB, `full / docker-build-push` 479 kB).

Five are **empty**, and that is the correct content: they are the five jobs the
run skipped — `Cancel superseded runs`, `Check for Manual Version Changes`,
`Check for Changesets`, `version-bump`, `pr-tests` (conclusion `skipped` in
`../runs/34366976358.jobs.json`). A skipped job has no log to fetch.

This directory is the evidence for the release run's single `failure`
annotation: sweeping all 99 for a workflow command finds exactly one file
(`../annotations/README.md` has the reading).

```
$ zgrep -lE '\#\#\[(error|warning|notice)\]' release-34366976358/*.log.gz
release-34366976358/102518168976-Apply_Changesets_.log.gz
```

## `jobs/` — the four jobs the analysis quotes line by line

| File | Run | Job | Conclusion |
| --- | --- | --- | --- |
| `102518097388.log.gz` | 34366975927 | Validate measurement scripts | success |
| `102518097809.log.gz` | 34366975927 | Measure Component Disk Space | **cancelled** |
| `102540700828.log.gz` | 34366975927 | pipeline-status | success |
| `102518168976-apply-changesets.log.gz` | 34366976358 | Apply Changesets | success |

`102518097809` is the 1h overrun: the `Get:` timestamps in it are the measurement
behind "a mirror that stopped delivering" (`../apt/README.md`). `102540700828` is
the status gate excusing that cancellation as a supersede. The `Apply Changesets`
log is a second copy of the file in `release-34366976358/`, kept under the name
the annotation analysis refers to.

## `pr-runs/` — the branch's own runs that turned four root causes red

Four of the twenty root causes were not visible in the nine runs above: they
were latent until a suite this branch wrote ran on the `ubuntu-24.04` runner, or
until this branch's own release path ran over its own committed evidence. These
are those runs, one job each, `gh run view --job <id> --log`, gzipped.

| File | Run | Commit | Job | Conclusion | What it is |
| --- | --- | --- | --- | --- | --- |
| `34434788500-scripts-regression_78db753b_failure.log.gz` | 34434788500 | `78db753b` | scripts / regression suites | **failure** | RC-14/15/16: the runner measures apt's default at 1 retry (4 connections), a SIGKILL survivor unescalated, and both SIGPIPE legs ignored — none reproducible on any machine here |
| `34434789000-check-changesets_78db753b_failure.log.gz` | 34434789000 | `78db753b` | Check for Changesets | **failure** | RC-20, first sighting: `Invalid changeset format` on `templates/go/.changeset/add-changeset-workflow.md`, a changeset belonging to another repository |
| `34435214054-check-changesets_1a756e6_failure.log.gz` | 34435214054 | `1a756e6` | Check for Changesets | **failure** | RC-20, the run quoted in `../analysis/ROOT-CAUSES.md` §RC-20 |
| `34448597859-scripts-regression_2ba6591_success.log.gz` | 34448597859 | `2ba6591` | scripts / regression suites | **success** | the same suites green after the fixes: `passed: 92, failed: 0`, and the apt suite now *reports* the runner's 1 rather than asserting 3 |

The last row is the end-to-end control: remove the RC-14/15/16 fixes and exactly
the first row's failures return, and the RC-20 fix turns the changeset gate green
on the run at `2ba6591` (`Check for Changesets` no longer reads another project's
file). These live outside `release-34366976358/` because they are not the release
run the issue lists; they are the evidence that "fix it everywhere" reached the
code this branch itself added.
