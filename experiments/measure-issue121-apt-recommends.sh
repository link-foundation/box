#!/usr/bin/env bash
# measure-issue121-apt-recommends.sh
#
# What `--no-install-recommends` would actually change, per DL3015 site.
#
# hadolint reports DL3015 ("Avoid additional packages by specifying
# `--no-install-recommends`") ten times across this repository's Dockerfiles.
# The rule is advisory and the gate does not fail on it, so the question is not
# "does the linter complain" but "what would taking its advice remove". A box
# is a development environment, and a recommended package dropped here is a
# tool missing from someone's shell - so the answer has to be measured rather
# than assumed.
#
# For each package set this runs `apt-get install --dry-run` inside a clean
# `ubuntu:24.04` container twice, with and without the flag, and prints the
# packages that only the recommends-enabled run would install.
#
# This is a measurement, not a test: it needs Docker and the network, it takes
# a couple of minutes, and it is not wired into run-experiments.sh. The result
# it produced is recorded in dev/log/issues/121/pulls/122/apt-recommends/.
#
# Usage:
#   bash experiments/measure-issue121-apt-recommends.sh [set-name ...]
#
# Environment:
#   BOX_VERBOSE=1   trace every command
#   APT_IMAGE       base image to measure in (default ubuntu:24.04)

set -euo pipefail

if [ "${BOX_VERBOSE:-0}" = "1" ]; then
  set -x
fi

IMAGE="${APT_IMAGE:-ubuntu:24.04}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Each entry is `name|file:line|packages`. The package lists are copied from the
# `apt-get install` invocation at that exact location; keep them in step.
SETS=(
  "js-prereqs|ubuntu/24.04/js/Dockerfile:17|curl git sudo ca-certificates unzip"
  "js-playwright|ubuntu/24.04/js/Dockerfile:27|libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 libcairo2 libcups2t64 libdbus-1-3 libdrm2 libgbm1 libglib2.0-0t64 libnspr4 libnss3 libpango-1.0-0 libx11-6 libxcb1 libxcomposite1"
  "essentials-acl|ubuntu/24.04/essentials-box/Dockerfile:32|acl"
  "rocq-bubblewrap|ubuntu/24.04/rocq/Dockerfile:11|bubblewrap"
  "php-global|ubuntu/24.04/php/Dockerfile:47|php-cli php-common php-curl php-mbstring php-xml php-zip php-bcmath php-opcache"
  "full-toolchain|Dockerfile:62|r-base cmake clang llvm lld nasm bubblewrap"
)

WANTED=("$@")

want() {
  [ "${#WANTED[@]}" -eq 0 ] && return 0
  local n
  for n in "${WANTED[@]}"; do
    [ "$n" = "$1" ] && return 0
  done
  return 1
}

# plan — the package names apt would install, one per line, sorted.
#
# `--dry-run` prints `Inst <name> (<version> ...)`; the name is the second
# field. `-o Debug::NoLocking=1` keeps it from wanting the lock as a non-root
# user, which matters only if this is ever run outside the container.
plan() {
  local flag="$1" pkgs="$2"
  docker run --rm "$IMAGE" bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y $flag --dry-run $pkgs 2>/dev/null |
      awk '\$1 == \"Inst\" { print \$2 }' | sort -u
  "
}

printf '%-18s %-40s %8s %8s  %s\n' SET SITE WITH WITHOUT EXTRA
printf '%.0s-' {1..110}
echo

for entry in "${SETS[@]}"; do
  name="${entry%%|*}"
  rest="${entry#*|}"
  site="${rest%%|*}"
  pkgs="${rest#*|}"
  want "$name" || continue

  with="$(plan '' "$pkgs")"
  without="$(plan '--no-install-recommends' "$pkgs")"
  n_with="$(printf '%s\n' "$with" | grep -c . || true)"
  n_without="$(printf '%s\n' "$without" | grep -c . || true)"
  extra="$(comm -23 <(printf '%s\n' "$with") <(printf '%s\n' "$without") | tr '\n' ' ')"

  printf '%-18s %-40s %8s %8s  %s\n' "$name" "$site" "$n_with" "$n_without" "${extra:-<none>}"
done
