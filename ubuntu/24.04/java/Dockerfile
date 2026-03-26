ARG ESSENTIALS_IMAGE=konard/sandbox-essentials:latest
FROM ${ESSENTIALS_IMAGE}
# Build: docker build -f ubuntu/24.04/java/Dockerfile --build-arg ESSENTIALS_IMAGE=sandbox-essentials -t sandbox-java .

# Java sandbox: SDKMAN + Eclipse Temurin 21
# Built on top of essentials-sandbox (inherits JS, git, gh, glab, dev libraries)

USER sandbox

COPY --chown=sandbox:sandbox ubuntu/24.04/common.sh /tmp/common.sh
COPY --chown=sandbox:sandbox ubuntu/24.04/java/install.sh /tmp/install.sh
RUN chmod +x /tmp/install.sh /tmp/common.sh && \
    bash /tmp/install.sh && \
    rm -f /tmp/install.sh /tmp/common.sh

WORKDIR /workspace

ENV SDKMAN_DIR="/workspace/.sdkman"

SHELL ["/bin/bash", "-c"]
CMD ["/bin/bash"]
