# Verifies the two issue #115 opam fixes against the published images:
#  1. ubuntu/24.04/rocq/Dockerfile      -> ~/.local/bin on PATH
#  2. ubuntu/24.04/full-box/Dockerfile  -> COPY the opam binary out of rocq-stage
FROM konard/box-rocq:latest AS rocq-stage
ENV PATH="/home/box/.local/bin:${PATH}"
RUN opam --version && rocq --version

FROM konard/box:latest AS full-stage
COPY --from=rocq-stage /home/box/.local/bin/opam /usr/local/bin/opam
RUN opam --version && rocq --version
