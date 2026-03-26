ARG ESSENTIALS_IMAGE=konard/sandbox-essentials:latest
FROM ${ESSENTIALS_IMAGE}
# Build: docker build -f ubuntu/24.04/swift/Dockerfile --build-arg ESSENTIALS_IMAGE=sandbox-essentials -t sandbox-swift .

# Swift sandbox: Swift 6.0.3
# Built on top of essentials-sandbox (inherits JS, git, gh, glab, dev libraries)

USER sandbox

COPY --chown=sandbox:sandbox ubuntu/24.04/common.sh /tmp/common.sh
COPY --chown=sandbox:sandbox ubuntu/24.04/swift/install.sh /tmp/install.sh
RUN chmod +x /tmp/install.sh /tmp/common.sh && \
    bash /tmp/install.sh && \
    rm -f /tmp/install.sh /tmp/common.sh

WORKDIR /workspace

ENV PATH="/workspace/.swift/usr/bin:${PATH}"

SHELL ["/bin/bash", "-c"]
CMD ["/bin/bash"]
