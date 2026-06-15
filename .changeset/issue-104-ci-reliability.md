---
bump: patch
---

CI reliability: retry transient network failures in the JS image build and remove
a SIGPIPE false-negative from the dind example tests (issue #104 / PR #105).

The JS image build (`ubuntu/24.04/js/install.sh`, `COPY`'d into every dind/language
image) occasionally died on a single transient third-party error, with no retry:
the lean/language build hit a flaky npm registry response during
`npm install -g npm@latest`, and the dind-swift build hit
`playwright install … msedge …` getting an invalid GPG key body from
packages.microsoft.com ("gpg: no valid OpenPGP data found" → "Failed to install
msedge"). Every network-bound build step — the npm self-update, the
Playwright/Puppeteer CLI install, and the Playwright browser-binary download — now
goes through a `run_with_retry` wrapper that retries with exponential backoff
(mirroring `apt_update_with_retry` in `common.sh`, with the same overridable retry
budget so it stays unit-testable). `playwright install` skips already-present
browsers, so a retry only re-attempts the one that blipped. This is build-time
resilience only — the resulting image is unchanged on success.

Separately, the dind example suite asserted on container logs with
`docker logs … | grep -q "needle"`. Under `set -o pipefail`, `grep -q` closes the
pipe the instant it matches, which can deliver SIGPIPE to the still-streaming
`docker logs`; pipefail then propagates that 141 and a present message reads as
absent, failing the test spuriously (observed on the preload test even though the
expected line was right there in the logs). `tests/dind/lib.sh` now provides a
pipe-free `logs_contain` helper (capture once, match with a `case` glob) and all
example assertions use it.

Covered by new unit tests `experiments/test-issue104-build-retry.sh` and
`experiments/test-issue104-logs-contain.sh`.
