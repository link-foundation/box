# Template and best-practices comparison

Covers [R3](REQUIREMENTS.md#r3), [R5](REQUIREMENTS.md#r5) and [R6](REQUIREMENTS.md#r6).

Two references:

* **Template** — [`link-foundation/js-ai-driven-development-pipeline-template`](https://github.com/link-foundation/js-ai-driven-development-pipeline-template),
  snapshot in [`templates/js-ai-driven-development-pipeline-template/`](templates/js-ai-driven-development-pipeline-template/)
  (commit recorded in `PROVENANCE.txt`).
* **Best practices** — [`link-assistant/hive-mind` `docs/CI-CD-BEST-PRACTICES.md`](https://github.com/link-assistant/hive-mind/blob/main/docs/CI-CD-BEST-PRACTICES.md),
  snapshot in [`templates/hive-mind-CI-CD-BEST-PRACTICES.md`](templates/hive-mind-CI-CD-BEST-PRACTICES.md).

The template is a JavaScript/npm project and this repository is a Docker image
factory (80.9 % shell, 11.2 % JavaScript, 7.9 % Dockerfile per the issue), so
the comparison is about **practices and enforcement mechanisms**, not about
copying `npm`-specific jobs. Where a practice does not transfer, that is stated
with the reason.

---

## Part 1 — Full file-tree comparison of the CI/CD surface

`git ls-files` on both sides, restricted to workflows, composite actions, CI
scripts, hooks and tool configuration.

### 1a. Workflows

| Template | Lines | Box | Lines | Gap |
| --- | --- | --- | --- | --- |
| `.github/workflows/release.yml` | 890 | `.github/workflows/release.yml` | **3432** | Box is 2.3× the 1500-line limit the template enforces on this exact file ([RC-8](ROOT-CAUSES.md#rc-8)) |
| `.github/workflows/workflows.yml` | 69 | — | — | **Missing.** actionlint + zizmor. Directly causes [RC-6](ROOT-CAUSES.md#rc-6) |
| `.github/workflows/security.yml` | 93 | — | — | **Missing.** CodeQL (incl. the `actions` language), dependency review, `npm audit` on a weekly schedule |
| `.github/workflows/links.yml` | 104 | — | — | **Missing.** lychee link checking with Web-Archive fallback |
| `.github/workflows/example-app.yml` | 318 | — | — | Not applicable — template-specific demo app |
| — | — | `.github/workflows/measure-disk-space.yml` | 212 | Box-specific. Has no `pull_request` trigger ([RC-2](ROOT-CAUSES.md#rc-2)) and cancels a `contents: write` main-writer job |

### 1b. Composite actions

| Template | Box | Gap |
| --- | --- | --- |
| `.github/actions/setup-buildx-resilient/action.yml` | same file, present | Identical apart from comment wording — the two repositories already share this action. `diff` is 14 lines, all prose |
| `.github/actions/publish-dockerhub/action.yml` | — | **Missing, and it is the fix for [RC-3](ROOT-CAUSES.md#rc-3).** It builds **one registry per invocation** with `push-by-digest=true`, so one registry's credentials cannot fail another registry's push |

### 1c. CI scripts

| Template script | Box equivalent | Gap |
| --- | --- | --- |
| `scripts/check-file-line-limits.sh` | — | **Missing.** This is the check that would have flagged `release.yml` at 3432 lines |
| `scripts/simulate-fresh-merge.sh` | — | **Missing.** Box tests the merge preview, not the actual merge result (best practice #7) |
| `scripts/publish-failure-classifier.mjs`, `scripts/push-failure-classifier.mjs` | — | **Missing, and it is the fix for [RC-5](ROOT-CAUSES.md#rc-5).** The template's classifier lists `401`/`403`/`access token expired` as `NON_RETRYABLE_PATTERNS` and refuses to retry them; box retries an expired token three times |
| `scripts/detect-code-changes.mjs` | `scripts/ci/detect-changes.sh` | Present in both — box satisfies best practice #1 |
| `scripts/check-changesets.mjs`, `check-version.mjs`, `validate-changeset.mjs`, `changeset-version.mjs` | `scripts/release/check-changesets.sh`, `check-version.sh`, `validate-changeset.sh`, `apply-changesets.sh`, `create-changeset.sh` | Present in both — box satisfies best practice #6 |
| `scripts/check-web-archive.mjs` | — | Missing, follows from `links.yml` being missing |
| `scripts/lint.mjs`, `lint-changed-lines.mjs` | — | No linter of any kind runs in box CI |
| — | `scripts/ci/supersede.sh` | Box-only, added for issue #112. No template counterpart; keep |
| — | `scripts/release/docker-push-with-retry.sh` | Box-only, and **dead code**: `grep -rn docker-push-with-retry` finds no caller. Meanwhile `release.yml` carries **ten hand-copied inline retry loops** that are worse than it (no classifier, no per-tag isolation) |

### 1d. Tool configuration and hooks

| Template | Box | Gap |
| --- | --- | --- |
| `.github/zizmor.yml` | — | **Missing.** The template's `unpinned-uses` policy allows tag pins only for a named allow-list of publishers and requires hash pins for everything else. Box uses `jlumbroso/free-disk-space@main` — a mutable branch — in every build job |
| `.husky/pre-commit` + `lint-staged` | — | **Missing.** Best practice #8 |
| `.secretlintrc.json` | — | **Missing.** Best practice #11 |
| `.prettierrc`, `.prettierignore` | — | **Missing.** Best practice #3 |
| `.jscpd.json` | — | Missing. Duplication detection — directly relevant given the ten copied retry blocks |
| `.lycheeignore` | — | Missing, follows from `links.yml` |
| `.changeset/config.json` | `.changeset/config.json` | Present in both |

---

## Part 2 — The 15 hive-mind principles, scored

| # | Principle | Box | Evidence |
| --- | --- | --- | --- |
| 1 | Run checks only on relevant file changes | **Pass** | `scripts/ci/detect-changes.sh` + a `detect-changes` job feeding every build gate |
| 2 | File size limits (1500 lines) | **Fail** | `release.yml` 3432. No check enforces it ([RC-8](ROOT-CAUSES.md#rc-8)) |
| 3 | Automated code formatting | **Fail** | No prettier/shfmt, no `format:check` job |
| 4 | Static analysis and linting | **Fail** | No actionlint, no zizmor, no shellcheck job. 83 + 173 + 15 findings sit unreported ([RC-6](ROOT-CAUSES.md#rc-6)) |
| 5 | Fast-fail job ordering | **Fail** | The slowest thing in the repository — a 22-minute image build — starts before anything cheap has validated the change. Run 33972074755 spent ~40 min on 44 builds after a credential failure was already known at 14:34:38 |
| 6 | Changeset-based versioning | **Pass** | `scripts/release/*changeset*.sh`, `Apply Changesets` job succeeded even in the failing run |
| 7 | Validate the actual merge result | **Fail** | No `simulate-fresh-merge.sh`; jobs check out `ref: main` or the merge preview |
| 8 | Pre-commit hooks | **Fail** | No `.husky/` |
| 9 | Release automation | **Partial** | Automated, but gated on image pushes to two registries at once, so one expired token stops the release ([RC-3](ROOT-CAUSES.md#rc-3)). Principle #13 explicitly says never gate the release on the image push |
| 10 | Concurrency control | **Fail** | `always()` × 24, `!cancelled()` × 0 ([RC-7](ROOT-CAUSES.md#rc-7)); `measure-disk-space.yml` sets `cancel-in-progress: true` on a `contents: write` job that pushes to `main` — the read/write separation the principle requires is inverted |
| 11 | Secrets detection | **Fail** | No secretlint |
| 12 | Documentation validation | **Fail** | No `validate-docs`, no link checking |
| 13 | Native runners per architecture, no QEMU, always cache, never gate release on image push, assert published manifests | **Partial** | Native `ubuntu-24.04` / `ubuntu-24.04-arm` runners: **pass**. Cache: **fails in practice** — the coupled push cancels the cache export (`#18 CANCELED`). Never gate release on push: **fail**. Assert published manifests: **fail** — nothing verified that `konard/box-js:2.5.0-amd64` actually existed before 28 dind jobs tried to pull it ([RC-4](ROOT-CAUSES.md#rc-4)) |
| 14 | Lint the workflows themselves | **Fail** | The single most directly-applicable principle, and the one with no implementation at all |
| 15 | Audit the dependency tree | **Fail** | No scheduled audit, no dependency review, no CodeQL |

**Score: 2 pass, 2 partial, 11 fail.**

---

## Part 3 — Defects that also exist in the template ([R4](REQUIREMENTS.md#r4))

The shared surface between the two repositories is the composite action
`setup-buildx-resilient` (byte-identical apart from comments) and the general
release/changeset shape. Findings to report upstream are recorded in
[`SOLUTION-PLAN.md`](SOLUTION-PLAN.md#s7) once each has been reproduced against
a clean checkout of the template, so that every report carries a reproducible
example, a workaround and a suggested code fix as required.
