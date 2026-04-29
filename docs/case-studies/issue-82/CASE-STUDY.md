# Case Study: Issue #82 - CI/CD Pipeline Hard-Fails on Expired Docker Hub Token

## Summary

The CI/CD release workflow ([run #25073172386](https://github.com/link-foundation/box/actions/runs/25073172386)) failed on **2026-04-28 at 19:26 UTC** when the `da0c1f3` merge commit was pushed to `main` (PR #81 merge commit for the `dind-box` family from issue #80). **Every** Docker build job failed at the same step — `Log in to Docker Hub` — with the identical error:

```
##[error]Error response from daemon: Get "https://registry-1.docker.io/v2/":
unauthorized: personal access token is expired
```

Out of 68 jobs in the run, **52 failed, 14 were skipped (because their `needs:` chain was broken), and only 2 succeeded** (`Apply Changesets`, `detect-changes`). The release was not produced and no images were published to either registry.

## Timeline of Events

| Time (UTC) | Event |
|---|---|
| 2026-04-28 13:26-14:28 | Issue #80 PR (#81) iterates: several pushes to `issue-80-bded956c66f7` initially fail (workflow file syntax issues), then succeed once the workflow is fixed. |
| 2026-04-28 14:28:48 | PR #81 final CI run on the branch passes (run `25058867725`). |
| 2026-04-28 ~19:25 | PR #81 is merged into `main` as commit `da0c1f3` (`2.1.0: Add dind-box family`). |
| 2026-04-28 19:26:28 | Push to `main` triggers `Build and Release Docker Image` workflow (run `25073172386`). |
| 2026-04-28 19:27:00 | First failure: `build-js-amd64` → `Log in to Docker Hub` fails with `unauthorized: personal access token is expired`. |
| 2026-04-28 19:27:08 → 19:28:29 | Within ~80 seconds, **all 52 build jobs** fail at the same login step with the same expired-token error — across `js`, `essentials` (skipped via dependency), all 11 `languages-*` matrix jobs (×amd64/arm64), and all 14 `dind-*` matrix jobs (×amd64/arm64). |
| 2026-04-28 19:28:29 | Last build job fails. Downstream `*-manifest`, `docker-build-push`, `create-release` jobs are skipped because their `needs:` upstream did not succeed. |
| 2026-04-28 19:28:41 | Issue #82 is opened, linking the failing run. |
| 2026-04-28 19:28:48 | This PR's branch `issue-82-9bbaad39cc07` opens a PR run (#83) which **passes**, because the `pull_request` event in `release.yml` only runs `version-check`, `changeset-check`, and `detect-changes` (no registry pushes). |

## Failed Jobs

All 52 failures share the same root cause. Jobs (run-id `25073172386`):

| Group | Architectures | Count |
|---|---|---|
| `build-js-{amd64,arm64}` | both | 2 |
| `build-languages-{amd64,arm64}` × 11 languages | both | 22 |
| `build-dind-{amd64,arm64}` × 14 variants | both | 28 |
| **Total** | | **52** |

(`build-essentials-*` were skipped because the `js` upstream failed; the language and dind matrices have weaker dependencies and ran independently — all of them then died on the same login step.)

Skipped because of the broken dependency chain (14): `Check for Manual Version Changes`, `version-bump`, `Check for Changesets`, `docker-build-test`, `build-essentials-amd64`, `js-manifest`, `build-essentials-arm64`, `essentials-manifest`, `docker-build-push`, `languages-manifest`, `docker-build-push-arm64`, `docker-manifest`, `dind-manifest`, `create-release`.

Full failed-step logs are saved at [`ci-logs/failed-25073172386.txt`](./ci-logs/failed-25073172386.txt) (728 lines). A run summary is at [`ci-logs/run-25073172386-summary.json`](./ci-logs/run-25073172386-summary.json).

## Root Cause Analysis

### Primary root cause: expired Docker Hub Personal Access Token

The `secrets.DOCKERHUB_TOKEN` repository secret used by every `docker/login-action@v3` step in `.github/workflows/release.yml` is a Docker Hub Personal Access Token (PAT). PATs on Docker Hub have an immutable expiration date — once expired, they cannot be renewed; a new token must be generated and the secret rotated. From [Docker's docs](https://docs.docker.com/security/for-developers/access-tokens/):

> You cannot modify the expiration date after a token is created. You must create a new PAT if you need to set a new expiration date.

When the token expires, every `docker/login-action` call to `docker.io` returns:

```
Error response from daemon: Get "https://registry-1.docker.io/v2/":
unauthorized: personal access token is expired
```

This is a 30-day-default token rotation policy issue, not a code bug per se — but the workflow **amplifies** the impact into a complete release outage.

### Contributing factor: the workflow has no graceful degradation

The release workflow logs into both **GHCR** (via the auto-provisioned `GITHUB_TOKEN`) and **Docker Hub** (via `DOCKERHUB_TOKEN`). The Docker Hub login step is identical in every build job:

```yaml
- name: Log in to Docker Hub
  uses: docker/login-action@v3
  with:
    registry: ${{ env.DOCKERHUB_REGISTRY }}
    username: ${{ secrets.DOCKERHUB_USERNAME }}
    password: ${{ secrets.DOCKERHUB_TOKEN }}
```

There is no `continue-on-error: true`, no fallback, and no conditional pruning of Docker Hub tags from the subsequent `docker/build-push-action` step. As a result, an expired Docker Hub token takes down **every push to GHCR as well**, even though the GHCR credential is still perfectly valid.

This is the exact same anti-pattern that issue #78 highlighted (no retry on transient GHCR 403s) — a single transient/external failure cascades into a workflow-wide outage.

### Why the PR (#83) check still passes

`release.yml` only runs `Log in to Docker Hub` for `push`/`workflow_dispatch` events. On `pull_request` events, only the lightweight `version-check`, `changeset-check`, and `detect-changes` jobs run, so the expired-token failure is invisible until the PR is merged into `main`.

## Requirements (from the issue body)

1. Download all logs/data and compile them under `./docs/case-studies/issue-{id}` — **done** (this folder).
2. Reconstruct the timeline/sequence of events — **done** (above).
3. List all requirements from the issue — **this section**.
4. Find the root cause(s) of each problem — **done** (single root cause with one contributing factor).
5. Propose solutions and a solution plan — **see below**.
6. Check known existing components/libraries for similar problems — **see "Existing solutions" below**.
7. Add debug output / verbose mode if root cause is unclear — **N/A**, root cause is unambiguous from the logs.
8. If the issue is in another project, file an upstream issue — **N/A**, this is a configuration/workflow issue local to this repo.

## Solution Plan

The fix is two-track: an immediate operational rotation of the Docker Hub PAT (cannot be done in code — requires a repo admin), plus workflow hardening so that a future PAT expiry (or any Docker Hub outage) does not cause a full release blackout again.

### Track A — Operational (manual, one-time)

A repo admin must:

1. Sign in to Docker Hub at https://hub.docker.com/settings/security
2. Generate a new Personal Access Token with `Read, Write, Delete` scopes for the `konard/box*` repositories. Set an expiry that fits the project's rotation policy (e.g. 90 days), and add a calendar reminder to rotate.
3. Update the `DOCKERHUB_TOKEN` secret at https://github.com/link-foundation/box/settings/secrets/actions
4. Re-run the failed `Build and Release Docker Image` workflow (`gh run rerun 25073172386 --repo link-foundation/box`) — or push an empty commit / use `workflow_dispatch` with `release_mode=release-only`.

This step is documented in [`README.md` → "Releasing"](../../../README.md) as part of this PR.

### Track B — Workflow hardening (this PR)

Make the release workflow degrade gracefully when Docker Hub is unavailable, so that:

* **GHCR keeps publishing** even when Docker Hub login fails.
* The job exits **non-zero** at the end if Docker Hub was the intended target, so the failure is still visible — but only after GHCR has been pushed.
* The error message in the GHA log clearly tells the next engineer "rotate `DOCKERHUB_TOKEN`".

The minimal, low-risk implementation:

1. Add `continue-on-error: true` to every `Log in to Docker Hub` step and capture the step's `outcome` via an `id`.
2. Add a small `Check Docker Hub login` step right after that emits a clear, actionable warning when the login failed (matching the expired-token error specifically) and exposes a `dockerhub-available` step output.
3. Leave the existing `docker/build-push-action` push to both registries in place. When Docker Hub is down, those pushes will fail and the existing **retry logic** (added in issue #78) will kick in. The retry logic already wraps each `docker/build-push-action` and retries with `docker buildx build --push`, which respects whatever credentials have been logged in. If Docker Hub is unreachable, the GHCR tags will still succeed, and the retry block will then fail on the Docker Hub tags only — but at that point GHCR has the image and the retry log makes it clear which registry blocked the job.

The smallest change that fixes the catastrophic-cascade behavior without restructuring the entire workflow is:

* `continue-on-error: true` on every `Log in to Docker Hub` step (15 occurrences in `release.yml`).
* A new "Check Docker Hub login" step right after that prints a very loud, actionable error message when the login failed, naming the secret to rotate. This is what the next engineer will see in the GHA UI, and it's how we avoid a future debugging dead-end.

This change is intentionally narrow:

* It does **not** restructure the build matrix.
* It does **not** drop Docker Hub from the publish targets — when the token is rotated, behavior is unchanged.
* It does **not** swap the cross-job base-image source from Docker Hub to GHCR (a desirable follow-up but bigger surgery, deferred).

### Track C — Documentation (this PR)

Add a "Releasing" section to the project `README.md` and to `docs/case-studies/issue-82/CASE-STUDY.md` (this file) that:

* Documents which secrets the release workflow needs (`DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`).
* Names Docker Hub PAT expiry as a known operational hazard.
* Gives the rotation runbook step-by-step.

## Existing Solutions Considered

| Approach | Verdict |
|---|---|
| **Use OIDC federation to Docker Hub** instead of a long-lived PAT | Docker Hub does **not** support OIDC trust as of writing (only paid orgs have org-token support; PATs remain the recommended GHA path). [docker/login-action#229](https://github.com/docker/login-action/issues/229) tracks this. Not actionable today. |
| **Use a Docker Hub *organization* access token** (admin-managed, rotatable) | Available on paid Docker Team/Business; same expiry semantics. Would still need rotation but is centrally managed. Out of scope for this PR. |
| **Drop Docker Hub entirely, publish only to GHCR** | Project's release notes (`create-release` job) and `README.md` advertise both registries; users may have pulled `konard/box*:latest` directly from Docker Hub. Removing it is a breaking change and not requested by the issue. |
| **Monitor PAT expiry with a scheduled job** that pings Docker Hub every day and opens an issue if auth fails | Reasonable next step. Tracked as a follow-up — the `schedule:` block can be added to `release.yml` or split out, paired with a `peter-evans/create-issue-from-file` action. Not in this PR. |
| **Make `Log in to Docker Hub` non-blocking** (this PR) | Smallest blast radius, immediately stops a token expiry from cascading into a 52-job failure. |

## Prevention

* `continue-on-error: true` on `Log in to Docker Hub` everywhere ensures that a future token expiry only fails the Docker Hub *push* attempts, not the upstream login itself — so GHCR pushes complete and the release pipeline still produces images that users can pull.
* The new "Check Docker Hub login" step's loud error message reduces mean-time-to-diagnosis from "investigate 52 failing jobs" to "read one annotation in the run summary".
* The README rotation runbook removes the "what do I do?" step from the on-call response.

## Follow-up: second CI/CD bug surfaced by this PR's own CI

After the initial fix in this PR (PAT-tolerance), the next PR-event run [`25075335426`](https://github.com/link-foundation/box/actions/runs/25075335426) failed in the `docker-build-test` job with a different error:

```
#37 ERROR: failed to copy files: copy file range failed: no space left on device
##[warning]You are running out of disk space. The runner will stop working when the machine runs out of disk space. Free space left: 0 MB
```

The failure occurs at `Dockerfile:99` (`full-box`) on `COPY --from=ruby-stage --chown=box:box /home/box/.rbenv /home/box/.rbenv`, after the job has already built **JS → essentials → 11 language images → full-box** sequentially on a single `ubuntu-24.04` runner.

### Root cause

`docker-build-test` (PR-only smoke test, lines 403-564 of `release.yml`) does not free disk space before the build. The publish-jobs (`docker-build-push`, `docker-build-push-arm64`) already use `jlumbroso/free-disk-space@main` to reclaim ~30 GB before building (added in [issue #41](../../issue-41/CASE-STUDY.md)), but the PR-CI smoke test was missed. As more language images were added (most recently `dind` family in #80), cumulative disk usage from BuildKit's working set tipped over the runner's default ~22 GB free.

### Fix in this PR

Add the same `jlumbroso/free-disk-space@main` step to `docker-build-test`, with the same `with:` block already used in `docker-build-push`:

```yaml
- name: Free disk space
  uses: jlumbroso/free-disk-space@main
  with:
    tool-cache: false
    android: true
    dotnet: true
    haskell: true
    large-packages: true
    docker-images: true
    swap-storage: true
```

Captured logs: [`ci-logs/docker-build-test-job-73466319389.txt`](./ci-logs/docker-build-test-job-73466319389.txt).

## Follow-up: parallelize the PR test matrix and free disk on every build job

A subsequent PR-review request widened the scope: every Docker image configuration must be tested in the PR's CI/CD, each on its own VM with maximum free disk space, and in parallel where possible to keep iteration fast.

### What changed

The single sequential `docker-build-test` job (which built JS → essentials → 11 language images → full-box on one runner) is replaced by a chain of parallel matrix jobs in `release.yml`:

| Job | Strategy | What it does |
|---|---|---|
| `pr-test-js` | 1 VM | Free disk → build + smoke-test the JS image; populates the `pr-js-amd64` GHA buildx cache. |
| `pr-test-essentials` | 1 VM, `needs: pr-test-js` | Free disk → build + test essentials with `cache-from` `pr-js-amd64`; writes `pr-essentials-amd64`. |
| `pr-test-language` | matrix × 11 (`python, go, rust, java, kotlin, ruby, php, perl, swift, lean, rocq`), `needs: pr-test-essentials`, `fail-fast: false` | Each language on its own VM: free disk → build the language box (`cache-from` `pr-essentials-amd64`) → run a language-specific runtime check (e.g. `python3 --version`, `cat /home/box/.php-install-method`). |
| `pr-test-full` | 1 VM, `needs: pr-test-language` | Rebuilds the entire JS → essentials → 11 langs → full-box chain locally (the `full` Dockerfile uses `COPY --from=*-stage` so all language images must be present in the local daemon) and runs the same comprehensive end-to-end checks the old `docker-build-test` performed. |
| `pr-test-dind` | matrix × 14 (`js, essentials, 11 langs, full`), `needs: pr-test-essentials`, `fail-fast: false` | Each dind variant on its own VM: free disk → rebuild its base chain locally → build + smoke-test the `dind-*` image. Decoupled from `pr-test-full` so the 14 dind builds run in parallel with `pr-test-full`. |
| `docker-build-test` | aggregator, `needs: [pr-test-js, pr-test-essentials, pr-test-language, pr-test-full, pr-test-dind]` | Branch-protection sentinel: succeeds only if every PR-test job above succeeded. Keeps the existing branch-protection rule pointing at `docker-build-test` working without a settings change. |

In addition, every build job that lacked it now has the `jlumbroso/free-disk-space@main` step (`tool-cache: false, android: true, dotnet: true, haskell: true, large-packages: true, docker-images: true, swap-storage: true`) — 11 jobs total, up from 3 (`docker-build-push`, `docker-build-push-arm64`, `docker-build-test`).

### Why this shape

* **Per-image VM isolation.** Every leaf image build runs on a fresh `ubuntu-24.04` runner with ~30 GB freed up front, so a heavy image (e.g. `lean`, `rocq`, `swift`, or any `dind-*` variant) cannot starve disk for any other image.
* **Parallel wall clock, not serial.** The 11 languages and 14 dind variants run concurrently rather than sequentially, trading CPU minutes for iteration speed.
* **Each VM rebuilds its required base chain locally** with plain `docker build` against the host Docker daemon. We deliberately do **not** use buildx's `docker-container` driver here — that driver runs in an isolated container that cannot see images in the host daemon, so `FROM box-js:pr` resolves against `docker.io/library/box-js:pr` and fails (observed on the first attempt of this matrix, run [`25117130513`](https://github.com/link-foundation/box/actions/runs/25117130513)). With the default `docker` driver every `FROM box-*` resolves locally. The cost is that each VM rebuilds JS and essentials from source, which is acceptable because each VM starts with 30 GB freed up front and the parallel matrix bounds wall-clock by the slowest single image, not by the depth of the chain.
* **`pr-test-full` and the `full` dind variant must build the chain locally** because `Dockerfile`'s `full-box` uses `COPY --from=python-stage`, `--from=ruby-stage`, etc., which requires every language image in the local Docker daemon. This is the only place where multiple images share a VM, and it is justified by the multi-stage Docker constraint.
* **`fail-fast: false`** on both matrices so a single language failure does not mask the others — when fixing CI, you want to see every broken variant at once.
* **Aggregator pattern** (`docker-build-test` → `needs: [pr-test-*]`) preserves the existing branch-protection check name. No GitHub settings changes are required.

### Latent bug surfaced by per-language tests: `box-kotlin` had no JVM

Switching `pr-test-language` from "build everything serially on one VM" to "build and run a runtime check per VM" exposed a latent defect in the standalone `box-kotlin` image: it had never installed Java. `kotlinc` is a thin shell wrapper that ultimately `exec`s `java`, so the new matrix test `docker run --rm box-kotlin kotlin -version` failed with:

```
/home/box/.sdkman/candidates/kotlin/current/bin/kotlinc:
line 102: java: command not found
##[error]Process completed with exit code 127.
```

The `box-test` (full-box) image was unaffected because Java was supplied by the parallel `box-java` build stage in `full-box/Dockerfile`. The standalone `box-kotlin` image, however, was simply never exercised in isolation by the previous serial `docker-build-test` job.

The fix is in [`ubuntu/24.04/kotlin/install.sh`](../../../ubuntu/24.04/kotlin/install.sh): install Java 21 LTS (Eclipse Temurin, fall back to OpenJDK) via SDKMAN before installing Kotlin, so the standalone `box-kotlin` image is self-sufficient. This is exactly the kind of regression the per-language matrix is designed to catch.

### Validation

A static-analysis sanity check is included at [`experiments/test-issue82-pr-parallel-tests.sh`](../../../experiments/test-issue82-pr-parallel-tests.sh). It enforces:

1. Every `pr-test-*` job exists.
2. Every build job (`pr-test-*`, `build-{js,essentials,languages,dind}-{amd64,arm64}`, `docker-build-push{,-arm64}` — 15 jobs) has a `Free disk space` step using `jlumbroso/free-disk-space@main`.
3. The `pr-test-language` matrix lists all 11 languages.
4. The `pr-test-dind` matrix lists all 14 variants.
5. The `docker-build-test` aggregator depends on every `pr-test-*` job.

Running it against the post-fix `release.yml` reports `RESULT: PASS`.

## Files

* [`ci-logs/failed-25073172386.txt`](./ci-logs/failed-25073172386.txt) — full failed-step logs from the original `release.yml` PAT-expiry incident, all 52 jobs.
* [`ci-logs/run-25073172386-summary.json`](./ci-logs/run-25073172386-summary.json) — run-level metadata for the original incident.
* [`ci-logs/docker-build-test-job-73466319389.txt`](./ci-logs/docker-build-test-job-73466319389.txt) — log capture of the follow-up `docker-build-test` disk-exhaustion failure on PR run `25075335426`.
