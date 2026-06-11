# Case Study: Issue #100 — Transient Docker Hub outage fails the release run and cascades into "image not found" across dependent dind builds

## Executive Summary

Issue [#100](https://github.com/link-foundation/box/issues/100) asks us to "fix
all false positives and errors at latest CI/CD run"
([run 27314587149](https://github.com/link-foundation/box/actions/runs/27314587149)),
reuse best practices from the four pipeline templates, and compile a deep case
study with timeline, requirements, root causes and solutions.

The run had **four** red jobs:

| Job | Conclusion | Apparent error |
| --- | --- | --- |
| `build-languages-amd64 (java)` | failure | `Set up Docker Buildx` could not pull `moby/buildkit:buildx-stable-1` — `registry-1.docker.io` timed out |
| `build-dind-amd64 (java)` | failure | `docker.io/***/box-java:2.3.0-amd64: not found` |
| `build-dind-amd64 (full)` | failure | `docker.io/***/box:2.3.0-amd64: not found` |
| `build-dind-arm64 (full)` | failure | `docker.io/***/box:2.3.0-arm64: not found` |

All four collapse to a **single root cause**: Docker Hub's registry endpoint
(`registry-1.docker.io`) was unreachable from the amd64 runner for ~2.5 minutes
(00:16:40–00:19:13 UTC). That outage outlasted the existing pre-pull retry
budget in `setup-buildx-resilient` (added for issue #97), so the `java` amd64
language build failed at buildx boot — and that one failure cascaded through the
release graph into three more "image not found" jobs that are not independent
errors at all.

The original `issue.md` is preserved [here](./issue.md); the raw failed-job
logs are under [`ci-logs/`](./ci-logs/).

## 1. Timeline of events (UTC)

Run triggered by push of merge commit `57abb41` ("Merge pull request #99").

| Time | Event |
| --- | --- |
| 00:06:44 | Release workflow starts. |
| 00:14:27 | `build-languages-amd64 (java)` starts. |
| 00:16:25 | `setup-buildx-resilient` pre-pull begins: 5 attempts to pull `moby/buildkit:buildx-stable-1`. |
| 00:16:40 → 00:18:55 | All 5 pre-pull attempts fail: `Get "https://registry-1.docker.io/v2/": ... Client.Timeout exceeded` / `context deadline exceeded`. Backoff 5→10→20→40s. |
| 00:18:55 | Pre-pull gives up (non-fatal) and falls through to `docker/setup-buildx-action`. |
| 00:18:58 | "Creating a new builder instance" — buildx boots the docker-container driver and tries its own registry pull. |
| 00:19:13 | Boot pull also fails (same registry timeout). **`build-languages-amd64 (java)` → failure.** |
| 00:26:56 | `docker-build-push`, `docker-build-push-arm64`, `languages-manifest`, `docker-manifest` are all **skipped** — their `if:` requires `needs.build-languages-amd64.result == 'success' \|\| 'skipped'`, and it was `failure`. |
| 00:27:20 → 00:29:29 | `build-dind-arm64 (full)` runs anyway (its needs tolerate `skipped`) and fails: `box:2.3.0-arm64: not found` — the full `box` image was never built. |
| 00:30:32 → 00:32:30 | `build-dind-amd64 (full)` fails the same way: `box:2.3.0-amd64: not found`. |
| 00:30:47 → 00:33:00 | `build-dind-amd64 (java)` fails: `box-java:2.3.0-amd64: not found` — `java`'s own amd64 push never happened because its build failed at 00:19. |

By contrast every arm64 language build and every other amd64 language build
succeeded — the outage was a narrow, runner- and time-localized network blip on
one amd64 runner, not a code defect.

## 2. Requirements extracted from the issue

1. **Fix the false positives and errors** in the latest CI/CD run.
2. **Reuse best practices** from the JS / Rust / Python / C# pipeline templates;
   compare *all* workflow files so the same class of error cannot recur.
3. **If the same issue exists in a template, report it there too**, with a
   reproducible example, workaround and suggested fix.
4. **Compile all logs and data** for the issue into `./docs/case-studies/issue-100/`
   and perform a deep case study: timeline, full requirement list, root cause per
   problem, proposed solutions and plans, and a survey of existing
   components/libraries that solve the problem.
5. **If data is insufficient to find the root cause, add debug/verbose output**
   so the next iteration can.
6. **Report issues to any other affected repositories** with reproducible
   examples, workarounds and code suggestions.
7. **Apply the fix across the entire codebase** — fix every place that has the
   problem, not just one.
8. Do all of this in the single pull request
   [#101](https://github.com/link-foundation/box/pull/101).

## 3. Root-cause analysis

### 3.1 The one real failure: Docker Hub registry outage during buildx boot

The `docker-container` buildx driver runs BuildKit inside a container that
dockerd must first pull (`moby/buildkit:buildx-stable-1`) from Docker Hub. Issue
#97 already recognised that a transient registry blip there fails the whole job,
and added [`setup-buildx-resilient`](../../../.github/actions/setup-buildx-resilient/action.yml):
it pre-pulls the BuildKit image with 5 retries so the boot reuses a locally
cached copy.

That hardening assumes the registry is *intermittently* reachable. In this run
`registry-1.docker.io` was **continuously** unreachable for ~2.5 minutes — longer
than the pre-pull's ~2.5-minute budget — so:

- all 5 pre-pull attempts failed, then
- the boot's own pull (the original failure mode #97 tried to avoid) failed too,
- because **both** the pre-pull and the boot pull only ever talk to Docker Hub.

Retrying the *same* unreachable host more or longer is the wrong lever; the fix
needs a **second, independent source** for the BuildKit image.

### 3.2 The three cascade failures (not independent errors)

`docker-build-push` (full amd64 `box`) gates on
`build-languages-amd64.result == 'success' || 'skipped'`. With that job
`failure`, it skipped; `docker-build-push-arm64` gates on `docker-build-push`
success, so it skipped too; `languages-manifest` and `docker-manifest` likewise
skipped. The full `box:2.3.0-{amd64,arm64}` images were therefore never built.

The `build-dind-*` jobs, however, gate on their manifest needs being
`success` **or `skipped`** (so dind can still run when only some flavours
changed). With the manifests skipped, the dind `full` jobs ran and tried to
build `FROM docker.io/***/box:2.3.0-<arch>`, which does not exist → "not found".
Likewise `build-dind-amd64 (java)` built `FROM box-java:2.3.0-amd64`, which the
failed `java` build never pushed.

So three of the four red jobs are **downstream symptoms** of 3.1. They are the
"false positives" the issue refers to: the dind builds were never broken; they
were starved of a base image by an upstream network blip. Eliminating the root
cause (3.1) removes all four reds together. (A possible future refinement —
skipping dind `full`/`java` when their base manifest was skipped rather than
letting them fail on a missing base — is noted in §5 as defense-in-depth, but is
deliberately *not* the primary fix because a skipped base on a real release is
itself a signal that should not be silently green.)

## 4. The fix (this PR)

`setup-buildx-resilient` now seeds the BuildKit image from a **pull-through
registry mirror on independent infrastructure** when Docker Hub is unreachable:

1. Pull `moby/buildkit:buildx-stable-1` from Docker Hub with the existing 5×
   exponential-backoff retries (handles the common transient blip).
2. **New:** if that exhausts, pull `mirror.gcr.io/moby/buildkit:buildx-stable-1`
   (Google's public pull-through cache of Docker Hub, served from Google infra
   that is essentially never down at the same instant as Docker Hub), then
   `docker tag` it back to the canonical `moby/buildkit:buildx-stable-1`. The
   docker-container driver boot then finds the image locally and **never touches
   the failing registry**.
3. If even the mirror fails, fall through to the previous behaviour (let buildx
   try its own boot pull) — strictly no worse than before.

Supporting changes:

- **Verbose/debug mode** (requirement 5): a `verbose` input plus automatic
  tracing under `RUNNER_DEBUG=1`, so a future outage prints `set -x` detail of
  exactly which source served (or failed) the pull.
- **Tunable retry budget** via `PREPULL_ATTEMPTS` / `PREPULL_DELAY` env (CI
  defaults unchanged at 5 / 5s), used by the unit test to run fast.
- **Codebase-wide coverage** (requirement 7): every `Set up Docker Buildx` in
  `release.yml` (12 occurrences) already routes through this one composite
  action, so the single edit hardens **all** buildx boots — JS, essentials,
  every language, the full `box` image, both arch push jobs, and every dind
  variant. No other workflow boots buildx.
- **Unit test**
  [`experiments/test-issue100-buildx-mirror-fallback.sh`](../../../experiments/test-issue100-buildx-mirror-fallback.sh)
  extracts the real pre-pull script out of `action.yml` and drives it with a
  mock `docker` for three scenarios: canonical-healthy (no mirror touched),
  Docker-Hub-down/mirror-healthy (recovers + re-tags — the issue #100 scenario),
  and both-down (non-fatal fall-through), plus static assertions on the action.

### 4.1 Existing components / prior art considered

| Option | Verdict |
| --- | --- |
| `mirror.gcr.io` pull-through cache | **Chosen.** Zero-config, public, independent infra, well-documented Docker Hub mirror; smallest surgical change. |
| Configure dockerd `registry-mirrors` in `/etc/docker/daemon.json` + restart | Covers boot pulls natively but adds a daemon restart to every job and is heavier than a targeted re-tag; rejected for now. |
| `nick-fields/retry` around `setup-buildx-action` | Only retries the same unreachable host; does not add an independent source. Insufficient alone. |
| Mirror `moby/buildkit` into GHCR ourselves | Works but adds a maintenance/publishing burden and another moving part vs. an existing public mirror. |
| Switch buildx to the default `docker` driver | Avoids the BuildKit container pull but loses multi-platform / cache-export features the release relies on. Not viable. |

## 5. Defense-in-depth / future work (not required to close this issue)

- Optionally gate `build-dind-*` (full/java) on the *actual* base manifest having
  been built (e.g. condition on `docker-manifest.result == 'success'` for `full`)
  so a skipped base yields a skip, not a confusing "not found" failure. Kept out
  of this PR to avoid masking genuinely missing-base releases.
- Consider applying the same mirror fallback default to the templates (see §6).

## 6. Template comparison and upstream reports (requirements 2, 3, 6)

The four templates were compared for the same buildx-boot exposure:

- **rust-ai-driven-development-pipeline-template** — uses
  `docker/setup-buildx-action@v4` **with no pinned-image pre-pull and no mirror
  fallback** (`release.yml`). Its boot pulls `moby/buildkit` straight from Docker
  Hub, so it is vulnerable to exactly this outage. → reported upstream with the
  `setup-buildx-resilient` pattern as the suggested fix.
- **js-ai-driven-development-pipeline-template** — publishes via a
  `publish-dockerhub` composite action; reviewed for the same gap.
- **python-** / **csharp-…-template** — `release.yml` reviewed; buildx-boot
  exposure assessed.

Upstream issue links are recorded in [`template-reports.md`](./template-reports.md).

## 7. Verification

```
$ bash experiments/test-issue100-buildx-mirror-fallback.sh
...
PASS=15 FAIL=0
All issue #100 buildx mirror-fallback checks passed.
```

`release.yml` and the composite `action.yml` both pass `YAML.load_file`. The
real-world verification is the next release run booting buildx through the mirror
fallback when Docker Hub blips.
