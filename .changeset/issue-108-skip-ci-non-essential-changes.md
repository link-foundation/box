---
bump: patch
---

ci: skip the build/test matrix when a PR's latest commit only touches
non-essential files (issue #108).

Change detection is extracted from four inline `release.yml` steps into a
single, unit-tested `scripts/ci/detect-changes.sh`. For `pull_request` events it
now diffs **only the PR head's latest commit** (`HEAD^2^..HEAD^2` against
GitHub's synthetic merge commit) instead of the whole-PR diff against the base
SHA, so a trivial synchronize commit (`.gitkeep`, docs, Markdown, changeset) no
longer re-runs the full ~33-minute image build/test matrix when an earlier
commit on the same PR changed image source — those earlier commits were already
tested when they were pushed. `push` events still evaluate the full pushed range
so release builds are never skipped, and `docs/dind/` no longer triggers the
dind matrix. This mirrors the per-commit `detect-code-changes` scripts shipped
by the link-foundation pipeline templates. Covered by
`experiments/test-issue108-detect-changes.sh` (21 assertions) and documented in
`docs/case-studies/issue-108/`.
