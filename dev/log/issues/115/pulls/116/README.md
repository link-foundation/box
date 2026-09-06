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
logs/     the full CI logs of both failing runs, and of the runs this branch itself turned red
analysis/ linter baselines measured against the tree at the branch point, plus per-defect probes
templates/ snapshots of the reference template and the best-practices document the issue points at
```

| Log | Run | What it proves |
| --- | --- | --- |
| `logs/release-33972074755.log.gz` | 33972074755, `main` @ `42be663` | R2's first failing run, in full (19 MB uncompressed). |
| `logs/release-33972074755-failures.log` | same | Every error, warning, retry and authorization line extracted from it. |
| `logs/measure-disk-space-33972074753.log` | 33972074753, `main` @ `42be663` | R2's second failing run. |
| `logs/release-33997488721.log.gz` | 33997488721, this branch @ `30801ee` | The base-image preflight firing on a branch whose `konard/box-*` bases did not exist yet. |
| `logs/scripts-34003004420.log` | 34003004420, this branch @ `46f80a5` | `test-issue108-detect-changes.sh` dying with git exit 128 in a shallow checkout — the defect ROOT-CAUSES.md records as RC-15. |

Analysis probes:

| File | What it proves |
| --- | --- |
| `analysis/{actionlint,zizmor,shellcheck}-baseline.txt` | What each linter reported against the tree at the branch point. |
| `analysis/zizmor-template-baseline.txt` | zizmor run against the *vendored template*, i.e. the findings reported upstream under R4. |
| `analysis/lean-toolchain-verification.*` | elan setting a default toolchain it never installed (RC-14). |
| `analysis/lean-install-clean-container.log` | The patched Lean install script in a clean `ubuntu:24.04`: one toolchain, resolved, present. |
| `analysis/opam-path-verification.*` | opam's binary directory missing from `PATH` in a built box. |

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
