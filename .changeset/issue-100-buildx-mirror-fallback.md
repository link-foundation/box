---
bump: patch
---

ci: make the buildx boot survive a full Docker Hub registry outage (issue #100).

Run 27314587149 failed not from a code defect but from `registry-1.docker.io`
being unreachable for ~2.5 minutes while booting BuildKit in
`build-languages-amd64 (java)`. The existing `setup-buildx-resilient` pre-pull
(issue #97) only retries Docker Hub, so once the outage outlasted its retry
budget the boot pull failed too — and that single failure cascaded into
`box-java:<ver>-amd64: not found` and `box:<ver>-{amd64,arm64}: not found`
across `build-dind-amd64 (java)`, `build-dind-amd64 (full)` and
`build-dind-arm64 (full)`.

`setup-buildx-resilient` now falls back to a pull-through registry mirror
(`mirror.gcr.io`, on independent infrastructure) and re-tags the BuildKit image
to its canonical reference so the docker-container driver boot reuses the local
copy and never touches the failing registry. Adds an opt-in `verbose` /
`RUNNER_DEBUG` trace and a unit test
(`experiments/test-issue100-buildx-mirror-fallback.sh`). All 12 buildx boots in
`release.yml` route through this one composite action, so every build job is
hardened. Full analysis in `docs/case-studies/issue-100/CASE-STUDY.md`.
