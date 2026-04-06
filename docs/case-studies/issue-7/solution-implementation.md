# Solution Implementation Guide

This document provides step-by-step implementation instructions for fixing the ARM64 build timeout issue.

## Recommended Solution: Use Native ARM64 Runners

### Step 1: Update Workflow File

Modify `.github/workflows/release.yml`:

```yaml
# Change this job configuration:

docker-build-push-arm64:
  runs-on: ubuntu-24.04-arm  # Changed from: ubuntu-latest
  needs: [detect-changes, docker-build-push]
  if: github.event_name == 'push' && github.ref == 'refs/heads/main' && needs.detect-changes.outputs.should-build == 'true'
  permissions:
    contents: read
    packages: write

  steps:
    - name: Checkout repository
      uses: actions/checkout@v4

    # Note: Emulation setup is NOT needed for native ARM64 runner
    # Remove any emulation setup step as it's not needed

    - name: Set up Docker Buildx
      uses: docker/setup-buildx-action@v3

    - name: Log in to GitHub Container Registry
      uses: docker/login-action@v3
      with:
        registry: ${{ env.REGISTRY }}
        username: ${{ github.actor }}
        password: ${{ secrets.GITHUB_TOKEN }}

    - name: Extract metadata (tags, labels) for Docker
      id: meta
      uses: docker/metadata-action@v5
      with:
        images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
        flavor: |
          suffix=-arm64
        tags: |
          type=raw,value=latest
          type=sha,prefix=
          type=raw,value={{date 'YYYYMMDD'}}

    - name: Build and push Docker image (arm64)
      uses: docker/build-push-action@v5
      with:
        context: .
        platforms: linux/arm64
        push: true
        tags: ${{ steps.meta.outputs.tags }}
        labels: ${{ steps.meta.outputs.labels }}
        cache-from: type=gha
        cache-to: type=gha,mode=max
```

### Step 2: Add Workflow Timeout (Safety Net)

Add a timeout to prevent indefinitely running builds:

```yaml
docker-build-push-arm64:
  runs-on: ubuntu-24.04-arm
  timeout-minutes: 120  # 2 hours max - should be plenty with native runner
```

### Step 3: Improve Caching (Optional Enhancement)

Consider using registry-based caching for better cross-run cache hits:

```yaml
- name: Build and push Docker image (arm64)
  uses: docker/build-push-action@v5
  with:
    context: .
    platforms: linux/arm64
    push: true
    tags: ${{ steps.meta.outputs.tags }}
    labels: ${{ steps.meta.outputs.labels }}
    # Registry-based caching (persists longer than GHA cache)
    cache-from: |
      type=registry,ref=ghcr.io/link-foundation/box:buildcache-arm64
      type=gha
    cache-to: |
      type=registry,ref=ghcr.io/link-foundation/box:buildcache-arm64,mode=max
      type=gha,mode=max
```

## Complete Updated Workflow

Here's the complete updated ARM64 job:

```yaml
# === BUILD AND PUSH ARM64 IMAGE (Native ARM64 Runner) ===
docker-build-push-arm64:
  runs-on: ubuntu-24.04-arm  # Native ARM64 runner (free for public repos)
  timeout-minutes: 120       # Safety timeout
  needs: [detect-changes, docker-build-push]
  if: github.event_name == 'push' && github.ref == 'refs/heads/main' && needs.detect-changes.outputs.should-build == 'true'
  permissions:
    contents: read
    packages: write

  steps:
    - name: Checkout repository
      uses: actions/checkout@v4

    # Emulation is not needed on native ARM64 runner

    - name: Set up Docker Buildx
      uses: docker/setup-buildx-action@v3

    - name: Log in to GitHub Container Registry
      uses: docker/login-action@v3
      with:
        registry: ${{ env.REGISTRY }}
        username: ${{ github.actor }}
        password: ${{ secrets.GITHUB_TOKEN }}

    - name: Extract metadata (tags, labels) for Docker
      id: meta
      uses: docker/metadata-action@v5
      with:
        images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
        flavor: |
          suffix=-arm64
        tags: |
          type=raw,value=latest
          type=sha,prefix=
          type=raw,value={{date 'YYYYMMDD'}}

    - name: Build and push Docker image (arm64)
      uses: docker/build-push-action@v5
      with:
        context: .
        platforms: linux/arm64
        push: true
        tags: ${{ steps.meta.outputs.tags }}
        labels: ${{ steps.meta.outputs.labels }}
        cache-from: type=gha
        cache-to: type=gha,mode=max
```

## Verification Steps

After implementing the solution:

1. **Trigger a workflow run**
   ```bash
   # Via workflow dispatch or push to main
   gh workflow run release.yml --repo link-foundation/box
   ```

2. **Monitor the ARM64 build**
   ```bash
   gh run watch --repo link-foundation/box
   ```

3. **Expected results:**
   - ARM64 job should run on `ubuntu-24.04-arm` runner
   - Build time should be 30-60 minutes instead of 6+ hours
   - No timeout or cancellation

4. **Verify the runner type in logs**
   Look for:
   ```
   Operating System
   Ubuntu
   24.04
   ARM64
   ```

## Rollback Plan

If the native ARM64 runner has issues:

1. Revert to the original `ubuntu-latest` runner
2. Add emulation setup step back if needed
3. Consider alternative solutions:
   - Remove heavy dependencies (PHP, Rocq)
   - Use pre-built base image

## References

- [GitHub: Linux arm64 hosted runners for free](https://github.blog/changelog/2025-01-16-linux-arm64-hosted-runners-now-available-for-free-in-public-repositories-public-preview/)
- [GitHub: Using GitHub-hosted runners](https://docs.github.com/en/actions/using-github-hosted-runners/using-github-hosted-runners/about-github-hosted-runners)
- [Docker: Build multi-platform images](https://docs.docker.com/build/building/multi-platform/)
