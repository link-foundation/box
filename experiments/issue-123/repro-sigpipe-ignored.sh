#!/usr/bin/env bash
# Reproduce: `producer | head` prints `write error: Broken pipe` and fails the
# pipeline on a GitHub Actions runner, where SIGPIPE is ignored.
#
# What the runs showed (issue #123). Two of the nine runs carry error text that
# no check emitted and nothing acted on:
#
#   run 34366975942, security / secretlint, 14:57:00
#     Running secretlint with a 180s budget (warning at 126s).
#     tr: write error: Broken pipe
#     tr: write error: Broken pipe
#     ==> Canary: secretlint must find a planted key before its silence ...
#
#   run 34366976358, full / docker-build-push, 16:06:40
#     --- Runtime freshness and one-version-per-language invariant (issue #112) ---
#     grep: write error: Broken pipe
#     tr: write error: Broken pipe
#     image ships Node v24.21.0, expected major 24
#
# The two producers are:
#
#   scripts/ci/run-secretlint.sh:60   tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"
#   ubuntu/24.04/common.sh:262-264    fetch_release_feed ... | tr '{' '\n' \
#                                       | grep '"lts":"' | head -n1 | sed ...
#
# In both, the reader exits before the writer is done, so the writer's next
# write() hits a pipe with no reader. Normally that is SIGPIPE and the writer
# dies silently, which is why neither line appears when the same command is run
# in a terminal. A GitHub runner is not that environment: the step's shell is
# started by the runner process with SIGPIPE already set to SIG_IGN, bash
# passes an inherited SIG_IGN on to the commands it starts, and an ignored
# SIGPIPE turns the failed write into EPIPE -- which coreutils reports on
# stderr and exits non-zero for.
#
# `trap '' PIPE` reproduces exactly that disposition, with no runner and no
# network: it is the same SIG_IGN, inherited the same way.
#
# Why it is more than log noise: the writer's non-zero status is the pipeline's
# status under `set -o pipefail`, which both files set. The secretlint site
# survives only because its result is an argument to printf, where a failed
# command substitution does not propagate; written as `x=$(rand_alnum 16)` --
# one refactor away -- the same call aborts the script under `set -e`.
#
# Usage: bash experiments/issue-123/repro-sigpipe-ignored.sh
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# A stand-in for nodejs.org/dist/index.json: newest first, and large enough
# that the writer is still writing when `head -n1` leaves.
feed="${work}/index.json"
{
  printf '['
  printf '{"version":"v25.1.0","date":"2026-02-01","lts":false,"security":false},'
  printf '{"version":"v24.21.0","date":"2025-10-01","lts":"Krypton","security":false},'
  # ... and then the rest of the feed. Most of it matches too -- every LTS
  # release ever published carries a codename -- which is what makes `grep`
  # flush before `head -n1` has left, rather than buffering its whole output
  # into a reader that is still there. The real feed has 287 such entries,
  # the first of them 57 records in.
  for i in $(seq 1 4000); do
    printf '{"version":"v20.%d.0","date":"2023-01-01","lts":"Iron","security":false},' "$i"
  done
  printf '{"version":"v18.0.0","date":"2022-01-01","lts":false,"security":false}]'
} >"${feed}"
printf '  feed fixture: %s bytes, %s of them matching lines, newest LTS second.\n' \
  "$(wc -c <"${feed}")" "$(tr '{' '\n' <"${feed}" | grep -c '"lts":"')"
printf '  (Measured 2026-09-10, the real feed is 330601 bytes / 287 matching.) Pipe: 64 KiB.\n'

run_case() {
  local label="$1" disposition="$2" script="$3"
  local out err status
  out="${work}/out"
  err="${work}/err"
  if [ "${disposition}" = ignored ]; then
    bash -c "trap '' PIPE; ${script}" >"${out}" 2>"${err}"
  else
    bash -c "${script}" >"${out}" 2>"${err}"
  fi
  status=$?
  printf '  %-28s SIGPIPE %-8s exit=%-3s stdout=%-18s stderr=%s\n' \
    "${label}" "${disposition}" "${status}" \
    "$(tr -d '\n' <"${out}" | cut -c1-18)" \
    "$(tr '\n' ';' <"${err}")"
}

echo "### 1. the shipped secretlint canary generator"
secretlint_shape='set -euo pipefail
rand_alnum() { LC_ALL=C tr -dc "A-Za-z0-9" </dev/urandom | head -c "$1"; }
printf "%s" "$(rand_alnum 16)"'
run_case "tr </dev/urandom | head" default "${secretlint_shape}"
run_case "tr </dev/urandom | head" ignored "${secretlint_shape}"

echo
echo "### 2. the same generator one refactor away (a bare assignment)"
assignment_shape='set -euo pipefail
rand_alnum() { LC_ALL=C tr -dc "A-Za-z0-9" </dev/urandom | head -c "$1"; }
x=$(rand_alnum 16); printf "%s" "$x"'
run_case "x=\$(rand_alnum 16)" default "${assignment_shape}"
run_case "x=\$(rand_alnum 16)" ignored "${assignment_shape}"

echo
echo "### 3. the shipped Node LTS resolver, over the fixture feed"
resolver_shape="set -euo pipefail
cat '${feed}' | tr '{' '\\n' | grep '\"lts\":\"' | head -n1 \
  | sed -n 's/.*\"version\":\"v\\([0-9][0-9]*\\)\\..*/\\1/p'"
run_case "... | grep | head -n1" default "${resolver_shape}"
run_case "... | grep | head -n1" ignored "${resolver_shape}"

echo
echo "### 4. the reader-bounded forms, which have no early-exiting reader"
bounded_random='set -euo pipefail
x=$(head -c 128 /dev/urandom | LC_ALL=C tr -dc "A-Za-z0-9"); printf "%s" "${x:0:16}"'
run_case "head -c N /dev/urandom | tr" ignored "${bounded_random}"
bounded_resolver="set -euo pipefail
cat '${feed}' | tr '{' '\\n' \
  | awk '/\"lts\":\"/ && !found {
           if (match(\$0, /\"version\":\"v[0-9]+\\./)) {
             major = substr(\$0, RSTART, RLENGTH)
             gsub(/[^0-9]/, \"\", major)
             print major
             found = 1
           }
         }'"
run_case "... | awk (reads to EOF)" ignored "${bounded_resolver}"

echo
echo "### 5. the shipped definitions themselves, unedited"
(
  cd "${repo_root}" || exit 1
  generator="$(sed -n '/^rand_alnum()/,/^}$/p' scripts/ci/run-secretlint.sh)"
  echo "  scripts/ci/run-secretlint.sh: rand_alnum(), as shipped:"
  printf '%s\n' "${generator}" | sed 's/^/      /'
  bash -c "trap '' PIPE
    set -euo pipefail
    ${generator}
    printf 'canary=%s\\n' \"\$(rand_alnum 16)\"" 2>&1 | sed 's/^/    /'

  echo "  ubuntu/24.04/common.sh: resolve_node_lts_major, feed stubbed to the fixture"
  bash -c "trap '' PIPE
    . ubuntu/24.04/common.sh
    fetch_release_feed() { cat '${feed}'; }
    unset NODE_VERSION
    printf 'major=%s\\n' \"\$(resolve_node_lts_major)\"" 2>&1 | sed 's/^/    /'
)
