---
bump: patch
---

ci(release): tolerate Docker Hub login failure so a single expired
DOCKERHUB_TOKEN no longer takes down the entire release workflow
(issue #82). Every "Log in to Docker Hub" step now uses
`continue-on-error: true` and is followed by a "Check Docker Hub
login" step that emits a clear `::warning` annotation pointing at
the rotation runbook in `README.md` and `docs/case-studies/issue-82`.
GHCR pushes proceed on their existing credentials when Docker Hub is
unavailable.

ci(release): free ~30 GB of disk space before `docker-build-test` so
the PR-CI smoke job stops failing with `no space left on device`
while building the JS -> essentials -> 11 language images -> full-box
chain on a single ubuntu-24.04 runner. Mirrors the existing
`jlumbroso/free-disk-space` step in `docker-build-push` (issue #41).

ci(release): parallelize the PR test matrix and isolate every Docker
image build on its own VM (issue #82). The single sequential
`docker-build-test` job is replaced by a chain of parallel matrix jobs:
`pr-test-js` (1 VM) -> `pr-test-essentials` (1 VM) ->
`pr-test-language` (matrix x 11 languages, parallel) ->
`pr-test-full` (1 VM, builds the full chain locally because the
`full-box` Dockerfile uses `COPY --from=*-stage`), with
`pr-test-dind` (matrix x 14 variants, parallel) running alongside
`pr-test-full` once `pr-test-essentials` finishes. A
`docker-build-test` aggregator job preserves the existing
branch-protection check name. Every build job (15 jobs:
`pr-test-*`, `build-{js,essentials,languages,dind}-{amd64,arm64}`,
`docker-build-push{,-arm64}`) now runs `jlumbroso/free-disk-space@main`
before its first build step. Cross-job layer reuse uses
`docker/build-push-action` with `cache-from`/`cache-to: type=gha`.
