# Requirements and closure map

## Explicit issue requirements

| ID | Requirement | Evidence and disposition |
| --- | --- | --- |
| R1 | Check every false positive, false negative, warning, and error in the listed CI/CD runs. | All nine run logs, 126 jobs, and four annotations were collected. `warnings-errors.raw.tsv` classifies all 2,598 text matches; `LOG-DISPOSITIONS.md` gives each class a verdict. |
| R2 | Fix every defect found. | The one false verdict and its associated output loss share one root cause. The wrapper state is isolated in `RUNNER_TEMP`; the regression fails on `origin/main` and passes here. |
| R3 | Use the JavaScript and Python template best practices. | The current full trees are captured and compared by role. Both templates are at the same revisions as the previous exhaustive audit, so all prior dispositions were rechecked rather than assumed. |
| R4 | Compare the full GitHub workflow and CI/CD script tree of JavaScript, Python, Rust, and PHP templates. | Complete upstream file trees, relevant file contents, and 155-script-role/17-workflow-role matrices are in `templates/`; `templates/COMPARISON.md` records the semantic finding. |
| R5 | Apply the hive-mind CI/CD best-practices document. | The current source is stored verbatim and all sixteen principles are remeasured in `BEST-PRACTICES-VERIFICATION.md`. |

## Solver requirements applied to this issue

| ID | Requirement | Evidence and disposition |
| --- | --- | --- |
| R6 | Read the issue, all comments, related PR, and all PR comment types. | JSON snapshots show no issue comments and no PR #126 conversation comments, inline review comments, or reviews at collection time. PR #124's corresponding channels are also stored. |
| R7 | Download all logs and preserve relevant artifacts. | `ci-logs/README.md` describes the eight aggregate logs and the official release archive; all 58 non-expired artifacts were downloaded and indexed. |
| R8 | Establish the root cause before changing code. | The production timestamps show deletion one second after launch. The minimum reproducer changes command exit 0 into wrapper exit 1 on the baseline and JavaScript template, and exits 0 after the fix. |
| R9 | Start with a reproducing test and verify the fix. | `experiments/test-issue125-budget-state-survives-tmp-cleanup.sh`; saved output is in `reproducer-{before,after}.log.gz`. |
| R10 | Apply a repeated fix throughout the codebase. | There is one shared wrapper and 15 workflow invocations. Fixing the state owner closes every call site. Searches found no second local implementation. |
| R11 | Add opt-in diagnostics if the available evidence cannot identify the cause. | The cause is conclusive. Existing `BUDGET_VERBOSE=1` remains off by default and now additionally prints the selected control-state path, making any environment-specific recurrence diagnosable. |
| R12 | Research existing components and similar defects. | `PRIOR-ART.md` assesses GitHub's job temp directory, GNU `timeout`, and related runner limitations using primary sources saved under `research/`. |
| R13 | Report a defect in a related project when possible, with reproduction, workaround, and suggested code fix. | The only affected reference project is reported as [js template #189](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/189); the exact submitted body and API response are under `upstream/`. |
| R14 | Prepare a release trigger for a package/versioned repository. | `.changeset/fix-budget-state-cleanup.md` requests a patch release. |
| R15 | Update, validate, and mark PR #126 ready. | Completed during finalization after local and GitHub checks; the PR description links this closure map and the regression. |
