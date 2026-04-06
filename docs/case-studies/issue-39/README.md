# Case Study: Issue #39 - Multi-arch Docker Tag Documentation Gap

## Summary

**Issue**: [#39](https://github.com/link-foundation/box/issues/39) - Make sure all docker versions support multi-arch, arm64 only, and amd64 only

**Root Cause**: Documentation gap in release notes template - architecture-specific tags exist on Docker Hub but are not documented in the GitHub release notes.

## Timeline of Events

| Date | Event |
|------|-------|
| 2026-02-01 | v1.3.0 release published |
| 2026-02-01 | All Docker images built with architecture-specific tags (`-amd64`, `-arm64`) |
| 2026-02-02 | Release notes published mentioning only multi-arch for most images |
| 2026-02-13 | Issue #39 reported identifying the documentation gap |

## Investigation Findings

### Docker Hub Tag Verification

All box images actually have architecture-specific tags available:

| Image | Available Tags |
|-------|---------------|
| `konard/box` | `1.3.0`, `1.3.0-amd64`, `1.3.0-arm64`, `latest`, `latest-amd64`, `latest-arm64` |
| `konard/box-essentials` | `1.3.0`, `1.3.0-amd64`, `1.3.0-arm64`, `latest`, `latest-amd64`, `latest-arm64` |
| `konard/box-js` | `1.3.0`, `1.3.0-amd64`, `1.3.0-arm64`, `latest`, `latest-amd64`, `latest-arm64` |
| `konard/box-python` | `1.3.0`, `1.3.0-amd64`, `1.3.0-arm64`, `latest`, `latest-amd64`, `latest-arm64` |
| `konard/box-go` | `1.3.0`, `1.3.0-amd64`, `1.3.0-arm64`, `latest`, `latest-amd64`, `latest-arm64` |
| `konard/box-rust` | `1.3.0`, `1.3.0-amd64`, `1.3.0-arm64`, `latest`, `latest-amd64`, `latest-arm64` |
| (all other languages) | Same pattern: multi-arch + amd64 + arm64 tags |

### Release Notes Analysis

The release notes template in `.github/workflows/release.yml` (lines 1610-1692) shows:

**Full Box Section (correct)**:
```
- konard/box:${VERSION} (multi-arch)
- konard/box:${VERSION}-amd64 (AMD64)
- konard/box:${VERSION}-arm64 (ARM64)
```

**Essentials/JS/Language Boxes (incomplete)**:
```
- konard/box-essentials:${VERSION} (multi-arch)
- konard/box-js:${VERSION} (multi-arch)
- konard/box-python:${VERSION} (multi-arch)
... etc
```

## Root Cause

The release notes template was written to only document full box architecture variants in detail. When modular language boxes were added in v1.3.0, the workflow correctly builds and pushes architecture-specific tags for all images, but the release notes generation only mentions "(multi-arch)" for the new images.

This is a **documentation-only issue** - the actual Docker images are correctly built and available.

## Solution

Update the release notes template in `.github/workflows/release.yml` to document all available tags for each image:

1. Add `-amd64` and `-arm64` tag documentation for essentials box
2. Add `-amd64` and `-arm64` tag documentation for JS box
3. Add `-amd64` and `-arm64` tag documentation for all language boxes

## Verification Commands

```bash
# Verify tags exist for any image
docker manifest inspect konard/box-python:1.3.0-amd64
docker manifest inspect konard/box-python:1.3.0-arm64

# Pull specific architecture
docker pull --platform linux/amd64 konard/box-python:1.3.0-amd64
docker pull --platform linux/arm64 konard/box-python:1.3.0-arm64
```

## References

- Docker Hub API: `https://hub.docker.com/v2/repositories/konard/<image>/tags`
- GitHub workflow: `.github/workflows/release.yml`
- Release v1.3.0: https://github.com/link-foundation/box/releases/tag/v1.3.0
