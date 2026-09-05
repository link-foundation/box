---
bump: minor
---

Find and fix every false positive, false negative, warning and error in CI/CD (issue #115).

- **A failed measurement reported success.** `measure-disk-space.yml` wrote its
  script through an *unquoted* heredoc, so `${TOTAL}`, `${USED}` and friends were
  expanded by the outer shell — which had never set them — and the generated
  script measured the empty string. The threshold comparison then ran on `0`,
  passed, and the job went green while measuring nothing. The heredoc is quoted,
  the script asserts every variable is populated before comparing, and
  `BOX_VERBOSE=1` (default off) traces the generated script line by line.
- **GHCR is the registry of record; Docker Hub is a mirror.** Every build pushed
  both registries from one `docker buildx build --push`, so the expired
  `DOCKERHUB_TOKEN` on run 33972074755 destroyed the GHCR tags and the
  `cache-to: type=gha` export as collateral — and because every downstream job
  resolved its base image from Docker Hub only, GHCR was a write-only mirror
  nothing could fall back to. Builds now push GHCR (written with the per-run
  `GITHUB_TOKEN`, which cannot expire), resolve all 18 base-image references from
  GHCR, and mirror to Docker Hub through `scripts/release/mirror-to-dockerhub.sh`
  in a step guarded on the login outcome. A broken Docker Hub credential now
  degrades to a warning on a published release instead of failing it.
- **Permanent failures are no longer retried.** `docker-push-failure-classifier.sh`
  (modelled on the template's `publish-failure-classifier.mjs`) tells an expired
  token or a denied repository apart from a 403, a 5xx, a reset or a
  `TOOMANYREQUESTS`. Permanent failures stop after one attempt and print how to
  rotate the credential; transient ones keep their three attempts. The ten
  copy-pasted inline retry loops collapse into `scripts/release/buildx-retry.sh`.
- **A skipped job no longer reads as a successful one.** When a base image was
  never published, the dind jobs failed deep inside the Dockerfile with a
  confusing pull error. `scripts/release/assert-base-image.sh` checks the
  manifest first and says which upstream job actually collapsed.
- **CI configuration is linted like code.** actionlint 1.7.7 (with shellcheck over
  every `run:` block) and zizmor 1.30.0 gate the workflows; third-party actions
  are pinned to full commit SHAs, `permissions:` is least-privilege, and all 24
  `always()` gates became `!cancelled()` so a cancelled run stops instead of
  cascading. Fifteen jobs that could hang forever got `timeout-minutes`.
- **The regression suites actually run.** `scripts/ci/run-experiments.sh` discovers
  every suite under `experiments/` and runs it in a new `scripts / regression
  suites` job; nothing had executed them before. Three suites were themselves
  producing false results and are fixed: two crashed on `File.read` under a
  non-UTF-8 default locale, and two asserted stale facts (a `@main` action ref
  that is now SHA-pinned, and a helper an example had legitimately switched away
  from). New suites cover each fix above.
