ARG ESSENTIALS_IMAGE=konard/box-essentials:latest
FROM ${ESSENTIALS_IMAGE}
# Build: docker build -f ubuntu/24.04/rocq/Dockerfile --build-arg ESSENTIALS_IMAGE=box-essentials -t box-rocq .

# Rocq/Coq box: Opam + Rocq theorem prover
# Built on top of essentials-box (inherits JS, git, gh, glab, dev libraries)

USER root
RUN apt-get update -y && apt-get install -y bubblewrap && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

USER box

COPY --chown=box:box ubuntu/24.04/common.sh /tmp/common.sh
COPY --chown=box:box ubuntu/24.04/rocq/install.sh /tmp/install.sh
RUN chmod +x /tmp/install.sh /tmp/common.sh && \
    bash /tmp/install.sh && \
    rm -f /tmp/install.sh /tmp/common.sh

WORKDIR /home/box

ENV OPAM_SWITCH_PREFIX="/home/box/.opam/default"
ENV CAML_LD_LIBRARY_PATH="/home/box/.opam/default/lib/stublibs:/home/box/.opam/default/lib/ocaml/stublibs:/home/box/.opam/default/lib/ocaml"
ENV OCAML_TOPLEVEL_PATH="/home/box/.opam/default/lib/toplevel"
ENV PATH="/home/box/.opam/default/bin:${PATH}"

SHELL ["/bin/bash", "-c"]
CMD ["/bin/bash"]
