ARG ESSENTIALS_IMAGE=konard/box-essentials:latest
FROM ${ESSENTIALS_IMAGE}
# Build: docker build -f ubuntu/24.04/rust/Dockerfile --build-arg ESSENTIALS_IMAGE=box-essentials -t box-rust .

# Rust box: rustup + latest stable Rust
# Built on top of essentials-box (inherits JS, git, gh, glab, dev libraries)

USER box

COPY --chown=box:box ubuntu/24.04/common.sh /tmp/common.sh
COPY --chown=box:box ubuntu/24.04/rust/install.sh /tmp/install.sh
RUN chmod +x /tmp/install.sh /tmp/common.sh && \
    bash /tmp/install.sh && \
    rm -f /tmp/install.sh /tmp/common.sh

WORKDIR /home/box

ENV CARGO_HOME="/home/box/.cargo"
ENV PATH="/home/box/.cargo/bin:${PATH}"

SHELL ["/bin/bash", "-c"]
CMD ["/bin/bash"]
