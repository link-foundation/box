---
bump: minor
---

Publish every architecture the release built, and fail when a tag serves fewer (issue #119).

Run 34056619231 finished `success` and left `konard/box:latest` amd64-only — the tag the README hands to every reader, which had been multi-arch since June. `docker manifest inspect` still answered 200, so nothing noticed. Four mechanisms, one sentence: **"it resolves" is not "it was published"**.

### The two tools could never have agreed

`mirror-to-dockerhub.sh` copies with `docker buildx imagetools create`, which always wraps its result in an OCI index — even around a single platform. `create-multiarch-manifest.sh` then fed those copies to `docker manifest create`, which refuses an index source: `docker.io/***/box:2.7.0-amd64 is a manifest list`, three times, 40 seconds, then a warning. Retrying a deterministic failure is not resilience, it is a permanent defect wearing a transient one's costume — which is why the warning read like a flaky registry for a month. The manifest step publishes with `imagetools create` now, and Docker Hub assembles nothing at all: it mirrors the index GHCR already serves, which is what the issue proposed.

### Which job may write a tag a user pulls

The `box` amd64 job mirrored **8** tags, the four suffixed and the four unsuffixed, so an architecture-specific job claimed `:latest`; `box-dind`'s mirror wrote only suffixed tags, which is why `konard/box-dind:2.7.0` is simply absent. Two spellings of one step, disagreeing about a rule nobody had written down. It is written down now — only a manifest step may name a bare tag — and `experiments/test-issue119-tag-policy.sh` reads every image reference out of the five release workflows and asserts it, so the next family added to the matrix cannot pick the other convention. For the manifest step to be the only writer it has to know every tag the release writes, which it did not: `docker/metadata-action` evaluates `{{date 'YYYYMMDD'}}` when the step runs, and the full box takes over an hour to build, so the two architecture jobs of a release started near midnight UTC name different tags — and the date and commit tags stayed single-architecture (`ghcr.io/link-foundation/box:20260907  linux/amd64`). `scripts/release/image-tags.sh` computes the list once and hands it to the other jobs, so every tag of a release reaches the manifest step.

### The check now asks what a tag serves

`check-publication.sh` asked whether a reference resolves, and an amd64-only index answers yes. It reads the platform list now and fails on a reference carrying less than the release built, holding three distinctions apart: a **missing** mirror tag is lag and stays a warning (a mirror may trail the registry of record), a mirror tag that **resolves with the wrong architectures** is an error because somebody pulling it today gets the wrong answer today, and an **unreadable** platform list means "I could not look" — never "one architecture", which would be issue #117's false claim pointed the other way, at the cost of a release. `EXPECTED_PLATFORMS` is a constant, so `PREVIOUS_VERSION` adds the comparison a constant cannot make: a tag that was multi-arch in the previous release and is single-arch now is a regression regardless. `latest` joined the sample, being the tag the regression landed on.

### The tables say what was measured

The v2.7.0 notes listed `konard/box-dind:2.7.0` as not published and then linked its `2.7.0-arm64` tag, under a column headed **Multi-arch**, while `konard/box:2.7.0` served linux/amd64 alone. A heading reads the same in the release where it is false — the same defect as a check that cannot fail, in documentation form. The heading is "Tag", the cell carries the probe's answer for that exact reference (`**linux/amd64 only**, missing linux/arm64`), and a per-architecture tag is linked only where its parent index was measured to serve that platform. Without `VERIFY_IMAGES` nothing was measured and the notes say so instead of implying it. The README's tables follow, and now state what the registries actually carried on 2026-09-08.

### Evidence and tests

Run anonymously against the released v2.7.0 from this branch, the new gate exits 1 with `::error title=The Docker Hub mirror of v2.7.0 is single-architecture` — GHCR 8/8 pullable and multi-arch, Docker Hub 5/8 with `konard/box:2.7.0` and `:latest` at the same amd64-only digest. The transcript, the regenerated notes and the per-reference platform sweeps are in `dev/log/issues/119/pulls/120/`; `docs/case-studies/issue-119/` has the full analysis. 130 offline assertions across six suites: `test-issue119-platform-coverage.sh` (21), `test-issue119-image-tags.sh` (19), `test-issue119-check-publication.sh` (16), `test-issue119-tag-policy.sh` (13), `test-issue119-manifest-media-type.sh` (11) and `test-issue115-release-notes.sh` (50).

### Still outstanding

Nothing here rewrites a tag that is already published, so the Docker Hub mirror of 2.7.0 stays wrong until a release runs with these changes. GHCR — the registry of record — has been correct throughout, including for the consumer that prompted the issue.
