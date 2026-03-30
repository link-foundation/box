---
bump: minor
---

Pre-install Playwright browsers, @playwright/test, and @puppeteer/browsers in JS sandbox image (issue #74)

- Move playwright, @playwright/test, and @puppeteer/browsers CLI installation to JS sandbox layer
- Download all Playwright browser binaries (chromium, firefox, webkit, msedge, chrome) during image build
- Remove duplicate Playwright/Puppeteer system deps and CLI installs from essentials install.sh
- Add /workspace ownership fix after COPY --from operations in full-sandbox Dockerfiles
- Add strict verification for browser installations (fail build on error)
