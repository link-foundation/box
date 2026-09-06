FROM konard/box-lean:latest
ENV PATH="/home/box/.elan/bin:${PATH}"
RUN elan toolchain install stable && elan default stable && elan toolchain list && lean --version
