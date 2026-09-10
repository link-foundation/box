#!/usr/bin/env bash
# Measure what `WORKDIR /home/box` before `useradd -m` costs, and what the fix
# for it must not cost in exchange.
#
# ubuntu/24.04/js/Dockerfile has `WORKDIR /home/box` near the top and creates
# the box user much further down. Docker creates a WORKDIR that does not exist,
# so by the time useradd runs the home directory is already there - and useradd
# then says
#
#   useradd: warning: the home directory /home/box already exists.
#   useradd: Not copying any file from skel directory into it.
#
# which is the warning both JS build jobs printed in run 34366976358. Every
# other image in this repository descends from that one (js -> essentials-box ->
# the rest), so the box user in all of them is the user created there.
#
# The second line is the one that matters: no /etc/skel means no ~/.profile, and
# Ubuntu's skel ~/.profile is what sources ~/.bashrc for a *login* shell. The
# install scripts write their environment into ~/.bashrc.
#
# Four images, identical but for how the box user's home is populated, each
# asked the same three questions - does a login shell see what ~/.bashrc
# exports, does an interactive shell, and does a *non-interactive* `source
# ~/.bashrc`, which is what scripts/entrypoint.sh does:
#
#   early-workdir   the shipped defect: WORKDIR first, useradd -m, no skel;
#   late-workdir    the obvious fix, moving the WORKDIR after the useradd, which
#                   restores ~/.profile and brings skel's guarded .bashrc with
#                   it;
#   shipped         what this branch ships: WORKDIR stays where it is, useradd
#                   -M, and .profile/.bash_logout copied back explicitly;
#   shipped+bashrc  the same, plus skel's .bashrc - the variant that shows why
#                   the third skel file is deliberately left out.
#
# Needs docker. Usage: bash experiments/issue-123/repro-workdir-skips-skel.sh
set -uo pipefail

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The probe every variant runs, once its box user exists.
probe() {
  cat <<'DF'
RUN su - box -c 'echo "export BOX_MARKER=from-bashrc" >> ~/.bashrc'
RUN echo "--- ls -a /home/box ---" && ls -a /home/box && \
    echo "--- non-interactive login shell (su - box, how the Dockerfile runs install.sh) ---" && \
    su - box -c 'echo "BOX_MARKER=${BOX_MARKER:-UNSET}"' && \
    echo "--- interactive non-login shell (docker run -it box bash) ---" && \
    su box -c 'bash -i -c "echo BOX_MARKER=\${BOX_MARKER:-UNSET}"' 2>/dev/null && \
    echo "--- interactive login shell (docker run -it box bash -l, ssh, su - box) ---" && \
    su box -c 'bash -li -c "echo BOX_MARKER=\${BOX_MARKER:-UNSET}"' 2>/dev/null && \
    echo "--- non-interactive source, the way scripts/entrypoint.sh loads it ---" && \
    su box -c 'bash -c ". \$HOME/.bashrc; echo BOX_MARKER=\${BOX_MARKER:-UNSET}"' && \
    echo "--- is Ubuntu's own .bashrc still there? ---" && \
    (grep -qF 'case $- in' /home/box/.bashrc && echo 'skel .bashrc: present (interactive guard found)' || echo 'skel .bashrc: ABSENT - the file holds only what the install scripts appended')
DF
}

create_m() {
  cat <<'DF'
RUN groupadd box && \
    useradd -m -g box -d /home/box -s /bin/bash box && \
    passwd -d box && \
    chown box:box /home/box && \
    chmod 2775 /home/box
DF
}

create_M() {
  local extra="${1:-}"
  cat <<DF
RUN groupadd box && \\
    useradd -M -g box -d /home/box -s /bin/bash box && \\
    cp -a /etc/skel/.profile /etc/skel/.bash_logout ${extra}/home/box/ && \\
    passwd -d box && \\
    chown -R box:box /home/box && \\
    chmod 2775 /home/box
DF
}

{
  printf 'FROM ubuntu:24.04\nWORKDIR /home/box\n'
  create_m
  probe
} >"$WORK/Dockerfile.early-workdir"

{
  printf 'FROM ubuntu:24.04\n'
  create_m
  probe
  printf 'WORKDIR /home/box\n'
} >"$WORK/Dockerfile.late-workdir"

{
  printf 'FROM ubuntu:24.04\nWORKDIR /home/box\n'
  create_M
  probe
} >"$WORK/Dockerfile.shipped"

{
  printf 'FROM ubuntu:24.04\nWORKDIR /home/box\n'
  create_M '/etc/skel/.bashrc '
  probe
} >"$WORK/Dockerfile.shipped-plus-bashrc"

for variant in early-workdir late-workdir shipped shipped-plus-bashrc; do
  echo "### ${variant}"
  docker build --progress=plain --no-cache \
    -f "$WORK/Dockerfile.${variant}" -t "box-skel-${variant}" "$WORK" 2>&1 \
    | sed -n 's/^#[0-9]* [0-9.]* //p' | grep -vE '^(Reading|Selecting|Preparing|Unpacking|Setting up|Processing|Get:|debconf)' \
    | sed 's/^/  /'
  docker image rm -f "box-skel-${variant}" >/dev/null 2>&1
  echo
done
