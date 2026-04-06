# Case Study: Automatic Release Workflow Not Triggering on Push to Main

**Issue:** [#23 - Changesets and automatic version bump, and GitHub releases support](https://github.com/link-foundation/box/issues/23)

**Date of Investigation:** 2026-01-29

## Executive Summary

The automatic release workflow for the box Docker image fails to build and release when code is pushed to the main branch, despite the detect-changes job correctly identifying that a build should occur. The root cause is a GitHub Actions behavior where jobs in a dependency chain are skipped when an upstream job is skipped, even if the downstream job has an explicit `if` condition that evaluates to true.

## Timeline of Events

| Date | Event | Run ID | Result |
|------|-------|--------|--------|
| 2026-01-22 16:38 | Manual workflow_dispatch release | [21256601666](https://github.com/link-foundation/box/actions/runs/21256601666) | **Success** - v1.0.0 released |
| 2026-01-23 21:30 | Push to main (after PR merge) | [21301810652](https://github.com/link-foundation/box/actions/runs/21301810652) | **Failure** - ARM64 build error |
| 2026-01-25 17:55 | Push to main (after PR merge) | [21336989545](https://github.com/link-foundation/box/actions/runs/21336989545) | **Failure** - ARM64 build error |
| 2026-01-29 00:55 | Push to main (PR #22 merged) | [21461368663](https://github.com/link-foundation/box/actions/runs/21461368663) | **All jobs skipped** |

## Root Cause Analysis

### Problem Statement

When a PR is merged to main, the release workflow's `detect-changes` job runs successfully and sets `should-build=true`, but all downstream jobs (`docker-build-push`, `docker-build-push-arm64`, `docker-manifest`, `create-release`) are skipped.

### Root Cause: GitHub Actions Implicit `success()` Check

The workflow has the following dependency structure:

```
version-bump (skipped for push events)
    └── detect-changes (runs with always())
            └── docker-build-push (condition evaluates to true but job is skipped!)
                    └── docker-build-push-arm64
                            └── docker-manifest
                                    └── create-release
```

The `docker-build-push` job has this condition:
```yaml
if: |
  (github.event_name == 'push' && github.ref == 'refs/heads/main' && needs.detect-changes.outputs.should-build == 'true') ||
  (github.event_name == 'workflow_dispatch')
```

**The Problem:** GitHub Actions implicitly prepends `success()` to all job `if` conditions. This means the actual evaluation is:
```yaml
if: success() && ((github.event_name == 'push' && ...) || ...)
```

When `version-bump` is skipped, the implicit `success()` check fails for all downstream jobs, regardless of whether their explicit conditions evaluate to true.

### Evidence from Logs

Run [21461368663](https://github.com/link-foundation/box/actions/runs/21461368663):

1. **detect-changes** job ran successfully:
   - Set `should-build=true`
   - Set `version=1.0.1`
   - Output: "Build triggered by: Dockerfile or scripts changes"

2. **docker-build-push** job was skipped despite meeting all explicit conditions:
   - `github.event_name == 'push'` ✓
   - `github.ref == 'refs/heads/main'` ✓
   - `needs.detect-changes.outputs.should-build == 'true'` ✓
   - **Implicit `success()` check failed** due to `version-bump` being skipped ✗

### Reference

This is a well-documented GitHub Actions behavior:
- [actions/runner#491 - Job-level "if" condition not evaluated correctly if job in "needs" property is skipped](https://github.com/actions/runner/issues/491)
- [GitHub Community Discussion #26945 - Jobs being skipped while using both `needs` and `if`](https://github.com/orgs/community/discussions/26945)

## Solution

### Fix: Add `always()` to Job Conditions

All downstream jobs that depend on jobs that might be skipped need to explicitly include `always()` (or `!cancelled()`) in their `if` conditions:

```yaml
# Before (broken)
docker-build-push:
  needs: [detect-changes]
  if: |
    (github.event_name == 'push' && github.ref == 'refs/heads/main' && needs.detect-changes.outputs.should-build == 'true') ||
    (github.event_name == 'workflow_dispatch')

# After (fixed)
docker-build-push:
  needs: [detect-changes]
  if: |
    always() &&
    needs.detect-changes.result == 'success' &&
    (
      (github.event_name == 'push' && github.ref == 'refs/heads/main' && needs.detect-changes.outputs.should-build == 'true') ||
      (github.event_name == 'workflow_dispatch')
    )
```

### Jobs That Need Fixing

1. **docker-build-push** - Needs `always()` and check for `detect-changes.result == 'success'`
2. **docker-build-push-arm64** - Needs `always()` and checks for both `detect-changes.result` and `docker-build-push.result`
3. **docker-manifest** - Needs `always()` and checks for dependent job results
4. **create-release** - Needs `always()` and checks for dependent job results

## Implemented Solution

### Changeset-Based Versioning System

The following features have been implemented based on the template repository patterns:

| Feature | Implementation |
|---------|----------------|
| Version Source | VERSION file (kept as-is) |
| Changesets | `.changeset/` directory with shell scripts |
| Version Bump | Automatic via changesets on push to main |
| Version Check | Prevents manual VERSION changes in PRs |
| Changeset Check | Requires changesets for code changes in PRs |
| Manual Release | Supported via `workflow_dispatch` with `bump-and-release` mode |

### New Files Added

1. **`.changeset/README.md`** - Documentation for contributors
2. **`.changeset/config.json`** - Changeset configuration
3. **`scripts/release/check-changesets.sh`** - Detects pending changesets
4. **`scripts/release/check-version.sh`** - Prevents manual VERSION changes
5. **`scripts/release/validate-changeset.sh`** - Validates changeset format in PRs
6. **`scripts/release/apply-changesets.sh`** - Applies changesets and bumps version
7. **`scripts/release/create-changeset.sh`** - Creates changesets for manual releases

### Workflow Changes

1. **version-check job** - Runs on PRs to prevent manual VERSION changes
2. **changeset-check job** - Runs on PRs to require changesets for code changes
3. **apply-changesets job** - Runs on push to main, applies pending changesets
4. **always() pattern** - Added to all downstream jobs to prevent skipping

## Comparison with Template Repository

The [js-ai-driven-development-pipeline-template](https://github.com/link-foundation/js-ai-driven-development-pipeline-template) uses Node.js/Bun scripts and the `@changesets/cli` package. This repository uses shell scripts for simplicity since it's a Docker-based project without Node.js dependencies.

## Industry Best Practices

### From Research

1. **[Changesets](https://github.com/changesets/changesets)** - Standard tool for managing versioning in monorepos and single packages
2. **Semantic Release** - Alternative approach using conventional commits
3. **GitHub Actions OIDC** - For trusted publishing to npm without secrets

### Recommended Approach for Docker-based Projects

For projects like box that primarily release Docker images (not npm packages):

1. **Keep VERSION file** - Simple and explicit version tracking
2. **Add changeset support** - For documenting changes between versions
3. **Automated version bump** - On merge to main when changesets exist
4. **GitHub Release creation** - With auto-generated notes from changesets

## Files

- `ci-runs.json` - Full list of recent CI runs
- `ci-logs/` - Downloaded logs from failed and successful runs
- `template-release.yml` - Template repository's release workflow for comparison
- `releases.txt` - Current GitHub releases list

## Metrics

| Metric | Before Fix | After Fix (Expected) |
|--------|-----------|---------------------|
| Auto-release on push to main | 0% (skipped) | 100% |
| Manual release success | 100% | 100% |
| Version sync (VERSION file to release) | Manual only | Automatic |

## Conclusion

The automatic release workflow failure is caused by GitHub Actions' implicit `success()` check in job conditions. When the `version-bump` job is skipped (which happens for all push events), the implicit success check fails for all downstream jobs, even if their explicit conditions evaluate to true.

The fix requires adding `always()` to job conditions and explicitly checking the result of dependent jobs. This is a well-known GitHub Actions behavior documented in multiple issues and discussions.

## References

- [GitHub Actions Runner Issue #491](https://github.com/actions/runner/issues/491)
- [GitHub Community Discussion #26945](https://github.com/orgs/community/discussions/26945)
- [Changesets Documentation](https://github.com/changesets/changesets)
- [GitHub Docs - Workflow syntax](https://docs.github.com/actions/using-workflows/workflow-syntax-for-github-actions)
- [Auto-Tag Docker Images with Semantic Versioning](https://dev.to/devopswithamol/auto-tag-docker-images-with-semantic-versioning-using-github-actions-1g50)
