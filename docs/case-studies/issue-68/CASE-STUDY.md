# Case Study: Issue #68 — Playwright and Puppeteer Dependencies Missing from Sandbox Images

## Executive Summary

When using the `konard/sandbox` (or any of the sandbox-based images: `konard/sandbox-js`, `konard/sandbox-essentials`) to run Playwright or Puppeteer browser automation, the host system is missing critical OS-level dependencies required to launch browsers (Chromium, Firefox, WebKit). Additionally, no CLI tools for managing browsers (`playwright`, `@puppeteer/browsers`) are preinstalled.

**Root cause**: The sandbox Dockerfiles only install minimal prerequisites. The system libraries required by Chromium/Firefox/WebKit (GTK, CUPS, D-Bus, libXkbcommon, ALSA, ATK, etc.) are not included.

**Secondary issue**: No Playwright or Puppeteer CLI tools are globally installed, requiring users to install them before use.

---

## 1. Data Collection

### 1.1 CI Log — Playwright Warning During Docker Build

Source: `https://github.com/link-assistant/hive-mind/actions/runs/22902572178/job/66453518615`

The warning appears during the hive-mind Docker image build, when `npx playwright install` downloads browsers:

```
#16 13.80 WebKit 26.0 (playwright webkit v2248) downloaded to /home/hive/.cache/ms-playwright/webkit-2248
#16 14.22 Playwright Host validation warning:
#16 14.22 ╔══════════════════════════════════════════════════════╗
#16 14.22 ║ Host system is missing dependencies to run browsers. ║
#16 14.22 ║ Please install them with the following command:      ║
#16 14.22 ║                                                      ║
#16 14.22 ║     sudo npx playwright install-deps                 ║
#16 14.22 ║                                                      ║
#16 14.22 ║ Alternatively, use apt:                              ║
#16 14.22 ║     sudo apt-get install libatk1.0-0t64\             ║
#16 14.22 ║         libatk-bridge2.0-0t64\                       ║
#16 14.22 ║         libcups2t64\                                 ║
#16 14.22 ║         libxkbcommon0\                               ║
#16 14.22 ║         libatspi2.0-0t64\                            ║
#16 14.22 ║         libxdamage1\                                 ║
#16 14.22 ║         libasound2t64                                ║
#16 14.22 ║                                                      ║
#16 14.22 ║ <3 Playwright Team                                   ║
#16 14.22 ╚══════════════════════════════════════════════════════╝
```

The warning only lists the minimum deps missing for the installed browsers. The complete list is larger.

### 1.2 Context — Image Hierarchy

```
ubuntu:24.04
  └── konard/sandbox-js (JS runtimes: Node.js/NVM, Bun, Deno)
        └── konard/sandbox-essentials (+ gh, glab, git identity tools)
              ├── konard/sandbox-python, sandbox-go, ...  (language-specific)
              └── konard/sandbox (full-sandbox — all languages merged)
```

The CI log comes from building `konard/hive-mind` which is built on top of `konard/sandbox`.

### 1.3 Current System Dependencies in JS Sandbox (minimal)

From `ubuntu/24.04/js/Dockerfile`:
```dockerfile
RUN apt update -y && \
    apt install -y curl git sudo ca-certificates unzip && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
```

None of the Playwright/Puppeteer browser dependencies are present.

### 1.4 Official Playwright Dependencies for Ubuntu 24.04

From the Playwright source code (`packages/playwright-core/src/server/registry/nativeDeps.ts`):

**Chromium dependencies (ubuntu24.04):**
```
libasound2t64, libatk-bridge2.0-0t64, libatk1.0-0t64, libatspi2.0-0t64,
libcairo2, libcups2t64, libdbus-1-3, libdrm2, libgbm1, libglib2.0-0t64,
libnspr4, libnss3, libpango-1.0-0, libx11-6, libxcb1, libxcomposite1,
libxdamage1, libxext6, libxfixes3, libxkbcommon0, libxrandr2
```

**Firefox dependencies (ubuntu24.04):**
```
libasound2t64, libatk1.0-0t64, libavcodec60, libcairo-gobject2, libcairo2,
libdbus-1-3, libfontconfig1, libfreetype6, libgdk-pixbuf-2.0-0,
libglib2.0-0t64, libgtk-3-0t64, libpango-1.0-0, libpangocairo-1.0-0,
libx11-6, libx11-xcb1, libxcb-shm0, libxcb1, libxcomposite1, libxcursor1,
libxdamage1, libxext6, libxfixes3, libxi6, libxrandr2, libxrender1
```

**WebKit dependencies (ubuntu24.04):**
```
gstreamer1.0-libav, gstreamer1.0-plugins-bad, gstreamer1.0-plugins-base,
gstreamer1.0-plugins-good, libicu74, libatomic1, libatk-bridge2.0-0t64,
libatk1.0-0t64, libcairo-gobject2, libcairo2, libdbus-1-3, libdrm2,
libenchant-2-2, libepoxy0, libevent-2.1-7t64, libflite1, libfontconfig1,
libfreetype6, libgbm1, libgdk-pixbuf-2.0-0, libgles2, libglib2.0-0t64,
libgstreamer-gl1.0-0, libgstreamer-plugins-bad1.0-0,
libgstreamer-plugins-base1.0-0, libgstreamer1.0-0, libgtk-4-1,
libharfbuzz-icu0, libharfbuzz0b, libhyphen0, libjpeg-turbo8, liblcms2-2,
libmanette-0.2-0, libopus0, libpango-1.0-0, libpangocairo-1.0-0,
libpng16-16t64, libsecret-1-0, libvpx9, libwayland-client0, libwayland-egl1,
libwayland-server0, libwebp7, libwebpdemux2, libwoff1, libx11-6,
libxkbcommon0, libxml2, libxslt1.1, libx264-164, libavif16
```

**Tools/display/fonts (ubuntu24.04):**
```
xvfb, fonts-noto-color-emoji, fonts-unifont, libfontconfig1, libfreetype6,
xfonts-cyrillic, xfonts-scalable, fonts-liberation, fonts-ipafont-gothic,
fonts-wqy-zenhei, fonts-tlwg-loma-otf, fonts-freefont-ttf
```

### 1.5 Official Puppeteer Dependencies on Ubuntu

From the Puppeteer troubleshooting documentation, for the bundled Chrome for Testing:
```
ca-certificates, fonts-liberation, libasound2, libatk-bridge2.0-0,
libatk1.0-0, libc6, libcairo2, libcups2, libdbus-1-3, libexpat1,
libfontconfig1, libgbm1, libgcc1, libglib2.0-0, libgtk-3-0, libnspr4,
libnss3, libpango-1.0-0, libpangocairo-1.0-0, libstdc++6, libx11-6,
libx11-xcb1, libxcb1, libxcomposite1, libxcursor1, libxdamage1, libxext6,
libxfixes3, libxi6, libxrandr2, libxrender1, libxss1, libxtst6, lsb-release,
wget, xdg-utils
```

Note: On Ubuntu 24.04, some packages use the `t64` suffix (e.g., `libasound2t64` instead of `libasound2`, `libglib2.0-0t64` instead of `libglib2.0-0`). The naming change is part of Debian's time_t 64-bit transition.

---

## 2. Root Cause Analysis

### 2.1 Primary Root Cause

The sandbox images are designed as development environments but do not include the system-level shared libraries required by browsers (Chromium, Firefox, WebKit). These libraries cannot be installed by the sandbox user (they require root/apt). They must be baked into the Docker image at build time.

The affected Dockerfiles:
- `ubuntu/24.04/js/Dockerfile` — the base image that all others build upon
- `ubuntu/24.04/essentials-sandbox/install.sh` — where system packages are installed for the essentials image
- `ubuntu/24.04/full-sandbox/Dockerfile` and `ubuntu/24.04/full-sandbox/install.sh` — the full image

Since `sandbox-js` is the lowest-level image, adding Playwright/Puppeteer dependencies there propagates to all derived images (essentials, full-sandbox).

### 2.2 Secondary Issue — No CLI Tools Preinstalled

The `playwright` CLI (`npx playwright`) and `@puppeteer/browsers` CLI are not globally installed in the sandbox. Users need to run:
```bash
npm install -D @playwright/test  # or
npm install puppeteer
```

This adds setup friction for automated e2e testing workflows. The issue requests preinstalling these CLIs globally via npm/bun.

### 2.3 Why Only Some Deps Were Reported as Missing

Playwright's runtime validation only checks for the specific browsers that were installed (e.g., if only WebKit was installed, only WebKit deps are checked). The warning in the CI log shows 7 missing packages, but that's only what was checked against the installed browsers.

The complete list of all browser dependencies (Chromium + Firefox + WebKit) is significantly larger (~60-80 unique packages).

---

## 3. Timeline / Sequence of Events

1. **Sandbox image build**: `konard/sandbox-js`, `konard/sandbox-essentials`, and `konard/sandbox` are built with minimal system prerequisites.
2. **hive-mind image build**: Built on top of `konard/sandbox`, runs `npx playwright install` to download browsers.
3. **Playwright validation**: After downloading browsers, Playwright checks whether host system has all required libraries.
4. **Warning emitted**: Playwright detects 7 missing libraries for the installed browsers, reports:
   `"Host system is missing dependencies to run browsers."`
5. **Runtime failure risk**: When attempting to actually launch a browser in the container, it will fail with a missing library error.

---

## 4. Proposed Solution

### 4.1 Add Playwright/Puppeteer System Dependencies to `js/Dockerfile`

Add all system-level library dependencies for Playwright and Puppeteer as an apt install step in `ubuntu/24.04/js/Dockerfile`. Since this is the base for all sandbox images, all derived images will automatically inherit these dependencies.

The dependencies to add are the union of:
- Playwright's complete dependency list for ubuntu24.04 (Chromium + Firefox + WebKit)
- Puppeteer's Chrome dependencies (mostly overlapping with Playwright's Chromium list)

### 4.2 Add Browser CLI Tools to `essentials-sandbox/install.sh`

Globally install Playwright CLI and Puppeteer browser management CLI via npm:
```bash
npm install -g playwright @puppeteer/browsers
```

This allows users to run:
- `playwright install chromium` (or firefox, webkit, etc.)
- `npx @puppeteer/browsers install chrome@stable`

### 4.3 Architecture Decision

Add dependencies to `js/Dockerfile` (base level) rather than only to `essentials-sandbox` or `full-sandbox` because:
1. The issue explicitly states "all core Dockerfiles should include dependencies for puppeteer and playwright CLI at apt level"
2. `sandbox-js` is the smallest image that users might use directly for JS e2e testing
3. Adding at the base level avoids duplication

---

## 5. Solution Implementation

See the changes in:
- `ubuntu/24.04/js/Dockerfile` — Playwright/Puppeteer system dependencies added
- `ubuntu/24.04/essentials-sandbox/install.sh` — Playwright and Puppeteer CLIs installed globally
- `ubuntu/24.04/full-sandbox/install.sh` — Playwright browser download step

---

## 6. References

- [Issue #68](https://github.com/link-foundation/sandbox/issues/68)
- [PR #69](https://github.com/link-foundation/sandbox/pull/69)
- [CI run with warning](https://github.com/link-assistant/hive-mind/actions/runs/22902572178/job/66453518615)
- [Playwright nativeDeps.ts (official dependency list)](https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/server/registry/nativeDeps.ts)
- [Playwright: Install System Dependencies](https://playwright.dev/docs/browsers#install-system-dependencies)
- [Puppeteer Troubleshooting: Chrome dependencies](https://pptr.dev/troubleshooting)
- [Puppeteer: @puppeteer/browsers CLI](https://pptr.dev/browsers-api)
- [ci-logs/issue-68-playwright-warning.txt](../../ci-logs/issue-68-playwright-warning.txt)
