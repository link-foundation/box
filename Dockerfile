# Full Sandbox environment Docker image
# Contains all language runtimes and development tools.
# This is the "full-sandbox" image (konard/sandbox or konard/sandbox-full).
#
# Architecture:
#   essentials-sandbox (base for all language images)
#     ├─ sandbox-python, sandbox-go, sandbox-rust, ... (built in parallel)
#     └─ full-sandbox (merges all language images via COPY --from)
#
# Build from repository root:
#   docker build -t sandbox .
#
# Build with specific images:
#   docker build --build-arg ESSENTIALS_IMAGE=konard/sandbox-essentials:latest -t sandbox .
#
# For a lighter image with just essentials, see ubuntu/24.04/essentials-sandbox/Dockerfile.
# For just JavaScript, see ubuntu/24.04/js/Dockerfile.
# For individual language images, see ubuntu/24.04/<language>/Dockerfile.

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
WORKDIR /workspace

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
      bubblewrap && \
    # FASM only available on x86_64
    if [ "$(uname -m)" = "x86_64" ]; then apt-get install -y fasm; fi && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# --- Copy user-home language runtimes from pre-built images ---

# Python (pyenv)
COPY --from=python-stage --chown=sandbox:sandbox /home/sandbox/.pyenv /home/sandbox/.pyenv

# Go
COPY --from=go-stage --chown=sandbox:sandbox /home/sandbox/.go /home/sandbox/.go

# Rust (cargo + rustup)
COPY --from=rust-stage --chown=sandbox:sandbox /home/sandbox/.cargo /home/sandbox/.cargo
COPY --from=rust-stage --chown=sandbox:sandbox /home/sandbox/.rustup /home/sandbox/.rustup

# Java (SDKMAN)
COPY --from=java-stage --chown=sandbox:sandbox /home/sandbox/.sdkman /home/sandbox/.sdkman

# Kotlin (SDKMAN - merge Kotlin candidate into Java's SDKMAN)
COPY --from=kotlin-stage --chown=sandbox:sandbox /home/sandbox/.sdkman/candidates/kotlin /home/sandbox/.sdkman/candidates/kotlin

# Ruby (rbenv)
COPY --from=ruby-stage --chown=sandbox:sandbox /home/sandbox/.rbenv /home/sandbox/.rbenv

# PHP: Copy marker file and handle local (Homebrew) vs global (apt) install (Issue #44)
COPY --from=php-stage --chown=sandbox:sandbox /home/sandbox/.php-install-method /home/sandbox/.php-install-method
RUN mkdir -p /home/linuxbrew/.linuxbrew && \
    chown -R sandbox:sandbox /home/linuxbrew
COPY --from=php-stage --chown=sandbox:sandbox /home/linuxbrew/.linuxbrew/ /home/linuxbrew/.linuxbrew/
RUN PHP_METHOD=$(cat /home/sandbox/.php-install-method 2>/dev/null || echo "unknown") && \
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
COPY --from=perl-stage --chown=sandbox:sandbox /home/sandbox/.perl5 /home/sandbox/.perl5

# Swift
COPY --from=swift-stage --chown=sandbox:sandbox /home/sandbox/.swift /home/sandbox/.swift

# Lean (elan)
COPY --from=lean-stage --chown=sandbox:sandbox /home/sandbox/.elan /home/sandbox/.elan

# Rocq/Coq (Opam)
COPY --from=rocq-stage --chown=sandbox:sandbox /home/sandbox/.opam /home/sandbox/.opam

# --- Copy bashrc configurations from language stages ---
COPY --from=python-stage --chown=sandbox:sandbox /home/sandbox/.bashrc /tmp/.bashrc-python
COPY --from=go-stage --chown=sandbox:sandbox /home/sandbox/.bashrc /tmp/.bashrc-go
COPY --from=rust-stage --chown=sandbox:sandbox /home/sandbox/.bashrc /tmp/.bashrc-rust
COPY --from=java-stage --chown=sandbox:sandbox /home/sandbox/.bashrc /tmp/.bashrc-java
COPY --from=kotlin-stage --chown=sandbox:sandbox /home/sandbox/.bashrc /tmp/.bashrc-kotlin
COPY --from=ruby-stage --chown=sandbox:sandbox /home/sandbox/.bashrc /tmp/.bashrc-ruby
COPY --from=php-stage --chown=sandbox:sandbox /home/sandbox/.bashrc /tmp/.bashrc-php
COPY --from=perl-stage --chown=sandbox:sandbox /home/sandbox/.bashrc /tmp/.bashrc-perl
COPY --from=swift-stage --chown=sandbox:sandbox /home/sandbox/.bashrc /tmp/.bashrc-swift
COPY --from=lean-stage --chown=sandbox:sandbox /home/sandbox/.bashrc /tmp/.bashrc-lean
COPY --from=rocq-stage --chown=sandbox:sandbox /home/sandbox/.bashrc /tmp/.bashrc-rocq

# Merge bashrc configurations: take the essentials bashrc as base,
# then append sections from each language stage that are not yet present.
# Uses section-header deduplication (checks for unique "# <Tool> configuration"
# comment) to avoid corrupting multi-line shell constructs (if/fi blocks) that
# would break when individual lines like bare "fi" are deduplicated.
RUN cp /home/sandbox/.bashrc /tmp/.bashrc-base && \
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
    cp /tmp/.bashrc-base /home/sandbox/.bashrc && \
    chown sandbox:sandbox /home/sandbox/.bashrc && \
    rm -f /tmp/.bashrc-*

# Switch to sandbox user
USER sandbox
WORKDIR /home/sandbox

# Environment variables for all tools
ENV NVM_DIR="/home/sandbox/.nvm"
ENV PYENV_ROOT="/home/sandbox/.pyenv"
ENV BUN_INSTALL="/home/sandbox/.bun"
ENV DENO_INSTALL="/home/sandbox/.deno"
ENV CARGO_HOME="/home/sandbox/.cargo"
ENV GOROOT="/home/sandbox/.go"
ENV GOPATH="/home/sandbox/.go/path"
ENV SDKMAN_DIR="/home/sandbox/.sdkman"
ENV PERLBREW_ROOT="/home/sandbox/.perl5"
ENV RBENV_ROOT="/home/sandbox/.rbenv"

# PATH for tools that don't need special initialization
# Includes Homebrew PHP paths (only effective if local install was used, harmless otherwise)
ENV PATH="/home/linuxbrew/.linuxbrew/opt/php@8.3/bin:/home/linuxbrew/.linuxbrew/opt/php@8.3/sbin:/home/linuxbrew/.linuxbrew/bin:/home/sandbox/.pyenv/bin:/home/sandbox/.pyenv/shims:/home/sandbox/.rbenv/bin:/home/sandbox/.rbenv/shims:/home/sandbox/.swift/usr/bin:/home/sandbox/.elan/bin:/home/sandbox/.opam/default/bin:/home/sandbox/.cargo/bin:/home/sandbox/.deno/bin:/home/sandbox/.bun/bin:/home/sandbox/.go/bin:/home/sandbox/.go/path/bin:${PATH}"

# Opam environment variables for Rocq/Coq theorem prover
ENV OPAM_SWITCH_PREFIX="/home/sandbox/.opam/default"
ENV CAML_LD_LIBRARY_PATH="/home/sandbox/.opam/default/lib/stublibs:/home/sandbox/.opam/default/lib/ocaml/stublibs:/home/sandbox/.opam/default/lib/ocaml"
ENV OCAML_TOPLEVEL_PATH="/home/sandbox/.opam/default/lib/toplevel"

SHELL ["/bin/bash", "-c"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash"]
