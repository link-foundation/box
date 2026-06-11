# Template comparison & upstream reports (issue #100, requirements 2/3/6)

The issue asks us to compare the four pipeline templates for the same class of
CI error and, where a template shares the defect, report it upstream with a
reproducible example, workaround and suggested fix.

## Method

For each template we inspected every file under `.github/workflows/` and
`.github/actions/` for buildx usage (`docker/setup-buildx-action`,
`docker/build-push-action`, `moby/buildkit`, registry-mirror configuration).
The relevant exposure is the **buildx boot pull**: the default `docker-container`
driver makes dockerd pull `moby/buildkit:buildx-stable-1` from Docker Hub, so a
transient `registry-1.docker.io` outage fails the job (the issue #100 root
cause).

## Findings

| Template | Boots buildx? | Pre-pull / mirror fallback? | Exposed? | Action |
| --- | --- | --- | --- | --- |
| [rust](https://github.com/link-foundation/rust-ai-driven-development-pipeline-template) | Yes — `docker/setup-buildx-action@v4` in `release.yml` (two jobs) | No | **Yes** | Reported: [issue #69](https://github.com/link-foundation/rust-ai-driven-development-pipeline-template/issues/69) |
| [js](https://github.com/link-foundation/js-ai-driven-development-pipeline-template) | Yes — `docker/setup-buildx-action@v4` + `build-push-action@v7` in `.github/actions/publish-dockerhub` | No | **Yes** | Reported: [issue #75](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/75) |
| [python](https://github.com/link-foundation/python-ai-driven-development-pipeline-template) | No buildx / docker build in any workflow | n/a | No | None needed |
| [csharp](https://github.com/link-foundation/csharp-ai-driven-development-pipeline-template) | No buildx / docker build in any workflow | n/a | No | None needed |

## Suggested upstream fix (shared)

Both reports propose porting the `box` repo's reusable composite action
[`setup-buildx-resilient`](../../../.github/actions/setup-buildx-resilient/action.yml):
pre-pull the pinned BuildKit image with retries, fall back to
`mirror.gcr.io/moby/buildkit:buildx-stable-1` when Docker Hub is unreachable,
re-tag to the canonical reference, then boot buildx with
`driver-opts: image=moby/buildkit:buildx-stable-1` so it reuses the cached copy.
