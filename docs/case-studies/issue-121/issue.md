# Issue #121: Check for all false positives, false negatives, warnings and errors in CI/CD and fix them all

> Source: https://github.com/link-foundation/box/issues/121
> Opened: 2026-09-09T06:05:57Z

---

### Recent CI/CD runs on `main`

| Workflow | Status | Conclusion | Commit | Run |
| --- | --- | --- | --- | --- |
| Build and Release Docker Image | completed | success | `e77abcc` | [run](https://github.com/link-foundation/box/actions/runs/34293699247) |
| Workflows | completed | success | `e77abcc` | [run](https://github.com/link-foundation/box/actions/runs/34293699033) |
| Security | completed | success | `e77abcc` | [run](https://github.com/link-foundation/box/actions/runs/34293699154) |
| Scripts | completed | failure | `e77abcc` | [run](https://github.com/link-foundation/box/actions/runs/34293699072) |
| File sizes | completed | success | `e77abcc` | [run](https://github.com/link-foundation/box/actions/runs/34293699000) |
| Links | completed | success | `e77abcc` | [run](https://github.com/link-foundation/box/actions/runs/34293698989) |
| Measure Disk Space and Update README | completed | success | `b245dd8` | [run](https://github.com/link-foundation/box/actions/runs/34011750117) |
| Dockerfiles | completed | success | `b245dd8` | [run](https://github.com/link-foundation/box/actions/runs/34011750123) |

Use all the best practices from CI/CD templates (check full file tree to compare for all GitHub workflow and CI/CD scripts file), if the same issue is found in template report issue also in templates:

- https://github.com/link-foundation/js-ai-driven-development-pipeline-template
- https://github.com/link-foundation/python-ai-driven-development-pipeline-template

We should compare all files, so we don't have more CI/CD errors in the future and reuse all the best practices from these templates.

Follow the CI/CD best practices collected in [https://github.com/link-assistant/hive-mind/blob/main/docs/CI-CD-BEST-PRACTICES.md](https://github.com/link-assistant/hive-mind/blob/main/docs/CI-CD-BEST-PRACTICES.md).

Please plan and execute everything in this single pull request, you have unlimited time and context, as context auto-compacts and you can continue indefinitely, until it is each and every requirement fully addressed, and everything is totally done.

---

<details>
<summary>Context collected by <code>/fix --ci-cd</code></summary>

- **Repository:** [link-foundation/box](https://github.com/link-foundation/box)
- **Default branch:** `main`
- **Latest commit:** `42858af` ([commit](https://github.com/link-foundation/box/commit/42858af9823d2a0c0a5c85929c6e13a61b69a154)) — 2.8.0: Publish every architecture the release built, and fail when a tag serves fewer (issue #119). Run 34056619231 finished `success` and left `konard/box:latest` amd64-only — the tag the README hands to every reader, which had been multi-arch since June. `docker manifest inspect` still answered 200, so nothing noticed. Four mechanisms, one sentence: **"it resolves" is not "it was published"**. ### The two tools could never have agreed `mirror-to-dockerhub.sh` copies with `docker buildx imagetools create`, which always wraps its result in an OCI index — even around a single platform. `create-multiarch-manifest.sh` then fed those copies to `docker manifest create`, which refuses an index source: `docker.io/***/box:2.7.0-amd64 is a manifest list`, three times, 40 seconds, then a warning. Retrying a deterministic failure is not resilience, it is a permanent defect wearing a transient one's costume — which is why the warning read like a flaky registry for a month. The manifest step publishes with `imagetools create` now, and Docker Hub assembles nothing at all: it mirrors the index GHCR already serves, which is what the issue proposed. ### Which job may write a tag a user pulls The `box` amd64 job mirrored **8** tags, the four suffixed and the four unsuffixed, so an architecture-specific job claimed `:latest`; `box-dind`'s mirror wrote only suffixed tags, which is why `konard/box-dind:2.7.0` is simply absent. Two spellings of one step, disagreeing about a rule nobody had written down. It is written down now — only a manifest step may name a bare tag — and `experiments/test-issue119-tag-policy.sh` reads every image reference out of the five release workflows and asserts it, so the next family added to the matrix cannot pick the other convention. For the manifest step to be the only writer it has to know every tag the release writes, which it did not: `docker/metadata-action` evaluates `{{date 'YYYYMMDD'}}` when the step runs, and the full box takes over an hour to build, so the two architecture jobs of a release started near midnight UTC name different tags — and the date and commit tags stayed single-architecture (`ghcr.io/link-foundation/box:20260907 linux/amd64`). `scripts/release/image-tags.sh` computes the list once and hands it to the other jobs, so every tag of a release reaches the manifest step. ### The check now asks what a tag serves `check-publication.sh` asked whether a reference resolves, and an amd64-only index answers yes. It reads the platform list now and fails on a reference carrying less than the release built, holding three distinctions apart: a **missing** mirror tag is lag and stays a warning (a mirror may trail the registry of record), a mirror tag that **resolves with the wrong architectures** is an error because somebody pulling it today gets the wrong answer today, and an **unreadable** platform list means "I could not look" — never "one architecture", which would be issue #117's false claim pointed the other way, at the cost of a release. `EXPECTED_PLATFORMS` is a constant, so `PREVIOUS_VERSION` adds the comparison a constant cannot make: a tag that was multi-arch in the previous release and is single-arch now is a regression regardless. `latest` joined the sample, being the tag the regression landed on. ### The tables say what was measured The v2.7.0 notes listed `konard/box-dind:2.7.0` as not published and then linked its `2.7.0-arm64` tag, under a column headed **Multi-arch**, while `konard/box:2.7.0` served linux/amd64 alone. A heading reads the same in the release where it is false — the same defect as a check that cannot fail, in documentation form. The heading is "Tag", the cell carries the probe's answer for that exact reference (`**linux/amd64 only**, missing linux/arm64`), and a per-architecture tag is linked only where its parent index was measured to serve that platform. Without `VERIFY_IMAGES` nothing was measured and the notes say so instead of implying it. The README's tables follow, and now state what the registries actually carried on 2026-09-08. ### The two CI jobs that could not finish `pr-test / full` and `pr-test / dind-full` — the only two jobs that hold JS, essentials, 11 language images and the full box on one runner — died four times in the full box's `#64 exporting layers`, with `exit code 143` and `The runner has received a shutdown signal`, while every other job passed on the same commit. Nothing in either job had ever sampled a resource, so `scripts/ci/resource-monitor.sh` now prints memory, disk, swap and the biggest processes from *inside* the build step, which is the only output that survives a runner going down. It answered on the next run: 11 MB of disk consumed across the whole 4.5-minute export with 88 GB still free, against 2.3 GB → **18.8 GB of committed memory** still climbing when the runner was taken down. dockerd buffering an export in anonymous memory is [docker/buildx#1606](https://github.com/docker/buildx/issues/1606), open since Docker 23.0 with nothing to configure; what changed on our side is that commit 46f80a5 made the Lean boxes install a real toolchain, so the full box's `COPY --from=lean-stage` stopped copying a stub. 16 GB of RAM is what an `ubuntu-24.04` runner has and larger runners are not available here, so `scripts/ci/ensure-swap.sh` spends the idle disk on the resource that ran out: a 32 GB swap target, sized down only if it would encroach on the 40 GB the chain and its export still need, decided out loud on `[ensure-swap]` lines, and never a job failure — a runner that cannot get swap gets a warning and the build attempt, because the failure belongs on the build. The `full` dind variant gets 90 minutes instead of 60, since an export that pages is slower than one that does not, and a timeout would hide the fix. ### Evidence and tests Run anonymously against the released v2.7.0 from this branch, the new gate exits 1 with `::error title=The Docker Hub mirror of v2.7.0 is single-architecture` — GHCR 8/8 pullable and multi-arch, Docker Hub 5/8 with `konard/box:2.7.0` and `:latest` at the same amd64-only digest. The transcript, the regenerated notes and the per-reference platform sweeps are in `dev/log/issues/119/pulls/120/`; `docs/case-studies/issue-119/` has the full analysis. 170 offline assertions across seven suites: `test-issue115-release-notes.sh` (50), `test-issue119-ci-resource-headroom.sh` (40, with the swapfile's privileged steps stubbed so the sequence is checked without root), `test-issue119-platform-coverage.sh` (21), `test-issue119-image-tags.sh` (19), `test-issue119-check-publication.sh` (16), `test-issue119-tag-policy.sh` (13) and `test-issue119-manifest-media-type.sh` (11). ### Still outstanding Nothing here rewrites a tag that is already published, so the Docker Hub mirror of 2.7.0 stays wrong until a release runs with these changes. GHCR — the registry of record — has been correct throughout, including for the consumer that prompted the issue.
- **CI/CD runs found:** 8 (1 not passing)

**Detected languages**

- **Shell** — 73.4%
- **JavaScript** — 21.9%
- **Dockerfile** — 3.2%
- **Python** — 1.5%

**Recommended CI/CD templates**

Apply the best practices from these templates, in priority order (most-used language first):

1. **JavaScript / TypeScript** — [link-foundation/js-ai-driven-development-pipeline-template](https://github.com/link-foundation/js-ai-driven-development-pipeline-template) _(detected: JavaScript)_
2. **Python** — [link-foundation/python-ai-driven-development-pipeline-template](https://github.com/link-foundation/python-ai-driven-development-pipeline-template) _(detected: Python)_

Other detected languages without a dedicated template: Shell, Dockerfile.

</details>
