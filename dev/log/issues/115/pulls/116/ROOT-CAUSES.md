# Root causes

Each entry states the defect, the evidence that proves it, why it happened, and
**everywhere in the tree it occurs** — the last part matters because RC-1 was
observed in one file and exists in two.

Classification uses the four categories from [`REQUIREMENTS.md`](REQUIREMENTS.md#r1):
**error**, **false positive**, **false negative**, **warning**.

---

<a id="rc-1"></a>
## RC-1 — Parent-shell variables referenced inside a *quoted* heredoc — **error**

**Symptom.** Run 33972074753:

```
/tmp/box-measure.sh: line 128: NODE_MAJOR: unbound variable
##[error]Process completed with exit code 1.
```

**Mechanism.** `scripts/measure-disk-space.sh` resolves the runtime versions in
the parent shell (lines 316–320):

```bash
NODE_MAJOR="$(box_resolve resolve_node_lts_major 24)"
NVM_INSTALL_VERSION="$(box_resolve resolve_nvm_version v0.40.7)"
JAVA_MAJOR="$(box_resolve resolve_java_lts_major 25)"
```

and then writes a second script with a **quoted** heredoc (line 393):

```bash
cat > /tmp/box-measure.sh << 'EOF_BOX'
```

The quotes around `EOF_BOX` are what make the heredoc literal: nothing inside is
expanded. That is deliberate for the `$HOME`, `$(…)` and `${var}` references
that the *generated* script needs to evaluate at its own runtime — but commit
`92d66aa` added references to three variables that only ever exist in the
*parent*. The generated file therefore contains the literal characters
`$NODE_MAJOR`, and it is executed in a fresh login shell that does not inherit
the parent's environment:

```bash
su - box -c "bash /tmp/box-measure.sh '$JSON_TMP_COPY'"   # line 825
sudo -i -u box bash /tmp/box-measure.sh "$JSON_TMP_COPY"  # line 827
```

`su -` and `sudo -i` both start a *login* shell, which discards the caller's
non-exported variables; the variables were never exported either. Combined with
the generated script's own `set -euo pipefail` (line 395), the first reference
aborts the whole measurement.

**It is a three-variable cascade, not one bug.** Fixing only `NODE_MAJOR` moves
the failure to `${NVM_INSTALL_VERSION}` and then to `${JAVA_MAJOR}`.

**Where it occurs — two places, one of which has never been exercised:**

| File | Heredoc | Variables used inside | Executed by |
| --- | --- | --- | --- |
| `scripts/measure-disk-space.sh` | `<< 'EOF_BOX'`, lines 393–802 | `$NODE_MAJOR` (521), `${NVM_INSTALL_VERSION}`, `${JAVA_MAJOR}` | `measure-disk-space.yml` — this is the run that failed |
| `scripts/ubuntu-24-server-install.sh` | `<<'EOF_BOX_SCRIPT'`, lines 406–1143 | `$NODE_MAJOR` / `${NODE_MAJOR}` (1031–1039), `${NVM_INSTALL_VERSION}`, `${JAVA_MAJOR}` | nothing in CI — the defect is latent and would only surface on a user's server |

**Why no linter caught it.** ShellCheck's SC2154 ("referenced but not assigned")
deliberately **exempts identifiers that are entirely upper case**, because those
are assumed to come from the environment. Reproduced directly:

```bash
$ printf 'set -u\necho "$FOO_BAR"\necho "$foo_bar"\n' > /tmp/t2.sh
$ shellcheck /tmp/t2.sh
In /tmp/t2.sh line 3:
echo "$foo_bar"
       ^-- SC2154 (warning): foo_bar is referenced but not assigned.
```

`FOO_BAR` produces nothing. Every variable in this bug is upper case, so no
off-the-shelf shell linter can find it — and ShellCheck does not analyse heredoc
bodies as separate scripts at all. A purpose-built repository check is required
(see [`SOLUTION-PLAN.md`](SOLUTION-PLAN.md#s1)).

---

<a id="rc-2"></a>
## RC-2 — `measure-disk-space.yml` never runs on pull requests — **false negative**

**Evidence.** `.github/workflows/measure-disk-space.yml` lines 3–20 declare only:

```yaml
on:
  push:
    branches: [main]
    paths:
      - 'scripts/ubuntu-24-server-install.sh'
      - 'scripts/measure-disk-space.sh'
      ...
  workflow_dispatch:
```

There is no `pull_request` trigger. The path list already names exactly the two
files RC-1 broke, so the workflow *knew* which changes matter — it just only
looked after they had already landed on `main`.

**Consequence.** Pull request #113 changed both scripts and merged green. The
first execution of the changed code was on `main`, in the run the issue is
about. This is the reason RC-1 reached the default branch, and it is the purest
false negative in the repository: a check that exists, is correctly scoped, and
is wired to fire too late to prevent anything.

**Second-order problem.** The job that this workflow runs has
`permissions: contents: write` and pushes the updated README back to `main`,
yet the workflow sets `cancel-in-progress: true` on a `${{ github.ref }}` group.
Cancelling a job mid-push to the default branch is exactly what hive-mind
best practice #10 forbids.

---

<a id="rc-3"></a>
## RC-3 — Expired `DOCKERHUB_TOKEN`, and one buildx solve that pushes to two registries — **error + warning**

**Evidence.** `build-js-amd64`, 14:34:38:

```
##[error]Error response from daemon: Get "https://registry-1.docker.io/v2/": unauthorized: personal access token is expired
```

The secret itself is expired. That part is an operational fact, not a code
defect — but everything the pipeline does about it is a code defect.

**Defect 3a — the failure is downgraded to a warning that gates nothing.**
The login step is `continue-on-error: true` and the follow-up step only emits
`::warning title=Docker Hub login failed::…`. GitHub does not fail a run on
warnings, so 44 build jobs then spend between 3 and 22 minutes each building
images they are already known to be unable to publish.

**Defect 3b — a single `docker/build-push-action` carries tags for both
registries.** The `build-js-amd64` step (release.yml lines ~1174–1204) is
representative:

```yaml
tags: |
  ${{ env.GHCR_REGISTRY }}/${{ env.GHCR_IMAGE_NAME }}-js:latest-amd64
  ${{ env.GHCR_REGISTRY }}/${{ env.GHCR_IMAGE_NAME }}-js:${{ steps.version.outputs.version }}-amd64
  ${{ env.DOCKERHUB_IMAGE_NAME }}-js:latest-amd64
  ${{ env.DOCKERHUB_IMAGE_NAME }}-js:${{ steps.version.outputs.version }}-amd64
```

buildx treats that as **one solve**. The log shows precisely what that costs:

```
14:35:25.108  #16 pushing manifest for ghcr.io/link-foundation/box-js:latest-arm64@sha256:… done
14:35:25.854  #16 pushing manifest for ghcr.io/link-foundation/box-js:2.5.0-arm64@sha256:… done
14:35:26.427  #16 ERROR: failed to push ***/box-js:latest-arm64: failed to authorize: failed to fetch oauth token
              ERROR: failed to build: failed to solve: failed to fetch oauth token
14:35:26      #18 exporting to GitHub Actions Cache … #18 CANCELED
```

Three separate harms, all from the coupling:

1. **The GHCR artifacts are actually published**, yet the job, and therefore the
   whole workflow, reports total failure — a red run that misrepresents what
   really happened.
2. **The GHCR-only jobs are held hostage** by a registry they do not need.
3. **`#18 CANCELED`** — the failed solve aborts the GitHub Actions cache export,
   so nothing is banked and the *next* run has to rebuild from scratch too.

**Where it occurs.** The same four-tag/one-solve pattern is repeated in every
build job of `release.yml` (`build-js-*`, `build-essentials-*`,
`build-languages-*`, `build-dind-*`, `docker-build-push*`).

**Prior art for the fix, already in the tree next door.** The template's
`.github/actions/publish-dockerhub/action.yml` builds **one registry per
invocation**, by digest:

```yaml
outputs: type=image,name=${{ inputs.image }},push-by-digest=true,name-canonical=true,push=true
```

---

<a id="rc-4"></a>
## RC-4 — `skipped` is accepted as if it were `success` — **false positive**

**Evidence.** `build-dind-amd64`, release.yml lines 2873–2885:

```yaml
if: |
  always() &&
  needs.detect-changes.result == 'success' &&
  (needs.js-manifest.result == 'success' || needs.js-manifest.result == 'skipped') &&
  ...
```

In run 33972074755, `js-manifest` was `skipped` — and it was skipped *because
`build-js-amd64` and `build-js-arm64` had failed* (js-manifest's own `if`
requires `needs.build-js-*.result == 'success'`). The dind gate cannot tell
"skipped because this flavour was not rebuilt" from "skipped because the build
it depends on collapsed", so it ran all 28 matrix legs.

Each of them then failed with:

```
failed to resolve source metadata for docker.io/***/box-js:2.5.0-amd64: not found
```

because `ubuntu/24.04/dind/Dockerfile` line 25 is `FROM ${BASE_IMAGE}` with
`ARG BASE_IMAGE=konard/box:latest` — a **Docker Hub** reference, i.e. exactly
the registry RC-3 failed to push to.

**Impact.** 28 of the run's 52 failures, and the last 8.5 minutes of its
wall-clock time, are red jobs blaming the wrong file. Anyone reading this run
top-down sees "the dind images are broken" when the actual finding is "the
Docker Hub token expired".

`build-essentials-*` shows the correct pattern by contrast — it requires
`build-js-amd64.result == 'success' || … == 'skipped'` too, but since
`build-js-amd64` **failed** (rather than being skipped) it was correctly
skipped. The dind jobs depend on the *manifest* jobs instead, and failure
launders into `skipped` as it passes through them.

---

<a id="rc-5"></a>
## RC-5 — The retry loop retries a non-retryable error — **warning**

**Evidence.** After the first failure at 14:35:26, `build-js-arm64` ran three
more full push attempts with 10 s and 20 s backoff, each re-pushing the GHCR
manifests successfully and each hitting the identical
`failed to fetch oauth token`, before printing `==> All retry attempts failed`
at 14:36:03.

A `401 unauthorized: personal access token is expired` is a permanent
condition; no amount of backoff changes it. The retry helper has no failure
classifier, so it treats an authentication error the same as a transient
network error. Across ~44 build jobs this burns tens of minutes and, worse,
buries the one line that actually explains the run under three copies of a
misleading one.

---

<a id="rc-6"></a>
## RC-6 — Nothing lints the CI/CD configuration itself — **false negative**

The repository has **no workflow-linting job at all**. Measured against the tree
at the branch point (raw output in [`analysis/`](analysis/)):

| Tool | Result | Breakdown |
| --- | --- | --- |
| `actionlint` 1.7.12 | exit 1, **83 findings** | 79 × SC2086 (unquoted expansion), 3 × SC2016, 1 × SC2034 — all in `release.yml` |
| `zizmor --min-confidence medium` | exit 14, **173 findings** reported (604 raised, 125 ignored, 306 suppressed) | 91 high, 5 medium, 77 low; 89 × `unpinned-uses`, 67 × `template-injection`, 12 × `self-repository`, 5 × `excessive-permissions`. By file: 171 in `release.yml`, 3 in `measure-disk-space.yml`, 2 in `.github/actions/setup-buildx-resilient/action.yml` |
| `shellcheck --severity=warning` (64 scripts) | **15 findings** | 4 × SC2155, 4 × SC1090, 3 × SC2010, 2 × SC2064, 1 × SC2045, 1 × SC2034 |

None of this is a hypothetical: SC2086 on `>> $GITHUB_OUTPUT` and
`template-injection` on `${{ … }}` interpolated straight into `run:` blocks are
the two mechanisms behind most real GitHub Actions incidents. The template
gates all three of these tools in `.github/workflows/workflows.yml`; this
repository gates none.

---

<a id="rc-7"></a>
## RC-7 — `always()` instead of `!cancelled()`, and 25 × `continue-on-error` — **false positive / false negative**

`release.yml` uses `always()` **24 times** and `!cancelled()` **zero times**.
`always()` keeps a job running even when the run has been *cancelled*, which
directly fights the supersede machinery added for issue #112: a superseded run
cannot actually stop, so it keeps holding runner slots. `!cancelled()` gives the
same "run even if an upstream failed" behaviour while still honouring
cancellation.

`continue-on-error: true` appears **25 times**. Each one is a place where a step
can fail without the job noticing, which is the definition of a false negative;
RC-3a is the instance that cost this run 40 minutes.

---

<a id="rc-8"></a>
## RC-8 — `release.yml` is 3432 lines — **maintainability, and the cause of RC-4/RC-7 recurring**

Hive-mind best practice #2 caps files at 1500 lines; the template enforces it
with `scripts/check-file-line-limits.sh` in a dedicated job. `release.yml` is
**2.3×** that limit and contains 30 jobs with the four-tag build block copied
about ten times. Every one of RC-3, RC-4, RC-5 and RC-7 is a defect that was
duplicated by copy-paste rather than fixed once — the file's size is not a
cosmetic complaint, it is the delivery mechanism for the other root causes.

Also over the limit: `scripts/ubuntu-24-server-install.sh` (1166 lines, and the
second home of RC-1) — under the cap, but the largest shell file, and
`scripts/measure-disk-space.sh` (872 lines).

---

<a id="rc-9"></a>
## RC-9 — Whole categories of check are simply absent — **false negative**

Present in the template, absent here:

| Missing | Template file | What it would have caught |
| --- | --- | --- |
| actionlint + zizmor | `.github/workflows/workflows.yml` | RC-6, all 83 actionlint + 173 zizmor findings |
| CodeQL (incl. `actions` language), dependency review, `npm audit` | `.github/workflows/security.yml` | supply-chain and workflow-injection issues |
| lychee link checking | `.github/workflows/links.yml` | dead links in README/docs |
| file line limits | `check-file-line-limits` job | RC-8 |
| fresh-merge simulation | `scripts/simulate-fresh-merge.sh` | stale-merge-preview passes |
| secret scanning | `secretlint` step in the `lint` job | committed credentials |
| documentation validation | `validate-docs` job | missing required docs |
| pre-commit hooks | `.husky/pre-commit` + `lint-staged` | everything above, before push |
| `unpinned-uses` policy | `.github/zizmor.yml` | `jlumbroso/free-disk-space@main` |

`jlumbroso/free-disk-space@main` is used unpinned in every build job of
`release.yml` — a third-party action tracked by mutable branch, running before
the build on a runner that holds registry credentials.
