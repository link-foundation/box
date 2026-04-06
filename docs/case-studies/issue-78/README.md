# Case Study: Issue #78 - CI/CD Failed with GHCR 403 Forbidden on Docker Push

## Summary

The CI/CD release pipeline (GitHub Actions run [#24024582176](https://github.com/link-foundation/box/actions/runs/24024582176)) failed on April 6, 2026 when building and pushing Docker images to GitHub Container Registry (ghcr.io). Three out of eleven `build-languages-amd64` matrix jobs failed with `403 Forbidden` errors during the push phase, while all other jobs (including all arm64 builds and eight other amd64 builds) succeeded.

## Timeline of Events

| Time (UTC) | Event |
|---|---|
| 2026-04-05 | PR #77 merged: Rename everything from `sandbox` to `box` (version 2.0.0). Docker image names changed from `konard/sandbox-*` to `konard/box-*`, and GHCR names from `link-foundation/sandbox-*` to `link-foundation/box-*`. |
| 2026-04-06 08:19:36 | CI/CD release workflow triggered on `main` branch (commit `8353431`). |
| 2026-04-06 08:19:39 | Apply Changesets job completes successfully. |
| 2026-04-06 08:19:50 | detect-changes job identifies `VERSION_CHANGED=true`, triggering full rebuild of all images. |
| 2026-04-06 ~08:20-08:22 | `build-js-amd64` and `build-js-arm64` complete successfully - first-ever push to `box-js` packages on GHCR. |
| 2026-04-06 ~08:22-08:28 | `build-essentials-amd64` and `build-essentials-arm64` complete successfully - first-ever push to `box-essentials` packages. |
| 2026-04-06 08:28:42 | All `build-languages-amd64` and `build-languages-arm64` matrix jobs start. |
| 2026-04-06 08:29:55 | **`build-languages-amd64 (kotlin)` FAILS** with 403 Forbidden pushing to `ghcr.io/link-foundation/box-kotlin:2.0.0-amd64`. |
| 2026-04-06 08:31:46 | **`build-languages-amd64 (swift)` FAILS** with 403 Forbidden pushing to `ghcr.io/link-foundation/box-swift:2.0.0-amd64`. |
| 2026-04-06 08:32:10 | **`build-languages-amd64 (python)` FAILS** with 403 Forbidden pushing to `ghcr.io/link-foundation/box-python:2.0.0-amd64`. |
| 2026-04-06 08:30-08:33 | All `build-languages-arm64` jobs succeed, including kotlin, python, and swift. |
| 2026-04-06 08:30-08:31 | Other `build-languages-amd64` jobs (go, java, rust, ruby, php, perl, lean, rocq) all succeed. |

## Failed Jobs - Error Details

All three failures share the same error pattern:

```
ERROR: failed to build: failed to solve: failed to push ghcr.io/link-foundation/box-{language}:{version}-amd64:
unexpected status from HEAD request to https://ghcr.io/v2/link-foundation/box-{language}/blobs/sha256:{hash}: 403 Forbidden
```

Each failure had a **different blob SHA**, ruling out a shared-layer issue:
- **kotlin**: `sha256:31e5c778549155610fd5c26dd3589f79c524ed47195fea0658630fbd72ed3ce0`
- **python**: `sha256:9c09dd8e153f5a85595ac2d89d18c9ec426b7a2786868c3e51866433123ae9fe`
- **swift**: `sha256:202e76296c60393df1af5dfd6c523e58fe45b51ed0af6f4fca770737b1773b8b`

### Key Observations

1. **Login succeeded**: All jobs logged `Login Succeeded!` for ghcr.io before the push.
2. **Packages: write permission was set**: GITHUB_TOKEN had `Contents: read`, `Metadata: read`, `Packages: write`.
3. **Build succeeded**: All Docker builds completed successfully (image export done).
4. **Auth token was obtained**: `[auth] link-foundation/box-{language}:pull,push token for ghcr.io` appeared in logs.
5. **Push failed**: The actual blob push via HEAD request returned 403.
6. **arm64 succeeded for the same packages**: The arm64 builds for kotlin, python, and swift all pushed successfully to the same package names.

## Root Cause Analysis

### Primary Root Cause: Transient GHCR 403 errors during first-time package creation

This was the **first time** the CI/CD pipeline attempted to push to `box-*` package names on ghcr.io. The previous successful release build (run #23774161484, March 31, 2026) pushed to `sandbox-*` packages under the old repository name `link-foundation/sandbox`.

When `docker buildx` pushes to a new package on ghcr.io for the first time, the package must be created on the registry side. This process is known to be subject to transient 403 Forbidden errors, especially when:

1. **Multiple concurrent pushes** target the same registry namespace
2. **Package creation has not fully propagated** across GHCR infrastructure
3. **Rate limiting** on new package creation during concurrent workflows

The fact that 8 out of 11 amd64 language builds succeeded (and all 11 arm64 builds succeeded) confirms the transient nature of this issue. There was no persistent permissions or configuration problem.

### Contributing Factor: No retry mechanism

The `docker/build-push-action@v5` step has no built-in retry logic. When a push fails, the entire job fails immediately without any attempt to retry, even though a simple retry would likely succeed (as demonstrated by the arm64 builds succeeding and manual re-runs resolving similar issues).

## Evidence

### Successful vs Failed amd64 builds (same workflow run)

| Language | amd64 | arm64 |
|---|---|---|
| python | FAILED (403) | SUCCESS |
| kotlin | FAILED (403) | SUCCESS |
| swift | FAILED (403) | SUCCESS |
| go | SUCCESS | SUCCESS |
| java | SUCCESS | SUCCESS |
| rust | SUCCESS | SUCCESS |
| ruby | SUCCESS | SUCCESS |
| php | SUCCESS | SUCCESS |
| perl | SUCCESS | SUCCESS |
| lean | SUCCESS | SUCCESS |
| rocq | SUCCESS | SUCCESS |

### Known Issue in docker/build-push-action

This is a well-documented issue in the Docker ecosystem:
- [docker/build-push-action#463](https://github.com/docker/build-push-action/issues/463) - "Random 403 errors when pushing to GHCR"
- [docker/build-push-action#981](https://github.com/docker/build-push-action/issues/981) - "Can't push to ghcr 403: unexpected status from HEAD request"
- [docker/build-push-action#687](https://github.com/docker/build-push-action/issues/687) - "raise ghcr unexpected status: 403 Forbidden when push ghcr image"
- [nextstrain/docker-base#131](https://github.com/nextstrain/docker-base/issues/131) - "Transient 403 Forbidden errors when pushing to ghcr.io"
- [GitHub Community Discussion #26274](https://github.com/orgs/community/discussions/26274) - "Unable to push to ghcr.io from Github Actions"

## Solution

### Implemented Fix: Retry logic for docker push

Split the `docker/build-push-action` steps into two phases:
1. **Build and load** the image locally (no push)
2. **Push with retry** using `docker push` with a retry loop (up to 3 attempts with exponential backoff)

This approach:
- Avoids rebuilding the image on retry (saves time and compute)
- Handles transient GHCR 403 errors gracefully
- Logs each attempt for debugging

### Alternative Solutions Considered

1. **"Inherit access from source repository" setting on GHCR packages**: Requires manual setup after first push; doesn't prevent the initial failure.
2. **Using a Personal Access Token (PAT) instead of GITHUB_TOKEN**: Reported to help in some cases, but adds secret management complexity and doesn't address the fundamental GHCR transient issue.
3. **Upgrading to `docker/build-push-action@v6`**: No built-in retry for push was added in v6; the issue is on the GHCR side.
4. **Simply re-running failed jobs**: Works but requires manual intervention and delays releases.

## Prevention

The retry logic added to the workflow ensures that transient GHCR failures will be automatically retried, eliminating the need for manual re-runs. This is particularly important for:
- Repository/package renames that create new packages
- First-time pushes of new language variants
- High-concurrency release workflows with many matrix jobs
