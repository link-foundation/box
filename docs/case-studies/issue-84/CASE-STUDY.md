# Case Study: Issue #84 - Changeset release job fails on quoted markdown text

## Summary

The latest failed `main` release run linked from issue #84 is
[run #25125551441](https://github.com/link-foundation/box/actions/runs/25125551441), job
[`Apply Changesets`](https://github.com/link-foundation/box/actions/runs/25125551441/job/73637479652).
It started on 2026-04-29 at 18:04:44 UTC for commit `c7626c0d9d2a08907634ebd5babcaa7579b83222`
and failed six seconds later while applying `.changeset/issue-82-tolerate-dockerhub-login-failure.md`.

The immediate error in the preserved log is:

```text
xargs: unmatched single quote; by default quotes are special to xargs unless you use the -0 option
```

The triggering changeset body contains `buildx's`, and `scripts/release/apply-changesets.sh`
used `xargs` as a whitespace trimmer for arbitrary markdown description text. That made ordinary
release-note prose part of `xargs` syntax.

## Data Preserved

Local evidence saved for this issue:

| File | Purpose |
|---|---|
| [`issue.md`](./issue.md) | Issue body snapshot. |
| [`ci-logs/run-25125551441-summary.json`](./ci-logs/run-25125551441-summary.json) | Linked failed run metadata. |
| [`ci-logs/job-73637479652.json`](./ci-logs/job-73637479652.json) | Linked failed job metadata. |
| [`ci-logs/run-25125551441.log`](./ci-logs/run-25125551441.log) | Full linked run log. |
| [`ci-logs/job-73637479652.log`](./ci-logs/job-73637479652.log) | Focused failed job log. |
| [`ci-logs/recent-runs-main.json`](./ci-logs/recent-runs-main.json) | Recent `main` run list. |
| [`ci-logs/recent-runs-issue-branch.json`](./ci-logs/recent-runs-issue-branch.json) | Prepared branch run list. |
| [`ci-logs/run-25073172386*`](./ci-logs/) | Older Docker Hub token failure evidence from issue #82. |
| [`ci-logs/run-24024582176*`](./ci-logs/) | Older GHCR/Kotlin failure evidence later addressed by issue #82. |
| [`templates/box-file-tree.txt`](./templates/box-file-tree.txt) | This repo file tree snapshot. |
| [`templates/js-template-file-tree.txt`](./templates/js-template-file-tree.txt) | JS template file tree snapshot. |
| [`templates/rust-template-file-tree.txt`](./templates/rust-template-file-tree.txt) | Rust template file tree snapshot. |

## Timeline

| Time (UTC) | Event |
|---|---|
| 2026-04-28 19:26 | Run `25073172386` fails broadly because Docker Hub rejects the expired token. This is documented in issue #82. |
| 2026-04-29 18:04:44 | PR #83 merge commit `c7626c0` is pushed to `main`, triggering run `25125551441`. |
| 2026-04-29 18:04:51 | `check-changesets.sh` finds one pending changeset, `.changeset/issue-82-tolerate-dockerhub-login-failure.md`. |
| 2026-04-29 18:04:51 | `apply-changesets.sh` reads the changeset, detects `bump: patch`, then pipes the markdown description through `xargs`. |
| 2026-04-29 18:04:51 | `xargs` aborts on `buildx's`, producing `unmatched single quote`; the job exits 1. |
| 2026-04-30 07:15 | Issue #84 is opened with the failed job link and a request for a CI/CD audit against the template repos. |

## Requirements Extracted From Issue #84

| ID | Requirement | Status in this PR |
|---|---|---|
| REQ-84.1 | Download logs and data related to the failed CI/CD run into `docs/case-studies/issue-84`. | Done. |
| REQ-84.2 | Reconstruct the sequence of events. | Done in this case study. |
| REQ-84.3 | List all requirements from the issue. | Done in this section. |
| REQ-84.4 | Find root causes of each problem. | Done; the current failure is quote-unsafe markdown trimming. |
| REQ-84.5 | Propose solution plans for each requirement. | Done below. |
| REQ-84.6 | Compare CI/CD files with JS and Rust pipeline templates. | Done; file trees are preserved under `templates/`, findings below. |
| REQ-84.7 | Search online for additional facts and data. | Done; GNU findutils and GitHub Actions docs are referenced below. |
| REQ-84.8 | Report the same issue in templates if present. | Not needed; the same Bash `xargs` parser is not present in either template. |
| REQ-84.9 | Add debug output if root cause is unclear. | Not needed; the log and reproduction are deterministic. |
| REQ-84.10 | Finish in PR #85. | Done by this branch. |

## Root Cause

### Primary root cause: `xargs` was used on arbitrary markdown prose

`scripts/release/apply-changesets.sh` extracted the body after the second `---` in a changeset and then used:

```bash
awk '/^---$/{n++; next} n>=2' "$CHANGESET" | tr '\n' ' ' | xargs
```

That was intended only to trim and normalize whitespace. It is unsafe for arbitrary release notes because
default `xargs` treats quotes as syntax. The issue #82 changeset text included the normal English possessive
`buildx's`, so `xargs` saw an opening single quote without a matching closing quote and stopped the release.

The GNU findutils manual documents the broader rule: default `xargs` is unsafe for data that can contain
quotes, backslashes, blanks, or newlines, and NUL-delimited handling is the safe option when passing paths
or arbitrary records between tools:
https://www.gnu.org/software/findutils/manual/html_mono/find.html#Safe-File-Name-Handling

### Contributing factor: Bash parser had no regression test

There was no local test or experiment covering changeset bodies with apostrophes, double quotes, extra
spaces, or changeset filenames with whitespace. The script passed for simple descriptions but failed for
real release-note prose.

### Non-root-cause: GitHub Actions outputs

The job correctly used `GITHUB_OUTPUT` for step outputs. GitHub documents writing `name=value` lines to
`$GITHUB_OUTPUT` for step outputs:
https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands#setting-an-output-parameter

The failure happened before output writing in `apply-changesets.sh`.

## Template Comparison

The issue asked to compare the full file tree with:

- `link-foundation/js-ai-driven-development-pipeline-template`
- `link-foundation/rust-ai-driven-development-pipeline-template`

The file tree snapshots are preserved in `templates/`. Relevant CI/CD differences:

| Area | Box repo | JS template | Rust template | Finding |
|---|---|---|---|---|
| Release workflow size | `.github/workflows/release.yml` is 3203 lines. | `release.yml` is 537 lines. | `release.yml` is 488 lines. | Box has a much larger Docker matrix; splitting helpers out of YAML remains a good follow-up. |
| Changeset/changelog parsing | Bash scripts under `scripts/release/*.sh`. | Node/Bun scripts such as `validate-changeset.mjs`, `merge-changesets.mjs`. | Rust scripts such as `get-bump-type.rs`, `collect-changelog.rs`. | Templates avoid ad hoc shell parsing for release metadata. This PR ports the relevant safety property by hardening Bash parsing. |
| PR diff detection | Inline Bash in workflow plus `validate-changeset.sh`. | Dedicated `detect-code-changes.mjs` and explicit base/head SHA support. | Dedicated `detect-code-changes.rs`. | Dedicated scripts are easier to test. Box should continue moving inline workflow logic into scripts. |
| Fresh merge simulation | Not present in Box release checks. | `scripts/simulate-fresh-merge.sh` used by checks. | Not present in the sampled Rust release path. | Useful follow-up for PR checks that need to test the true merge result. |
| Same `xargs` bug | Present in Box `apply-changesets.sh`. | Not present. | Not present. | No upstream template issue is warranted for this bug. |

## Solution Implemented

`scripts/release/apply-changesets.sh` now:

1. Finds changeset files with `find ... -print0` and reads them into a Bash array, so filenames with
   whitespace or shell metacharacters are safe.
2. Prints and iterates changeset paths with quoted array expansion.
3. Replaces `xargs` trimming with `sed` whitespace normalization, so apostrophes and double quotes remain
   ordinary markdown text.

The reproduction and regression check is:

```bash
experiments/test-issue84-apply-changesets-quotes.sh
```

It creates a temporary repository, writes a changeset named `.changeset/quote test's file.md`, includes
`buildx's apostrophe` in the body, runs `DRY_RUN=true scripts/release/apply-changesets.sh`, and verifies
that the version advances from `1.2.3` to `1.2.4` without an `xargs` failure.

## Alternatives Considered

| Option | Pros | Cons | Decision |
|---|---|---|---|
| Replace release scripts with Node/Rust like the templates. | Stronger parsing and easier unit tests. | Larger migration, more risk in a Docker release workflow already carrying many issue #82 changes. | Defer. |
| Keep `xargs` but use `xargs -0`. | Correct for NUL-delimited input. | The description stream is not NUL-delimited and does not need `xargs` at all. | Rejected. |
| Trim with `sed`. | Small, portable on Ubuntu runners, preserves quote characters as data. | Still Bash, so keep scope narrow and test it. | Implemented. |

## Follow-up Plan

1. Move more inline release workflow logic into testable scripts, following the JS/Rust template pattern.
2. Add a CI check that runs fast release-script experiments such as the issue #84 quote regression.
3. Consider splitting the 3203-line Docker release workflow into smaller reusable workflows or composite
   actions once the Docker matrix stabilizes.
4. Consider a fresh-merge simulation step for PR checks that depend on base branch state.

## Validation

Local validation for this PR:

```bash
bash -n scripts/release/apply-changesets.sh
bash -n experiments/test-issue84-apply-changesets-quotes.sh
experiments/test-issue84-apply-changesets-quotes.sh
```
