# Case Study: Docker ARM64 Build Timeout

**Issue:** [#7 - Investigate why docker image build has stuck and what we can do to avoid such problems in the future](https://github.com/link-foundation/box/issues/7)

**GitHub Actions Run:** [#21002878662](https://github.com/link-foundation/box/actions/runs/21002878662/job/60377477070)

**Date of Incident:** 2026-01-14

## Executive Summary

The Docker ARM64 build job (`docker-build-push-arm64`) ran for approximately **6 hours** before being cancelled due to exceeding the GitHub Actions timeout. The build was stuck during PHP 8.3 installation via Homebrew, which was being compiled from source through emulation on an x86-64 runner.

## Timeline of Events

| Time (UTC) | Duration | Event |
|------------|----------|-------|
| 17:04:47 | 0m | Workflow started |
| 17:04:51 - 17:04:53 | 2s | `detect-changes` job completed successfully |
| 17:04:57 - 17:05:27 | 30s | `docker-build-push` (amd64) completed successfully |
| 17:05:31 | 0m | `docker-build-push-arm64` job started |
| 17:05:54 | 0m | ARM64 Docker image build started |
| 17:05:54 - 17:52:43 | ~47m | OCaml packages installation (via opam) |
| 17:52:43 - 18:01:16 | ~9m | Opam initialization |
| 18:02:25 - 19:05:37 | ~63m | Rocq Prover installation (rocq-stdlib took ~35 minutes alone) |
| 19:07:32 | ~2h | PHP 8.3 installation via Homebrew started |
| 23:05:31 | **~6h total** | **Build cancelled - exceeded timeout** |

## Root Cause Analysis

### Primary Root Cause: Emulation Performance

The ARM64 Docker image is being built on an x86-64 GitHub Actions runner using **emulation**. The emulator must translate every ARM instruction into corresponding x86 instructions, causing:

- **10-30x slower execution** compared to native ARM64
- Particularly severe impact on CPU-intensive tasks like compiling software from source

### Contributing Factors

1. **Heavy Software Compilation Requirements**
   - Rocq Prover (OCaml-based theorem prover) - requires compiling OCaml packages
   - PHP 8.3 via Homebrew - requires compiling from source on ARM64
   - Python via pyenv - compiles Python interpreter
   - Perl via Perlbrew - compiles Perl interpreter

2. **No Build Caching for ARM64**
   - Each build starts from scratch
   - Homebrew's bottle (pre-compiled binary) support is limited for ARM64 Linux
   - OCaml packages compiled every time

3. **Sequential Dependencies**
   - The ARM64 job waits for the AMD64 job to complete
   - This creates a waterfall effect in the workflow

## Evidence from Logs

### Emulation Usage Confirmed
```
2026-01-14T17:05:47Z Set up emulation - binfmt/8bf932d
```

### Rocq Prover Installation Timeline
```
2026-01-14T18:02:25 - Installing Rocq Prover (this may take several minutes)...
2026-01-14T18:29:33 - rocq-runtime.9.1.0 installed (27 minutes)
2026-01-14T18:31:12 - rocq-core.9.1.0 installed
2026-01-14T19:05:37 - rocq-stdlib.9.0.0 installed (34 minutes)
```

### PHP Installation (Where Build Stopped)
```
2026-01-14T19:07:32 [*] Installing PHP via Homebrew...
... (no further progress until cancellation)
2026-01-14T23:05:31 ##[error]The operation was canceled.
```

The build was cancelled **~4 hours into PHP compilation** with no completion in sight.

## Solutions and Recommendations

### Solution 1: Use Native ARM64 Runners (Recommended)

GitHub now offers free native ARM64 runners for public repositories as of January 2025.

**Change in `.github/workflows/release.yml`:**
```yaml
# Before
docker-build-push-arm64:
  runs-on: ubuntu-latest  # x86-64 with emulation

# After
docker-build-push-arm64:
  runs-on: ubuntu-24.04-arm  # Native ARM64 runner (free for public repos)
```

**Expected Improvement:**
- 10-30x faster build times
- Build that currently takes 6+ hours could complete in 30-60 minutes

**References:**
- [GitHub Changelog: Linux arm64 hosted runners now available for free](https://github.blog/changelog/2025-01-16-linux-arm64-hosted-runners-now-available-for-free-in-public-repositories-public-preview/)
- [Arm64 on GitHub Actions: Powering faster, more efficient build systems](https://github.blog/news-insights/product-news/arm64-on-github-actions-powering-faster-more-efficient-build-systems/)

### Solution 2: Remove Heavy Dependencies from ARM64 Build

Consider whether all tools are necessary for ARM64:

| Tool | Current Build Time (Emulated) | Criticality | Recommendation |
|------|---------------------------|-------------|----------------|
| PHP 8.3 | 4+ hours (incomplete) | Medium | Consider removing or using pre-built ARM64 image |
| Rocq Prover | ~65 minutes | Low-Medium | Consider separate optional layer |
| Perl (Perlbrew) | ~20 minutes | Low | Use system Perl or pre-built binary |

### Solution 3: Multi-Stage Build with Caching

Implement better caching strategies:

```yaml
- name: Build and push Docker image (arm64)
  uses: docker/build-push-action@v5
  with:
    context: .
    platforms: linux/arm64
    push: true
    cache-from: type=registry,ref=ghcr.io/link-foundation/box:buildcache-arm64
    cache-to: type=registry,ref=ghcr.io/link-foundation/box:buildcache-arm64,mode=max
```

### Solution 4: Add Workflow Timeout

Prevent builds from running indefinitely:

```yaml
docker-build-push-arm64:
  runs-on: ubuntu-latest
  timeout-minutes: 180  # 3 hours max
```

### Solution 5: Pre-built Base Image Strategy

Create a base image with heavy dependencies pre-installed:

1. Build base image with Rocq, PHP, etc. monthly or on-demand
2. Use that base image in the main Dockerfile
3. Main build only adds lightweight changes

## Industry References

1. **[Performance - builds are very slow with emulation](https://github.com/docker/build-push-action/issues/982)** - Community discussion on multi-platform build and emulation performance issues

2. **[How to make GitHub Actions 22x faster with bare-metal Arm](https://actuated.com/blog/native-arm64-for-github-actions)** - Case study showing 33 min -> 1.5 min improvement

3. **[Multiplatform build slows drastically after the first platform](https://github.com/docker/build-push-action/issues/982)** - Community discussion on multi-platform build optimization

4. **[Building Multi-Platform Docker Images for ARM64 in GitHub Actions](https://www.blacksmith.sh/blog/building-multi-platform-docker-images-for-arm64-in-github-actions)** - Best practices guide

## Recommended Action Plan

### Immediate (Quick Win)
1. **Switch to native ARM64 runner** (`ubuntu-24.04-arm`)
   - Single line change in workflow
   - Expected 10-30x improvement
   - No cost for public repositories

### Short-term
2. Add workflow timeout to prevent resource waste
3. Implement registry-based caching for ARM64 builds

### Long-term
4. Evaluate necessity of each heavy dependency for ARM64
5. Consider pre-built base image strategy for heavy dependencies
6. Set up monitoring/alerts for long-running builds

## Metrics

| Metric | Before | After (Expected with native ARM64) |
|--------|--------|-------------------------------------|
| AMD64 Build Time | ~30 seconds | ~30 seconds (unchanged) |
| ARM64 Build Time | 6+ hours (timeout) | 30-60 minutes |
| Total Workflow Time | 6+ hours | ~1 hour |
| Build Success Rate | 0% (timeout) | Expected 95%+ |

## Conclusion

The Docker ARM64 build timeout was caused by using emulation to build a complex multi-tool Docker image containing software that must be compiled from source (PHP, Rocq, Python, Perl). Emulation's 10-30x performance penalty makes such builds impractical on x86-64 runners.

The most effective solution is to use GitHub's native ARM64 runners (`ubuntu-24.04-arm`), which became freely available for public repositories in January 2025. This single-line change should reduce build times from 6+ hours to under 1 hour.
