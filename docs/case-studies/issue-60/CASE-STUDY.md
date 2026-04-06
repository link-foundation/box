# Case Study: Manual CI/CD Did Not Produce Any New Releases (Issue #60)

## Issue Reference
- **Issue**: https://github.com/link-foundation/box/issues/60
- **Commit referenced in issue**: https://github.com/link-foundation/box/commit/7f7671300d152cf110b5d0cf2a9f4e16b3982dab
- **Actions page**: https://github.com/link-foundation/box/actions

---

## Executive Summary

After PR #58 merged on 2026-02-26 (containing the issue-57 fix), the CI/CD pipeline:
1. Correctly bumped the version from 1.3.10 → 1.3.11 via changeset
2. Built Docker images tagged `1.3.11` for most components
3. **Failed to complete the Docker build due to transient network timeouts** on GitHub-hosted runners when connecting to ghcr.io and Docker Hub
4. As a result, **v1.3.11 Docker images were never fully published** and no GitHub Release was created for v1.3.11

The user then manually triggered `workflow_dispatch` with `bump-and-release` mode, which:
1. Bumped 1.3.11 → 1.3.12 (introducing an unintentional version skip)
2. Successfully built and released v1.3.12

**v1.3.11 was never released.** The root cause was **transient network timeouts** on GitHub-hosted runners, compounded by a secondary issue that once a `GITHUB_TOKEN`-based commit is pushed, failures cannot trigger a fresh re-run for that commit automatically.

---

## Timeline of Events

### 2026-02-26T14:05:54Z — Merge Commit `b7462ab` Pushed to `main`

- **Event**: PR #58 merged to `main`, containing the issue-57 fix
- **Trigger**: `push` event on `main`
- **Workflow Run**: [22445566687](https://github.com/link-foundation/box/actions/runs/22445566687) — `Build and Release Docker Image` — **FAILED**

**What happened inside this run:**

**Job: Apply Changesets** (14:05:57Z - 14:06:00Z) — ✅ SUCCESS
- Found `.changeset/fix-du-exit-code-regression.md` (bump: patch)
- Bumped version 1.3.10 → 1.3.11
- Committed as `e20cf46`: `"1.3.11: Fix CI failure caused by du exit code regression..."`
- **Pushed `e20cf46` to `main` at 14:05:59Z** using GITHUB_TOKEN

**Job: detect-changes** (14:06:05Z - 14:06:08Z) — ✅ SUCCESS
- Checked out `refs/heads/main` and saw HEAD as `e20cf46` (v1.3.11) — correctly fetched the new commit
- Detected: `Detected version: 1.3.11`
- Detected VERSION file changed → `should-build=true`

**Jobs: build-js-arm64, build-js-amd64, build-essentials-*,  build-languages-*** (14:06:23Z - 14:18+Z) — ❌ FAILED
- Started building v1.3.11 Docker images (tags included `1.3.11-amd64`, `1.3.11-arm64`)
- JS images: Successfully built and pushed `box-js:1.3.11-*`
- Essentials images: Successfully built and pushed
- Language images: **FAILED** due to transient network timeouts:
  - `ruby` (amd64): `DeadlineExceeded: Post "https://results-receiver.actions.githubusercontent.com/...": dial tcp 140.82.112.22:443: i/o timeout`
  - `java` (amd64): `Error response from daemon: Get "https://ghcr.io/v2/": context deadline exceeded`
  - `java` (arm64): `DeadlineExceeded: failed to fetch oauth token: Post "https://ghcr.io/token": dial tcp 140.82.112.34:443: i/o timeout`
  - `rust` (arm64): `net/http: request canceled while waiting for connection (Client.Timeout exceeded while awaiting headers)`

**Jobs: create-release, docker-manifest** — NEVER RAN (workflow failed before reaching them)

### Why `e20cf46` Never Got Its Own Workflow Run

After `apply-changesets` pushed commit `e20cf46` using `GITHUB_TOKEN`, **GitHub Actions did NOT create a new `on: push` workflow run for that commit**. This is an intentional GitHub restriction to prevent infinite workflow loops.

- **GitHub Documentation**: "If an action pushes code using the repository's GITHUB_TOKEN, a new workflow will not run even when the repository contains a workflow configured to run when push events occur." — [Triggering a workflow from a workflow](https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/triggering-a-workflow#triggering-a-workflow-from-a-workflow)
- **Confirmation**: Zero GitHub Actions workflow runs exist with `head_sha == e20cf4648c446c54bf9492b99bb4ed2356b0a2e9`

This means: if the original push-triggered run fails, there is **no automatic mechanism to retry the build for the version bump commit**. The version bump commit is effectively "orphaned" from CI/CD.

### 2026-02-26T20:05:35Z — User Manually Triggers `workflow_dispatch`

- **Actor**: `konard`
- **Mode**: `bump-and-release`, `bump_type: patch`, `description: "Test patch release"`
- **Workflow Run**: [22459099802](https://github.com/link-foundation/box/actions/runs/22459099802) — **SUCCESS**

**What happened:**
- Read current version (1.3.11, from the `apply-changesets` commit)
- Bumped 1.3.11 → **1.3.12** (this was not the user's intention — v1.3.11 was already bumped, just not released)
- Committed `7f76713`: "1.3.12: Test patch release"
- Successfully built and pushed all Docker images tagged `1.3.12`
- Created GitHub Release `v1.3.12`

**The user's intention** was likely to force a release, but the `workflow_dispatch` with `bump-and-release` mode performed another version bump instead of releasing the already-bumped v1.3.11.

---

## Version/Release Outcome

| Version | Commit  | Docker Images Released | GitHub Release | Notes |
|---------|---------|----------------------|----------------|-------|
| 1.3.10  | f274bfa | ✅ Released           | ✅ v1.3.10     | Previous release |
| 1.3.11  | e20cf46 | ⚠️ Partial (JS + essentials only, language images failed) | ❌ None | Changeset bump succeeded, build failed |
| 1.3.12  | 7f76713 | ✅ Released           | ✅ v1.3.12     | Manual dispatch created extra bump |

---

## Root Cause Analysis

### Root Cause 1 (Primary): Transient Network Timeouts on GitHub-Hosted Runners

**Description**: The build jobs for language images failed due to transient network timeouts when connecting to GitHub Container Registry (ghcr.io) and Docker Hub from GitHub-hosted runners.

**Errors observed** (from run 22445566687):
```
build-languages-amd64 (ruby):
  ##[error]buildx failed with: ERROR: failed to build: failed to solve:
  DeadlineExceeded: Post "https://results-receiver.actions.githubusercontent.com/...":
  dial tcp 140.82.112.22:443: i/o timeout

build-languages-amd64 (java):
  ##[error]Error response from daemon: Get "https://ghcr.io/v2/":
  context deadline exceeded

build-languages-arm64 (java):
  ##[error]buildx failed with: ERROR: failed to build: failed to solve:
  DeadlineExceeded: failed to fetch oauth token: Post "https://ghcr.io/token":
  dial tcp 140.82.112.34:443: i/o timeout

build-languages-arm64 (rust):
  ##[error]Error response from daemon: Get "https://ghcr.io/v2/":
  net/http: request canceled while waiting for connection
  (Client.Timeout exceeded while awaiting headers)
```

**This is a known issue**: GitHub-hosted ARM64 runners in particular have known network instability when connecting to external registries. See:
- [actions/runner-images#11886](https://github.com/actions/runner-images/issues/11886) — Ubuntu network instability on GitHub Actions runners
- Previous case study: [issue-53 case study](../issue-53/CASE-STUDY.md) documented similar ARM64 network issues

**Impact**: Since language builds failed, the `create-release` and `docker-manifest` jobs never ran. No GitHub Release was created for v1.3.11.

### Root Cause 2 (Secondary): No Retry Mechanism for GITHUB_TOKEN-Pushed Version Bump Commits

**Description**: When `apply-changesets` pushes a version bump commit using `GITHUB_TOKEN`, GitHub Actions deliberately does NOT trigger a new `on: push` workflow run for that commit. This is by design to prevent infinite loops.

**Consequence**: If the push-triggered workflow run fails (as it did here), there is no automatic mechanism to retry the build for the version bump commit `e20cf46`. The commit is effectively "orphaned" — it exists in git history with the correct version but no CI/CD will ever automatically build/release it.

**GitHub's documentation on this**:
> "When you use the GITHUB_TOKEN to perform tasks, events triggered by the GITHUB_TOKEN, with the exception of workflow_dispatch and repository_dispatch, will not create a new workflow run."
> — [GitHub Docs](https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/triggering-a-workflow#triggering-a-workflow-from-a-workflow)

**The design gap**: The `workflow_dispatch` `bump-and-release` mode was intended as a manual workaround, but it performs a NEW version bump rather than retrying the failed release of the already-bumped version.

---

## Contributing Factors

### Factor: `workflow_dispatch` bump-and-release Doesn't Retry — It Bumps Again

When the user triggered `workflow_dispatch` with `bump-and-release`, the workflow read the current version (1.3.11) and bumped it to 1.3.12. This created an unintentional extra version increment:
- v1.3.11 was meant to be the release of the issue-57 fix
- v1.3.12 was created as a "Test patch release" but its actual content is identical to v1.3.11

There is no `release-only` mode that would: "build and release the current HEAD version without bumping."

---

## Online Research

### GitHub Actions GITHUB_TOKEN Push Limitation

Sources confirming that GITHUB_TOKEN pushes don't trigger subsequent workflows:
- [GitHub Community Discussion #25702](https://github.com/orgs/community/discussions/25702): "Push from Action does not trigger subsequent action" — confirmed intentional
- [GitHub Community Discussion #37103](https://github.com/orgs/community/discussions/37103): "Push by workflow does not trigger another workflow anymore"
- [GitHub Community Discussion #33804](https://github.com/orgs/community/discussions/33804): "GitHub-actions bot not triggering Actions"
- [GitHub Docs: Triggering a workflow from a workflow](https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/triggering-a-workflow#triggering-a-workflow-from-a-workflow)

### Known Workarounds for Triggering Workflows from Workflows

1. **Use a Personal Access Token (PAT)**: Pushes via PAT DO trigger subsequent `on: push` workflows. Requires maintaining a secret PAT.

2. **Use a GitHub App Token** (`tibdex/github-app-token`): More robust than PAT, doesn't expire.

3. **Use `repository_dispatch`**: Fire a repository dispatch event after the push. Works with GITHUB_TOKEN.

4. **Consolidate build into the same workflow run**: Don't rely on a separate push event — run the build pipeline directly after the version bump within the same run (this is how `workflow_dispatch` mode already works successfully).

5. **Add retry logic**: Use GitHub's `gh run rerun` command or a monitoring workflow to retry failed runs.

### Network Timeout Issues on GitHub Runners

- [actions/runner-images#11886](https://github.com/actions/runner-images/issues/11886): Reports of network instability on GitHub-hosted runners
- Previous case study [issue-53](../issue-53/CASE-STUDY.md): Documented ARM64 runner network issues causing build hangs

---

## Solutions Implemented

### Solution A (Implemented): Add `release-only` Mode to `workflow_dispatch`

A new `release_mode` option `release-only` was added to the workflow. It builds and releases the **current HEAD version** without performing a version bump:

```
workflow_dispatch → release_mode: release-only
→ Skips version-bump job (only runs for bump-and-release)
→ Reads current VERSION (e.g. 1.3.11)
→ Builds all Docker images with 1.3.11 tags
→ Creates GitHub Release v1.3.11
```

**What changed in `.github/workflows/release.yml`** (PR #61):
- Added `release-only` as a third option in the `release_mode` input (alongside `build-only` and `bump-and-release`)
- Updated `should-build` determination: any `workflow_dispatch` event (all three modes) always sets `should-build=true`
- The `version-bump` job's existing `if: release_mode == 'bump-and-release'` condition already correctly skips it for `release-only`
- All build, manifest, and `create-release` jobs already used `github.event_name == 'workflow_dispatch'` in their conditions, so they work for `release-only` without any additional changes

This directly addresses the "stuck version" problem — if `apply-changesets` successfully bumped the version but the build failed, the user can now trigger `release-only` to retry the build and create the release without creating an unwanted extra version increment.

## Proposed Future Solutions

### Solution B (Future): Add Retry Capability for Failed Builds

Implement automatic or semi-automatic retry for failed build runs:
- **Option 1**: A scheduled monitoring workflow that detects failed `push`-triggered runs and re-runs failed jobs
- **Option 2**: Clear documentation telling users to use `gh run rerun <run-id>` to retry a failed run
- **Option 3**: Add retry configuration to build jobs using GitHub Actions' built-in retry (not native, but achievable with `nick-fields/retry` action)

### Solution C (Future): Address Network Timeout Failures

The network timeouts that caused the original failure:
- Increase timeout settings on Docker build/push operations
- Add retry logic around registry pushes
- Consider caching strategies to reduce registry interaction
- Already partially addressed in issue-53 (timeout reduction for ARM64 language builds)

### Solution D (Future): Use PAT for `apply-changesets` Push

Replace the GITHUB_TOKEN push in `apply-changesets.sh` with a PAT to enable triggering of subsequent workflows. This would cause a new `on: push` workflow run when the version bump is committed, eliminating the "orphaned version bump commit" problem.

**Trade-off**: Requires managing a PAT secret with rotation. If the PAT expires, changesets stop working.

---

## Summary of Issues Found

| Issue | Severity | Type |
|-------|----------|------|
| Transient network timeouts caused build failure for v1.3.11 | High | Infrastructure/Reliability |
| No `release-only` workflow_dispatch mode — bump-and-release always creates extra version increment | High | Design Gap |
| GITHUB_TOKEN push doesn't trigger new workflow — no auto-retry for failed version bump builds | Medium | GitHub Platform Limitation |
| v1.3.11 Docker images partially published (JS+essentials but not language images) | Medium | Side Effect of Failure |

---

## Data Files

- `ci-logs/workflow-dispatch-22459099802.log` — The successful `workflow_dispatch` run that created v1.3.12
- `ci-logs/push-failure-22445566687.log` — The failed `push`-triggered run for `b7462ab` that was supposed to release v1.3.11

---

## References

- [GitHub Docs: Triggering a workflow from a workflow](https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/triggering-a-workflow#triggering-a-workflow-from-a-workflow)
- [GitHub Community #25702: Push from Action does not trigger subsequent action](https://github.com/orgs/community/discussions/25702)
- [GitHub Community #37103: Push by workflow does not trigger another workflow anymore](https://github.com/orgs/community/discussions/37103)
- [GitHub Community #33804: GitHub-actions bot not triggering Actions](https://github.com/orgs/community/discussions/33804)
- [actions/runner-images#11886: ARM64 runner network instability](https://github.com/actions/runner-images/issues/11886)
- [Issue #53 Case Study: PHP ARM64 build timeouts](../issue-53/CASE-STUDY.md)
