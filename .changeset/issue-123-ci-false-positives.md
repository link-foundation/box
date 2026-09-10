---
bump: minor
---

Make every CI/CD check in this repository fail when it cannot answer (issue #123).

Three pull-request gates asked `git diff --name-only "origin/${BASE_REF}...HEAD"`
and discarded the exit status. `git diff` exits 128 and prints nothing when the
range does not resolve, so `check-version.sh` and the inline `changeset-check`
step reported the passing verdict on a branch that had rewritten VERSION and
changed a script with no changeset. All three now go through
`scripts/release/pr-diff-range.sh`, which restores a base ref that is only
missing locally and otherwise names the cause on stderr and exits 1.
`scripts/release/git-push-with-retry.sh` no longer reads a failed `gh pr list`
as "no pull request is open", and no longer hands a declined `gh pr create` to
`gh pr merge` as if its last line were a URL.
