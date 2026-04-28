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
