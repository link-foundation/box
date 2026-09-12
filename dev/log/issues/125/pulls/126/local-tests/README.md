# Final local verification

The final commands below ran against the complete post-fix worktree. No product
source changed between these successful checks and staging.

| Check | Exit | Result |
| --- | ---: | --- |
| `scripts/ci/run-experiments.sh` | 0 | 94 passed, 0 failed, 7 documented environment-dependent skips |
| targeted budget/zizmor/registry/preflight regressions | 0 | all six entry-point suites passed |
| pre-commit gates, whole worktree, verbose | 0 | all applicable gates passed |
| hadolint | 0 | all tracked Dockerfiles passed |
| actionlint v1.7.12, digest-pinned | 0 | all workflows passed |
| zizmor regular, online | 0 | no finding at the configured floor |
| zizmor pedantic high/high, online | 0 | no finding at the configured floor |
| lychee 0.24.2, live links and fragments | 0 | 711 links checked, 0 errors |

`full-gates.tsv` is the machine-readable summary. The corresponding output is
stored beside it; the two logs longer than 1,500 lines are gzip-compressed.

## Verbose diagnostic

The first experiment pass deliberately exported repository-wide
`BOX_VERBOSE=1`. It produced 12 expected failures in older fixtures whose
premise is that verbose mode is *off by default*, or which compare a gate's
exact combined output. This is retained as
`full-experiments-forced-verbose.txt.gz`, status 1. The official runner was
then rerun without altering its environment, tests, or timeouts and passed all
94 runnable suites; that result is `full-experiments.txt.gz`, status 0.

## Verbose credential safety

The first real online verbose zizmor logs disclosed the GitHub token through
raw Bash xtrace. Staged secretlint rejected them before a commit or push. The
same pattern was reproduced with inert canaries in zizmor, registry probe, and
credential preflight: three functional checks passed while all three secrecy
checks failed. After the three-site fix, the regression passes 6/6.

Both online zizmor modes were rerun with `BOX_VERBOSE=1`; the clean logs stored
here contain neither a credential nor a redaction placeholder. The before/after
canary outputs are under `../analysis/`, and `targeted-regressions.txt` records
the adjacent compatibility suites.

The seven skips are measurements requiring live feeds or large image builds,
not silently omitted assertions. Their reasons are printed in the official
log. The live actionlint, zizmor, and link checks were run separately above;
GitHub CI supplies the remaining hosted-runner and image-build coverage.
