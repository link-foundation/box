# Case Study: Issue #39 - Multi-arch Docker Image Tags in Release Notes

## Summary

This case study documents the investigation and resolution of GitHub issue #39, which identified incomplete documentation of Docker image tags in release notes. The release notes were not providing clickable links for all architecture-specific tags, making it difficult for users to find and pull specific architecture images from both Docker Hub and GitHub Container Registry (GHCR).

## Timeline

| Date | Event |
|------|-------|
| 2026-02-01 | v1.3.0 released with limited architecture-specific tag documentation |
| 2026-02-13 | v1.3.2 released with improved but still incomplete tag documentation |
| 2026-02-15 | Issue #39 opened identifying the documentation gap |
| 2026-02-15 | Comment added clarifying requirement for comprehensive clickable links |

## Problem Analysis

### Original Issue

The release notes at [v1.3.0](https://github.com/link-foundation/box/releases/tag/v1.3.0) did not include:
- Architecture-specific tags (-amd64, -arm64) for language boxes
- Architecture-specific tags for essentials and JS boxes
- Separate GHCR listings with all architecture variants

### Partial Fix in v1.3.2

The [v1.3.2](https://github.com/link-foundation/box/releases/tag/v1.3.2) release improved documentation by:
- Adding architecture tags for Full Box, Essentials, and JS boxes
- Adding a table for language boxes with architecture columns

However, the table still had issues:
- Only the Multi-arch column had clickable links to Docker Hub
- AMD64 and ARM64 columns showed tag names without clickable links
- GHCR section only mentioned that images are "available" without clickable links for each variant

### User Requirement (from comment)

The user requested:
> "We need to have table for all images... for each tag we should have clickable link, and not only on Docker Hub, but also in GitHub Registry. So we should have at least 6 columns for each language version, or we can have 4 tables, so 2 of them are for language boxes, and 1 of these table will be dedicated to Docker Hub, and another for GitHub Registry, so in both table we will have 3 columns with clickable links."

## Root Cause

The release notes generation in `.github/workflows/release.yml` at the `create-release` job used a template that:

1. Created markdown tables without clickable links for architecture-specific tags
2. Only linked the multi-arch tag to Docker Hub for language boxes
3. Listed GHCR images in text format without individual clickable links for each architecture

## Solution

### Design Decision

After analyzing the options, we chose to use **4 separate tables** approach:
- 2 tables for Docker Hub (combo boxes + language boxes)
- 2 tables for GHCR (combo boxes + language boxes)

This provides better readability than cramming 6 columns into one table, especially on mobile devices.

### Implementation

Modified the release notes template in `.github/workflows/release.yml` to generate:

1. **Docker Hub Combo Boxes Table**: Full, Essentials, JS boxes with 3 clickable link columns
2. **Docker Hub Language Boxes Table**: All 11 languages with 3 clickable link columns
3. **GHCR Combo Boxes Table**: Full, Essentials, JS boxes with 3 clickable link columns
4. **GHCR Language Boxes Table**: All 11 languages with 3 clickable link columns

Each clickable link follows the pattern:
- Docker Hub: `https://hub.docker.com/r/konard/box-{lang}/tags?name={version}-{arch}`
- GHCR: `https://github.com/link-foundation/box/pkgs/container/box-{lang}?tag={version}-{arch}`

## Key Learnings

1. **User Experience**: Release notes should make it easy for users to directly access what they need. Clickable links are more valuable than plain text tags.

2. **Multi-registry Support**: Modern container distributions often publish to multiple registries (Docker Hub + GHCR). Documentation should equally serve users of both registries.

3. **Architecture Awareness**: With ARM64 adoption increasing (Apple Silicon, Raspberry Pi, AWS Graviton), architecture-specific documentation is increasingly important.

## Files Changed

- `.github/workflows/release.yml`: Updated `create-release` job to generate comprehensive tables with clickable links

## Testing

The release notes format can be validated by:
1. Running the workflow manually with `workflow_dispatch`
2. Checking that all generated links are valid and point to correct registry pages

## References

- [GitHub Issue #39](https://github.com/link-foundation/box/issues/39)
- [v1.3.0 Release](https://github.com/link-foundation/box/releases/tag/v1.3.0) - Original incomplete format
- [v1.3.2 Release](https://github.com/link-foundation/box/releases/tag/v1.3.2) - Partially improved format
- [Docker Hub box](https://hub.docker.com/r/konard/box)
- [GHCR box](https://github.com/link-foundation/box/pkgs/container/box)
