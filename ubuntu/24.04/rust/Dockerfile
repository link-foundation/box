ARG ESSENTIALS_IMAGE=konard/sandbox-essentials:latest
FROM ${ESSENTIALS_IMAGE}
# Build: docker build -f ubuntu/24.04/rust/Dockerfile --build-arg ESSENTIALS_IMAGE=sandbox-essentials -t sandbox-rust .

# Rust sandbox: rustup + latest stable Rust
# Built on top of essentials-sandbox (inherits JS, git, gh, glab, dev libraries)

USER sandbox

COPY --chown=sandbox:sandbox ubuntu/24.04/common.sh /tmp/common.sh
COPY --chown=sandbox:sandbox ubuntu/24.04/rust/install.sh /tmp/install.sh
RUN chmod +x /tmp/install.sh /tmp/common.sh && \
    bash /tmp/install.sh && \
    rm -f /tmp/install.sh /tmp/common.sh

WORKDIR /workspace

ENV CARGO_HOME="/workspace/.cargo"
ENV PATH="/workspace/.cargo/bin:${PATH}"

SHELL ["/bin/bash", "-c"]
CMD ["/bin/bash"]
