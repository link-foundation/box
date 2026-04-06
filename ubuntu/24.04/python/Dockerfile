ARG ESSENTIALS_IMAGE=konard/box-essentials:latest
FROM ${ESSENTIALS_IMAGE}
# Build: docker build -f ubuntu/24.04/python/Dockerfile --build-arg ESSENTIALS_IMAGE=box-essentials -t box-python .

# Python box: Pyenv + latest stable Python
# Built on top of essentials-box (inherits JS, git, gh, glab, dev libraries)

USER box

COPY --chown=box:box ubuntu/24.04/common.sh /tmp/common.sh
COPY --chown=box:box ubuntu/24.04/python/install.sh /tmp/install.sh
RUN chmod +x /tmp/install.sh /tmp/common.sh && \
    bash /tmp/install.sh && \
    rm -f /tmp/install.sh /tmp/common.sh

WORKDIR /home/box

ENV PYENV_ROOT="/home/box/.pyenv"
ENV PATH="/home/box/.pyenv/bin:/home/box/.pyenv/shims:${PATH}"

SHELL ["/bin/bash", "-c"]
CMD ["/bin/bash"]
