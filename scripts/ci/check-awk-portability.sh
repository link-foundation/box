#!/usr/bin/env bash
#
# check-awk-portability.sh — catch awk programs that only work under gawk.
#
# Issue #121. A check written for this very branch asserted that no `run:` block
# in a composite action interpolates a `${{ }}` expansion, and extracted the
# block with
#
#     awk '/^\s+run: \|/,0' "$ACTION" | grep -q '\${{'
#
# `\s` is a GNU extension. POSIX awk does not define it and mawk — the default
# `awk` on Debian and Ubuntu, and therefore in this repository's own containers
# — does not implement it: the pattern matches nothing, the range never opens,
# awk prints nothing, and the negated grep passes. The check could not fail.
# GitHub's ubuntu-24.04 image ships gawk, where the same line matches, so the
# suite passed locally and failed in CI on a defect that was not there.
#
# That is the worst shape a check can have: it reports a different answer
# depending on which machine ran it, and the machine where it is silent is the
# one a developer uses. Nothing warns — mawk does not diagnose an unknown escape
# in a regex, it just does not match. Hence this check.
#
# WHAT IT CHECKS
#   Every awk program text in a tracked file, for regex escapes that mawk does
#   not implement: \s \S \w \W \d \D \< \> \y. An awk program is found by
#   scanning quote-aware from an `awk` word to the end of that command, so a
#   `\s` in the `sed` on the other side of a pipe is not reported, and a program
#   spanning fifty lines inside one pair of quotes is.
#
#   `gawk` and `mawk` invocations are skipped: naming the implementation is the
#   supported way to depend on its extensions.
#
# WHAT IT DOES NOT FLAG
#   Escapes that mean the same thing everywhere (\t \n \. \\ \/ \[ ...), and
#   anything outside an awk command. A comment `# awk-portability: ignore` on
#   the line above the finding suppresses it; suppressions are counted and
#   printed, because a suppression nobody can see is how a rule stops applying.
#
# USAGE
#   scripts/ci/check-awk-portability.sh [--verbose] [--list-inputs] [file ...]
#
#   With no files, checks every tracked text file outside dev/log/ (which holds
#   verbatim copies of other projects' sources, collected as issue evidence and
#   not ours to fix).
#   --verbose (default off) prints every awk program the scanner extracted,
#   which is what you want when a finding looks wrong.
#
# EXIT
#   0 = clean, 1 = at least one non-portable escape, 2 = usage error.

set -euo pipefail

VERBOSE=0
LIST_INPUTS=0
FILES=()

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
      sed -n '2,50p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    --)
      shift
      FILES+=("$@")
      break
      ;;
    -*)
      echo "check-awk-portability.sh: unknown option $1" >&2
      exit 2
      ;;
    *)
      FILES+=("$1")
      shift
      ;;
  esac
done

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
    echo "check-awk-portability.sh: not inside a git repository and no files given" >&2
    exit 2
  fi
  cd "$root" || exit 2
}

# collect_files / discover_or_exit - the two empty answers told apart, neither
# of them reported as a clean run (issue #123, RC-17). `mapfile < <(git ls-files
# …)` discards git's exit status entirely: a git that could not read the index
# produced an empty array, which this gate reported as "the discovery glob is
# wrong" on the check path and as a clean, empty answer on the --list-inputs
# path that the coverage gate reads as fact.
collect_files() {
  local listing
  # grep's exit 1 ("selected nothing") is a legitimately empty tree, not an
  # error; git's status is the one that has to survive the pipeline.
  listing="$(
    git ls-files -- '*.sh' '*.bash' '*.mjs' '*.js' '*.py' '*.yml' '*.yaml'
    exit "${PIPESTATUS[0]}"
  )" || return 1
  printf '%s\n' "$listing" | { grep -v '^dev/log/' || [ "$?" = 1 ]; }
}

discover_or_exit() {
  local listing
  if ! listing="$(collect_files)"; then
    echo "::error title=check-awk-portability::could not list this repository's files - git ls-files failed and printed the reason above. No awk program was scanned; this is not a clean run." >&2
    exit 2
  fi
  if [ -z "$listing" ]; then
    echo "::error title=check-awk-portability::discovery matched no file at all. Either the globs are wrong or this is not the repository they were written for; a gate that read nothing must not report a clean tree." >&2
    exit 2
  fi
  printf '%s\n' "$listing"
}

if [ "${#FILES[@]}" -eq 0 ]; then
  anchor_at_repository_root
  # `$(...)` and not `< <(...)`: discover_or_exit ends the script when it cannot
  # answer, and a process substitution's exit would end only the subshell.
  LISTING="$(discover_or_exit)" || exit $?
  while IFS= read -r f; do [ -n "$f" ] && FILES+=("$f"); done <<<"$LISTING"
fi

# The discovered set, one repository-relative path per line, nothing else,
# exit 0. scripts/ci/check-workflow-path-coverage.mjs reads it to check that a
# change to any of these files can start the workflow that runs this gate — a
# `paths:` filter that matches none of them makes the job unreachable, which
# looks exactly like a clean tree (issue #121).
if [ "$LIST_INPUTS" -eq 1 ]; then
  printf '%s\n' "${FILES[@]}"
  exit 0
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "::error title=check-awk-portability::No files to check — the discovery glob is wrong." >&2
  exit 1
fi

# python3 rather than a hand-rolled shell scanner: this needs quote-aware
# tracking across newlines, and writing that in awk to check awk is a joke with
# a maintenance cost. python3 is present wherever the other checks in this
# directory run (scripts/ci/check-pipeline-status.sh relies on the same).
VERBOSE="$VERBOSE" python3 - "${FILES[@]}" <<'PYTHON'
import os
import re
import sys

VERBOSE = os.environ.get("VERBOSE") == "1"

# Escapes mawk does not implement in a regex. gawk accepts all of them; mawk
# matches nothing and says nothing, which is the whole problem.
GNU_ONLY = re.compile(r"\\+[sSwWdDy<>]")

# `awk` as a command word, not as part of `gawk`, `mawk`, or `awkward`.
AWK_WORD = re.compile(r"(?<![\w./-])awk(?![\w.-])")

# Unquoted text that ends the command an awk program belongs to.
COMMAND_END = re.compile(r"[\n;|&)]")

IGNORE = "awk-portability: ignore"


def contexts(text, comments):
    """Classify every character as code, quoted, or comment.

    Returns a list as long as `text`: None for unquoted shell code, "'" or '"'
    inside a quoted string, and "#" inside a comment. Command substitution
    re-enters code context, because `"$(awk '...')"` is a `"` to a naive
    scanner and an awk command to the shell — which is exactly where the defect
    that prompted this check was written.
    """
    out = []
    stack = []  # each entry: "'", '"', or None for $( ) / ` `
    in_comment = False
    i = 0
    n = len(text)

    def top():
        # The topmost entry, and None (code) for a `$( )`: a command
        # substitution inside a double-quoted string is code again, which is
        # the case the first version of this scanner got wrong and the reason
        # it missed the very line that prompted the check.
        return stack[-1] if stack else None

    while i < n:
        ch = text[i]
        quote = top()

        if in_comment:
            out.append("#")
            if ch == "\n":
                in_comment = False
            i += 1
            continue

        if quote == "'":
            out.append("'")
            if ch == "'":
                stack.pop()
            i += 1
            continue

        # Unquoted, or inside double quotes: both honour backslash and $( ).
        if ch == "\\" and i + 1 < n:
            out.append(quote)
            out.append(quote)
            i += 2
            continue

        if ch == "$" and i + 1 < n and text[i + 1] == "(":
            out.append(quote)
            out.append(None)
            stack.append(None)
            i += 2
            continue

        if ch == ")" and stack and stack[-1] is None:
            stack.pop()
            out.append(top())
            i += 1
            continue

        if quote == '"':
            out.append('"')
            if ch == '"':
                stack.pop()
            i += 1
            continue

        # Unquoted code.
        if ch in "'\"":
            out.append(None)
            stack.append(ch)
            i += 1
            continue

        if comments and ch == "#" and (i == 0 or text[i - 1] in " \t\n"):
            in_comment = True
            out.append("#")
            i += 1
            continue

        out.append(None)
        i += 1

    return out


def awk_program_regions(text, quote_at):
    """Yield (start, end) offsets of the quoted arguments of each awk command."""
    for match in AWK_WORD.finditer(text):
        start = match.start()
        if start < len(quote_at) and quote_at[start] is not None:
            # The word `awk` inside a string or a comment is prose, not a
            # command. A program passed to `sh -c` is out of scope.
            continue
        i = match.end()
        first = None
        last = None
        while i < len(text):
            ch = text[i]
            q = quote_at[i]
            if q is None and COMMAND_END.match(ch):
                break
            if q in ("'", '"'):
                if first is None:
                    first = i
                last = i
            i += 1
        if first is not None:
            yield (first, last + 1)


def line_of(text, offset):
    return text.count("\n", 0, offset) + 1


findings = 0
suppressed = 0
checked = 0
unreadable = 0

for path in sys.argv[1:]:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError as error:
        # A path that cannot be read is not a clean path. Skipping it silently
        # is how a check reports success about a file it never opened, which is
        # the whole subject of issue #121.
        print(
            "::error file=%s,title=check-awk-portability::Could not read this file: %s"
            % (path, error)
        )
        unreadable += 1
        continue
    if "awk" not in text:
        continue
    checked += 1
    lines = text.split("\n")
    quote_at = contexts(text, comments=not path.endswith((".mjs", ".js")))
    for start, end in awk_program_regions(text, quote_at):
        program = text[start:end]
        if VERBOSE:
            print(
                "[awk-portability] %s:%d program: %s"
                % (path, line_of(text, start), program.replace("\n", "\\n")[:120]),
                file=sys.stderr,
            )
        for hit in GNU_ONLY.finditer(program):
            # An even number of backslashes leaves the escape to the shell, not
            # to awk: `\\s` in a double-quoted string is one backslash and an s
            # by the time awk reads it, which is still the same defect, so both
            # are reported.
            line_no = line_of(text, start + hit.start())
            above = lines[line_no - 2] if line_no >= 2 else ""
            if IGNORE in above or IGNORE in lines[line_no - 1]:
                suppressed += 1
                continue
            findings += 1
            print(
                "::error file=%s,line=%d,title=Non-portable awk escape::%s is a GNU extension; "
                "mawk (the default awk on Debian and Ubuntu) matches nothing and reports nothing. "
                "Use a bracket expression such as [[:space:]] or [ \\t], or call gawk by name."
                % (path, line_no, hit.group(0))
            )
            print("  %s:%d: %s" % (path, line_no, lines[line_no - 1].strip()))

if findings or unreadable:
    print("")
    if findings:
        print(
            "check-awk-portability.sh: %d non-portable escape(s) in awk programs."
            % findings
        )
    if unreadable:
        print("check-awk-portability.sh: %d file(s) could not be read." % unreadable)
    sys.exit(1)

print(
    "check-awk-portability.sh: OK — no GNU-only regex escapes in awk programs "
    "(%d file(s) mentioning awk checked)." % checked
)
if suppressed:
    print("  %d finding(s) suppressed with '# awk-portability: ignore'" % suppressed)
PYTHON
