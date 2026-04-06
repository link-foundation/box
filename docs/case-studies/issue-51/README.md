# Case Study: CI Failure — `git push` Rejected Due to Concurrent Push Race Condition

**Issue**: [#51 - Fix CI/CD](https://github.com/link-foundation/box/issues/51)
**CI Run**: [22267653514, Job 64416730310](https://github.com/link-foundation/box/actions/runs/22267653514/job/64416730310)
**Date**: 2026-02-22
**Status**: Investigation Complete — Fix Applied

## Executive Summary

The "Measure Disk Space and Update README" CI workflow failed at the "Commit and push changes" step with:

```
To https://github.com/link-foundation/box
 ! [rejected]        main -> main (fetch first)
error: failed to push some refs to 'https://github.com/link-foundation/box'
hint: Updates were rejected because the remote contains work that you do not
hint: have locally. This is usually caused by another repository pushing to
hint: the same ref. If you want to integrate the remote changes, use
hint: 'git pull' before pushing again.
```

All 18+ measurement steps succeeded. The failure occurred only during the final `git push` step — **after 18 minutes of valid computation** — because another workflow had pushed a version bump commit to `main` within 1 second of this job starting.

## Timeline of Events

| Time (UTC) | Event |
|------------|-------|
| 2026-02-22T00:57:44 | PR #50 merged into `main` — creates merge commit `411b384e` |
| 2026-02-22T00:57:47 | Two workflows triggered simultaneously on push to `main`: <br> &bull; "Build and Release Docker Image" (run `22267653513`) <br> &bull; "Measure Disk Space and Update README" (run `22267653514`) |
| 2026-02-22T00:57:51 | Measure Disk Space job checks out commit `411b384e` (start of long computation) |
| 2026-02-22T00:57:52 | Build and Release "Apply Changesets" job (run time: 6s) pushes version bump commit `feba582c` to `main` — only **1 second** after Measure Disk Space started |
| 2026-02-22T00:57:52–01:16:23 | Measure Disk Space job runs 18 minutes of disk measurement (all steps succeed) |
| 2026-02-22T01:16:23 | Measure Disk Space: `git commit` succeeds locally (26 components, 7545MB total) |
| 2026-02-22T01:16:23 | Measure Disk Space: `git push origin main` **fails** — remote now at `feba582c`, local at `411b384e` |
| 2026-02-22T01:16:23 | Workflow exits with code 1 |

## Root Cause Analysis

### Primary Cause: No Pull-Before-Push in Long-Running CI Job

The `measure-disk-space.yml` workflow "Commit and push changes" step does a direct `git push origin main` without first doing a `git pull`:

```yaml
- name: Commit and push changes
  if: steps.changes.outputs.has_changes == 'true' && steps.validate.outputs.valid == 'true'
  run: |
    git config user.name "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"
    git add README.md data/disk-space-measurements.json
    TOTAL_SIZE=$(python3 -c "..." 2>/dev/null || echo "unknown")
    git commit -m "chore: update component disk space measurements (${TOTAL_SIZE}MB total)"
    git push origin main   # <-- FAILS if any other push happened during the 18-min run
    echo "Changes committed and pushed successfully"
```

Because this workflow takes **~18 minutes** to run (package installations for disk measurement), the window for a conflicting push is very wide. Any push to `main` during those 18 minutes causes this step to fail.

### Why the Concurrency Setting Didn't Help

The workflow has a concurrency group configured:

```yaml
concurrency:
  group: measure-disk-space-${{ github.ref }}
  cancel-in-progress: true
```

This only prevents **two instances of the same workflow** from running simultaneously. It does **not** prevent other workflows (like "Build and Release Docker Image") from pushing to `main` while the measurement is running.

### Contributing Factor: Release Workflow Pushes to Main Within Seconds

The "Build and Release Docker Image" workflow has an "Apply Changesets" job that runs in ~6 seconds and pushes a version bump commit to `main`. This runs on every push to `main` that includes changeset files. When PR #50 was merged:

1. The merge commit `411b384e` triggered both workflows
2. The release workflow applied the changeset and pushed `feba582c` within 1 second
3. The measure workflow was already past its checkout step and couldn't see the new commit
4. 18 minutes later, the measurement results were ready but the push failed

### This Is a Recurring Failure Mode

Looking at historical CI runs, this same failure pattern has caused multiple CI failures in the past:
- Run `22261112919` — failed at "Run disk space measurement" (permission denied, Issue #46 era)
- Run `22263724056` — failed at "Run disk space measurement" (permission denied, Issue #46 era)
- Run `22265618808` — failed at "Fail on invalid measurements" (Issue #49 era, sed bug)
- Run `22267653514` — failed at "Commit and push changes" **(this issue, git push rejection)**

## Impact

- **Wasted compute**: 18 minutes of CI time thrown away per occurrence
- **Misleading failure**: All measurement steps passed; the failure is at the final push step
- **Data loss**: Valid measurement data (26 components, 7545MB total) never committed to repository
- **Frequency**: Any push to `main` during the ~18 minute measurement window triggers this failure

## Possible Solutions

### Solution 1: Pull-Then-Rebase Before Push (Recommended ✓)

Add a `git pull --rebase origin main` before the `git push`:

```bash
git pull --rebase origin main
git push origin main
```

**Pros**: Simple, robust — handles the race without data loss. The measurement data (README.md, JSON) is non-conflicting with version bumps which only change the `VERSION` file.

**Cons**: Very small risk of conflict if another measurement was committed simultaneously (same files changed).

### Solution 2: Retry Loop with Pull-Rebase

```bash
MAX_RETRIES=3
for i in $(seq 1 $MAX_RETRIES); do
  git pull --rebase origin main && git push origin main && break
  [ $i -lt $MAX_RETRIES ] && sleep $((i * 5))
done
```

**Pros**: Handles the edge case where multiple retries are needed (e.g., multiple concurrent pushes).

**Cons**: Adds complexity; the simple single pull-rebase should be sufficient given only one instance of this workflow runs at a time (via `concurrency`).

### Solution 3: Use a Third-Party Action (e.g., `stefanzweifel/git-auto-commit-action`)

Actions like [`stefanzweifel/git-auto-commit-action`](https://github.com/stefanzweifel/git-auto-commit-action) and [`ad-m/github-push-action`](https://github.com/ad-m/github-push-action) implement retry logic internally.

**Pros**: Battle-tested, handles many edge cases.

**Cons**: Adds a dependency; the problem is simple enough to solve without an additional action.

### Solution 4: Separate the Measurement from the Commit

Run measurement and commit as two separate workflows triggered sequentially. Measurement uploads artifacts; a separate short-lived commit job downloads artifacts and commits.

**Pros**: The commit job would start fresh with the latest main.

**Cons**: Much more complex architecture change; overkill for this problem.

### Chosen Fix

**Solution 1**: Add `git pull --rebase origin main` before `git push origin main` in the "Commit and push changes" step. This is the simplest, most direct fix that addresses the root cause without adding complexity.

The measurement data (README.md and data/disk-space-measurements.json) and the version bump (VERSION file) change different files, so rebase will always succeed cleanly.

## Other CI Steps Review

Per the issue request to "double check all other steps in the same CI/CD flow," the other steps were reviewed:

| Step | Status | Notes |
|------|--------|-------|
| Set up job | ✓ | Standard GitHub Actions setup |
| Checkout repository | ✓ | `fetch-depth: 0` correctly fetches full history |
| Free up disk space | ✓ | Correctly avoids `apt-get remove` (per issue-29 learnings) |
| Create data directory | ✓ | Simple `mkdir -p data` |
| Run disk space measurement | ✓ | Uses `set -o pipefail` correctly; fixed by issues #35, #46, #49 |
| Update README with component sizes | ✓ | No issues found |
| Check for changes | ✓ | Correctly uses `git diff --quiet` |
| Validate measurements | ✓ | Good validation thresholds |
| **Commit and push changes** | **✗ FIXED** | **Missing `git pull --rebase` before `git push`** |
| Fail on invalid measurements | ✓ | Correct safeguard |
| Upload measurement artifacts | ✓ | No issues found |
| Summary | ✓ | No issues found |

## Related Resources

- [GitHub Community Discussion: Error in git push github actions](https://github.com/orgs/community/discussions/25710)
- [Solution to `error: failed to push some refs` on GitHub Actions](https://jonathansoma.com/everything/git/github-actions-refs-error/)
- [peaceiris/actions-gh-pages Issue #1078: support: action failed with "fetch first" hint](https://github.com/peaceiris/actions-gh-pages/issues/1078)
- [GitHub Docs: Control the concurrency of workflows and jobs](https://docs.github.com/en/actions/using-jobs/using-concurrency)
- [Dealing with flaky GitHub Actions – epiforecasts](https://epiforecasts.io/posts/2022-04-11-robust-actions/)

## Artifacts

- [`ci-run-22267653514-failed.log`](./ci-run-22267653514-failed.log) — Failed run log (the git push rejection)
- [`ci-run-22267653514-full.log`](../../ci-run-22267653514.log) — Full run log
- [`ci-run-22265618808-failed.log`](./ci-run-22265618808-failed.log) — Previous failure (Issue #49 era)
- [`ci-run-22263724056-failed.log`](./ci-run-22263724056-failed.log) — Earlier failure (Issue #46 era)
