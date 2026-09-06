#!/usr/bin/env bash
# run-shfmt.sh
#
# Formats, or checks the formatting of, every tracked shell script.
#
# Why this exists (issue #115, template best practice #3, "automated code
# formatting"). The template runs prettier over a repository written in
# JavaScript; this repository is written in shell, and had no formatter at all.
# Formatting arguments are the cheapest possible review comment and the least
# valuable, and hand-formatting drifts: before this landed, 75 of the 98
# tracked scripts disagreed with a single consistent style, including files
# edited in the same week.
#
# What it mostly does not do: change behaviour. shfmt parses the script and
# prints the syntax tree back out, so a reformat is nearly always inert - which
# is why applying it to 73 files at once was tractable at all.
#
# Nearly. It is not inert, and this repository has the counter-example: shfmt
# formats an array subscript as an arithmetic expression, so
# `[node-lts-integration-test.sh]=...` in scripts/ci/run-experiments.sh came
# back as `[node - lts - integration - test.sh]=...`. Bash does not evaluate
# the subscript of an associative array, so that is a different key; three skip
# entries stopped matching and nothing said so. Two conclusions, both acted on:
# quote every associative-array subscript (asserted by
# experiments/test-issue115-shfmt-gate.sh), and treat "the 39 regression suites
# still pass" as the evidence that a reformat was safe rather than as a
# formality - it is what caught this one.
#
# Style: -i 2 (two-space indent, the repository's existing convention), -ci
# (indent switch cases) and -bn (break before a binary operator, so a long `||`
# chain reads down the left margin). Chosen by measuring all six candidate
# combinations against the tree and taking the one that moved the fewest lines.
#
# Discovery, not a list: the file set comes from git, so a script added in a
# later pull request is formatted from the moment it lands. dev/log/ is
# excluded because it holds verbatim copies of other projects' files, collected
# as issue evidence; they are not ours to reformat.
#
# Usage:
#   bash scripts/ci/run-shfmt.sh            # check; non-zero if anything differs
#   bash scripts/ci/run-shfmt.sh --fix      # rewrite the files in place
#   bash scripts/ci/run-shfmt.sh --list     # print the file set, format nothing
#   bash scripts/ci/run-shfmt.sh path/to.sh # only these files
#
# Environment:
#   SHFMT_IMAGE    Docker image used when shfmt is not on PATH
#   BOX_VERBOSE=1  Trace every command this script runs
#
# Exit codes:
#   0  every file is formatted (or was rewritten by --fix)
#   1  at least one file differs from the formatter's output
#   2  shfmt could not run, or ran without producing a usable answer

set -euo pipefail

if [ "${BOX_VERBOSE:-0}" = "1" ]; then
  set -x
fi

IMAGE="${SHFMT_IMAGE:-mvdan/shfmt:v3.10.0}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STYLE=(-i 2 -ci -bn)

cd "$REPO_ROOT"

collect_files() {
  git ls-files -z --cached --others --exclude-standard --deduplicate '*.sh' \
    | tr '\0' '\n' | grep -v '^dev/log/' | sort -u || true
}

MODE=check
FILES=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fix)
      MODE=fix
      shift
      ;;
    --list)
      MODE=list
      shift
      ;;
    -h | --help)
      sed -n '2,43p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    -*)
      echo "run-shfmt.sh: unknown option $1" >&2
      exit 2
      ;;
    *)
      FILES+=("$1")
      shift
      ;;
  esac
done

if [ "${#FILES[@]}" -eq 0 ]; then
  while IFS= read -r f; do
    [ -n "$f" ] && FILES+=("$f")
  done < <(collect_files)
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "==> No shell scripts to format"
  exit 0
fi

if [ "$MODE" = "list" ]; then
  printf '%s\n' "${FILES[@]}"
  exit 0
fi

if command -v shfmt >/dev/null 2>&1; then
  RUNNER=(shfmt)
elif command -v docker >/dev/null 2>&1; then
  echo "==> shfmt not on PATH; using ${IMAGE}"
  # --user matters for --fix: the container's default user is root, and
  # `shfmt -w` replaces each file rather than writing through the inode, so
  # without this every reformatted file comes back owned by root. On a machine
  # where the checkout is not root's - a developer's laptop, this repository's
  # own dev container - the next edit then fails with "Permission denied", and
  # the person who ran a formatter gets a tree they cannot write to. Found by
  # experiments/test-issue115-shfmt-gate.sh, which reruns the fixture after
  # --fix and could not read it back.
  RUNNER=(docker run --rm --user "$(id -u):$(id -g)" -v "$REPO_ROOT:/mnt" -w /mnt "$IMAGE")
else
  echo "::error title=shfmt unavailable::Neither shfmt nor docker is available, so the shell scripts were not formatted. Install shfmt (https://github.com/mvdan/sh) or Docker."
  exit 2
fi

if [ "$MODE" = "fix" ]; then
  echo "==> shfmt -w over ${#FILES[@]} shell script(s)"
  "${RUNNER[@]}" "${STYLE[@]}" -w "${FILES[@]}"
  echo "==> Done. Review the diff before committing."
  exit 0
fi

echo "==> shfmt -d over ${#FILES[@]} shell script(s)"

# The formatter's own self-check. A gate whose silence is indistinguishable
# from "the gate did not run" is the false negative this repository keeps
# finding (RC-16), and shfmt is easy to invoke in a way that reports nothing:
# a bad mount path makes it see an empty file set and exit 0. So hand it a
# file that is definitely misformatted and require it to say so.
CANARY="$(mktemp "$REPO_ROOT/.shfmt-canary-XXXXXX.sh")"
trap 'rm -f "$CANARY"' EXIT
printf 'if true; then\n    echo "four spaces"\nfi\n' >"$CANARY"

# Captured, not piped: `shfmt -d` exits 1 when it finds a difference, and under
# `set -o pipefail` that status wins over grep's, so `shfmt -d ... | grep -q`
# reports "no difference found" precisely when a difference was found. The
# first version of this self-check failed for that reason - a false positive
# produced by the check meant to rule out false negatives.
CANARY_DIFF="$("${RUNNER[@]}" "${STYLE[@]}" -d "${CANARY#"$REPO_ROOT"/}" 2>/dev/null || true)"
if printf '%s' "$CANARY_DIFF" | grep -q '^-'; then
  rm -f "$CANARY"
  trap - EXIT
else
  echo "::error title=shfmt self-check failed::shfmt reported no difference on a deliberately misformatted file, so a clean result here would prove nothing. The invocation or the mount is wrong."
  exit 2
fi

set +e
DIFF="$("${RUNNER[@]}" "${STYLE[@]}" -d "${FILES[@]}" 2>&1)"
STATUS=$?
set -e

if [ "$STATUS" -eq 0 ] && [ -z "$DIFF" ]; then
  echo "==> Every shell script matches shfmt ${STYLE[*]}"
  exit 0
fi

echo "$DIFF"

# One annotation per file, on its first line: the diff itself is in the log,
# and a per-hunk annotation on a whitespace change is noise.
UNFORMATTED="$(printf '%s\n' "$DIFF" | sed -n 's/^--- \([^ ]*\)\.orig$/\1/p' | sort -u)"
COUNT=0
while IFS= read -r file; do
  [ -n "$file" ] || continue
  COUNT=$((COUNT + 1))
  echo "::error file=${file},line=1::Not formatted. Run: bash scripts/ci/run-shfmt.sh --fix"
done <<<"$UNFORMATTED"

if [ "$COUNT" -eq 0 ]; then
  echo "::error title=shfmt could not run::shfmt exited ${STATUS} without naming a single file. Its output is above."
  exit 2
fi

echo ""
echo "==> ${COUNT} shell script(s) are not formatted"
echo "==> Fix them all with: bash scripts/ci/run-shfmt.sh --fix"
exit 1
