ARG ESSENTIALS_IMAGE=konard/sandbox-essentials:latest
FROM ${ESSENTIALS_IMAGE}
# Build: docker build -f ubuntu/24.04/perl/Dockerfile --build-arg ESSENTIALS_IMAGE=sandbox-essentials -t sandbox-perl .

# Perl sandbox: Perlbrew + latest stable Perl
# Built on top of essentials-sandbox (inherits JS, git, gh, glab, dev libraries)

USER sandbox

COPY --chown=sandbox:sandbox ubuntu/24.04/common.sh /tmp/common.sh
COPY --chown=sandbox:sandbox ubuntu/24.04/perl/install.sh /tmp/install.sh
RUN chmod +x /tmp/install.sh /tmp/common.sh && \
    bash /tmp/install.sh && \
    rm -f /tmp/install.sh /tmp/common.sh

WORKDIR /workspace

ENV PERLBREW_ROOT="/workspace/.perl5"

SHELL ["/bin/bash", "-c"]
CMD ["/bin/bash"]
