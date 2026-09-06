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

---

<a id="rc-10"></a>
## RC-10 — Four hand-maintained copies of the box acceptance checks — **false negative**

`release.yml` contained the box checks four times: `pr-test-js`,
`pr-test-essentials`, `pr-test-language`, `pr-test-full`, and once more as the
smoke test of the *pushed* image. Copies drift, and these had: the released-image
smoke test ran **22 of the 29** checks the pre-merge full-box test ran.

Absent from the test of the artifact users actually pull:

| Missing from the released-image test | Where it existed |
| --- | --- |
| `gh-setup-git-identity`, `glab-setup-git-identity` | pre-merge full-box test |
| `cat /home/box/.php-install-method` | pre-merge full-box test |
| Node/Rust freshness + one-version-per-language invariants (issue #112) | pre-merge full-box test |
| `rocq` / `opam` | nowhere — see [RC-12](#rc-12) |

Nothing compared the two lists, so the difference was invisible: every job was
green while the published image was the least-tested thing in the pipeline.

**Fix.** `scripts/ci/test-box.sh PROFILE IMAGE` is the single definition; all
five steps call it, and the release smoke test calls the *same* `full` profile
the candidate passed. The `full` profile is composed from the same per-language
functions the `language` profile uses, so a check cannot exist for the
standalone box and be forgotten in the composed one.

**Pinned by.** `experiments/test-issue115-test-box.sh` (41 assertions) asserts,
among other things, that every per-language check reappears in the `full`
profile, that no inline `docker run --rm box-test` survives in the workflow, and
that exactly two steps run the `full` profile.

---

<a id="rc-11"></a>
## RC-11 — Four language directories that no job builds — **false negative**

`ubuntu/24.04/{cpp,assembly,dotnet,r}/` each ship a `Dockerfile` and an
`install.sh`, and README tells users to run those `install.sh` scripts directly
(`curl -fsSL … | bash`). No CI job built any of them. A broken `install.sh` there
reached users with every check green.

The gap was reproduced at four layers, each of which listed the languages by
hand:

| Layer | Listed | Should list |
| --- | --- | --- |
| `scripts/ci/detect-changes.sh` `LANGUAGES` | 11 | 15 |
| `release.yml` `<language>-changed` outputs | 11 | 15 |
| `pr-test-language` matrix | 11 | 15 |
| `scripts/ci/test-box.sh` `check_language()` | 11 | 15 |

**Fix.** All four extended to the 15 directories, and the assertions that pin
them derive the expected list from the directory listing
(`ubuntu/24.04/*/Dockerfile` minus `js`, `essentials-box`, `full-box`, `dind`)
rather than restating it — adding `ubuntu/24.04/<new>/Dockerfile` without wiring
it up now fails.

The *publish* matrices (`build-languages-amd64`, `build-languages-arm64`,
`languages-manifest`) deliberately stay at the 11 published images; the release
notes generator is pinned to that matrix, and
`experiments/test-issue115-language-coverage.sh` asserts the published set is a
subset of the tested set.

**Pinned by.** `experiments/test-issue115-language-coverage.sh` (51 assertions)
and `experiments/test-issue82-pr-parallel-tests.sh`.

---

<a id="rc-12"></a>
## RC-12 — `opam` is not on PATH in the rocq box or the full box — **error, hidden by a false negative**

The product bug RC-10/RC-11 were hiding. Both published images ship a working
`rocq` and no reachable `opam`:

```console
$ docker run --rm konard/box:latest opam --version
/usr/local/bin/entrypoint.sh: line 57: exec: opam: not found
$ docker run --rm konard/box-rocq:latest bash -c 'command -v opam; echo "exit=$?"'
exit=1
```

Two independent causes, one per image:

1. `ubuntu/24.04/rocq/install.sh` installs the binary to `$HOME/.local/bin` (it
   runs as the unprivileged `box` user), while `ubuntu/24.04/rocq/Dockerfile`
   put only the *switch* — `~/.opam/default/bin` — on `PATH`. `opam` resolved
   only in a shell that had sourced `~/.bashrc`, which `docker run`,
   `docker exec` and CI steps do not.
2. `ubuntu/24.04/full-box/Dockerfile` copied `~/.opam` out of the rocq stage and
   nothing else. `COPY --from` copies the paths it is given; the binary lives
   outside `~/.opam`.

**Fix.** `ENV PATH="/home/box/.local/bin:…"` in the rocq box, and
`COPY --from=rocq-stage /home/box/.local/bin/opam /usr/local/bin/opam` in the
full box. Both verified against the live images before being committed —
build log and Dockerfile in
[`analysis/opam-path-verification.md`](analysis/opam-path-verification.md).

**Pinned by.** `box opam --version` in the `rocq` profile of
`scripts/ci/test-box.sh`, which the `full` profile also runs.

---

<a id="rc-13"></a>
## RC-13 — An assertion that forks to check its own output — **false positive**

`experiments/test-issue115-shellcheck-gate.sh` matched the linter's output with
`echo "$OUT" | grep -q …` under `set -o pipefail`. Observed once while the suite
ran beside a docker build: the gate *did* report `[SC2045]` and the assertion
still failed, because a pipeline is two forks and a fork can fail for reasons
that have nothing to do with the thing under test. A check that fails when the
machine is busy is a false positive, and the flake trains people to re-run.

**Fix.** Match with bash's own `==` / `=~`, which cannot fork. The suite's three
`echo … | grep -q` assertions are gone; the remaining pipes are diagnostics
inside failure branches, where a fork failure cannot flip a verdict.

---

<a id="rc-14"></a>
## RC-14 — Every Lean box ships elan and no Lean — **error, hidden by a false negative**

**Symptom.** Running the extended `full` profile against the patched image
(`bash scripts/ci/test-box.sh full …`, [log](analysis/lean-toolchain-verification.log)):

```
--- lean ---
warning: could not canonicalize path: '/home/box/.elan/toolchains'
info: downloading https://releases.lean-lang.org/lean4/v4.33.1/lean-4.33.1-linux.tar.zst
info: installing /home/box/.elan/toolchains/leanprover--lean4---v4.33.1
Lean (version 4.33.1, x86_64-unknown-linux-gnu, …)
```

The check printed a version — and passed — *because it downloaded Lean while the
check was running*. In both published images the toolchain directory does not
exist at all:

```
$ docker run --rm konard/box-lean:latest ls /home/box/.elan/toolchains
ls: cannot access '/home/box/.elan/toolchains': No such file or directory
$ docker run --rm konard/box-lean:latest du -sh /home/box/.elan
13M     /home/box/.elan
```

13 MB is elan itself. A Lean toolchain is ~200 MB.

**Mechanism.** elan's installer records the default toolchain and exits 0
*without installing it*. Reproduced in a clean `ubuntu:24.04`:

```
$ curl https://elan.lean-lang.org/elan-init.sh -sSf | sh -s -- -y --default-toolchain stable
info: downloading installer
info: default toolchain set to 'stable'
$ echo $?
0
$ elan toolchain list
no installed toolchains
```

`ubuntu/24.04/lean/install.sh` ran exactly that line, checked only that
`~/.elan/env` exists, and logged `Lean installed successfully`. `~/.elan/bin/lean`
is a *shim*: on first use it resolves the default toolchain and, if it is not
installed, fetches it. So the box is not broken in a way anything looks at — it
is broken for the user who is offline, behind a proxy, on a metered link, or
simply expects `docker run box lean --version` not to pull 200 MB.

**Why CI could not see it.** The check was `docker run --rm "$IMAGE" lean
--version` with the network up. A `<tool> --version` that the tool can satisfy by
downloading itself proves nothing about the image — the same false-negative shape
as RC-11 (nobody built the directory) and RC-12 (nobody ran the binary).

**Where it occurs — every image that advertises Lean:**

| Image | `~/.elan` | `~/.elan/toolchains` | `lean --version` offline |
| --- | --- | --- | --- |
| `konard/box-lean:latest` | 13 MB | absent | fails |
| `konard/box:latest` (full) | copied from lean-stage | absent | fails |
| `ubuntu/24.04/lean/Dockerfile` | runs `install.sh` | never created | — |
| `ubuntu/24.04/full-box/Dockerfile` | `COPY --from=lean-stage … /home/box/.elan` | copies the absence | — |

One cause, one file: `ubuntu/24.04/lean/install.sh`. The full box inherits the
defect through `COPY`, so fixing the language box fixes both — which is only true
because the full box composes the same script; it is checked by
`experiments/test-issue115-test-box.sh`, which requires every language check to
run in the full profile too.

**Fix.**

1. `ubuntu/24.04/lean/install.sh` installs the toolchain explicitly
   (`elan toolchain install "$LEAN_TOOLCHAIN"`, `elan default …`, with
   `LEAN_VERSION` as the override the issue #112 version policy requires) and
   **fails the build** when `elan toolchain list` still says
   `no installed toolchains`. A silent no-op cannot ship again.
2. `scripts/ci/test-box.sh` gains `box_offline_sh()` —
   `docker run --rm --network none …` — and checks Lean through it, so
   "it downloads itself" can never again be read as "it is installed".
3. `~/.elan/toolchains` joins the one-version-per-language-root invariant in
   `assert_single_runtime_versions()` (elan keeps every toolchain it is ever
   asked for, at ~200 MB each).

**Verified.** `elan toolchain install stable` on top of the published
`konard/box-lean:latest`, then `docker run --network none` — see
[`analysis/lean-toolchain-verification.md`](analysis/lean-toolchain-verification.md).

**Pinned by.** `experiments/test-issue115-elan-toolchain.sh` (static assertions in
the default run; `ELAN_LIVE=1` adds the live docker reproduction) and the two
offline checks in the `lean` profile of `scripts/ci/test-box.sh`.

---

<a id="rc-15"></a>

## RC-15 — A regression suite that dies before its first assertion — **error, hidden by a false negative**

**Symptom.** The `Scripts` workflow had been red on this branch since `149f807`
— eight commits — and nothing in its log named an assertion
([`logs/scripts-34003004420.log`](logs/scripts-34003004420.log)):

```
==> RUN  test-issue108-detect-changes.sh
fatal: ambiguous argument 'HEAD~1': unknown revision or path not in the working tree.
error: Could not access 'HEAD~1'
Error: Process completed with exit code 128
```

No `FAIL:` line, no count, no suite summary. The run was not reporting a failed
assertion; it was reporting that the suite never got far enough to make one.

**Mechanism — two defects, one visible.**

*The production defect.* `scripts/ci/detect-changes.sh` ends `resolve_range()`
with `echo "HEAD~1 HEAD"` as its last-resort fallback, and `get_changed_files()`
then ran

```bash
git diff --name-only $range 2>/dev/null || git diff --name-only HEAD~1 HEAD
```

`actions/checkout` clones with `fetch-depth: 1`, so `HEAD~1` does not exist in a
CI checkout. `git diff` exits 128; the `||` fallback re-runs the *identical*
failing command; `set -euo pipefail` takes the script down before it prints one
`should-build=` line. The same happens on a repository's root commit. So
`detect-changes.sh` was not merely untested in that state — it was *broken* in
it, for any caller without full history.

*The detector defect.* `experiments/test-issue108-detect-changes.sh` invoked the
script inside a command substitution:

```bash
run_detect() { bash "$SCRIPT" | sed -n 's/^should-build=//p' | tail -n1; }
```

Under `set -euo pipefail` a command substitution whose command exits non-zero
kills the calling suite on the spot. An assertion that cannot fail and say so is
not an assertion — which is why eight commits of red produced no diagnostic.

**Why it was not caught locally.** Local git is 2.43 (Ubuntu 24.04), the runner's
is 2.55, and the local clone has full history. Reproduced with the runner's git
and a genuinely shallow tree:

```bash
docker run --rm -v "$PWD:/repo" alpine:edge sh -c \
  'apk add -q git bash && git clone -q --depth 1 file:///repo /tmp/r && cd /tmp/r &&
   GITHUB_EVENT_NAME=push bash scripts/ci/detect-changes.sh; echo "exit=$?"'
# exit=128
```

**Where it occurs.** One script, `scripts/ci/detect-changes.sh`, called from
`.github/workflows/dockerfiles.yml` and `release.yml`; and one suite,
`experiments/test-issue108-detect-changes.sh`. Every other suite in
`experiments/` was audited for the same command-substitution shape — no other
suite invokes a script under test that way.

**Fix.**

1. `resolve_range()`'s last resort becomes `last_resort_range()`, which prints
   `HEAD~1 HEAD` **only if `git rev-parse --verify -q HEAD~1` succeeds**, and
   prints nothing otherwise.
2. `get_changed_files()` degrades instead of dying: with no usable range it logs
   the reason and falls back to `git ls-files`. *Never under-build* — a build
   that was not needed costs runner minutes, a build that was needed and skipped
   ships an unbuilt image.
3. The suite's `run_detect` swallows the exit status (`|| true`) so an assertion
   can fail and print `FAIL:` rather than aborting the process.

**Pinned by.** `experiments/test-issue108-detect-changes.sh`, Part 2b: two
generated fixtures — a repository with only a root commit, and a
`git clone --depth 1` that the suite first *verifies* is shallow (a fixture that
is not shallow proves nothing) — each asserted under both `push` and
`workflow_dispatch`. 26 assertions → 31.

---

<a id="rc-16"></a>

## RC-16 — A secret scanner that finds a planted secret nowhere — **false negative**

**Symptom.** The pipeline template runs secretlint and box does not (RC-9), so
the obvious port is a `secretlint` job. Run against this repository it exits 0.
Run against a file containing AWS's own documented example credentials it *also*
exits 0:

```
$ printf 'aws_access_key_id = AKIAIOSFODNN7EXAMPLE\naws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\n' > /tmp/c/canary.txt
$ npx --yes -p secretlint@13.0.5 -p @secretlint/secretlint-rule-preset-recommend secretlint /tmp/c/canary.txt
$ echo $?
0
```

**Mechanism.** `@secretlint/secretlint-rule-aws` allow-lists exactly that key
pair, because it appears verbatim throughout AWS's documentation. The allow-list
is correct; the *test* was wrong. A randomly generated `AKIA` + 40-character
pair is flagged immediately.

The general shape is the one this whole issue is about: **a green check whose
green is indistinguishable from "the check did not run"**. A misconfigured
`.secretlintrc.json`, a preset that failed to resolve, a CLI that silently
skipped every file — all of them produce the same exit 0 as a genuinely clean
tree.

**Where it occurs.** Not yet in the tree: this was found while writing the port,
before it shipped. The same shape *is* the reason RC-6, RC-9, RC-11, RC-12 and
RC-14 went unnoticed for so long, so the fix is stated as a rule rather than a
patch.

**Fix.** Every scanner is validated against a planted positive in the same
invocation that scans the repository. `scripts/ci/run-secretlint.sh` writes a
canary to a temporary directory, scans it first, and **fails loudly if the canary
is not flagged** — before it reports anything about the repository:

```
==> Canary detected (secretlint exit 1); the rules are live
==> No secrets found
```

The canary key is generated from `/dev/urandom` at run time, never written down.
A literal 40-character key in the script would be found by the very scan it
exists to validate — the first version of the script failed on itself — and a
constant would eventually become an allow-listed one, which is the bug.

**Pinned by.** `experiments/test-issue115-secretlint-gate.sh` — 22 static
assertions (23 with `SECRETLINT_LIVE=1`), including that the canary is generated
rather than literal, that a missing canary detection is a hard failure, and that
the CLI and the preset are pinned to the same exact version.

---

<a id="rc-17"></a>
## RC-17 — 107 links in the documentation point at nothing, and 85 of them advertise images that were never published — **error, hidden by a missing check**

**Symptom.** No tool in this repository had ever resolved a URL. Running one
over the tree as it stood at `024dd6a`:

```
$ docker run --rm -v "$PWD:/repo" -w /repo lycheeverse/lychee:0.24.2 \
    --no-progress --max-retries 2 --timeout 30 --exclude-path dev/log './**/*.md'
Issues found in 16 inputs. Find details below.
...
🔍 688 Total 🔗 505 Unique ✅ 575 OK 🚫 113 Errors 🔀 15 Redirects
```

113 reported failures, 107 distinct URLs. Full log:
[`logs/lychee-baseline-024dd6a.log`](logs/lychee-baseline-024dd6a.log).

**Mechanism.** Four independent causes, each one a different way for a document
to become wrong after it was written:

1. **85 GHCR package pages that have never existed** (89 of the 107 failures are
   404s; 85 of those are `github.com/link-foundation/box/pkgs/container/box-*`).
   The README linked one per image. They 404 because **GHCR has never received a
   single push**:

   ```
   $ docker manifest inspect ghcr.io/link-foundation/box-js:latest
   manifest unknown
   $ docker manifest inspect docker.io/konard/box-js:latest
   { "schemaVersion": 2, ... }        # exit 0
   ```

   This is [RC-3](#rc-3) — the 52 × `personal access token is expired` in
   `logs/release-33972074755.log.gz` — seen from the outside. The README was
   advertising a registry the pipeline had never successfully written to, and
   nothing in CI could tell, because nothing checked.

2. **14 links to files that are not in the repository.** Case studies cite the
   CI logs that produced them, but the links point at GitHub run pages or at
   log files that were never committed. GitHub deletes a run's logs after 90
   days:

   ```
   $ gh run view 21997899227 --log
   HTTP 410: Not Found (https://api.github.com/repos/.../actions/runs/21997899227/logs)
   ```

   A document that cites a log it does not carry has a shelf life, and nothing
   said so. The rest are relative paths off by one `../` (`issue-66`,
   `issue-68`, `issue-82`), which have been wrong since they were committed.

3. **Three dead upstream URLs.** An OWASP page removed with no Wayback snapshot,
   a hive-mind script that moved in `ee6233a`, and a podman issue whose
   repository was transferred. All three were correct when they were written.

4. **Hosts that answer a link checker differently from a browser** — 429 from
   gnu.org, 503 from manpages.ubuntu.com, a TLS handshake failure from
   flatassembler.net. These are the only genuine false positives in the set.

**Where it occurs.** 16 markdown files, listed in the baseline log. The largest
single concentration is `README.md`.

**Fix.** Every one of the 107 is resolved in the diff, by kind:

| Kind | Fix |
| --- | --- |
| GHCR package pages | De-linked to plain code spans, plus a note in the README stating that GHCR is the registry of record but is not populated yet, that Docker Hub `konard/box-*` is what exists today, and linking the org's package index |
| Expired CI logs | Replaced with prose naming the run and job id and marking the log expired, so the citation survives the retention window |
| Relative paths | Corrected |
| Dead upstream URLs | Repointed at the current location (CAPEC-632 for the OWASP page, the transferred podman repository) or pinned to the commit that still holds the file |
| Unverifiable hosts | `.lycheeignore`, each with the reason |

The check itself is `.github/workflows/links.yml`, and
`scripts/ci/check-web-archive.mjs` asks the Wayback Machine for a replacement
before the job fails, so the red X arrives with a URL to use instead.

The rule that keeps this from decaying back is the one the whole issue is
about: **`.lycheeignore` may contain only URLs that are correct but
unverifiable.** Anything genuinely broken is fixed in the diff. Silencing a
dead link converts a true positive into permanent silence, which is exactly the
class of defect RC-6, RC-9, RC-11, RC-12, RC-14 and RC-16 belong to.

**Pinned by.** `experiments/test-issue115-links-gate.sh` — 28 assertions,
including offline unit tests of the Wayback parser (a redirect is not a broken
link; a missing local file is unarchivable and must fail), that lychee's exit
code still fails the job, and that no ignore pattern is broad enough to swallow
a URL this repository depends on being right — the Docker Hub repositories, the
repository itself, the hive-mind best-practices document.

---

<a id="rc-18"></a>
## RC-18 — A failed push to the mirror registry means no GitHub Release at all — **error**

**Symptom.** `create-release` did not run for the two failing runs on `main`
that issue #115 names, even though the source it releases was fine:

```yaml
    needs: [detect-changes, docker-manifest, js-manifest, essentials-manifest, languages-manifest, dind-manifest]
    if: |
      !cancelled() &&
      needs.detect-changes.result == 'success' &&
      needs.docker-manifest.result == 'success' &&
      ...
```

`docker-manifest` is the *full box* multi-arch manifest job. In run
33972074755 it failed on 52 × `personal access token is expired`
([RC-3](#rc-3)), so version 2.5.0 got no GitHub Release — not a partial one, not
a draft, none. The tag exists in the repository and nothing announces it.

**Mechanism.** Two separate things were fused into one condition:

* *Is there something to release?* — that is `detect-changes`, and it is a real
  precondition.
* *Did the images reach a registry?* — that is a delivery outcome, and it is
  **not** a property of the release. The notes describe a commit; the commit is
  releasable whether or not a long-lived Docker Hub secret was still valid nine
  months after it was minted.

Fusing them makes the least reliable dependency in the pipeline — a
third-party registry reachable with a credential that expires — a veto over the
most durable artefact, and the failure mode is silent: a skipped job is a grey
check, not a red one ([RC-4](#rc-4)).

It also gets the coupling backwards. The release is what tells a human the
push needs re-running; suppressing it removes the only notice.

**Where it occurs.** `.github/workflows/release.yml`, the `create-release`
job — one place, but with `dind-manifest` and four other manifest jobs listed
in `needs:` alongside it, so any of them turning `failure` while
`!cancelled()` holds could reach the same result through a different route.

**Fix.** Two halves, because dropping the gate alone would trade a missing
release for a lying one — notes that advertise 56 image references when 28 of
them were never pushed is precisely [RC-17](#rc-17).

1. `create-release` no longer requires `docker-manifest.result == 'success'`.
   It still `needs:` the manifest jobs (so it runs after them and can see what
   they did) and still requires `detect-changes`.
2. `scripts/release/build-release-notes.sh` gained a publication section,
   enabled in CI with `VERIFY_IMAGES=1`: it runs `docker manifest inspect` over
   every reference the notes advertise and reports `N of M image references
   resolve`, naming the ones that do not and telling the reader to re-run the
   release workflow. The GHCR package links the notes used to emit are gone for
   the same reason they left the README (RC-17) — a 404 dressed as evidence.

The section distinguishes three answers, not two: *published*, *missing*
(`manifest unknown` / `not found`), and *unknown* (anything else — a
rate-limited or unreachable registry). A registry that will not answer is not
evidence that an image is absent, and reporting it as missing would replace one
false claim with another. `create-release` logs in to GHCR with the job's own
`GITHUB_TOKEN` so that "does not exist" and "you may not look" stop being the
same error.

This is hive-mind best practice #13, *never gate the release on an image push,
and assert the manifests that were published* — both clauses, which is why the
gate and the assertion land together.

**Pinned by.** `experiments/test-issue115-release-notes.sh` — 28 assertions.
Part 5 reads `create-release`'s `if:` out of the workflow and fails if the
`docker-manifest` clause returns, checks the workflow sets `VERIFY_IMAGES`, and
drives the generator against a fake `docker` on `PATH` in three modes: every
reference published (`56 of 56`, nothing listed as missing), none published
(`0 of 56`, every reference named), and a rate-limited registry (reported as
unknown, never as missing). It also asserts the generator makes no registry
call at all when `VERIFY_IMAGES` is unset, so the notes stay reproducible
offline.
