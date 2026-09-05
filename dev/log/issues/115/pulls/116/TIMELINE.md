# Timeline

All times UTC. Sources: `git log`, [`runs/`](runs/), [`logs/`](logs/).

## Before the failure — how the defect entered `main`

| When | What |
| --- | --- |
| 2026-09-05 09:44:09 | Commit `92d66aa`, *"scripts: resolve dependency versions at install time in the standalone installers (issue #112)"*, on branch `issue-112-7f66cda6879b`. It replaces the hardcoded Node/nvm/Java versions **inside** the quoted heredocs of `scripts/measure-disk-space.sh` and `scripts/ubuntu-24-server-install.sh` with `$NODE_MAJOR`, `${NVM_INSTALL_VERSION}` and `${JAVA_MAJOR}`, which are only defined in the parent script. This is root cause [RC-1](ROOT-CAUSES.md#rc-1). |
| 09:44 → 14:31 | Pull request #113 runs its `pr-test` tiers. **None of them executes either script**: `measure-disk-space.yml` has no `pull_request` trigger ([RC-2](ROOT-CAUSES.md#rc-2)) and nothing anywhere runs `ubuntu-24-server-install.sh`. The pull request goes green. |
| 14:31:47 | `7ac36f4` — pull request #113 is merged into `main` as merge commit `42be663`. |

## The two failing runs

Both runs were queued by the same push at **14:31:42** on `42be6636f62b094d577a89751ea1cb351e506791`.

### Run [33972074753](https://github.com/link-foundation/box/actions/runs/33972074753) — *Measure Disk Space and Update README* — failed after 2 min 11 s

| When | What |
| --- | --- |
| 14:31:42 | Run created. Single job `measure-disk-space`. |
| ~14:32 | `sudo ./scripts/measure-disk-space.sh --json-output data/disk-space-measurements.json` starts. The parent script resolves the versions correctly and writes `/tmp/box-measure.sh` from the `<< 'EOF_BOX'` heredoc — unexpanded, so the generated script still contains the literal text `$NODE_MAJOR`. |
| 14:33:51.165 | `/tmp/box-measure.sh: line 128: NODE_MAJOR: unbound variable` |
| 14:33:51.171 | `##[error]Process completed with exit code 1.` |
| 14:33:53 | Run concludes `failure`. |

Generated line 128 corresponds to source line 521 of `scripts/measure-disk-space.sh`
(heredoc body starts at line 394, so `394 + 128 − 1 = 521`):
`measure_install "NVM + Node.js ${NODE_MAJOR}" ...`.

### Run [33972074755](https://github.com/link-foundation/box/actions/runs/33972074755) — *Build and Release Docker Image* — failed after 34 min 54 s

Final tally: **52 jobs failed, 21 skipped, 2 succeeded** (`detect-changes`, `Apply Changesets`).

| When | Job | What |
| --- | --- | --- |
| 14:31:58 | `build-js-amd64` | Starts. |
| 14:34:38.985 | `build-js-amd64` | `##[error]Error response from daemon: Get "https://registry-1.docker.io/v2/": unauthorized: personal access token is expired` — the `DOCKERHUB_TOKEN` secret has expired. This is root cause [RC-3](ROOT-CAUSES.md#rc-3). |
| 14:34:38.997 | `build-js-amd64` | The issue-#82 tolerance turns that into a **`::warning::` only**. Nothing stops. The job proceeds to build. |
| 14:35:25.108 | `build-js-arm64` | `#16 pushing manifest for ghcr.io/link-foundation/box-js:latest-arm64 … done` — **the GHCR half of the push succeeds.** |
| 14:35:25.854 | `build-js-arm64` | `#16 pushing manifest for ghcr.io/link-foundation/box-js:2.5.0-arm64 … done` |
| 14:35:26.427 | `build-js-arm64` | `#16 ERROR: failed to push ***/box-js:latest-arm64: failed to authorize: failed to fetch oauth token` — the Docker Hub half of the *same* buildx solve fails, so the whole solve fails. |
| 14:35:26 | `build-js-arm64` | `#18 exporting to GitHub Actions Cache … #18 CANCELED` — the cache export is aborted by the failed solve, so the work is not even banked for the next run. |
| 14:35:26.758 | `build-js-arm64` | `==> Retry attempt 1/3...` — the retry loop re-runs the identical 4-tag push. |
| 14:35:29.471 | `build-js-arm64` | Same GHCR success, same Docker Hub `failed to fetch oauth token`. `==> Retry failed, waiting 10s before next attempt...` |
| 14:35:39 → 14:36:03 | `build-js-arm64` | Attempts 2/3 and 3/3, identical outcome. `==> All retry attempts failed`. 37 s spent retrying a permanent 401. |
| 14:36:08 | `build-js-arm64` | Job fails. |
| 14:39:54 | `build-js-amd64` | Job fails the same way, after 7 min 56 s. |
| 14:36:12 → 14:58:02 | `build-languages-*` (22 jobs) | All 22 run the full language build — up to 21 min 50 s for `rocq` on amd64 — and all 22 fail at the Docker Hub push. |
| — | `js-manifest`, `essentials-manifest`, `languages-manifest`, `docker-manifest`, `build-essentials-*`, `create-release`, `version-bump` | Correctly **skipped**: their `if` requires `needs.build-*.result == 'success'`. |
| 14:58:04 → 15:06:35 | `build-dind-amd64` / `build-dind-arm64` (28 jobs) | **Run anyway**, because their `if` accepts `needs.js-manifest.result == 'skipped'` as equivalent to success ([RC-4](ROOT-CAUSES.md#rc-4)). Each pulls its base image `FROM ${BASE_IMAGE}` on Docker Hub, which was never published, and reports `failed to resolve source metadata for docker.io/***/box-*:2.5.0-*: not found`. |
| 15:06:36 | run | Concludes `failure`. |

The last 8.5 minutes of the run and 28 of its 52 failures are therefore
**false positives**: red jobs blaming the dind Dockerfiles for an expired
credential three layers upstream.

## The issue

| When | What |
| --- | --- |
| 2026-09-05 21:58:19 | Issue [#115](https://github.com/link-foundation/box/issues/115) opened by `konard` via `/fix --ci-cd`, naming both runs and pointing at the pipeline template and the hive-mind best-practices document. |
| 2026-09-05 | Branch `issue-115-3e95d428cf8a` and draft pull request [#116](https://github.com/link-foundation/box/pull/116) created. Evidence collection for this folder begins. |
