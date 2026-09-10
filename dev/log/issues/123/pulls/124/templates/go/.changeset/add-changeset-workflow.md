---
'go-ai-driven-development-pipeline-template': minor
---

Added `.changeset` folder workflow similar to JavaScript template. This provides safe, conflict-free version management where each PR includes a changeset file that specifies the version bump type (patch/minor/major) and description. Version bumps happen automatically after PR merge, preventing merge conflicts in version files.
