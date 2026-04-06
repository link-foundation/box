# Case Study: PHP Docker Image Build Takes 2+ Hours

**Issue**: [#44 - Why PHP image is built for more than 2 hours?](https://github.com/link-foundation/box/issues/44)
**Date**: 2026-02-17
**Status**: Investigation Complete

## Executive Summary

The PHP Docker image build (`box-php`) on x86_64/AMD64 architecture took over 2 hours, while the same build on ARM64 completed in ~7.5 minutes. The root cause is Homebrew falling back to compiling PHP from source when Docker build cache is invalidated and pre-built bottles cannot be used.

## Timeline of Events

| Time (UTC) | Event |
|------------|-------|
| 2026-02-17 18:01:13 | Workflow run #22109801787 started |
| 2026-02-17 18:04:43 | `build-languages-amd64 (php)` job started |
| 2026-02-17 18:05:59 | `build-languages-arm64 (php)` job started |
| 2026-02-17 18:13:35 | `build-languages-arm64 (php)` completed (7m 36s) |
| 2026-02-17 20:18:00+ | `build-languages-amd64 (php)` still running (2+ hours) |

### Comparison with Previous Successful Builds

| Run ID | Date | AMD64 Duration | ARM64 Duration | Notes |
|--------|------|----------------|----------------|-------|
| 22002755482 | 2026-02-13 | ~29s | ~35s | Cache hit - all layers CACHED |
| 22109801787 | 2026-02-17 | 2+ hours | 7m 36s | Cache miss - building from source |

## Root Cause Analysis

### Primary Cause: Homebrew Building PHP From Source

When Docker build cache is invalidated, the PHP installation via Homebrew (`brew install shivammathur/php/php@8.3`) must execute from scratch. Despite the shivammathur/homebrew-php tap providing pre-built bottles for `x86_64_linux`, Homebrew fell back to building from source.

**Evidence:**
1. ARM64 build completed in 7.5 minutes with bottles
2. AMD64 build stuck for 2+ hours (typical PHP compilation time)
3. Previous builds with cache completed in 30 seconds

### Why Bottles May Not Be Used

1. **CELLAR Path Mismatch**: Homebrew bottles require the `cellar` path to match. The Docker container's Homebrew installation path may differ from where bottles were built.

2. **glibc/Library Differences**: Ubuntu 24.04 Docker image may have different library versions than the GitHub Actions runners where bottles are built.

3. **Homebrew Version Differences**: If Homebrew updates between builds, bottle checksums may not match.

### Secondary Factors

1. **Ubuntu 24.04 Runner Issues**: Known performance degradation on Ubuntu 24.04 GitHub Actions runners ([Issue #11790](https://github.com/actions/runner-images/issues/11790), [Issue #11841](https://github.com/actions/runner-images/issues/11841))

2. **Docker Buildx Cache**: GitHub Actions cache (`type=gha,scope=php-amd64`) may have expired or been evicted

## Technical Details

### Current PHP Installation Method

```dockerfile
# ubuntu/24.04/php/Dockerfile
FROM ${ESSENTIALS_IMAGE}

USER box
COPY ubuntu/24.04/php/install.sh /tmp/install.sh
RUN bash /tmp/install.sh
```

```bash
# ubuntu/24.04/php/install.sh
brew tap shivammathur/php
brew install shivammathur/php/php@8.3  # <-- This compiles from source if no bottle
```

### PHP Source Compilation Time Breakdown (Estimated)

| Phase | Duration |
|-------|----------|
| Configure | 5-10 min |
| Make (all cores) | 60-90 min |
| Make install | 5-10 min |
| Dependencies | 20-30 min |
| **Total** | **90-140 min** |

## Solutions

### Solution 1: Use Pre-built PHP Docker Images (Recommended)

shivammathur provides pre-built PHP Docker images at `ghcr.io/shivammathur/php/php`.

**Advantages:**
- Instant installation (just `COPY --from`)
- No compilation time
- Consistent behavior across architectures
- Maintained by the same author as homebrew-php

**Implementation:**
```dockerfile
FROM ghcr.io/shivammathur/php/php:8.3 AS php-source

FROM ${ESSENTIALS_IMAGE}
COPY --from=php-source /home/linuxbrew/.linuxbrew /home/linuxbrew/.linuxbrew
```

### Solution 2: Use Ubuntu's Native PHP Package

Install PHP from Ubuntu repositories instead of Homebrew.

**Advantages:**
- Uses apt with fast binary packages
- Native integration with Ubuntu
- Quick installation (~30 seconds)

**Disadvantages:**
- Version tied to Ubuntu release
- May not have latest PHP version

**Implementation:**
```bash
# In install.sh
sudo apt-get install -y php8.3-cli php8.3-common
```

### Solution 3: Improve Cache Reliability

Ensure Docker build cache is preserved across runs.

**Actions:**
1. Pin specific base image versions
2. Use content-based cache keys
3. Consider GitHub Container Registry cache

### Solution 4: Add Timeout and Fallback

Add a timeout to the PHP build step with fallback to alternative installation method.

**Implementation:**
```yaml
- name: Build PHP box
  timeout-minutes: 15  # Fail fast if bottles unavailable
  continue-on-error: true

- name: Fallback PHP installation
  if: failure()
  run: # Use alternative method
```

## Recommendations

### Immediate Actions

1. **Cancel the stuck build** - Run 22109801787 should be cancelled to free resources
2. **Re-run with cache** - Trigger a new build to leverage any restored cache

### Short-term (This Sprint)

1. **Implement Solution 1** - Use pre-built PHP Docker images from shivammathur
2. **Add build timeout** - Prevent 2+ hour stuck builds

### Long-term

1. **Create GitHub Issue** - Report bottle compatibility issue to shivammathur/homebrew-php
2. **Evaluate alternatives** - Consider using official PHP Docker images or apt packages
3. **Improve CI resilience** - Add fallback mechanisms for slow builds

## References

### External Links

1. [Homebrew Support Tiers](https://docs.brew.sh/Support-Tiers) - Linux requirements
2. [shivammathur/homebrew-php](https://github.com/shivammathur/homebrew-php) - PHP Homebrew tap
3. [Ubuntu 24.04 CI Performance Issues](https://github.com/actions/runner-images/issues/11790) - GitHub Actions
4. [Homebrew Bottles Documentation](https://docs.brew.sh/Bottles)

### Internal Logs

- Fast build logs: `/ci-logs/php-amd64-fast-build.log`
- Stuck build job: `gh run view 22109801787 --repo link-foundation/box --job 63903035885`

## Appendix

### Homebrew PHP Bottle Availability

From `shivammathur/homebrew-php/Formula/php@8.3.rb`:

```ruby
bottle do
  sha256 arm64_tahoe:   "a20e0951..."
  sha256 arm64_sequoia: "21fa8cb3..."
  sha256 arm64_sonoma:  "800e544b..."
  sha256 sonoma:        "5f5e4ab8..."
  sha256 arm64_linux:   "6b7e952d..."
  sha256 x86_64_linux:  "774b27c3..."  # <-- Bottle exists!
end
```

### Environment Comparison

| Factor | Previous (Working) | Current (Stuck) |
|--------|-------------------|-----------------|
| Docker Cache | Hit (CACHED) | Miss |
| Build Method | Cached layers | From source |
| Duration | ~30 seconds | 2+ hours |
| Homebrew Bottles | Used | Not used |

## Solution: Tiered Installation with Timeout and Fallback

### Approach (Implemented 2026-02-21)

Rather than completely replacing Homebrew with apt, the solution preserves user-specific (Homebrew) installation as the preferred method with apt as a fallback:

1. **Homebrew first (user-specific/local)**: Try installing PHP via Homebrew as the box user
   - Uses a configurable timeout (default: 30 minutes)
   - If bottles are available, completes in seconds
   - If source compilation starts and exceeds timeout, fails gracefully

2. **apt fallback (global)**: If Homebrew fails or times out, install via apt packages
   - Always fast (~30 seconds)
   - Installs to `/usr/bin` (system-wide)

3. **Marker file**: `~/.php-install-method` records `local` or `global`
   - Used by full-box to determine merge strategy
   - Local: `COPY --from` the Homebrew directory
   - Global: Install PHP via apt in full-box

4. **Tagging**: PHP images get `-local` or `-global` suffix tags
   - `box-php:latest-amd64` (always exists)
   - `box-php:latest-amd64-local` (only if Homebrew succeeded)
   - `box-php:latest-amd64-global` (only if apt fallback used)

### Timeout Calculation

Based on previous successful builds:
- Cache hit: ~30 seconds
- ARM64 with bottles: ~7.5 minutes
- AMD64 source compilation: 2+ hours

A 30-minute timeout allows ample time for bottle downloads and minor compilation,
while catching full source compilations early.

---

*Case study compiled: 2026-02-17, updated: 2026-02-21*
*Investigation by: AI Issue Solver*
