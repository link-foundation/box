# Evidence and analysis — issue #115 / pull request #116

> Check for all false positives, false negatives, warnings and errors in CI/CD and fix them all
> <https://github.com/link-foundation/box/issues/115>

Everything in this folder was collected from the live repository and its CI on
2026-09-05 and is the raw material behind the fixes in pull request
[#116](https://github.com/link-foundation/box/pull/116).

## Read in this order

| File | What it answers |
| --- | --- |
| [`REQUIREMENTS.md`](REQUIREMENTS.md) | Every requirement stated in the issue, numbered R1–R7, each with an acceptance criterion. |
| [`TIMELINE.md`](TIMELINE.md) | What happened, in order, from the merge that broke `main` to the two red runs named in the issue. |
| [`ROOT-CAUSES.md`](ROOT-CAUSES.md) | The root cause of each problem, with the log lines and source lines that prove it. |
| [`TEMPLATE-COMPARISON.md`](TEMPLATE-COMPARISON.md) | File-by-file comparison against the pipeline template and the hive-mind best-practices document (R3, R5, R6). |
| [`PRIOR-ART.md`](PRIOR-ART.md) | Existing tools and libraries that solve these problems, and which of them this repository can adopt. |
| [`SOLUTION-PLAN.md`](SOLUTION-PLAN.md) | The plan per requirement, with the order of execution and what "done" means. |

## Raw evidence

```
meta/     issue #115, pull request #116, and every comment on both, as returned by the GitHub API
runs/     run and job metadata for the two failing runs named in the issue, plus the 60 most recent runs
logs/     the full CI logs of both failing runs
analysis/ linter baselines measured against the tree at the branch point
templates/ snapshots of the reference template and the best-practices document the issue points at
```

### Reproducing the log collection

```bash
gh run view 33972074755 --repo link-foundation/box --log > logs/release-33972074755.log
gh run view 33972074753 --repo link-foundation/box --log > logs/measure-disk-space-33972074753.log
```

The `Build and Release` log is 161 548 lines / 19 MB, so it is stored here
gzip-compressed. `logs/release-33972074755-failures.log` is the uncompressed
extract of every error, warning, retry and authorization line in it — that
extract is what the analysis quotes.

```bash
gunzip -c logs/release-33972074755.log.gz | less   # full log
```

The log lines are tab-separated `job<TAB>step<TAB>timestamp message`, so a
single job can be sliced out with:

```bash
gunzip -c logs/release-33972074755.log.gz | awk -F'\t' '$1=="build-js-arm64"'
```

### Reproducing the linter baselines

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.7 -color   > analysis/actionlint-baseline.txt
uvx zizmor --min-confidence medium .github/                              > analysis/zizmor-baseline.txt
git ls-files '*.sh' | xargs shellcheck --severity=warning                > analysis/shellcheck-baseline.txt
```
