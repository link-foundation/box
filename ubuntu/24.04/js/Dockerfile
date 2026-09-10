FROM ubuntu:24.04
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# JavaScript/TypeScript box: Node.js (NVM), Bun, Deno
# Standalone JS image without essentials overhead
# Published as: konard/box-js
#
# Build from repository root:
#   docker build -f ubuntu/24.04/js/Dockerfile -t box-js .

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /home/box

COPY ubuntu/24.04/common.sh /tmp/common.sh

# Install minimal system prerequisites
#
# Recommends are kept here: measured, --no-install-recommends turns these 53
# packages into 32, and among the 21 it drops are openssh-client (git over
# ssh://, which is how a box clones a private repository), less (git's default
# pager), patch and netbase. Those are the tools a developer expects `git` to
# come with, not incidental weight.
# Measured by experiments/measure-issue121-apt-recommends.sh (issue #121).
# hadolint ignore=DL3015
RUN . /tmp/common.sh && \
    apt_update_with_retry && \
    apt-get install -y curl git sudo ca-certificates unzip && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install system-level dependencies for Playwright and Puppeteer browser automation
# These libraries are required by Chromium, Firefox, and WebKit to run (Ubuntu 24.04 names)
# Source: https://playwright.dev/docs/browsers#install-system-dependencies
#         https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/server/registry/nativeDeps.ts
#         https://pptr.dev/troubleshooting
#
# The list is exactly Playwright's ubuntu24.04 set (tools + chromium + firefox +
# webkit, 79 packages, deduplicated) plus the three Puppeteer-only additions
# libxss1, libxtst6 and xdg-utils. experiments/test-issue121-playwright-deps.sh
# holds it against a recorded copy of that set, because until issue #121 the
# Dockerfile was seven packages short and Playwright said so on every JS build
# ("Host validation warning: missing libraries") without failing anything.
#
# --no-install-recommends is what Playwright's own installer passes
# (packages/playwright-core/src/server/registry/dependencies.ts), so the list is
# complete without recommends by construction; measured, it drops 65 packages
# from this step, systemd and dbus-user-session among them.
RUN . /tmp/common.sh && \
    apt_update_with_retry && \
    apt-get install -y --no-install-recommends \
      libasound2t64 \
      libatk-bridge2.0-0t64 \
      libatk1.0-0t64 \
      libatspi2.0-0t64 \
      libcairo2 \
      libcups2t64 \
      libdbus-1-3 \
      libdrm2 \
      libgbm1 \
      libglib2.0-0t64 \
      libnspr4 \
      libnss3 \
      libpango-1.0-0 \
      libx11-6 \
      libxcb1 \
      libxcomposite1 \
      libxdamage1 \
      libxext6 \
      libxfixes3 \
      libxkbcommon0 \
      libxrandr2 \
      libavcodec60 \
      libcairo-gobject2 \
      libfontconfig1 \
      libfreetype6 \
      libgdk-pixbuf-2.0-0 \
      libgtk-3-0t64 \
      libpangocairo-1.0-0 \
      libx11-xcb1 \
      libxcb-shm0 \
      libxcursor1 \
      libxi6 \
      libxrender1 \
      gstreamer1.0-libav \
      gstreamer1.0-plugins-bad \
      gstreamer1.0-plugins-base \
      gstreamer1.0-plugins-good \
      libatomic1 \
      libenchant-2-2 \
      libepoxy0 \
      libevent-2.1-7t64 \
      libflite1 \
      libgles2 \
      libgstreamer-gl1.0-0 \
      libgstreamer-plugins-bad1.0-0 \
      libgstreamer-plugins-base1.0-0 \
      libgstreamer1.0-0 \
      libgtk-4-1 \
      libharfbuzz-icu0 \
      libharfbuzz0b \
      libhyphen0 \
      libavif16 \
      libicu74 \
      libx264-164 \
      libjpeg-turbo8 \
      liblcms2-2 \
      libmanette-0.2-0 \
      libopus0 \
      libpng16-16t64 \
      libsecret-1-0 \
      libvpx9 \
      libwayland-client0 \
      libwayland-egl1 \
      libwayland-server0 \
      libwebp7 \
      libwebpdemux2 \
      libwoff1 \
      libxml2 \
      libxslt1.1 \
      libxss1 \
      libxtst6 \
      xdg-utils \
      xvfb \
      fonts-liberation \
      fonts-noto-color-emoji \
      fonts-ipafont-gothic \
      fonts-wqy-zenhei \
      fonts-freefont-ttf \
      fonts-tlwg-loma-otf \
      fonts-unifont \
      xfonts-cyrillic \
      xfonts-scalable \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Create box group and user with /home/box as home directory
# Standard home directory location for the box user
#
# -M, not -m: `WORKDIR /home/box` above already created the directory, and
# Docker creates a WORKDIR that does not exist. `useradd -m` over an existing
# directory does not populate it - it prints
#   useradd: warning: the home directory /home/box already exists.
#   useradd: Not copying any file from skel directory into it.
# which is the warning both JS build jobs printed in run 34366976358, and
# leaves the user without ~/.profile. Ubuntu's skel .profile is what sources
# ~/.bashrc for an interactive *login* shell, so without it `docker run -it box
# bash -l` and `su - box` saw none of the PATH the install scripts append to
# ~/.bashrc. Every image here descends from this one, so that was true of all
# of them. Measured both ways in
# experiments/issue-123/repro-workdir-skips-skel.sh (issue #123).
#
# The two skel files are copied explicitly instead, and skel's .bashrc is
# deliberately not among them: it returns early in a non-interactive shell
# (`case $- in *i*) ;; *) return;; esac`) and scripts/entrypoint.sh sources
# ~/.bashrc non-interactively, so adopting it would silently drop everything
# the install scripts appended below it.
RUN groupadd box && \
    useradd -M -g box -d /home/box -s /bin/bash box && \
    cp -a /etc/skel/.profile /etc/skel/.bash_logout /home/box/ && \
    passwd -d box && \
    usermod -aG sudo box && \
    chown -R box:box /home/box && \
    chmod 2775 /home/box

# Copy and run install script
COPY ubuntu/24.04/js/install.sh /tmp/install.sh
RUN chmod +x /tmp/install.sh /tmp/common.sh && \
    su - box -c "bash /tmp/install.sh" && \
    rm -f /tmp/install.sh /tmp/common.sh

USER box
WORKDIR /home/box

ENV HOME=/home/box
ENV NVM_DIR="/home/box/.nvm"
ENV BUN_INSTALL="/home/box/.bun"
ENV DENO_INSTALL="/home/box/.deno"
ENV PATH="/home/box/.deno/bin:/home/box/.bun/bin:${PATH}"

SHELL ["/bin/bash", "-c"]

CMD ["/bin/bash"]
