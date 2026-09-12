# Issue #125 / pull request #126 evidence

This directory is the reproducible record behind the CI/CD audit requested by
[issue #125](https://github.com/link-foundation/box/issues/125). It covers all
nine runs named by the issue, every job and annotation in those runs, the
available artifacts, the complete CI/CD trees of the four requested reference
templates, the current hive-mind guidance, and the issue/PR discussion state.

## Result

The only false verdict among the nine audited runs is `34455018634`. The disk
measurement completed successfully, generated all 27 component measurements,
and uploaded its artifact, but the wrapped command had deleted the wrapper's
own private files.
That converted command exit 0 into wrapper exit 1 and discarded nearly all
live output. `scripts/ci/run-with-budget-warning.sh` now keeps parent-owned
state under `RUNNER_TEMP`, independently of the child's `TMPDIR`.

The deliberately forced-verbose final gate then exposed a second, latent
defect: raw xtrace printed live credentials in three code paths. Staged
secretlint stopped the affected logs before commit or push. Zizmor now suspends
tracing around token handling, while registry probe and credential preflight
emit state-only diagnostics. The canary regression changed from three secrecy
failures to six total passes, and clean real-token online logs replaced the
quarantined copies.

The other signal is accurate:

- three failure annotations all describe that one propagated failure;
- one link-check notice points to its successful report;
- four Docker Hub copy attempts genuinely failed with HTTP/2
  `PROTOCOL_ERROR`, were visibly retried, and succeeded on attempt two;
- the remaining matches are package-manager warnings, checker summaries,
  fixture assertions, echoed scripts, schema fields, or filenames.

## Runs audited

All nine started at `2026-09-10T08:24:48Z` on merge commit
`90f1e2d95adbb0beb132da366b28d14a3746347c`.

| Run | Workflow | Conclusion | Jobs | Annotations |
| --- | --- | --- | ---: | ---: |
| `34455018688` | Links | success | 2 | 1 notice |
| `34455018700` | Workflows | success | 3 | 0 |
| `34455018611` | Docs | success | 2 | 0 |
| `34455018674` | File sizes | success | 2 | 0 |
| `34455018599` | Dockerfiles | success | 2 | 0 |
| `34455018650` | Security | success | 5 | 0 |
| `34455018681` | Scripts | success | 8 | 0 |
| `34455018634` | Measure Disk Space and Update README | **failure** | 3 | 3 failures |
| `34455018919` | Build and Release Docker Image | success | 99 | 0 |

`runs/index.json` is the machine-readable version of this table. It was built
from the Actions API rather than inferred from log text.

## Directory map

- `issue.json`, `issue-comments.json`: complete issue and comment payloads.
- `pr*.json`, `related-pr-124*.json`: PR #126 and the merge that triggered the
  audited runs, including all three GitHub review/comment channels.
- `runs/`: run metadata and every job for each run.
- `annotations/`: every check-run annotation, fetched with pagination.
- `ci-logs/`: complete logs for eight runs and the official per-job archive for
  the 99-job release run; see `ci-logs/README.md`.
- `artifacts/`: artifact API listings and every non-expired artifact available
  during collection. `artifacts/index.tsv` maps ids to files.
- `local-tests/`: complete local verification results, including the official
  complete experiment run and the deliberately forced-verbose diagnostic run.
- `analysis/`: requirements, timeline, root causes, alternatives, the complete
  warning/error census, and before/after reproductions.
- `templates/`: full tracked file trees and copies of every CI/CD-relevant file
  from the JavaScript, Python, Rust, and PHP templates.
- `research/`: primary GitHub documentation and related runner reports.
- `upstream/`: duplicate search, submitted report, and returned API record for
  [JavaScript template issue #189](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/189).

## Reproduce the analysis

```bash
bash experiments/issue-125/census-warnings-errors.sh
bash experiments/issue-125/snapshot-templates.sh
bash experiments/issue-125/compare-template-roles.sh \
  > dev/log/issues/125/pulls/126/templates/script-role-matrix.tsv
bash experiments/issue-125/compare-template-roles.sh --workflows \
  > dev/log/issues/125/pulls/126/templates/workflow-role-matrix.tsv
bash experiments/test-issue125-budget-state-survives-tmp-cleanup.sh
bash experiments/test-issue125-verbose-secret-redaction.sh
```

The first two snapshot commands require their documented network/checkouts;
the matrices, census, and regression test run offline from this repository.
