#!/usr/bin/env bash
set -euo pipefail

logs="$(mktemp -d)"
trap 'rm -rf "$logs"' EXIT

for ((trial = 0; trial < 60; trial++)); do
  # A producer that handles EPIPE emits the same warning as the CI log.
  (
    trap '' PIPE
    ldd --version
  ) | head -n1 >/dev/null
done 2>>"$logs/head"

for ((trial = 0; trial < 60; trial++)); do
  (
    trap '' PIPE
    ldd --version
  ) | sed -n '1p' >/dev/null
done 2>"$logs/sed"

printf 'head diagnostics: %s\n' "$(wc -l <"$logs/head")"
printf 'sed diagnostics: %s\n' "$(wc -l <"$logs/sed")"
head -n 4 "$logs/head"
test ! -s "$logs/sed"
