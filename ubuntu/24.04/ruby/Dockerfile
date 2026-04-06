ARG ESSENTIALS_IMAGE=konard/box-essentials:latest
FROM ${ESSENTIALS_IMAGE}
# Build: docker build -f ubuntu/24.04/ruby/Dockerfile --build-arg ESSENTIALS_IMAGE=box-essentials -t box-ruby .

# Ruby box: rbenv + latest stable Ruby 3.x
# Built on top of essentials-box (inherits JS, git, gh, glab, dev libraries including libyaml-dev)

USER box

COPY --chown=box:box ubuntu/24.04/common.sh /tmp/common.sh
COPY --chown=box:box ubuntu/24.04/ruby/install.sh /tmp/install.sh
RUN chmod +x /tmp/install.sh /tmp/common.sh && \
    bash /tmp/install.sh && \
    rm -f /tmp/install.sh /tmp/common.sh

WORKDIR /home/box

ENV RBENV_ROOT="/home/box/.rbenv"
ENV PATH="/home/box/.rbenv/bin:/home/box/.rbenv/shims:${PATH}"

SHELL ["/bin/bash", "-c"]
CMD ["/bin/bash"]
