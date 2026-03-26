ARG ESSENTIALS_IMAGE=konard/sandbox-essentials:latest
FROM ${ESSENTIALS_IMAGE}
# Build: docker build -f ubuntu/24.04/r/Dockerfile --build-arg ESSENTIALS_IMAGE=sandbox-essentials -t sandbox-r .

# R sandbox: R statistical language
# Built on top of essentials-sandbox (inherits JS, git, gh, glab, dev libraries)

USER root

COPY ubuntu/24.04/common.sh /tmp/common.sh
COPY ubuntu/24.04/r/install.sh /tmp/install.sh
RUN chmod +x /tmp/install.sh /tmp/common.sh && \
    bash /tmp/install.sh && \
    rm -f /tmp/install.sh /tmp/common.sh && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

USER sandbox
WORKDIR /workspace

SHELL ["/bin/bash", "-c"]
CMD ["/bin/bash"]
