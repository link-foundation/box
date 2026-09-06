# Solution plan

One numbered step per requirement, in execution order. Every step names the
test that proves it, because a fix without a failing-then-passing test is not
verifiable ([RC-1](ROOT-CAUSES.md#rc-1) reached `main` precisely because nothing
executed the changed code).

Ordering principle: **the checks come before the fixes they justify.** Each
check is committed in a state where it fails against the current tree, then the
fix turns it green — so the pull request itself demonstrates that the check
works.

---

<a id="s1"></a>
## S1 — RC-1: quoted-heredoc variable leak (R1, R2, T6)

**Test first.** `experiments/test-issue115-heredoc-unbound-vars.sh`, following the
existing style of `experiments/verify-script-syntax.sh`:

1. Scan every tracked `*.sh` for `cat > … << 'DELIM'` / `<<'DELIM'` whose product
   is later executed.
2. Extract the body verbatim.
3. Collect every `$NAME` / `${NAME}` reference in it.
4. Fail unless each name is assigned inside the body, is a shell built-in
   (`HOME`, `PATH`, `USER`, `PWD`, `SHELL`, `UID`, positional parameters…), or
   appears in an explicit, commented allow-list.
5. Additionally run `bash -u -n` over the extracted body.

Against the current tree this must report **six** violations — three in
`scripts/measure-disk-space.sh` and three in `scripts/ubuntu-24-server-install.sh`.

**Fix.** Prefer eliminating the class over patching the instances. In order of
preference:

1. Pass the resolved versions in explicitly. The generated script already takes
   an argument (`$JSON_TMP_COPY`), so extend the contract:
   ```bash
   su - box -c "NODE_MAJOR=$NODE_MAJOR NVM_INSTALL_VERSION=$NVM_INSTALL_VERSION \
                JAVA_MAJOR=$JAVA_MAJOR bash /tmp/box-measure.sh '$JSON_TMP_COPY'"
   ```
   with `: "${NODE_MAJOR:?}"`-style assertions at the top of the generated
   script so a future omission fails with a named, actionable message instead of
   `line 128: NODE_MAJOR: unbound variable`.
2. Or emit a small `/tmp/box-measure.env` from the parent and `source` it.

Apply to **both** files. Do not fix only `NODE_MAJOR`: it is a three-variable
cascade in each file.

**Promote the check to CI.** Move it to `scripts/ci/check-heredoc-vars.sh` and
run it in the new lint workflow, so it guards the whole tree, not just the two
files known to be broken today.

**Verbose mode (T4).** Add `--verbose` / `BOX_MEASURE_DEBUG=1` to
`scripts/measure-disk-space.sh` and `scripts/ubuntu-24-server-install.sh`,
**default off**, that prints the resolved version variables in the parent and
re-prints them inside the generated script before use, plus `set -x` around the
generation step. Had this existed, run 33972074753 would have said which
variable was empty and where, instead of a bare line number in a temporary file.

---

<a id="s2"></a>
## S2 — RC-2: validate script changes before they merge (R1)

Add a `pull_request` trigger to `.github/workflows/measure-disk-space.yml` with
the same `paths` filter it already has, running a **fast, non-measuring
validation** tier: `bash -n`, ShellCheck, the S1 heredoc check, and a dry-run
that generates `/tmp/box-measure.sh` and executes it with a stub that installs
nothing. The full 180-minute measurement stays on `push` to `main`.

Also fix the concurrency inversion: the main-writing job must use a
non-cancellable group, per hive-mind principle #10:

```yaml
concurrency:
  group: main-writer-${{ github.repository }}-main
  cancel-in-progress: false
```

**Test.** An assertion in the experiment script that `measure-disk-space.yml`
declares a `pull_request` trigger and that no `contents: write` job in the
repository sets `cancel-in-progress: true`.

---

<a id="s3"></a>
## S3 — RC-3: decouple the two registries (R1, R2)

1. **Split the push.** One `docker/build-push-action` per registry, sharing a
   `cache-from`/`cache-to` scope so the second is a cache hit. Model:
   `.github/actions/publish-dockerhub/action.yml` from the template, adapted into
   a box composite action so the change lands once instead of ten times.
2. **GHCR must not depend on Docker Hub.** GHCR authenticates with the built-in
   `GITHUB_TOKEN` and has no expiry problem; it becomes the source of truth.
   A Docker Hub failure degrades to a mirroring failure.
3. **Preserve the cache export.** With the solves separated, a Docker Hub 401
   can no longer cancel `#18 exporting to GitHub Actions Cache`.
4. **Fail fast on a bad credential.** Replace the warning-only handling: if the
   Docker Hub login fails on a `push` to `main`, skip the Docker Hub half
   deliberately, annotate it once at the workflow level, and let GHCR proceed —
   rather than building 44 images that cannot be published.
5. **Rotate the secret.** The token itself must be replaced; that is a
   repository-settings action, not a code change, and the pull request will say
   so explicitly since it cannot be done from here.

**Test.** `experiments/test-issue115-registry-split.sh` asserting that no
`tags:` block in `release.yml` mixes `ghcr.io` and Docker Hub references in a
single build step.

---

<a id="s4"></a>
## S4 — RC-4: stop laundering failure into `skipped` (R1)

1. Change the dind gates from
   `needs.X.result == 'success' || needs.X.result == 'skipped'` to a gate that
   distinguishes the two, using an explicit output the manifest jobs publish
   (`published=true`) rather than the job result.
2. Add a **manifest assertion** step (hive-mind #13) between publish and consume:
   `crane manifest "$IMAGE:$TAG"` for each base image a dind job is about to use.
   A missing base image then produces one accurate error naming the missing tag
   and the registry, instead of 28 `not found`s blaming the Dockerfiles.

**Test.** `experiments/test-issue115-job-gating.sh` asserting no job in
`release.yml` treats a `skipped` dependency as success without a corroborating
output.

---

<a id="s5"></a>
## S5 — RC-5: classify failures before retrying (R1)

Give `scripts/release/docker-push-with-retry.sh` a non-retryable pattern list
mirroring the template's `publish-failure-classifier.mjs`
(`unauthorized`, `denied`, `personal access token is expired`,
`failed to fetch oauth token`, `insufficient_scope`, `manifest unknown`),
have it exit immediately with actionable guidance when one matches, and
**replace all ten inline retry loops in `release.yml` with calls to it**. That
removes ~200 lines of duplicated YAML, ends the script's status as dead code,
and eliminates ten `template-injection` findings in one move.

**Test.** Unit tests driving the classifier with the exact strings captured in
[`logs/release-33972074755-failures.log`](logs/release-33972074755-failures.log)
and asserting zero retries.

---

<a id="s6"></a>
## S6 — RC-6 … RC-9: close the enforcement gaps (R1, R3, R5, R6)

| Add | Modelled on | Clears |
| --- | --- | --- |
| `.github/workflows/workflows.yml` — actionlint (Docker image, so ShellCheck runs) + zizmor | template `workflows.yml` | 83 + 173 findings, principle #14 |
| `.github/zizmor.yml` — `unpinned-uses` policy | template `.github/zizmor.yml` | `jlumbroso/free-disk-space@main` |
| A `shellcheck` + `shfmt` job over all 64 shell scripts | new; the repository is 80.9 % shell | 15 findings, principles #3 and #4 |
| `.github/workflows/security.yml` — CodeQL (`actions` language), dependency review, scheduled audit | template `security.yml` | principle #15 |
| `.github/workflows/links.yml` + `.lycheeignore` | template `links.yml` | principle #12 |
| `scripts/ci/check-file-line-limits.sh` extended to `.sh` and `.yml` | template `check-file-line-limits.sh` | principle #2 |
| `scripts/ci/simulate-fresh-merge.sh` | template `simulate-fresh-merge.sh` | principle #7 |
| secretlint step | template `lint` job | principle #11 |
| `.husky/pre-commit` + `lint-staged` | template `.husky/` | principle #8 |
| `always()` → `!cancelled()` across all 24 sites | GitHub docs | principle #10, RC-7 |

**`release.yml` at 3432 lines.** The line-limit check makes this a hard failure,
so it must be split as part of this work, not after it. The split follows the
duplication: extracting the ten retry blocks (S5) and the per-registry publish
(S3) into reusable composite actions and `scripts/release/` helpers removes the
bulk mechanically, and the remaining flavour-specific build jobs move into a
reusable workflow called with a matrix. Fast checks are ordered before the
expensive builds while the file is open, satisfying principle #5.

**Done, with one deviation.** 3432 → 596 lines. The families did not collapse
into *one* matrixed reusable workflow: their build steps genuinely differ (the
languages family carries a per-language matrix and a base-image preflight, the
dind family fourteen variants and a nested-daemon smoke test, the full box the
disk-space reclaim), so a single parameterised workflow would have re-created
the duplication as `if:` conditions inside one file. Each family gets its own
`on: workflow_call` file instead — `release-js.yml`, `release-essentials.yml`,
`release-languages.yml`, `release-full.yml`, `release-dind.yml` — with the
pull-request tier in `pr-tests.yml`. What the split had to be checked for is in
[RC-8](ROOT-CAUSES.md#rc-8): equivalence to the original
(`analysis/verify-split-equivalence.py`), the suites that read the workflows
following the jobs (`scripts/ci/list-release-workflows.sh`), and the
`workflow_call` contract itself
(`experiments/test-issue115-workflow-split.sh`, 85 assertions).

**Sequencing note.** Each linter is introduced together with the fixes that make
it pass, so no step in the pull request lands a knowingly-red gate.

---

<a id="s7"></a>
## S7 — R4 / T5: upstream reports

Candidates, each to be reproduced against a clean checkout before filing:

| Where | What | Contents of the report |
| --- | --- | --- |
| `link-foundation/js-ai-driven-development-pipeline-template` | Any defect confirmed present in the shared `setup-buildx-resilient` action or in the shared release/changeset shape | reproducible example, workaround, suggested code fix |
| `link-foundation/js-ai-driven-development-pipeline-template` | Feature request: promote `publish-dockerhub`'s one-registry-per-solve pattern and the failure classifier into documented, reusable building blocks, since box needed both and had neither | rationale from this run's logs |
| `koalaman/shellcheck` | Feature request: a check for a **quoted** heredoc that references a name defined only in the enclosing scope — the mirror image of SC2087. Includes the minimal reproducer from [`PRIOR-ART.md`](PRIOR-ART.md), the workaround (pass values explicitly / `: "${VAR:?}"`), and a suggested implementation sketch | minimal reproducer + suggested fix |
| `rhysd/actionlint` | Same idea for heredocs inside `run:` blocks, if reproducible there | reproducer + suggested fix |
| `mvdan/sh` | **Bug**: `shfmt` formats an associative-array subscript as an arithmetic expression, so `[node-lts-integration-test.sh]=` is rewritten to `[node - lts - integration - test.sh]=` — a different key. The reformat is silent and changes what the script does ([RC-21](ROOT-CAUSES.md)); it disabled a three-entry skip list here | minimal reproducer (the fixture in `experiments/test-issue115-shfmt-gate.sh`), workaround (quote every subscript), suggested fix (do not apply arithmetic spacing inside `[...]=` in an array literal, or warn) |
| `leanprover/elan` | **Bug**: `elan-init --default-toolchain <v>` exits 0 having installed no toolchain, so every Lean box shipped elan and no Lean ([RC-14](ROOT-CAUSES.md)) | reproducer, workaround (`elan toolchain install` as a separate step, then verify `lean --version`), suggested fix (fail when the requested toolchain is absent afterwards) |
| `secretlint/secretlint` | **Bug or documentation defect**: the allow-list shape shown in the documented example silences every finding, so a planted secret is not reported and the scan still exits 0 ([RC-16](ROOT-CAUSES.md)) | reproducer with a planted key, workaround (drop the example allow-list; add a canary that must be detected), suggested fix (reject or warn on an allow-list pattern that matches everything) |

If reproduction shows a candidate does **not** affect upstream, that is recorded
here with the evidence rather than filed — R4 asks for reports of *shared*
defects, and a wrong report is worse than none.

**Outcome: [`UPSTREAM-REPORTS.md`](UPSTREAM-REPORTS.md).** Five reports filed
([elan #210](https://github.com/leanprover/elan/issues/210),
[secretlint #1688](https://github.com/secretlint/secretlint/issues/1688),
[shellcheck #3534](https://github.com/koalaman/shellcheck/issues/3534),
template [#174](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/174)
and [#175](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/175)),
one added to an existing upstream issue as
[a comment on template #167](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/167#issuecomment-5556797713),
and four candidates dropped after reproduction showed the defect was ours and
not theirs. The evidence for each decision, filed or not, is in that file.

---

<a id="s8"></a>
## S8 — R7: land it as one pull request

1. Merge `main` into `issue-115-3e95d428cf8a`.
2. Commit in atomic steps, each independently useful, checks before fixes.
3. Run every new check locally before each push.
4. Bump `VERSION` / add a changeset so the release automation has a trigger.
5. Rewrite the #116 title and description around the root causes and the
   evidence in this folder.
6. Confirm CI is green — including the newly added gates — then `gh pr ready 116`.

---

## Traceability

| Requirement | Steps |
| --- | --- |
| [R1](REQUIREMENTS.md#r1) all four defect categories | S1–S6 |
| [R2](REQUIREMENTS.md#r2) the two failing runs | S1, S2 (run 33972074753); S3, S4, S5 (run 33972074755) |
| [R3](REQUIREMENTS.md#r3) template best practices | S6, informed by [`TEMPLATE-COMPARISON.md`](TEMPLATE-COMPARISON.md) |
| [R4](REQUIREMENTS.md#r4) upstream reports | S7 |
| [R5](REQUIREMENTS.md#r5) compare all files | [`TEMPLATE-COMPARISON.md`](TEMPLATE-COMPARISON.md) Part 1 → S6 |
| [R6](REQUIREMENTS.md#r6) hive-mind principles | [`TEMPLATE-COMPARISON.md`](TEMPLATE-COMPARISON.md) Part 2 → S6 |
| [R7](REQUIREMENTS.md#r7) single pull request | S8 |
| T4 verbose mode, default off | S1 |
| T6 fix everywhere it occurs | S1 (2 files), S3 and S5 (10 sites each), S6 (24 sites) |
