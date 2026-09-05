# Requirements

Every requirement stated in [issue #115](https://github.com/link-foundation/box/issues/115),
numbered so the rest of this folder and the pull request can refer to them.
Quotes are verbatim from the issue body.

---

## R1 — Find and fix every false positive, false negative, warning and error in CI/CD

From the title: *"Check for all false positives, false negatives, warnings and errors in CI/CD and fix them all"*.

The four categories, as they apply here:

| Category | Meaning in this repository |
| --- | --- |
| **False positive** | CI reports a failure that is not caused by the thing it blames. Example: `build-dind-*` failing with `box-js:2.5.0-amd64: not found`, which is an expired Docker Hub token three jobs upstream, not a defect in the dind Dockerfile. |
| **False negative** | CI reports success (or does not run at all) while a real defect passes through. Example: `measure-disk-space.yml` has no `pull_request` trigger, so pull request #113 merged a `scripts/measure-disk-space.sh` that cannot run. |
| **Warning** | Anything emitted as `::warning::`/`##[warning]` or by a linter that nothing gates on. Example: the Docker Hub login failure is *only* a warning, and 83 actionlint findings plus 173 zizmor findings are not checked by any job. |
| **Error** | A red run. The two named in the issue, and everything they cascade into. |

**Acceptance criterion:** each of the four categories has at least one committed,
automated check that fails when the defect returns, and the baselines in
[`analysis/`](analysis/) are driven to zero or to an explicitly justified,
enforced allow-list.

---

## R2 — Fix the two failing runs on `main` at commit `42be663`

| Workflow | Conclusion | Run |
| --- | --- | --- |
| Build and Release Docker Image | failure | [33972074755](https://github.com/link-foundation/box/actions/runs/33972074755) |
| Measure Disk Space and Update README | failure | [33972074753](https://github.com/link-foundation/box/actions/runs/33972074753) |

**Acceptance criterion:** the root cause of each is identified (see
[`ROOT-CAUSES.md`](ROOT-CAUSES.md)), fixed, and covered by a test that fails
against the current `main` and passes after the fix.

---

## R3 — Adopt the best practices from the CI/CD template, comparing the full file tree

> *"Use all the best practices from CI/CD templates (check full file tree to compare for all GitHub workflow and CI/CD scripts file)"*

Template: <https://github.com/link-foundation/js-ai-driven-development-pipeline-template>

**Acceptance criterion:** every workflow and CI/CD script in the template is
compared against this repository in [`TEMPLATE-COMPARISON.md`](TEMPLATE-COMPARISON.md),
with each gap either closed or recorded with the reason it does not apply.

---

## R4 — Report the defect upstream when the template shares it

> *"if the same issue is found in template report issue also in templates"*

**Acceptance criterion:** for every defect found in this repository that also
exists in the template (or in any other upstream project involved), a GitHub
issue is filed on that project containing a reproducible example, a workaround
and a suggested code fix. If no shared defect exists, that is stated with the
evidence that established it.

---

## R5 — Compare *all* files, so the class of error cannot recur

> *"We should compare all files, so we don't have more CI/CD errors in the future and reuse all the best practices from these templates."*

This is stronger than R3: the goal is not parity on the files that happen to
exist in both, but coverage of the whole CI/CD surface — workflows, composite
actions, `scripts/ci/`, shell scripts invoked by workflows, and the
configuration files (`.github/zizmor.yml`, `.lycheeignore`, hooks) that make
the checks enforceable.

**Acceptance criterion:** the comparison enumerates the full file tree on both
sides, not a sample, and every adopted practice is enforced by a job rather
than by documentation alone.

---

## R6 — Follow the hive-mind CI/CD best practices

> Follow the CI/CD best practices collected in
> <https://github.com/link-assistant/hive-mind/blob/main/docs/CI-CD-BEST-PRACTICES.md>

A snapshot is in [`templates/hive-mind-CI-CD-BEST-PRACTICES.md`](templates/hive-mind-CI-CD-BEST-PRACTICES.md).
It contains 15 numbered principles. [`TEMPLATE-COMPARISON.md`](TEMPLATE-COMPARISON.md)
scores this repository against each one.

**Acceptance criterion:** every one of the 15 principles is either satisfied or
has a recorded, justified exception.

---

## R7 — Do all of it in this one pull request

> *"Please plan and execute everything in this single pull request, you have unlimited time and context […] until it is each and every requirement fully addressed, and everything is totally done."*

**Acceptance criterion:** [#116](https://github.com/link-foundation/box/pull/116)
carries the whole change set, its CI is green, and no requirement is deferred
to a follow-up issue without saying so explicitly.

---

## Requirements from the task instructions (in addition to the issue)

| # | Requirement | Where it is satisfied |
| --- | --- | --- |
| T1 | Download all logs and collected data into `dev/log/issues/115/pulls/116` | This folder; see [`README.md`](README.md). |
| T2 | Deep analysis, timeline, root cause per problem, solution plan per requirement | [`TIMELINE.md`](TIMELINE.md), [`ROOT-CAUSES.md`](ROOT-CAUSES.md), [`SOLUTION-PLAN.md`](SOLUTION-PLAN.md). |
| T3 | Survey existing components/libraries that solve a similar problem | [`PRIOR-ART.md`](PRIOR-ART.md). |
| T4 | Where evidence is insufficient, add debug output and a verbose mode, default off | [`SOLUTION-PLAN.md`](SOLUTION-PLAN.md) § verbose mode. |
| T5 | Report issues upstream with reproducible example, workaround and code fix | Same as R4. |
| T6 | Apply each fix everywhere the defect occurs, not just where it was observed | Tracked per root cause; RC-1 in particular occurs **twice**. |
