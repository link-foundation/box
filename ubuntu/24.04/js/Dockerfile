FROM ubuntu:24.04

# JavaScript/TypeScript box: Node.js (NVM), Bun, Deno
# Standalone JS image without essentials overhead
# Published as: konard/box-js
#
# Build from repository root:
#   docker build -f ubuntu/24.04/js/Dockerfile -t box-js .

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /home/box

# Install minimal system prerequisites
RUN apt update -y && \
    apt install -y curl git sudo ca-certificates unzip && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install system-level dependencies for Playwright and Puppeteer browser automation
# These libraries are required by Chromium, Firefox, and WebKit to run (Ubuntu 24.04 names)
# Source: https://playwright.dev/docs/browsers#install-system-dependencies
#         https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/server/registry/nativeDeps.ts
#         https://pptr.dev/troubleshooting
RUN apt-get update -y && \
    apt-get install -y \
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
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Create box group and user with /home/box as home directory
# Standard home directory location for the box user
RUN groupadd box && \
    useradd -m -g box -d /home/box -s /bin/bash box && \
    passwd -d box && \
    usermod -aG sudo box && \
    chown box:box /home/box && \
    chmod 2775 /home/box

# Copy and run install script
COPY ubuntu/24.04/common.sh /tmp/common.sh
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
