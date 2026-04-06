# Data Collection for Issue #44

## GitHub Actions Runs Analyzed

### Slow Build (Issue Case)
- **Run ID**: 22109801787
- **URL**: https://github.com/link-foundation/box/actions/runs/22109801787
- **Job ID (PHP AMD64)**: 63903035885
- **Job URL**: https://github.com/link-foundation/box/actions/runs/22109801787/job/63903035885
- **Status**: In Progress (stuck)
- **Started**: 2026-02-17T18:04:44Z
- **Duration**: 2+ hours (ongoing)

### Fast Build (Reference)
- **Run ID**: 22002755482
- **URL**: https://github.com/link-foundation/box/actions/runs/22002755482
- **Job ID (PHP AMD64)**: 63579321456
- **Status**: Completed (success)
- **Started**: 2026-02-13T21:05:16Z
- **Completed**: 2026-02-13T21:05:45Z
- **Duration**: 29 seconds
- **Cache Status**: All layers CACHED

## Files Collected

| File | Description | Source |
|------|-------------|--------|
| `php-amd64-fast-build.log` | Fast build CI logs | Run 22002755482, Job 63579321456 |

## Commands Used for Data Collection

```bash
# View run overview
gh run view 22109801787 --repo link-foundation/box

# Get job details
gh run view 22109801787 --repo link-foundation/box --job 63903035885

# Download logs from completed run
gh run view 22002755482 --repo link-foundation/box --job 63579321456 --log

# List jobs with status
gh api repos/link-foundation/box/actions/runs/22109801787/jobs --paginate

# Get PHP formula details
gh api repos/shivammathur/homebrew-php/contents/Formula/php@8.3.rb
```

## Key Observations from Logs

### Fast Build (CACHED)
```
#7 importing cache manifest from gha:13033070811435074587
#8 CACHED
#9 CACHED
#10 CACHED
#11 CACHED
#12 CACHED
```

### Build Comparison

| Metric | Fast Build | Slow Build |
|--------|-----------|------------|
| Cache Import | Success | Unknown |
| Layer #8 | CACHED | Building |
| Layer #9 | CACHED | Building |
| Homebrew Install | Skipped (cached) | From source |
| Total Duration | 29s | 2+ hours |

## External Data Sources

### Homebrew PHP Formula
- Repository: https://github.com/shivammathur/homebrew-php
- Formula: `Formula/php@8.3.rb`
- Bottles available for `x86_64_linux`: Yes

### GitHub Actions Runner Issues
- Issue #11790: https://github.com/actions/runner-images/issues/11790
- Issue #11841: https://github.com/actions/runner-images/issues/11841
- Status: Ubuntu 24.04 performance issues documented

### Homebrew Documentation
- Bottles: https://docs.brew.sh/Bottles
- Support Tiers: https://docs.brew.sh/Support-Tiers
- Linux Requirements: https://docs.brew.sh/Homebrew-on-Linux

## Repository Files Analyzed

| File | Purpose |
|------|---------|
| `ubuntu/24.04/php/Dockerfile` | PHP Docker image definition |
| `ubuntu/24.04/php/install.sh` | PHP installation script |
| `.github/workflows/release.yml` | CI/CD workflow definition |
| `ubuntu/24.04/essentials-box/Dockerfile` | Base image definition |
| `ubuntu/24.04/js/Dockerfile` | JS base image (uses ubuntu:24.04) |

---

*Data collected: 2026-02-17*
