# Case Study: Docker Image Publishing Issues

**Issue:** [#11 - Docker image publishing](https://github.com/link-foundation/box/issues/11)

**Date of Analysis:** 2026-01-22

## Executive Summary

The Docker image publishing workflow has multiple issues that prevent successful builds:

1. **Manual force build (`workflow_dispatch`) never triggers Docker build jobs**
2. **Regular releases don't trigger Docker builds** (no changed files matching Dockerfile or scripts)
3. **`unknown/unknown` platform appears in GHCR package** due to Docker attestation manifests
4. **No versioning support** - images only tagged with `latest`, SHA, and date
5. **No GitHub Releases** for version tracking

## Issues Analyzed

### Issue 1: Manual Force Build Doesn't Work

**Observed Behavior:**
- Run [#21232569144](https://github.com/link-foundation/box/actions/runs/21232569144) was triggered with `workflow_dispatch` and `force_build: true`
- All Docker build jobs were **skipped**

**Root Cause:**
The `docker-build-push` job has this condition (line 176 of `release.yml`):
```yaml
if: github.event_name == 'push' && github.ref == 'refs/heads/main' && needs.detect-changes.outputs.should-build == 'true'
```

This requires `github.event_name == 'push'`, but `workflow_dispatch` events have `github.event_name == 'workflow_dispatch'`. The `force_build` input is correctly read (`"true" = "true"`), but the job condition excludes non-push events entirely.

**Evidence from logs:**
```
detect-changes	Determine if build is needed	2026-01-22T01:32:12.2018507Z ##[group]Run if [ "true" = "true" ]; then
```

The force_build was correctly parsed as `true`, and `should-build` was set to `true`, but the downstream job was skipped due to `github.event_name != 'push'`.

### Issue 2: Regular Releases Don't Trigger Builds

**Observed Behavior:**
- Run [#21206380504](https://github.com/link-foundation/box/actions/runs/21206380504) was triggered by `push` to `main`
- All Docker build jobs were **skipped**

**Root Cause:**
The push to main (commit `9bdbf5b`) merged PR #10 which reverted changes from issue-9. The diff between commits `a306c7f` and `9bdbf5b` only included documentation files, not `Dockerfile` or `scripts/` files.

**Evidence from logs:**
```
detect-changes	Determine if build is needed	2026-01-21T10:38:19.3557604Z ##[group]Run if [ "" = "true" ]; then
```

Note: `force_build` is empty (`""`) for push events, and `docker=false`, `scripts=false`, so `should-build` became `false`.

### Issue 3: `unknown/unknown` Platform in GHCR

**Observed Behavior:**
According to the issue description, the GHCR package at https://github.com/link-foundation/box/pkgs/container/box shows `unknown/unknown` instead of `linux/arm64`.

**Root Cause:**
This is caused by Docker Buildx's default behavior of including **provenance attestations** when pushing images. These attestations are stored as manifest entries with `unknown/unknown` platform.

Reference: [GitHub Community Discussion #45969](https://github.com/orgs/community/discussions/45969)

**Solutions:**
1. Disable provenance: `provenance: false` in `docker/build-push-action`
2. Use proper annotation levels with OCI manifests

### Issue 4: No Versioning Support

**Current State:**
Tags generated are only:
- `latest`
- `{SHA}` (e.g., `9bdbf5b`)
- `{DATE}` (e.g., `20260121`)

**Requirement:**
Version tags from `package.json` (currently `1.0.0`) should be included.

### Issue 5: No GitHub Releases

**Current State:**
No GitHub Releases are created for new versions.

**Requirement:**
Each version should have a GitHub Release with links to both GHCR and Docker Hub images.

## Timeline of Events

| Timestamp | Run ID | Event | Result |
|-----------|--------|-------|--------|
| 2026-01-10 14:50 | 20880000393 | push | Build started, ARM64 cancelled after 6h |
| 2026-01-13 21:17 | 20972929542 | push | Build started, ARM64 cancelled after 6h |
| 2026-01-14 17:04 | 21002878662 | push | Build started, ARM64 cancelled (see issue-7) |
| 2026-01-16 17:16 | 21074767637 | push | Skipped - no relevant changes |
| 2026-01-21 10:38 | 21206380504 | push | Skipped - no relevant changes |
| 2026-01-22 01:32 | 21232569144 | workflow_dispatch | Skipped - event_name mismatch |

## Root Causes Summary

1. **Workflow condition bug**: `docker-build-push` job only runs for `push` events, excluding `workflow_dispatch`
2. **Change detection too strict**: Only rebuilds when Dockerfile/scripts change, not on force_build
3. **Missing provenance settings**: Default provenance creates `unknown/unknown` manifests
4. **Missing version tagging**: No extraction of version from package.json
5. **Missing release automation**: No GitHub Release creation

## Proposed Solutions

### Solution 1: Fix Job Conditions for workflow_dispatch

**Before:**
```yaml
docker-build-push:
  if: github.event_name == 'push' && github.ref == 'refs/heads/main' && needs.detect-changes.outputs.should-build == 'true'
```

**After:**
```yaml
docker-build-push:
  if: |
    (github.event_name == 'push' && github.ref == 'refs/heads/main' && needs.detect-changes.outputs.should-build == 'true') ||
    (github.event_name == 'workflow_dispatch' && github.event.inputs.force_build == 'true')
```

### Solution 2: Add provenance: false

```yaml
- name: Build and push Docker image (amd64)
  uses: docker/build-push-action@v5
  with:
    provenance: false
    # ... rest of config
```

### Solution 3: Add Version Extraction and Tagging

```yaml
- name: Extract version from package.json
  id: pkg
  run: echo "version=$(node -p "require('./package.json').version")" >> $GITHUB_OUTPUT

- name: Extract metadata
  uses: docker/metadata-action@v5
  with:
    tags: |
      type=raw,value=latest
      type=raw,value=${{ steps.pkg.outputs.version }}
      type=sha,prefix=
```

### Solution 4: Add GitHub Release Creation

Add a new job to create GitHub Releases with links to both registries.

## References

- [Docker Multi-platform Build Documentation](https://docs.docker.com/build/ci/github-actions/multi-platform/)
- [GitHub Discussion: unknown/unknown Platform](https://github.com/orgs/community/discussions/45969)
- [Docker build-push-action Issue #820](https://github.com/docker/build-push-action/issues/820)
- [Case Study: Issue #7 - ARM64 Build Timeout](../issue-7/README.md)
