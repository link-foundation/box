#!/usr/bin/env bash
#
# check-mjs-syntax.sh — parse every JavaScript module in the repository.
#
# Issue #121. This repository is Dockerfiles and shell, so the handful of
# JavaScript in it is easy to forget: `git ls-files '*.mjs'` outside dev/log/
# returns 13 files, and before this check existed only 4 of them were ever
# parsed by CI. Two run in `workflows`; two more are executed by the
# links-recheck suite. The other nine — the seven ranking fetchers under
# scripts/language-tops/ and the three .mjs probes in experiments/ — were read
# by nothing at all: shellcheck and shfmt take *.sh, `run-experiments.sh`
# discovers *.sh, and no workflow names them.
#
# A syntax error in one of those files is invisible until the day somebody runs
# it, and the two that are only *executed* on the recovery path — links.yml runs
# recheck-broken-links.mjs when lychee has already failed — would break exactly
# when they are needed and never before. That is the same shape as every other
# finding in issue #121: a defect that no run reports, because no run looks.
#
# `node --check` is what the js template's scripts/check-mjs-syntax.sh does, and
# it costs milliseconds per file. This is that gate, with this repository's
# discovery (tracked files, not three hard-coded directory names) and one added
# rule, below.
#
# WHAT IT CHECKS
#   1. Every tracked *.mjs and *.js file outside dev/log/ parses: `node --check`.
#   2. Every relative import specifier in those files resolves to a file that
#      exists. `import { x } from './helpers.mjs'` after helpers.mjs is renamed
#      is a syntactically perfect module that throws ERR_MODULE_NOT_FOUND on
#      first use — the dormant-until-needed failure again, one level up from
#      syntax. Bare specifiers ('node:fs', a package name) are not resolved
#      here: there is no node_modules in this repository to resolve them
#      against, and inventing one would make the check report on the runner's
#      state rather than on the tree.
#
# WHAT IT DOES NOT FLAG
#   Anything that needs the module to run: an undefined variable, a wrong
#   argument, a renamed export. `node --check` is a parse, not an execution, and
#   executing these files as a gate would mean network calls and side effects.
#   The behaviour of the four .mjs files CI depends on is asserted by
#   experiments/test-issue121-links-recheck.sh, test-issue121-timeout-budgets.sh
#   and test-issue121-pipeline-status-gate.sh instead.
#
#   Rule 2 reads relative specifiers with a line-oriented match, so a specifier
#   built at run time (`import('./' + name)`) is not resolved, and neither is
#   one that appears inside a string literal that happens to spell an import.
#
# USAGE
#   scripts/ci/check-mjs-syntax.sh [--verbose] [--list-inputs] [file ...]
#
#   With no files, checks every tracked *.mjs and *.js outside dev/log/, which
#   holds verbatim copies of other projects' sources collected as issue
#   evidence and is not ours to fix.
#   --verbose (default off) names every file as it is parsed and every
#   specifier as it is resolved.
#
# EXIT
#   0 = every file parses and every relative specifier resolves
#   1 = at least one file does not
#   2 = the check could not run (no node, no files, bad usage)

set -euo pipefail

VERBOSE=0
LIST_INPUTS=0
FILES=()

# The `|| true` this function used to end with is gone (issue #123, RC-17).
# `git ls-files … || true` turns a git that could not read the index into an
# empty list, and this gate then reported that emptiness as "the discovery glob
# is wrong" — sending whoever reads it to check a glob that was never the
# problem. The two answers are told apart below, and git's own stderr is left
# alone so the reason arrives with the refusal.
collect_files() {
  local listing
  # grep's exit 1 ("selected nothing") is a legitimately empty tree, not an
  # error; git's status is the one that has to survive the pipeline.
  listing="$(
    git ls-files -- '*.mjs' '*.js'
    exit "${PIPESTATUS[0]}"
  )" || return 1
  printf '%s\n' "$listing" | { grep -v '^dev/log/' || [ "$?" = 1 ]; }
}

# discover_or_exit - collect_files with its two empty answers told apart, and
# neither of them reported as a clean run. Called unsubshelled it ends the
# script; called inside `$(...)` the status propagates, which is why every
# caller pairs it with `|| exit $?`.
discover_or_exit() {
  local listing
  if ! listing="$(collect_files)"; then
    echo "::error title=check-mjs-syntax::could not list this repository's files - git ls-files failed and printed the reason above. Nothing was parsed; this is not a clean run." >&2
    exit 2
  fi
  if [ -z "$listing" ]; then
    echo "::error title=check-mjs-syntax::discovery matched no JavaScript file at all. Either the globs ('*.mjs', '*.js') are wrong or this is not the repository they were written for; a gate that read nothing must not report a clean tree." >&2
    exit 2
  fi
  printf '%s\n' "$listing"
}

# `git ls-files` answers about the current directory, not about the repository:
# run from a subdirectory it lists that subtree alone, and lists it with paths
# relative to that subdirectory. A gate that discovers its own inputs without
# anchoring first therefore sweeps a fraction of the tree and exits 0 over it,
# which reads exactly like a clean repository — and answers --list-inputs with
# paths no repository-root `paths:` pattern can match, so the coverage gate
# above it sees either everything or nothing as a finding (issue #121).
#
# The anchor is the top of whichever repository the caller is standing in, not
# this script's own location: the fixtures drive it inside throwaway
# repositories, and it has to report on the one it was pointed at.
anchor_at_repository_root() {
  local root
  if ! root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    echo "check-mjs-syntax.sh: not inside a git repository and no files given" >&2
    exit 2
  fi
  cd "$root" || exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --verbose)
      VERBOSE=1
      shift
      ;;
    --list-inputs)
      LIST_INPUTS=1
      shift
      ;;
    -h | --help)
      sed -n '2,58p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    --)
      shift
      FILES+=("$@")
      break
      ;;
    -*)
      echo "check-mjs-syntax.sh: unknown option $1" >&2
      exit 2
      ;;
    *)
      FILES+=("$1")
      shift
      ;;
  esac
done

# The discovered set, one repository-relative path per line, nothing else,
# exit 0. scripts/ci/check-workflow-path-coverage.mjs reads it to check that a
# change to any of these files can start the workflow that runs this gate — a
# `paths:` filter matching none of them makes the job unreachable, which looks
# exactly like a clean tree (issue #121). It answers without node, because the
# question is which files exist, not whether they parse.
if [ "$LIST_INPUTS" -eq 1 ]; then
  if [ "${#FILES[@]}" -eq 0 ]; then
    anchor_at_repository_root
    # `$(...)` and not `< <(...)`: discover_or_exit ends the script when it
    # cannot answer, and a process substitution's exit would end only the
    # subshell, leaving this one to print an empty list and exit 0 - which is
    # the false negative, one layer up, that the coverage gate would then read
    # as fact.
    LISTING="$(discover_or_exit)" || exit $?
    while IFS= read -r f; do [ -n "$f" ] && FILES+=("$f"); done <<<"$LISTING"
  fi
  printf '%s\n' "${FILES[@]}"
  exit 0
fi

if ! command -v node >/dev/null 2>&1; then
  # Not a skip. A gate that reports success because its interpreter is missing
  # is the false negative this whole issue is about.
  echo "::error title=check-mjs-syntax::node is not on PATH, so nothing was parsed." >&2
  exit 2
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  anchor_at_repository_root
  LISTING="$(discover_or_exit)" || exit $?
  while IFS= read -r f; do [ -n "$f" ] && FILES+=("$f"); done <<<"$LISTING"
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "::error title=check-mjs-syntax::No files to check — the discovery glob is wrong." >&2
  exit 2
fi

# A parse cannot legitimately take seconds. The bound turns a pathological file
# into a named failure instead of a job that hits its timeout-minutes backstop
# with no indication of which step ran long (issue #121, §8).
TIMEOUT=()
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT=(timeout 20s)
fi

status=0
parsed=0
findings=0

for file in "${FILES[@]}"; do
  if [ ! -f "$file" ]; then
    echo "::error file=$file,title=check-mjs-syntax::Not a readable file. The discovery list names something that is not there."
    findings=$((findings + 1))
    status=1
    continue
  fi

  if ! out="$("${TIMEOUT[@]}" node --check "$file" 2>&1)"; then
    # node prints `<path>:<line>` first, then the source line, a caret, and the
    # error. Both halves are useful: the annotation carries the line so GitHub
    # can point at it, and the raw output is echoed so the caret survives.
    line="$(printf '%s\n' "$out" | sed -n '1s/.*:\([0-9][0-9]*\)$/\1/p')"
    message="$(printf '%s\n' "$out" | grep -m1 -E '^[A-Za-z]*Error' || true)"
    [ -n "$message" ] || message="node --check exited non-zero"
    echo "::error file=$file${line:+,line=$line},title=JavaScript syntax error::$message"
    printf '%s\n' "$out" | sed 's/^/    /'
    findings=$((findings + 1))
    status=1
    continue
  fi

  parsed=$((parsed + 1))
  [ "$VERBOSE" -eq 1 ] && echo "  [parse] $file"

  dir="$(dirname "$file")"
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    lineno="${hit%%:*}"
    text="${hit#*:}"
    spec="$(printf '%s\n' "$text" | sed -n "s/.*from[[:space:]]*['\"]\(\.[^'\"]*\)['\"].*/\1/p")"
    if [ -z "$spec" ]; then
      spec="$(printf '%s\n' "$text" | sed -n "s/.*import[[:space:]]*([[:space:]]*['\"]\(\.[^'\"]*\)['\"].*/\1/p")"
    fi
    [ -n "$spec" ] || continue
    target="$dir/$spec"
    if [ -e "$target" ]; then
      [ "$VERBOSE" -eq 1 ] && echo "  [import] $file:$lineno $spec -> $target"
      continue
    fi
    echo "::error file=$file,line=$lineno,title=Unresolved import::'$spec' does not exist ($target). It would throw ERR_MODULE_NOT_FOUND the first time this module is loaded."
    echo "    $file:$lineno: $text"
    findings=$((findings + 1))
    status=1
  done < <(grep -nE "(^|[^A-Za-z0-9_$.])from[[:space:]]*['\"]\.|import[[:space:]]*\([[:space:]]*['\"]\." "$file" || true)
done

if [ "$findings" -gt 0 ]; then
  echo ""
  echo "check-mjs-syntax.sh: $findings finding(s) across ${#FILES[@]} file(s)."
  exit "$status"
fi

echo "check-mjs-syntax.sh: OK — $parsed JavaScript module(s) parse and every relative import resolves."
exit 0
