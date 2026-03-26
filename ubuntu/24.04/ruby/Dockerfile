ARG ESSENTIALS_IMAGE=konard/sandbox-essentials:latest
FROM ${ESSENTIALS_IMAGE}
# Build: docker build -f ubuntu/24.04/ruby/Dockerfile --build-arg ESSENTIALS_IMAGE=sandbox-essentials -t sandbox-ruby .

# Ruby sandbox: rbenv + latest stable Ruby 3.x
# Built on top of essentials-sandbox (inherits JS, git, gh, glab, dev libraries including libyaml-dev)

USER sandbox

COPY --chown=sandbox:sandbox ubuntu/24.04/common.sh /tmp/common.sh
COPY --chown=sandbox:sandbox ubuntu/24.04/ruby/install.sh /tmp/install.sh
RUN chmod +x /tmp/install.sh /tmp/common.sh && \
    bash /tmp/install.sh && \
    rm -f /tmp/install.sh /tmp/common.sh

WORKDIR /workspace

ENV RBENV_ROOT="/workspace/.rbenv"
ENV PATH="/workspace/.rbenv/bin:/workspace/.rbenv/shims:${PATH}"

SHELL ["/bin/bash", "-c"]
CMD ["/bin/bash"]
