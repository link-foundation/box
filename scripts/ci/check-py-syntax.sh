#!/usr/bin/env bash
#
# check-py-syntax.sh — parse every Python file in the repository.
#
# Issue #121, and the same question check-mjs-syntax.sh asks of the JavaScript.
# `git ls-files '*.py'` outside dev/log/ returns three files and nothing had
# ever parsed one of them:
#
#   * scripts/ci/validate-measurements.py decides whether a three-hour disk
#     measurement is allowed to be committed to main.
#   * scripts/ci/summarize-measurements.py writes that measurement into the job
#     summary.
#   * experiments/issue-121-buildx-rm-timeout/stall-docker-volume-delete.py is a
#     reproduction, run by hand.
#
# Nothing else parses them. The shell linters take *.sh, run-experiments.sh
# discovers *.sh, and actionlint's pyflakes reads the `run:` blocks of
# workflows, not the files they call. So a SyntaxError in the validator would first be seen by the release
# that needed it — and, before the exit-code fix in measure-disk-space.yml, seen
# as "these measurements are invalid", discarding the three hours rather than
# reporting the typo.
#
# WHAT IT CHECKS
#   Every tracked *.py file outside dev/log/ compiles: Python's own `compile()`
#   in 'exec' mode, which is what `python3 -m py_compile` runs, called through
#   `python3 -c` so that no __pycache__ directory is written into the tree. A
#   compile is a parse; nothing here is imported or executed.
#
# WHAT IT DOES NOT FLAG
#   Anything that needs the module to run: an undefined name, a wrong argument,
#   a missing import. That is a type checker's or a linter's job, and this
#   repository has no Python dependencies to install one against. The behaviour
#   of the validator is asserted by experiments/test-add-measurement-fix.sh.
#
# USAGE
#   scripts/ci/check-py-syntax.sh [--verbose] [--list-inputs] [file ...]
#
#   With no files, checks every tracked *.py outside dev/log/, which holds
#   verbatim copies of other projects' sources collected as issue evidence and
#   is not ours to fix — the python template alone contributes 13 of them.
#   --verbose (default off) names every file as it is parsed.
#
# EXIT
#   0 = every file compiles
#   1 = at least one file does not
#   2 = the check could not run (no python3, no files, bad usage)

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
    git ls-files -- '*.py'
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
    echo "::error title=check-py-syntax::could not list this repository's files - git ls-files failed and printed the reason above. Nothing was parsed; this is not a clean run." >&2
    exit 2
  fi
  if [ -z "$listing" ]; then
    echo "::error title=check-py-syntax::discovery matched no python file at all. Either the glob ('*.py') is wrong or this is not the repository they were written for; a gate that read nothing must not report a clean tree." >&2
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
    echo "check-py-syntax.sh: not inside a git repository and no files given" >&2
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
      sed -n '2,47p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    --)
      shift
      FILES+=("$@")
      break
      ;;
    -*)
      echo "check-py-syntax.sh: unknown option $1" >&2
      exit 2
      ;;
    *)
      FILES+=("$1")
      shift
      ;;
  esac
done

# The discovered set, one repository-relative path per line, nothing else,
# exit 0 — the contract scripts/ci/check-workflow-path-coverage.mjs reads to
# check that a change to any of these files can start the workflow that runs
# this gate. It answers without python3, because the question is which files
# exist, not whether they parse.
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

if ! command -v python3 >/dev/null 2>&1; then
  # Not a skip. A gate that reports success because its interpreter is missing
  # is the false negative this whole issue is about.
  echo "::error title=check-py-syntax::python3 is not on PATH, so nothing was parsed." >&2
  exit 2
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  anchor_at_repository_root
  LISTING="$(discover_or_exit)" || exit $?
  while IFS= read -r f; do [ -n "$f" ] && FILES+=("$f"); done <<<"$LISTING"
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "::error title=check-py-syntax::No files to check — the discovery glob is wrong." >&2
  exit 2
fi

# A parse cannot legitimately take seconds. The bound turns a pathological file
# into a named failure instead of a job that hits its timeout-minutes backstop
# with no indication of which step ran long (issue #121, §8).
TIMEOUT=()
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT=(timeout 20s)
fi

# The path arrives in argv, never interpolated into the program text: a file
# named with a quote would otherwise change what is compiled. `compile()` is
# what py_compile calls, without py_compile's side effect of writing a .pyc.
# A SyntaxError carries the line and offset it was raised at; anything else is
# reported as itself rather than translated into a syntax claim.
READER=$(
  cat <<'PYTHON'
import sys, traceback
path = sys.argv[1]
try:
    with open(path, "rb") as handle:
        source = handle.read()
except OSError as error:
    print("READ|0|0|%s" % error)
    raise SystemExit(1)
try:
    compile(source, path, "exec")
except SyntaxError as error:
    print("SYNTAX|%d|%d|%s" % (error.lineno or 0, error.offset or 0, error.msg))
    raise SystemExit(1)
except Exception as error:
    print("OTHER|0|0|%s: %s" % (type(error).__name__, error))
    raise SystemExit(1)
PYTHON
)

status=0
parsed=0
findings=0

for file in "${FILES[@]}"; do
  if [ ! -f "$file" ]; then
    echo "::error file=$file,title=check-py-syntax::Not a readable file. The discovery list names something that is not there."
    findings=$((findings + 1))
    status=1
    continue
  fi

  if out="$("${TIMEOUT[@]}" python3 -c "$READER" "$file" 2>&1)"; then
    parsed=$((parsed + 1))
    [ "$VERBOSE" -eq 1 ] && echo "  [parse] $file"
    continue
  fi

  # A timeout, or a python3 that died before running the program, prints
  # nothing in this format. Say that, rather than reporting a syntax error
  # nobody can find.
  case "$out" in
    SYNTAX\|* | READ\|* | OTHER\|*) ;;
    *)
      echo "::error file=$file,title=check-py-syntax::python3 could not report on this file: ${out:-no output (timed out?)}"
      findings=$((findings + 1))
      status=1
      continue
      ;;
  esac

  kind="${out%%|*}"
  rest="${out#*|}"
  lineno="${rest%%|*}"
  rest="${rest#*|}"
  column="${rest%%|*}"
  message="${rest#*|}"

  case "$kind" in
    SYNTAX)
      title="Python syntax error"
      ;;
    READ)
      title="check-py-syntax"
      ;;
    *)
      title="check-py-syntax"
      ;;
  esac

  location=""
  [ "$lineno" != "0" ] && location=",line=$lineno"
  [ "$lineno" != "0" ] && [ "$column" != "0" ] && location="$location,col=$column"

  echo "::error file=$file$location,title=$title::$message"
  findings=$((findings + 1))
  status=1
done

if [ "$findings" -gt 0 ]; then
  echo ""
  echo "check-py-syntax.sh: $findings finding(s) across ${#FILES[@]} file(s)."
  exit "$status"
fi

echo "check-py-syntax.sh: OK — $parsed Python file(s) compile."
exit 0
