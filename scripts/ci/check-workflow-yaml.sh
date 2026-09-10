#!/usr/bin/env bash
# check-workflow-yaml.sh
#
# Every tracked workflow and composite action parses as YAML.
#
# Why this exists (issue #123)
# ----------------------------
#
# This branch replaced eighteen hand-rolled VERSION reads with a call to a
# helper. In three of the steps the old `run: |` block had a fourth line the
# others did not, and the replacement did not consume it, leaving:
#
#   run: bash scripts/release/release-version.sh
#     echo "Building version: $VERSION"
#
# which is not YAML. `release-full.yml` was unparseable, and the four gates that
# read workflows - status-gate, timeout-budgets, path-coverage and
# checkout-credentials - were each handed that file and each exited 0, printing
# a verdict about it. Measured, on the broken file:
#
#   check-status-gate-covers-all-jobs.mjs  EXIT=0  status covers all 3 other job(s).
#   check-timeout-budgets.mjs              EXIT=0  Every budget in 1 workflow(s) fits inside its job cap
#   check-workflow-path-coverage.mjs       EXIT=0  6 script(s) across 1 workflow(s); every file ... can start a run
#   check-checkout-credentials.mjs         EXIT=0  3 checkout step(s) across 1 file(s); each one states ...
#
# All four read workflows line by line, on purpose - they ask questions about
# ordering and indentation that a parsed tree throws away. That is a reasonable
# design and it is why none of them noticed: a line-oriented reader cannot tell
# a file it disagrees with from a file no parser accepts. So the guarantee they
# each assume has to be established somewhere, once, and this is that place.
#
# It is the same defect this whole issue is about - a check reporting a verdict
# about data it never obtained - and it was found in this branch's own edit, by
# the experiment suite, after eleven local gates had passed it.
#
# What this does not catch, stated because a gate's limits belong next to it:
# an orphan line with no colon in it is a legal plain-scalar continuation, so
#
#   run: bash scripts/release/release-version.sh
#     echo hello
#
# parses, as the string "bash scripts/release/release-version.sh echo hello".
# YAML validity is the floor, not the ceiling; actionlint's schema is what
# reads the parsed tree, and it runs in CI. The three orphans that shipped here
# all contained `version: `, which is why this floor was enough to find them.
#
# actionlint catches this in CI, but only there: it needs docker, so the
# pre-commit hook cannot run it, and the broken file was committable. Ruby ships
# psych in its standard library and is present on the runners and in the
# development image, so this gate is offline and costs milliseconds.
#
# Usage:
#   bash scripts/ci/check-workflow-yaml.sh [--list-inputs] [FILE...]
#
# With no arguments it checks every tracked workflow and composite action.
#
#   --list-inputs  print the repository-relative path of every file this gate
#                  reads, one per line, and exit. check-workflow-path-coverage
#                  reads that list to verify a workflow's `paths:` filter
#                  actually re-runs this check when one of them changes.
#
# Exit codes:
#   0 = every file parsed
#   1 = at least one file did not parse
#   2 = the check could not run (no ruby, not a repository, nothing to check)

set -uo pipefail

TITLE='check-workflow-yaml'

fail() {
  echo "::error title=${TITLE}::$1" >&2
  exit 2
}

if ! command -v ruby >/dev/null 2>&1; then
  fail 'ruby is not installed, so no workflow could be parsed'
fi

if ! ruby -ryaml -e '' >/dev/null 2>&1; then
  fail 'this ruby cannot load psych, so no workflow could be parsed'
fi

LIST_INPUTS=0
FILES=()

for arg in "$@"; do
  case "$arg" in
    --list-inputs) LIST_INPUTS=1 ;;
    -h | --help)
      sed -n '2,60p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    -*) fail "unknown option '${arg}'" ;;
    *) FILES+=("$arg") ;;
  esac
done

if [ "${#FILES[@]}" -eq 0 ] || [ "$LIST_INPUTS" -eq 1 ]; then
  # `git ls-files` answers about the current directory, not the repository: run
  # from a subdirectory it lists that subtree alone and exits 0 over it, which
  # reads exactly like a clean tree (issue #121). Anchor at the top of whichever
  # repository the caller is standing in, so the fixtures can still drive this
  # inside a throwaway one.
  if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    fail 'not inside a git repository, so no workflow could be discovered'
  fi

  cd "$REPO_ROOT" || fail "could not enter ${REPO_ROOT}"

  # `git ls-files` can fail, and a failed read must not look like a clean tree
  # (issue #123, RC-17): the list is built first and its status is checked.
  if ! LISTED="$(git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml' '.github/actions/*.yml' '.github/actions/*.yaml')"; then
    fail 'git ls-files could not list the workflows, so none were checked'
  fi

  DISCOVERED=()

  while IFS= read -r file; do
    [ -n "$file" ] && DISCOVERED+=("$file")
  done <<<"$LISTED"

  if [ "$LIST_INPUTS" -eq 1 ]; then
    if [ "${#DISCOVERED[@]}" -eq 0 ]; then
      fail 'no workflows or composite actions found; this check verified nothing'
    fi

    printf '%s\n' "${DISCOVERED[@]}"
    exit 0
  fi

  FILES=("${DISCOVERED[@]}")
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  fail 'no workflows or composite actions found; this check verified nothing'
fi

BAD=0

for file in "${FILES[@]}"; do
  if [ ! -r "$file" ]; then
    fail "${file} is not readable, so it could not be parsed"
  fi

  # The parse error goes through a here-string rather than being echoed, so a
  # message containing `::` cannot open an annotation of its own.
  if ! ERR="$(ruby -ryaml -e 'YAML.load_file(ARGV[0])' "$file" 2>&1)"; then
    WHERE="$(sed -n 's/.*at line \([0-9]*\) column \([0-9]*\).*/\1/p' <<<"$ERR" | head -1)"
    # psych's first line is "<backtrace>: (<file>): <reason> (Psych::SyntaxError)".
    # Keep the reason: the file is already in the annotation's own file= field,
    # and the backtrace is this gate's ruby, not the reader's problem.
    REASON="$(head -1 <<<"$ERR" | sed -e 's/.*): //' -e 's/ (Psych::SyntaxError)$//')"
    [ -n "$REASON" ] || REASON="$(head -1 <<<"$ERR")"
    printf '::error file=%s%s,title=%s::%s does not parse as YAML: %s\n' \
      "$file" "${WHERE:+,line=${WHERE}}" "$TITLE" "$file" \
      "$(sed -e 's/::/:_:/g' -e 's/##\[/#_[/g' <<<"$REASON")" >&2
    BAD=$((BAD + 1))
  fi
done

if [ "$BAD" -gt 0 ]; then
  echo "::error title=${TITLE}::${BAD} of ${#FILES[@]} file(s) do not parse as YAML" >&2
  exit 1
fi

echo "${TITLE}: ${#FILES[@]} workflow(s) and composite action(s) parse as YAML."
