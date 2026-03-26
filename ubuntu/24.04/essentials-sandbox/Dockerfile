ARG JS_IMAGE=konard/sandbox-js:latest
FROM ${JS_IMAGE}

# Essentials Sandbox Docker image
# Built on top of the JS sandbox, adds git identity tools (gh, glab)
# Published as: konard/sandbox-essentials
#
# Build from repository root:
#   docker build -f ubuntu/24.04/essentials-sandbox/Dockerfile -t sandbox-essentials .
#
# Build with specific JS image:
#   docker build -f ubuntu/24.04/essentials-sandbox/Dockerfile \
#     --build-arg JS_IMAGE=konard/sandbox-js:latest -t sandbox-essentials .

USER root

ENV DEBIAN_FRONTEND=noninteractive

# Copy install script
COPY ubuntu/24.04/common.sh /tmp/common.sh
COPY ubuntu/24.04/essentials-sandbox/install.sh /tmp/install.sh
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /tmp/install.sh /tmp/common.sh /usr/local/bin/entrypoint.sh && \
    DOCKER_BUILD=1 bash /tmp/install.sh && \
    rm -f /tmp/install.sh /tmp/common.sh

# Install ACL support for shared group permissions on /workspace
RUN apt-get update -y && apt-get install -y acl && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    setfacl -R -m g:sandbox:rwx /workspace && \
    setfacl -d -m g:sandbox:rwx /workspace

USER sandbox
WORKDIR /workspace

# Environment variables inherited from JS sandbox base image
# Additional ones for essentials are not needed (gh, glab are system-wide)

SHELL ["/bin/bash", "-c"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash"]
