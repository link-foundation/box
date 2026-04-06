ARG ESSENTIALS_IMAGE=konard/box-essentials:latest
FROM ${ESSENTIALS_IMAGE}
# Build: docker build -f ubuntu/24.04/lean/Dockerfile --build-arg ESSENTIALS_IMAGE=box-essentials -t box-lean .

# Lean box: Lean theorem prover via elan
# Built on top of essentials-box (inherits JS, git, gh, glab, dev libraries)

USER box

COPY --chown=box:box ubuntu/24.04/common.sh /tmp/common.sh
COPY --chown=box:box ubuntu/24.04/lean/install.sh /tmp/install.sh
RUN chmod +x /tmp/install.sh /tmp/common.sh && \
    bash /tmp/install.sh && \
    rm -f /tmp/install.sh /tmp/common.sh

WORKDIR /home/box

ENV PATH="/home/box/.elan/bin:${PATH}"

SHELL ["/bin/bash", "-c"]
CMD ["/bin/bash"]
