---
bump: patch
---

CI reliability: retry transient npm failures in the JS image build and remove a
SIGPIPE false-negative from the dind example tests (issue #104 / PR #105).

The JS image build occasionally failed on a single transient npm registry error
during `npm install -g npm@latest` (and the Playwright/Puppeteer install), aborting
the whole build with no retry. Those npm registry operations now go through a
`run_with_retry` wrapper in `ubuntu/24.04/js/install.sh` that retries with
exponential backoff (mirroring `apt_update_with_retry` in `common.sh`, with the
same overridable retry budget so it stays unit-testable). This is build-time
resilience only — the resulting image is unchanged on success.

Separately, the dind example suite asserted on container logs with
`docker logs … | grep -q "needle"`. Under `set -o pipefail`, `grep -q` closes the
pipe the instant it matches, which can deliver SIGPIPE to the still-streaming
`docker logs`; pipefail then propagates that 141 and a present message reads as
absent, failing the test spuriously (observed on the preload test even though the
expected line was right there in the logs). `tests/dind/lib.sh` now provides a
pipe-free `logs_contain` helper (capture once, match with a `case` glob) and all
example assertions use it.

Covered by new unit tests `experiments/test-issue104-npm-retry.sh` and
`experiments/test-issue104-logs-contain.sh`.
