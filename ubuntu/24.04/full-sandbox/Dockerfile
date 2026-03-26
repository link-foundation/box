# Full Sandbox Docker image - Multi-stage assembly
# Copies pre-built language runtimes from individual language images
# Published as: konard/sandbox (or konard/sandbox-full)
#
# Architecture:
#   essentials-sandbox (base for all language images)
#     ├─ sandbox-python   (built in parallel)
#     ├─ sandbox-go       (built in parallel)
#     ├─ sandbox-rust     (built in parallel)
#     ├─ sandbox-java     (built in parallel)
#     ├─ sandbox-kotlin   (built in parallel)
#     ├─ sandbox-ruby     (built in parallel)
#     ├─ sandbox-php      (built in parallel)
#     ├─ sandbox-perl     (built in parallel)
#     ├─ sandbox-swift    (built in parallel)
#     ├─ sandbox-lean     (built in parallel)
#     ├─ sandbox-rocq     (built in parallel)
#     └─ full-sandbox     (merges all + adds dotnet, r, cpp, assembly via apt)
#
# PHP Integration (Issue #44):
#   The php-stage image may have PHP installed locally (Homebrew) or globally (apt).
#   A marker file at /workspace/.php-install-method indicates the method:
#     "local"  → COPY /home/linuxbrew/.linuxbrew from php-stage (user-specific)
#     "global" → Install PHP via apt in this image directly
#
# Build from repository root:
#   docker build -f ubuntu/24.04/full-sandbox/Dockerfile -t sandbox-full .

# === Build arguments (all declared before first FROM for global scope) ===
ARG ESSENTIALS_IMAGE=konard/sandbox-essentials:latest
ARG PYTHON_IMAGE=konard/sandbox-python:latest
ARG GO_IMAGE=konard/sandbox-go:latest
ARG RUST_IMAGE=konard/sandbox-rust:latest
ARG JAVA_IMAGE=konard/sandbox-java:latest
ARG KOTLIN_IMAGE=konard/sandbox-kotlin:latest
ARG RUBY_IMAGE=konard/sandbox-ruby:latest
ARG PHP_IMAGE=konard/sandbox-php:latest
ARG PERL_IMAGE=konard/sandbox-perl:latest
ARG SWIFT_IMAGE=konard/sandbox-swift:latest
ARG LEAN_IMAGE=konard/sandbox-lean:latest
ARG ROCQ_IMAGE=konard/sandbox-rocq:latest

# === Language image stages (for COPY --from) ===
FROM ${PYTHON_IMAGE} AS python-stage
FROM ${GO_IMAGE} AS go-stage
FROM ${RUST_IMAGE} AS rust-stage
FROM ${JAVA_IMAGE} AS java-stage
FROM ${KOTLIN_IMAGE} AS kotlin-stage
FROM ${RUBY_IMAGE} AS ruby-stage
FROM ${PHP_IMAGE} AS php-stage
FROM ${PERL_IMAGE} AS perl-stage
FROM ${SWIFT_IMAGE} AS swift-stage
FROM ${LEAN_IMAGE} AS lean-stage
FROM ${ROCQ_IMAGE} AS rocq-stage

# === Final assembly image ===
FROM ${ESSENTIALS_IMAGE}

USER root
ENV DEBIAN_FRONTEND=noninteractive

# Copy entrypoint script
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# --- Install system-level packages (cannot be COPY'd from images) ---
# Note: PHP is NOT installed here unconditionally - it depends on the php-stage method
RUN apt-get update -y && \
    apt-get install -y \
      dotnet-sdk-8.0 \
      r-base \
      cmake clang llvm lld \
      nasm \
      expect \
      bubblewrap && \
    # FASM only available on x86_64
    if [ "$(uname -m)" = "x86_64" ]; then apt-get install -y fasm; fi && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# --- Copy user-home language runtimes from pre-built images ---

# Python (pyenv)
COPY --from=python-stage --chown=sandbox:sandbox /workspace/.pyenv /workspace/.pyenv

# Go
COPY --from=go-stage --chown=sandbox:sandbox /workspace/.go /workspace/.go

# Rust (cargo + rustup)
COPY --from=rust-stage --chown=sandbox:sandbox /workspace/.cargo /workspace/.cargo
COPY --from=rust-stage --chown=sandbox:sandbox /workspace/.rustup /workspace/.rustup

# Java (SDKMAN)
COPY --from=java-stage --chown=sandbox:sandbox /workspace/.sdkman /workspace/.sdkman

# Kotlin (SDKMAN - merge with Java's SDKMAN)
COPY --from=kotlin-stage --chown=sandbox:sandbox /workspace/.sdkman/candidates/kotlin /workspace/.sdkman/candidates/kotlin

# Ruby (rbenv)
COPY --from=ruby-stage --chown=sandbox:sandbox /workspace/.rbenv /workspace/.rbenv

# PHP: Copy marker file to determine install method
COPY --from=php-stage --chown=sandbox:sandbox /workspace/.php-install-method /workspace/.php-install-method

# PHP (local/Homebrew): Copy linuxbrew directory if it exists in php-stage
# This COPY succeeds if PHP was installed locally (Homebrew), and the directory exists
# If PHP was installed globally (apt), the directory was cleaned up and this will be empty/fail
# We use a shell check after to handle the global case
RUN mkdir -p /home/linuxbrew/.linuxbrew && \
    chown -R sandbox:sandbox /home/linuxbrew

# Try to copy Homebrew PHP files (only present if local install succeeded)
COPY --from=php-stage --chown=sandbox:sandbox /home/linuxbrew/.linuxbrew/ /home/linuxbrew/.linuxbrew/

# PHP (global/apt fallback): If php-stage used global install, install PHP via apt here too
RUN PHP_METHOD=$(cat /workspace/.php-install-method 2>/dev/null || echo "unknown") && \
    echo "PHP install method from php-stage: $PHP_METHOD" && \
    if [ "$PHP_METHOD" = "global" ]; then \
      echo "Installing PHP globally via apt (matching php-stage method)..." && \
      apt-get update -y && \
      apt-get install -y \
        php8.3-cli php8.3-common php8.3-curl php8.3-mbstring \
        php8.3-xml php8.3-zip php8.3-bcmath php8.3-opcache && \
      apt-get clean && rm -rf /var/lib/apt/lists/* && \
      rm -rf /home/linuxbrew/.linuxbrew && \
      echo "[✓] PHP installed globally via apt in full-sandbox"; \
    else \
      echo "[✓] PHP available via Homebrew (local/user-specific) from php-stage"; \
    fi

# Perl (Perlbrew)
COPY --from=perl-stage --chown=sandbox:sandbox /workspace/.perl5 /workspace/.perl5

# Swift
COPY --from=swift-stage --chown=sandbox:sandbox /workspace/.swift /workspace/.swift

# Lean (elan)
COPY --from=lean-stage --chown=sandbox:sandbox /workspace/.elan /workspace/.elan

# Rocq/Coq (Opam)
COPY --from=rocq-stage --chown=sandbox:sandbox /workspace/.opam /workspace/.opam

# --- Copy bashrc configurations from language stages ---
COPY --from=python-stage --chown=sandbox:sandbox /workspace/.bashrc /tmp/.bashrc-python
COPY --from=go-stage --chown=sandbox:sandbox /workspace/.bashrc /tmp/.bashrc-go
COPY --from=rust-stage --chown=sandbox:sandbox /workspace/.bashrc /tmp/.bashrc-rust
COPY --from=java-stage --chown=sandbox:sandbox /workspace/.bashrc /tmp/.bashrc-java
COPY --from=kotlin-stage --chown=sandbox:sandbox /workspace/.bashrc /tmp/.bashrc-kotlin
COPY --from=ruby-stage --chown=sandbox:sandbox /workspace/.bashrc /tmp/.bashrc-ruby
COPY --from=php-stage --chown=sandbox:sandbox /workspace/.bashrc /tmp/.bashrc-php
COPY --from=perl-stage --chown=sandbox:sandbox /workspace/.bashrc /tmp/.bashrc-perl
COPY --from=swift-stage --chown=sandbox:sandbox /workspace/.bashrc /tmp/.bashrc-swift
COPY --from=lean-stage --chown=sandbox:sandbox /workspace/.bashrc /tmp/.bashrc-lean
COPY --from=rocq-stage --chown=sandbox:sandbox /workspace/.bashrc /tmp/.bashrc-rocq

# Merge bashrc configurations: take the essentials bashrc as base,
# then append sections from each language stage that are not yet present.
# Uses section-header deduplication (checks for unique "# <Tool> configuration"
# comment) to avoid corrupting multi-line shell constructs (if/fi blocks) that
# would break when individual lines like bare "fi" are deduplicated.
RUN cp /workspace/.bashrc /tmp/.bashrc-base && \
    for lang_bashrc in /tmp/.bashrc-python /tmp/.bashrc-go /tmp/.bashrc-rust \
      /tmp/.bashrc-java /tmp/.bashrc-kotlin /tmp/.bashrc-ruby /tmp/.bashrc-php \
      /tmp/.bashrc-perl /tmp/.bashrc-swift /tmp/.bashrc-lean /tmp/.bashrc-rocq; do \
      if [ -f "$lang_bashrc" ]; then \
        in_new_section=0; \
        section_header=""; \
        while IFS= read -r line; do \
          if echo "$line" | grep -qE '^# .+ configuration$'; then \
            section_header="$line"; \
            if grep -qxF "$section_header" /tmp/.bashrc-base 2>/dev/null; then \
              in_new_section=0; \
            else \
              in_new_section=1; \
              echo "" >> /tmp/.bashrc-base; \
              echo "$section_header" >> /tmp/.bashrc-base; \
            fi; \
          elif [ "$in_new_section" = "1" ]; then \
            echo "$line" >> /tmp/.bashrc-base; \
          fi; \
        done < "$lang_bashrc"; \
      fi; \
    done && \
    cp /tmp/.bashrc-base /workspace/.bashrc && \
    chown sandbox:sandbox /workspace/.bashrc && \
    rm -f /tmp/.bashrc-*

USER sandbox
WORKDIR /workspace

# Environment variables for all tools
ENV HOME=/workspace
ENV NVM_DIR="/workspace/.nvm"
ENV PYENV_ROOT="/workspace/.pyenv"
ENV BUN_INSTALL="/workspace/.bun"
ENV DENO_INSTALL="/workspace/.deno"
ENV CARGO_HOME="/workspace/.cargo"
ENV GOROOT="/workspace/.go"
ENV GOPATH="/workspace/.go/path"
ENV SDKMAN_DIR="/workspace/.sdkman"
ENV PERLBREW_ROOT="/workspace/.perl5"
ENV RBENV_ROOT="/workspace/.rbenv"

# PATH for tools that don't need special initialization
# Includes Homebrew PHP paths (only effective if local install was used, harmless otherwise)
ENV PATH="/home/linuxbrew/.linuxbrew/opt/php@8.3/bin:/home/linuxbrew/.linuxbrew/opt/php@8.3/sbin:/home/linuxbrew/.linuxbrew/bin:/workspace/.pyenv/bin:/workspace/.pyenv/shims:/workspace/.rbenv/bin:/workspace/.rbenv/shims:/workspace/.swift/usr/bin:/workspace/.elan/bin:/workspace/.opam/default/bin:/workspace/.cargo/bin:/workspace/.deno/bin:/workspace/.bun/bin:/workspace/.go/bin:/workspace/.go/path/bin:${PATH}"

SHELL ["/bin/bash", "-c"]

# Opam environment variables for Rocq/Coq theorem prover
ENV OPAM_SWITCH_PREFIX="/workspace/.opam/default"
ENV CAML_LD_LIBRARY_PATH="/workspace/.opam/default/lib/stublibs:/workspace/.opam/default/lib/ocaml/stublibs:/workspace/.opam/default/lib/ocaml"
ENV OCAML_TOPLEVEL_PATH="/workspace/.opam/default/lib/toplevel"

SHELL ["/bin/bash", "-c"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash"]
