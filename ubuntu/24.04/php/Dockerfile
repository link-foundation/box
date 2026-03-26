ARG ESSENTIALS_IMAGE=konard/sandbox-essentials:latest
FROM ${ESSENTIALS_IMAGE}
# Build: docker build -f ubuntu/24.04/php/Dockerfile --build-arg ESSENTIALS_IMAGE=sandbox-essentials -t sandbox-php .

# PHP sandbox: PHP 8.3 via Homebrew (user-specific/local) with apt fallback (global)
# Built on top of essentials-sandbox (inherits JS, git, gh, glab, dev libraries)
#
# Strategy (Issue #44):
#   1. Try Homebrew installation as sandbox user (user-specific, under /home/linuxbrew/.linuxbrew)
#      - With timeout to prevent 2+ hour source compilations
#   2. If Homebrew fails/times out, fall back to apt (global, under /usr/bin)
#   3. Write marker file /workspace/.php-install-method with "local" or "global"
#
# The marker file is used by the full-sandbox Dockerfile to determine how to merge PHP:
#   - "local": COPY /home/linuxbrew/.linuxbrew from php-stage
#   - "global": Install PHP via apt in full-sandbox directly

# Build argument for Homebrew timeout (in seconds)
# Default: 1200 (20 minutes) - enough for bottle install + dependencies,
# but short enough to fail fast if source compilation or network hang occurs (Issue #53)
# Reduced from 1800 (30 min) to 1200 (20 min) based on analysis showing
# successful ARM64 builds complete in ~8 minutes with bottles
ARG PHP_HOMEBREW_TIMEOUT=1200

# Enable verbose output for debugging hangs (Issue #53)
ARG PHP_VERBOSE=0

# --- Step 1: Prepare directories ---
USER root
RUN mkdir -p /home/linuxbrew/.linuxbrew && \
    chown -R sandbox:sandbox /home/linuxbrew

# --- Step 2: Try Homebrew installation as sandbox user ---
USER sandbox

COPY --chown=sandbox:sandbox ubuntu/24.04/common.sh /tmp/common.sh
COPY --chown=sandbox:sandbox ubuntu/24.04/php/install.sh /tmp/install.sh
RUN chmod +x /tmp/install.sh /tmp/common.sh

# Run install script - tries Homebrew with timeout, writes marker file
# PHP_VERBOSE=1 enables detailed logging to debug potential hangs (Issue #53)
RUN PHP_HOMEBREW_TIMEOUT=${PHP_HOMEBREW_TIMEOUT} PHP_VERBOSE=${PHP_VERBOSE} bash /tmp/install.sh

# --- Step 3: Handle global fallback (apt install as root if needed) ---
USER root
RUN PHP_METHOD=$(cat /workspace/.php-install-method 2>/dev/null || echo "unknown") && \
    echo "PHP install method: $PHP_METHOD" && \
    if [ "$PHP_METHOD" = "global" ]; then \
      echo "Installing PHP globally via apt (Homebrew failed/timed out)..." && \
      apt-get update -y && \
      apt-get install -y \
        php8.3-cli php8.3-common php8.3-curl php8.3-mbstring \
        php8.3-xml php8.3-zip php8.3-bcmath php8.3-opcache && \
      apt-get clean && rm -rf /var/lib/apt/lists/* && \
      echo "[✓] PHP installed globally via apt"; \
    else \
      echo "[✓] PHP installed locally via Homebrew"; \
    fi

# Verify PHP installation (use full path for local, or /usr/bin/php for global)
RUN PHP_METHOD=$(cat /workspace/.php-install-method 2>/dev/null || echo "unknown") && \
    if [ "$PHP_METHOD" = "local" ]; then \
      /home/linuxbrew/.linuxbrew/opt/php@8.3/bin/php --version; \
    else \
      php --version; \
    fi && \
    echo "[✓] PHP verification passed (method: $PHP_METHOD)"

# Cleanup temp files
RUN rm -f /tmp/install.sh /tmp/common.sh
# Note: /home/linuxbrew/.linuxbrew is kept even if empty (global install case)
# so that COPY --from in full-sandbox Dockerfile always succeeds

USER sandbox
WORKDIR /workspace

# PATH: include Homebrew PHP paths (only effective if local install succeeded)
# For global (apt) install, /usr/bin/php is already in PATH
ENV PATH="/home/linuxbrew/.linuxbrew/opt/php@8.3/bin:/home/linuxbrew/.linuxbrew/opt/php@8.3/sbin:/home/linuxbrew/.linuxbrew/bin:${PATH}"

SHELL ["/bin/bash", "-c"]
CMD ["/bin/bash"]
