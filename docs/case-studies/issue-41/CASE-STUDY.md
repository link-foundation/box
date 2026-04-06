# Case Study: Issue #41 - Docker Image Publishing Failure

## Executive Summary

The Docker image publishing workflow (Run ID: 21997899227) failed on February 13, 2026, due to **disk space exhaustion** on the GitHub Actions runner. The `docker-build-push` job failed at the "Build and push full box (amd64)" step with the error:

```
System.IO.IOException: No space left on device : '/home/runner/actions-runner/cached/_diag/Worker_20260213-183604-utc.log'
```

## Timeline of Events

| Time (UTC) | Event |
|------------|-------|
| 18:19:47 | Workflow triggered by push to main branch |
| 18:19:50 | Apply Changesets job started |
| 18:19:55 | Apply Changesets job completed successfully |
| 18:20:00 | Multiple parallel jobs started (JS build, essentials build, languages build) |
| 18:36:04 | `docker-build-push` job started (depends on language builds) |
| 18:36:08 | Repository checkout completed |
| 18:36:14 | Docker Buildx setup completed |
| 18:36:15 | Login to GHCR and Docker Hub succeeded |
| 18:36:17 | Metadata extraction completed |
| 18:38:51 | **Job failed** due to "No space left on device" |

## Root Cause Analysis

### Primary Cause: Disk Space Exhaustion

The GitHub Actions runner ran out of disk space during the Docker build and push operation. This is a common issue for workflows that:

1. Build large Docker images with multiple layers
2. Run multiple parallel builds in a single workflow
3. Don't clean up disk space before starting builds

### Contributing Factors

1. **Multiple Large Images Built in Single Workflow**
   - The workflow builds multiple Docker images in parallel:
     - JS box (2 architectures)
     - Essentials box (2 architectures)
     - 11 language boxes (2 architectures each = 22 builds)
     - Full box (2 architectures)
   - Total: ~30+ Docker image builds

2. **Cumulative Resource Consumption**
   - Each parallel job on ubuntu-24.04 starts with ~22 GB free disk space
   - Docker layer caching and image storage consume significant disk space
   - BuildKit cache grows with each build

3. **No Pre-Build Disk Space Cleanup**
   - The workflow does not perform disk space cleanup before builds
   - Default runner includes pre-installed tools that consume ~30 GB:
     - Android SDK/NDK: ~14 GB
     - .NET runtime: ~2.7 GB
     - Large packages: ~5.3 GB
     - Tool cache: ~5.9 GB

4. **BuildKit Worker Diagnostic Logs**
   - The specific error occurred when writing worker diagnostic logs
   - This indicates the disk was completely full, not just low

## Impact Assessment

- **Failed Release**: Version 1.3.1 Docker images were not published
- **Partial Success**: Earlier jobs (JS, essentials, some language boxes) completed successfully
- **No Data Loss**: The failure was recoverable; no permanent damage occurred

## Proposed Solutions

### Solution 1: Add Disk Space Cleanup Action (Recommended)

Add the `jlumbroso/free-disk-space` action at the beginning of jobs that build Docker images.

```yaml
- name: Free Disk Space
  uses: jlumbroso/free-disk-space@main
  with:
    tool-cache: false  # Keep tool cache for compatibility
    android: true      # Free ~14 GB
    dotnet: true       # Free ~2.7 GB
    haskell: true      # Free ~0 GB (not pre-installed on ubuntu-24.04)
    large-packages: true  # Free ~5.3 GB
    docker-images: true   # Clean existing Docker images
    swap-storage: true    # Free ~4 GB
```

**Pros:**
- Can free up to 31 GB of disk space
- Well-maintained, popular action
- Configurable options

**Cons:**
- Adds ~3 minutes to job execution time
- May need to keep `tool-cache: false` to avoid breaking setup-* actions

### Solution 2: Use Docker Layer Caching Optimization

Optimize Docker builds to use layer caching more efficiently:

```yaml
- name: Build and push
  uses: docker/build-push-action@v5
  with:
    cache-from: type=gha,scope=build-${{ matrix.language }}
    cache-to: type=gha,mode=min  # Use 'min' instead of 'max' to reduce cache size
```

**Pros:**
- Reduces disk space used by build cache
- May speed up subsequent builds

**Cons:**
- May slow down builds if cache hits are reduced

### Solution 3: Split Workflow into Multiple Workflows

Split the monolithic workflow into separate workflows per image type:

1. `release-js.yml` - JS box only
2. `release-essentials.yml` - Essentials box only
3. `release-languages.yml` - Language boxes
4. `release-full.yml` - Full box (triggered after others)

**Pros:**
- Each workflow gets fresh disk space
- Easier to identify which image failed
- Can retry individual image builds

**Cons:**
- More complex workflow orchestration
- Harder to maintain consistency

### Solution 4: Periodic Docker System Prune

Add Docker cleanup steps between build stages:

```yaml
- name: Clean up Docker
  run: |
    docker system prune -af --volumes
    docker builder prune -af
```

**Pros:**
- Frees space used by intermediate images
- Simple to implement

**Cons:**
- May invalidate build caches
- Adds time to workflow

## Recommended Implementation

Implement **Solution 1** (Free Disk Space Action) as the primary fix, with **Solution 4** (Docker System Prune) as a complementary measure for the `docker-build-push` job.

### Implementation Steps

1. Add disk space cleanup to the `docker-build-push` job
2. Add docker system prune before the full box build
3. Test with a manual workflow_dispatch run
4. Monitor disk usage in future runs

## References

### Error Details
- **Run URL**: https://github.com/link-foundation/box/actions/runs/21997899227
- **Failed Job**: https://github.com/link-foundation/box/actions/runs/21997899227/job/63564368345
- **Error**: `System.IO.IOException: No space left on device`

### Related GitHub Issues
- [GitHub Community Discussion #25678](https://github.com/orgs/community/discussions/25678) - No space left on device
- [actions/runner-images#2875](https://github.com/actions/runner-images/issues/2875) - GitHub Actions fails with "no space left on device"
- [actions/runner-images#9344](https://github.com/actions/runner-images/issues/9344) - No space left on device regression on ubuntu-latest

### Solutions
- [jlumbroso/free-disk-space](https://github.com/jlumbroso/free-disk-space) - GitHub Action to free disk space
- [insightsengineering/disk-space-reclaimer](https://github.com/insightsengineering/disk-space-reclaimer) - Alternative disk space action
- [Mastering Disk Space on GitHub Actions Runners](https://www.geraldonit.com/mastering-disk-space-on-github-actions-runners-a-deep-dive-into-cleanup-strategies-for-x64-and-arm64-runners/) - Comprehensive guide

## Logs and Artifacts

- [Full workflow run logs](./logs/run-21997899227.log)
- [Failed job logs](./logs/job-docker-build-push-63564368345.log)

## Revision History

| Date | Author | Description |
|------|--------|-------------|
| 2026-02-13 | AI Analysis | Initial case study created |
