# Case Study: Issue #108 — CI runs the full build/test matrix for non-essential changes (`.gitkeep`, docs)

## Executive Summary

The Build and Release workflow (`.github/workflows/release.yml`) re-ran the
**entire** PR build/test matrix whenever a pull request was synchronized,
**even if the new commit only touched a non-essential file** such as `.gitkeep`,
a Markdown doc, or a changeset. The worked example from the issue is commit
[`eaeed07`](https://github.com/link-foundation/box/pull/107/commits/eaeed07bcfc8b5b9069a0c5bb8d2307f2bc6744b)
in PR #107 — a `Revert "Initial commit with task details"` that deleted a single
line from `.gitkeep` — whose PR check run
([27826090748](https://github.com/link-foundation/box/actions/runs/27826090748))
executed **32 non-skipped jobs**, the longest being `pr-test / dind-full` at
**32 m 48 s** and `pr-test / full` at **32 m 21 s**.

**Root cause:** the inline `detect-changes` job diffed the **whole pull request**
against its base branch (`github.event.pull_request.base.sha..HEAD`). So once
*any* commit anywhere in the PR's history touched image source, *every*
subsequent commit — including trivial ones — was classified as "should build".

**Fix:** the change-detection logic is extracted into a single, unit-tested
script, `scripts/ci/detect-changes.sh`, which for `pull_request` events diffs
**only the PR head's latest commit** (`HEAD^2^..HEAD^2` against GitHub's
synthetic merge commit) instead of the whole PR. A trivial synchronize commit
now skips the build/test matrix; earlier commits that changed image source were
already exercised when they were pushed. `push` events still diff the full
pushed range so a real release build is never skipped. This mirrors the
canonical `detect-code-changes` scripts already shipped by all four
link-foundation pipeline templates.

The referenced run
[27826405731](https://github.com/link-foundation/box/actions/runs/27826405731)
was audited end-to-end: **0 errors**, and every "warning" is benign/by-design
(see §5). The run itself is *not* a false positive — it is the legitimate
push/release build for the merge of PR #107.

---

## 1. Timeline of events (UTC)

| Time (2026-06-19) | Event |
|---|---|
| 12:36:46 | PR #107 synchronized with commit `eaeed07` (`Revert "Initial commit with task details"` — deletes **1 line from `.gitkeep`**, nothing else). |
| 12:36:46 | `pull_request` run **27826090748** starts and runs **32 jobs** (full PR matrix) — `dind-full` 32 m 48 s, `full` 32 m 21 s, `dind-rocq` 13 m 34 s, … — because an *earlier* commit on the PR changed `ubuntu/24.04/dind/`. **This is the false positive.** |
| 12:43:31 | PR #107 merged to `main`. `push` run **27826405731** starts — the legitimate release build (VERSION bumped to 2.3.4). |
| ~13:50 | Run 27826405731 finishes: **success**, 0 errors. The only GitHub `::warning::` annotations are the 28 `jlumbroso/free-disk-space` soft-failures (see §5). |
| 12:43:33 (issue) | Issue #108 filed: *"We should not execute tests or any other CI/CD when only non essential files like .gitkeep changes."* |

Data backing this table is saved under `data/`:
`false-positive-run-27826090748-jobs.json` (the 32-job evidence),
`issue-108.json` (issue body), and `../../../ci-logs/run-27826405731-full.log`
(213 k-line full log of the audited run).

---

## 2. Requirements extracted from the issue

| # | Requirement | Status |
|---|---|---|
| R1 | Do **not** run tests/CI for non-essential changes (`.gitkeep`, docs, other files that don't affect image builds). | ✅ Fixed — per-commit detection; docs/`.gitkeep`/changeset/experiments/examples no longer trigger the build matrix. |
| R2 | Audit run 27826405731 for false positives, errors, **and all warnings**; fix them. | ✅ Audited — 0 errors; all warnings classified benign/by-design (§5). The "false positive" is the *PR* run 27826090748, fixed by R1. |
| R3 | Compare **all** workflow/CI files against the 4 pipeline templates; reuse best practices; if the same bug exists in a template, file an upstream issue. | ✅ Compared — all 4 templates already use the per-commit `HEAD^2^..HEAD^2` approach; box was the only repo with the whole-PR-diff bug. Nothing to report upstream (§6). |
| R4 | Download all logs/data to `docs/case-studies/issue-108/` and do a deep case study (timeline, requirements, root causes, solutions, existing components). | ✅ This document + `data/`. |
| R5 | If data is insufficient for root cause, add debug/verbose output for the next iteration. | ✅ `detect-changes.sh` is verbose by default (prints the diff range, every classified file, every flag, and the build reason to the run log). |
| R6 | If the issue relates to other repos, file issues there with reproducible examples + workarounds + fix suggestions. | ✅ N/A — see §6. Templates are already correct; the only third-party warning source is documented as intentional upstream behavior. |
| R7 | Apply the fix across the **entire** codebase (fix everywhere it occurs). | ✅ There was exactly one detection site (`release.yml`); `measure-disk-space.yml` uses a static `on: paths` filter and is unaffected. Verified by grep (§4.2). |

---

## 3. Root-cause analysis

### 3.1 The build decision used the whole-PR diff

GitHub Actions checks out a **synthetic merge commit** for `pull_request`
events (`refs/pull/N/merge`): `HEAD^1` is the base branch tip and `HEAD^2` is
the PR head. The old `detect-changes` step computed:

```sh
BASE_SHA="${{ github.event.pull_request.base.sha }}"
CHANGED_FILES=$(git diff --name-only "$BASE_SHA" HEAD)
```

`base.sha..HEAD` is the **cumulative** diff of the whole PR. So if commit 1
edited `ubuntu/24.04/dind/entrypoint.sh` and commit 2 only deleted a line from
`.gitkeep`, the synchronize event for commit 2 still saw `ubuntu/...` in the
diff and set `should-build=true`, re-running the full ~33-minute matrix for a
no-op change. This is precisely what happened on `eaeed07`.

### 3.2 Why per-commit detection is correct

Each push to a PR triggers its own check run. The commit that *first* changed
image source was already tested when it was pushed. Re-testing identical image
source on every later commit is pure waste. Diffing only the PR head's latest
commit (`HEAD^2^..HEAD^2`) tests exactly what the newest push changed:

- `.gitkeep` / docs / changeset latest commit → `should-build=false` → matrix skipped.
- image-source latest commit → `should-build=true` → matrix runs.

For `push` events (including the merge-to-`main` release commit) we keep the
**full pushed range** (`github.event.before..HEAD`) so a real release build is
never skipped.

### 3.3 Secondary issue: `docs/dind/` triggered the dind build

The old per-image step set `dind=true` for `^(ubuntu/24\.04/dind/|docs/dind/|tests/dind/)`.
Including `docs/dind/` meant a pure documentation edit could trigger the
14-variant dind matrix — a direct violation of R1. The extracted script drops
`docs/dind/`: only image source (`ubuntu/24.04/dind/`) and the CI example tests
that exercise it (`tests/dind/`) trigger the dind build.

---

## 4. The fix (this PR)

### 4.1 What changed

1. **New `scripts/ci/detect-changes.sh`** — single source of truth for change
   detection. Resolves the diff range per event (per-commit for PRs, full range
   for pushes), classifies files into the existing box categories
   (docker/scripts/ubuntu/workflow/version + per-image + 13 languages), and
   writes every flag plus the aggregate `should-build` to `$GITHUB_OUTPUT`. It
   is **verbose by default** (R5) and **unit-testable** via a
   `CHANGED_FILES_OVERRIDE` env var that bypasses git.

2. **`release.yml` `detect-changes` job** — the four inline shell steps
   (`Detect changes`, `Detect per-image changes`, `Detect per-language changes`,
   `Determine if build is needed`) are replaced by one step that runs the
   script; all job `outputs:` now reference the single `steps.detect` id. The
   checkout `fetch-depth` is changed from `2` to `0` so the merge commit's
   parents are resolvable, and `docs/dind/` is removed from the dind trigger.

3. **New `experiments/test-issue108-detect-changes.sh`** — reproducing +
   regression test (21 assertions). Part 1 checks the classification truth
   table via `CHANGED_FILES_OVERRIDE`; Part 2 builds throwaway git repos that
   reproduce the synthetic merge commit and proves that a PR whose **latest**
   commit is `.gitkeep` skips the build while a PR whose latest commit changes
   an image builds, and that `push` ranges still evaluate the whole range.

### 4.2 Applied across the whole codebase (R7)

`grep` confirms there was exactly one change-detection implementation:

- `release.yml` — fixed (this PR).
- `measure-disk-space.yml` — uses a static `on: push: paths:` filter scoped to
  specific scripts/Dockerfile; it has no `pull_request` trigger and no per-PR
  detection, so it is unaffected and correct as-is.

### 4.3 Existing components / prior art considered

- **GitHub `on: paths` filters** — rejected as the primary mechanism. A
  whole-workflow path-skip leaves required status checks **Pending**, which
  *blocks* PR merge under branch protection. Box's design (always run the
  workflow; gate expensive jobs with job-level `if`) is correct: a job skipped
  by `if` reports **skipped = success**, so the required `docker-build-test`
  check stays green and the PR remains mergeable. The fix preserves this.
- **`dorny/paths-filter`**, **`tj-actions/changed-files`** — capable actions,
  but they default to whole-PR diffs and would re-introduce the bug unless
  configured for per-commit comparison; they also add a third-party dependency
  for logic that is ~150 lines of portable shell. The link-foundation templates
  deliberately use a hand-rolled per-commit script for the same reason.
- **link-foundation pipeline templates** — the canonical prior art. All four
  already extract detection into a standalone script using `HEAD^2^..HEAD^2`
  (see §6); this PR brings box in line with them.

---

## 5. Audit of run 27826405731 — warnings classified (R2)

The full log (`ci-logs/run-27826405731-full.log`, 213 514 lines) contains **0
errors**. Warning-bearing lines, by category:

| Source | Count | GitHub UI annotation? | Verdict |
|---|---|---|---|
| `jlumbroso/free-disk-space@main` — `::warning::The command [sudo apt-get remove …] failed … Proceeding...` | 28 distinct annotations | **Yes** (`::warning::`) | **Benign by design.** The action soft-fails when a package in its hardcoded list isn't installed and continues. `large-packages: true` frees ~5.3 GB that the image builds need (issue #82); disabling it to silence cosmetic noise would risk re-introducing "no space left on device" build failures. Cannot be suppressed without forking the action. |
| `git` — `hint: Using 'master' as the name for the initial branch … to suppress this warning` | 87 | No (plain stdout) | Emitted by **`actions/checkout`**'s internal `git init`, which doesn't set `init.defaultBranch`. Upstream cosmetic; not a build defect and not box code. |
| box `setup-buildx-resilient` — `==> WARNING: could not pre-pull ${BUILDKIT_IMAGE} … letting setup-buildx try its own boot pull` | 56 (command echoes) | No | Intentional fallback logging from the issue #100 buildx mirror resilience. The fallback path is by design. |
| `update-alternatives: warning: skip creation of …f77.1.gz…` (gfortran man pages) | a few | No | Cosmetic, emitted by an apt package install **inside the docker build**. |
| `warning: could not canonicalize path '/home/box/.elan/toolchains'` (Lean/elan) | 3 | No | Cosmetic, inside the docker build. |
| `Playwright Host validation warning`, `Warning: Sandbox unavailable …` | a few | No | Cosmetic, emitted by JS/Playwright/bun post-install **inside the docker build**. |

**Conclusion:** the only warnings that surface in the GitHub UI are the
free-disk-space soft-failures, which are an intentional, non-fatal property of a
widely-used third-party action and are required for disk headroom. The biggest
real reduction in CI noise comes from R1: for non-essential commits these jobs
**don't run at all**, so they emit no warnings.

---

## 6. Template comparison and upstream reports (R3, R6)

All four pipeline templates' release workflows and detection scripts were
downloaded to `data/` and compared:

| Template | Detection mechanism | Per-commit PR diff? |
|---|---|---|
| js-ai-driven-development-pipeline-template | `scripts/detect-code-changes.mjs` (`data/js-template-detect-code-changes.mjs`) | ✅ `HEAD^2^..HEAD^2` |
| rust-…-template | `scripts/detect-code-changes.rs` (`data/rust-template-detect-code-changes.rs`) | ✅ `HEAD^2^..HEAD^2` |
| python-…-template | `scripts/detect-code-changes.mjs` (referenced from `data/python-template-release.yml`) | ✅ (same family) |
| csharp-…-template | `scripts/detect-code-changes.mjs` (`bun run … detect-code-changes.mjs`, `data/csharp-template-release.yml`) | ✅ (same family) |

Every template **already** implements the per-commit approach this PR adds to
box. The bug was box-specific (whole-PR diff in an inline step), so there is
**nothing to report upstream** for the detection logic.

Best practices adopted from the templates:
- Extract detection into a **single, standalone, unit-testable script** (done).
- **Per-commit** PR-head diff for `pull_request`; full pushed range for `push`.
- Keep the workflow always-on for PRs and gate expensive work with **job-level
  `if`** so required checks stay green (box already did this; preserved).

The only third-party warning source (`jlumbroso/free-disk-space`) emits its
`Proceeding...` annotations by explicit design (`… || echo "::warning::…"`); a
"reduce cosmetic warning noise" issue there would be a duplicate of long-standing
upstream discussion and is not filed.

---

## 7. Verification

- `bash experiments/test-issue108-detect-changes.sh` → **21 passed, 0 failed**
  (stable across repeated runs).
- `bash experiments/test-issue90-release-workflow-policy.sh` (UTF-8 locale) →
  existing release-workflow policy checks still pass.
- `ruby -ryaml -e 'YAML.load_file(".github/workflows/release.yml")'` → valid YAML.
- Manual matrix spot-checks: `.gitkeep`, `README.md`, docs-only,
  `experiments/`, `examples/`, `.changeset/` → `should-build=false`;
  `Dockerfile`, `scripts/`, `ubuntu/24.04/<lang>/`, `ubuntu/24.04/dind/`,
  `tests/dind/`, `VERSION`, `.github/workflows/` → `should-build=true`;
  `workflow_dispatch` → always `true`.
