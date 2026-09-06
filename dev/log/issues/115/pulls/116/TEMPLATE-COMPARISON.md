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

**Two states are recorded throughout.** *As found* is `42be663`, the commit whose
two failing runs opened the issue. *Now* is the head of this pull request. The
ledger of what changed and in which commit is [Part 4](#part-4--adoption-ledger).

---

## Part 1 — Full file-tree comparison of the CI/CD surface

`git ls-files` on both sides, restricted to workflows, composite actions, CI
scripts, hooks and tool configuration.

### 1a. Workflows

| Template | Lines | Box | As found | Now | State |
| --- | --- | --- | --- | --- | --- |
| `.github/workflows/release.yml` | 890 | `.github/workflows/release.yml` | **3432** | **596** | **Under the limit.** −364 lines by extraction (`create-multiarch-manifest.sh`, `build-release-notes.sh`, `test-box.sh`), then split along the seam the duplication followed: one `workflow_call` workflow per image family, plus `pr-tests.yml` ([RC-8](ROOT-CAUSES.md#rc-8)). Proved to be a move rather than a rewrite by `analysis/verify-split-equivalence.py` |
| — | — | `.github/workflows/pr-tests.yml` | — | 671 | **Box-only, new** (from the split). The six `pr-test-*` jobs and the `docker-build-test` aggregator |
| — | — | `.github/workflows/release-js.yml` | — | 414 | **Box-only, new** (from the split). `on: workflow_call` |
| — | — | `.github/workflows/release-essentials.yml` | — | 469 | **Box-only, new** (from the split) |
| — | — | `.github/workflows/release-languages.yml` | — | 604 | **Box-only, new** (from the split) |
| — | — | `.github/workflows/release-full.yml` | — | 626 | **Box-only, new** (from the split) |
| — | — | `.github/workflows/release-dind.yml` | — | 450 | **Box-only, new** (from the split) |
| — | — | `.github/workflows/file-sizes.yml` | — | 91 | **Box-only, new.** Runs the ported line-limit gate. Its own workflow rather than a job in Scripts, because it checks Markdown and YAML too, and a gate that skips documentation-only pull requests has a hole in it |
| `.github/workflows/workflows.yml` | 69 | `.github/workflows/workflows.yml` | — | 78 | **Adopted.** actionlint + zizmor, both pinned. Closes [RC-6](ROOT-CAUSES.md#rc-6) |
| `.github/workflows/security.yml` | 93 | `.github/workflows/security.yml` | — | 107 | **Adopted** in `53dacc2`. CodeQL (`javascript-typescript`, `python` and `actions`, scoped by `.github/codeql-config.yml` to our own tree rather than the vendored evidence under `dev/log/`) and secretlint, which validates itself against a planted canary before its silence is believed ([RC-16](ROOT-CAUSES.md#rc-16)). `dependency-review` and `npm audit` did not transfer — this repository has no root `package.json` |
| `.github/workflows/links.yml` | 104 | `.github/workflows/links.yml` | — | 130 | **Adopted** in `ee78f40`. lychee with the Web-Archive fallback, on change, weekly and on demand. Its first run is the baseline in `logs/lychee-baseline-024dd6a.log` ([RC-17](ROOT-CAUSES.md#rc-17)) |
| `.github/workflows/example-app.yml` | 318 | — | — | — | Not applicable — template-specific demo app |
| — | — | `.github/workflows/scripts.yml` | — | 131 | **Box-only, new.** shellcheck over all 88 tracked scripts, the quoted-heredoc checker, and every regression suite. The template lints `.mjs`; this is the same practice applied to the language this repository is actually written in |
| — | — | `.github/workflows/dockerfiles.yml` | — | 70 | **Box-only, new.** hadolint over all 23 tracked Dockerfiles. No template counterpart — the template ships no Dockerfile — but principle #4 applies to the 7.9 % of this repository that is one |
| — | — | `.github/workflows/measure-disk-space.yml` | 212 | 289 | Box-specific. Gained the `pull_request` trigger it never had ([RC-2](ROOT-CAUSES.md#rc-2)) |

### 1b. Composite actions

| Template | Box | State |
| --- | --- | --- |
| `.github/actions/setup-buildx-resilient/action.yml` | same file, present | Identical apart from comment wording — the two repositories already share this action. `diff` is 14 lines, all prose |
| `.github/actions/publish-dockerhub/action.yml` | — | **Practice adopted, file not copied.** The template's action builds **one registry per invocation** so one registry's credentials cannot fail another's push. Box reached the same separation from the other end: GHCR is the registry of record and Docker Hub a mirror (`scripts/release/mirror-to-dockerhub.sh`), which is what [RC-3](ROOT-CAUSES.md#rc-3) required. Copying the action itself would mean adopting `push-by-digest` across 12 build jobs — a larger change than the defect warrants |

### 1c. CI scripts

| Template script | Box equivalent | State |
| --- | --- | --- |
| `scripts/check-file-line-limits.sh` | `scripts/ci/check-file-line-limits.sh` | **Adopted**, once the split brought `release.yml` under the limit ([RC-8](ROOT-CAUSES.md#rc-8)). Widened from the template's "JavaScript, Markdown and release.yml" to every `.sh`/`.md`/`.yml`/`.yaml`/`.mjs`/`.js`/`.cjs`/`.py`/`.rb` file, over `git ls-files` rather than `find` (an untracked build artefact must not be able to fail the gate), with the verbatim upstream copies under `dev/log/` and `docs/case-studies/*/data\|templates/` exempt. Two additions the template does not have: it exits 2 rather than 0 when it matches no files at all (RC-16), and the annotation names the remedy for the file kind — a workflow is told to extract a reusable workflow, a script to move code into `scripts/`. Pinned by `experiments/test-issue115-line-limits.sh`, including the case that matters: the real 3135-line pre-split `release.yml` fails it. Both additions were reported back to the template as [#174](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/174), with four reproductions — see [`UPSTREAM-REPORTS.md`](UPSTREAM-REPORTS.md) |
| `scripts/simulate-fresh-merge.sh` | `scripts/ci/simulate-fresh-merge.sh` | **Adopted**, plus the two parts a shallow-by-default checkout needs: it deepens before merging (`--depth 1` leaves no common ancestor, and the resulting *unrelated histories* error is not a conflict) and separates a conflict, exit 1, from CI misuse, exit 2 ([RC-19](ROOT-CAUSES.md#rc-19)). Wrapped in `.github/actions/simulate-fresh-merge` and called by all sixteen pull-request jobs. Not reported upstream: the template checks out with `fetch-depth: 0` at every call site, so neither addition fixes a live defect there ([`UPSTREAM-REPORTS.md`](UPSTREAM-REPORTS.md)) |
| `scripts/publish-failure-classifier.mjs`, `scripts/push-failure-classifier.mjs` | `scripts/release/docker-push-failure-classifier.sh` | **Adopted**, as shell. Box retried an expired token three times; the classifier now refuses to retry `401`/`403`/`denied`/`unauthorized` and fails fast instead ([RC-5](ROOT-CAUSES.md#rc-5)). Pinned by `experiments/test-issue115-push-retry-classifier.sh` |
| `scripts/detect-code-changes.mjs` | `scripts/ci/detect-changes.sh` | Present in both — box satisfies best practice #1 |
| `scripts/check-changesets.mjs`, `check-version.mjs`, `validate-changeset.mjs`, `changeset-version.mjs` | `scripts/release/check-changesets.sh`, `check-version.sh`, `validate-changeset.sh`, `apply-changesets.sh`, `create-changeset.sh` | Present in both — box satisfies best practice #6 |
| `scripts/check-web-archive.mjs` | `scripts/ci/check-web-archive.mjs` | **Adopted** in `ee78f40`, alongside `links.yml`. Suggests a Wayback replacement for each dead URL before the job fails, so a broken link arrives with its own fix |
| `scripts/lint.mjs`, `lint-changed-lines.mjs` | `scripts/ci/run-shellcheck.sh`, `scripts/ci/run-hadolint.sh` | **Adopted**, in the languages this repository is written in. Both discover their file set from `git ls-files`, so a new file is linted the moment it lands; both are the identical command CI runs, so a developer reproduces a CI failure with one line |
| — | `scripts/ci/supersede.sh` | Box-only, added for issue #112. No template counterpart; keep |
| — | `scripts/release/docker-push-with-retry.sh` | Was **dead code** while `release.yml` carried ten hand-copied inline retry loops. Now the single retry path, wired to the classifier |
| — | `scripts/ci/test-box.sh` | Box-only, new: one acceptance check per box, replacing per-job inline blocks. Runs the tool-presence checks offline (`--network none`), which is what caught [RC-14](ROOT-CAUSES.md#rc-14) |
| — | `scripts/release/assert-base-image.sh`, `create-multiarch-manifest.sh`, `build-release-notes.sh` | Box-only, new: the three largest blocks of duplicated inline YAML, extracted and unit-tested |

### 1d. Tool configuration and hooks

| Template | Box | State |
| --- | --- | --- |
| `.github/zizmor.yml` | `.github/zizmor.yml` | **Adopted.** `jlumbroso/free-disk-space@main` — a mutable branch — is now hash-pinned to `54081f13` (v1.3.1) in every build job |
| — | `.hadolint.yaml` | **Box-only, new.** `failure-threshold: warning`, one documented ignore (`DL3008`, for the issue-#112 reason). No template counterpart |
| `.husky/pre-commit` + `lint-staged` | — | **Skipped with reason.** husky installs from `package.json`'s `prepare` script; this repository has no root `package.json` and adding npm to a Docker-image factory to gain a hook is a worse trade than the hook is worth. The checks a hook would run (shellcheck, actionlint, hadolint) all run in CI and are all reproducible locally with the single command each workflow prints |
| `.secretlintrc.json` | `.secretlintrc.json` | **Adopted** in `53dacc2`. `@secretlint/secretlint-rule-preset-recommend`. Best practice #11 |
| `.prettierrc`, `.prettierignore` | `scripts/ci/run-shfmt.sh` (style in the script, not a dotfile) | **Adopted**, in the language this repository is written in. `shfmt -i 2 -ci -bn`, chosen by measuring all six candidate styles against the tree; the style lives with the runner so CI and a developer cannot disagree about it |
| `.jscpd.json` | — | **Skipped with reason.** jscpd is npm-only and its target here — the ten copied retry blocks and the duplicated manifest steps — has been removed by extraction rather than measured |
| `.lycheeignore` | `.lycheeignore` | **Adopted** in `ee78f40`. Holds only URLs that are correct but unverifiable from CI — nothing that is merely broken |
| `.changeset/config.json` | `.changeset/config.json` | Present in both |

---

## Part 2 — The 15 hive-mind principles, scored

"As found" is `42be663`; "Now" is this pull request's head.

| # | Principle | As found | Now | Evidence |
| --- | --- | --- | --- | --- |
| 1 | Run checks only on relevant file changes | **Pass** | **Pass** | `scripts/ci/detect-changes.sh` + a `detect-changes` job feeding every build gate |
| 2 | File size limits (1500 lines) | **Fail** | **Pass** | `release.yml` 3432 → 596, split into seven workflows; every tracked file is under the limit and `.github/workflows/file-sizes.yml` keeps it that way ([RC-8](ROOT-CAUSES.md#rc-8)) |
| 3 | Automated code formatting | **Fail** | **Pass** | `scripts/ci/run-shfmt.sh` and the `scripts / formatting` job; 73 of the 96 tracked scripts reformatted ([RC-20](ROOT-CAUSES.md#rc-20)). The reformat also silently disabled the skip list of the runner that runs every other check, which is recorded as its own root cause ([RC-21](ROOT-CAUSES.md#rc-21)) rather than quietly fixed |
| 4 | Static analysis and linting | **Fail** | **Pass** | actionlint + zizmor (`workflows.yml`), shellcheck over 88 scripts (`scripts.yml`), hadolint over 23 Dockerfiles (`dockerfiles.yml`). The 83 + 173 + 15 findings that sat unreported are fixed and gated ([RC-6](ROOT-CAUSES.md#rc-6)) |
| 5 | Fast-fail job ordering | **Fail** | **Partial** | The lint workflows are separate and finish in seconds, and `assert-base-image.sh` fails a build before it spends 22 minutes on a `FROM` that does not exist ([RC-4](ROOT-CAUSES.md#rc-4)). Within `release.yml` the build jobs still start off `detect-changes` alone |
| 6 | Changeset-based versioning | **Pass** | **Pass** | `scripts/release/*changeset*.sh` |
| 7 | Validate the actual merge result | **Fail** | **Pass** | All sixteen pull-request jobs merge the base tip in before checking anything, so a green check means "green after merging" rather than "green against the preview GitHub computed at the last push" ([RC-19](ROOT-CAUSES.md#rc-19)). Measured over the last 25 merges, that preview was never stale at merge time here — this repository merges one pull request at a time — so the row closes a latent false positive, not a demonstrated one, and says so |
| 8 | Pre-commit hooks | **Fail** | **Skipped** | No `package.json` to hang husky off; see 1d |
| 9 | Release automation | **Partial** | **Pass** | One registry can no longer fail another's push ([RC-3](ROOT-CAUSES.md#rc-3)), and `create-release` no longer requires `docker-manifest` to have succeeded — an expired Docker Hub token used to mean the tagged commit got no GitHub Release at all ([RC-18](ROOT-CAUSES.md#rc-18)). The notes now report which references the registries actually answer for |
| 10 | Concurrency control | **Fail** | **Pass** | `always()` × 24 → × 0; `!cancelled()` × 0 → × 24 ([RC-7](ROOT-CAUSES.md#rc-7)). `measure-disk-space.yml` no longer cancels its own `contents: write` main-writer |
| 11 | Secrets detection | **Fail** | **Pass** | `scripts/ci/run-secretlint.sh`, run by `security.yml`. It validates itself against a generated canary before it reports on the tree — a clean scan that proves nothing is the defect this check exists to avoid ([RC-16](ROOT-CAUSES.md#rc-16)) |
| 12 | Documentation validation | **Fail** | **Pass** | `links.yml` runs lychee over every tracked markdown file on change, weekly and on demand. The first run found 113 failures over 16 files, 107 distinct URLs — 85 of them GHCR package pages for images that have never been pushed ([RC-17](ROOT-CAUSES.md#rc-17)); every one is fixed, `.lycheeignore` holds only correct-but-unverifiable URLs, and `scripts/ci/check-web-archive.mjs` suggests a Wayback replacement before the job fails |
| 13 | Native runners, no QEMU, always cache, never gate release on image push, assert published manifests | **Partial** | **Pass** | Native runners: pass. Cache: no longer cancelled by a coupled push. Never gate release on push: pass ([RC-18](ROOT-CAUSES.md#rc-18)). Assert published manifests: pass, in both directions — `assert-base-image.sh` checks a `FROM` exists before the build, and `VERIFY_IMAGES=1` makes the release notes state, per reference, whether it resolves, distinguishing *missing* from *the registry would not answer* |
| 14 | Lint the workflows themselves | **Fail** | **Pass** | `workflows.yml`, both linters pinned by digest-bearing tag, both reproducible locally with the command the workflow prints |
| 15 | Audit the dependency tree | **Fail** | **Partial** | CodeQL over `javascript-typescript`, `python` and `actions`, on every push, pull request and weekly. `dependency-review`/`npm audit` still do not transfer — no root `package.json`, no lockfile, so both would report green forever |

**Score: 2 pass, 2 partial, 11 fail → 11 pass, 2 partial, 1 fail, 1 skipped-with-reason.**

---

## Part 3 — Defects that also exist in the template ([R4](REQUIREMENTS.md#r4))

The shared surface between the two repositories is the composite action
`setup-buildx-resilient` (byte-identical apart from comments) and the general
release/changeset shape. Findings to report upstream are recorded in
[`SOLUTION-PLAN.md`](SOLUTION-PLAN.md#s7) once each has been reproduced against
a clean checkout of the template, so that every report carries a reproducible
example, a workaround and a suggested code fix as required.

---

## Part 4 — Adoption ledger

Every row of Parts 1 and 2 that moved, and the commit that moved it.

| Practice adopted | Commit | Pinned by |
| --- | --- | --- |
| actionlint + zizmor, `.github/zizmor.yml`, hash-pinned third-party actions | `12992f8` | `experiments/test-issue115-ci-policy.sh` |
| `!cancelled()` for `always()`, everywhere | `12992f8` | `experiments/test-issue115-ci-policy.sh` |
| Non-retryable registry failures fail fast | `7e46ce8` | `experiments/test-issue115-push-retry-classifier.sh` |
| Assert a base image exists before building `FROM` it | `30801ee` | `experiments/test-issue115-base-image-preflight.sh` |
| Every regression suite runs in CI | `149f807` | `scripts/ci/run-experiments.sh --list` |
| GHCR the registry of record, Docker Hub a mirror | `a385c41` | `experiments/test-issue115-registry-split.sh` |
| shellcheck over every tracked script | `fa0fd07` | `experiments/test-issue115-shellcheck-gate.sh` |
| Duplicated manifest steps extracted | `ca338c7` | `experiments/test-issue115-manifest-script.sh` |
| Release notes generated, not hand-written | `bff4bf4` | `experiments/test-issue115-release-notes.sh` |
| One acceptance script per box, run offline | `780b762`, `8faf836` | `experiments/test-issue115-test-box.sh` |
| hadolint over every tracked Dockerfile; no bare `apt` | `46f80a5` | `experiments/test-issue115-hadolint-gate.sh` |
| Change detection degrades instead of dying on a shallow checkout | `9145c0e` | `experiments/test-issue108-detect-changes.sh` (Part 2b) |
| secretlint + CodeQL, with a canary that proves the scanner ran | `53dacc2` | `experiments/test-issue115-secretlint-gate.sh` |
| CodeQL scoped to our own tree, not the vendored evidence | `c7c5350` | `experiments/test-issue115-secretlint-gate.sh` |
| Link checking, with a Wayback fallback and an ignore file that may only hold false positives | `ee78f40` | `experiments/test-issue115-links-gate.sh` |
| The GitHub Release is no longer gated on an image push, and the notes assert what was published | `aa9f54e` | `experiments/test-issue115-release-notes.sh` (Part 5) |
| Every pull-request check runs against the real merge result, not a stale preview | `aca301c` | `experiments/test-issue115-fresh-merge.sh` |
| Automated formatting: `shfmt` over every tracked script, with a canary that proves the formatter looked | `7488af9` | `experiments/test-issue115-shfmt-gate.sh` |
| The runner that runs every other check is itself checked, and its skip list must name real files | `7488af9` | `experiments/test-issue115-experiment-runner.sh` |
| `release.yml` split by image family, and a line-limit gate so it cannot grow back | `7af5cf5` | `experiments/test-issue115-workflow-split.sh`, `experiments/test-issue115-line-limits.sh`, `analysis/verify-split-equivalence.py` |
| Workflows read a script through a parser instead of matching its formatting, so the formatter cannot break them | `ef5c29e` | `experiments/test-issue115-heredoc-extraction.sh` |
| The heredoc gate no longer reads an example of a heredoc as a heredoc (quote- and herestring-aware) | `ef5c29e` | `experiments/test-issue115-heredoc-unbound-vars.sh` (Part 2) |
