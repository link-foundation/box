---
'go-ai-driven-development-pipeline-template': patch
---

Fix CI/CD check differences between pull request and push events

Changes:

- Add `detect-changes` job with cross-platform `detect-code-changes.mjs` script
- Make lint job independent of changeset-check (runs based on file changes only)
- Allow docs-only PRs without changeset requirement
- Handle changeset-check 'skipped' state in dependent jobs
- Exclude `.changeset/`, `docs/`, `experiments/`, `examples/` folders and markdown files from code changes detection
