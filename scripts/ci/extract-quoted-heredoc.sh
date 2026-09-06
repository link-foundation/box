#!/usr/bin/env bash
# extract-quoted-heredoc.sh - Print the body of a quoted heredoc from a script.
#
# Why this exists (issue #115, RC-22). `scripts/measure-disk-space.sh` writes
# the script that runs as the unprivileged `box` user from a quoted heredoc:
#
#     cat >/tmp/box-measure.sh <<'EOF_BOX'
#     ...
#     EOF_BOX
#
# `bash -n` on the parent says nothing about that body - to the parser it is
# just data - so `measure-disk-space.yml` extracted it and syntax-checked it
# separately. It did so with an awk pattern that hardcoded one spelling of the
# opener:
#
#     awk '/^cat > \/tmp\/box-measure\.sh <</{flag=1; next} ...'
#
# `shfmt` then reformatted the script (commit 55416af) and wrote the opener the
# way it prefers, `cat >/tmp/box-measure.sh <<'EOF_BOX'` - same shell, no space
# after `>` or `<<`. The pattern stopped matching, awk printed nothing, and the
# job failed with "could not extract the generated script" on every push. The
# defect is not the awk expression: it is that a workflow was coupled to the
# *formatting* of a script that a formatter is allowed to rewrite.
#
# So the opener is matched here on what bash actually parses - a `<<` or `<<-`
# redirection whose delimiter is the requested one, quoted or not, with any
# spacing - and the failure modes that used to be silent (no opener, no
# terminator, empty body) each exit non-zero with a distinct code.
#
# Usage:
#   bash scripts/ci/extract-quoted-heredoc.sh <file> <delimiter>
#   bash scripts/ci/extract-quoted-heredoc.sh scripts/measure-disk-space.sh EOF_BOX > /tmp/body.sh
#
# Environment variables:
#   BOX_VERBOSE=1  Trace every command this script runs
#
# Exit codes:
#   0  the heredoc body was printed to stdout (always at least one line)
#   1  no opener for that delimiter, more than one opener, no terminator,
#      or an empty body
#   2  misuse (wrong argument count, unreadable file)

set -uo pipefail

if [ "${BOX_VERBOSE:-0}" = "1" ]; then
  set -x
fi

usage() {
  sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

if [ "$#" -ne 2 ]; then
  echo "::error title=extract-quoted-heredoc::expected 2 arguments (file, delimiter), got $#" >&2
  exit 2
fi

FILE="$1"
DELIM="$2"

if [ ! -r "$FILE" ]; then
  echo "::error title=extract-quoted-heredoc::cannot read '$FILE'" >&2
  exit 2
fi

case "$DELIM" in
  '' | *[!A-Za-z0-9_]*)
    echo "::error title=extract-quoted-heredoc::'$DELIM' is not a usable heredoc delimiter (letters, digits and underscore only)" >&2
    exit 2
    ;;
esac

# The opener: `<<` or `<<-`, optional space, the delimiter optionally wrapped in
# single or double quotes, then end of line. Anything before the `<<` is the
# redirection and is deliberately not inspected - `cat >x`, `cat > "$X"` and
# `tee /a /b` are all the same thing to this script.
#
# `<<<` is a herestring, not a heredoc, so the `<<` must not be preceded by a
# third `<`: without that guard `cmd <<<'EOF_BOX'` would be read as an opener
# and everything after it swallowed as a body.
#
# The terminator: the delimiter alone on its line. Leading whitespace is allowed
# because `<<-` strips tabs; a line with anything else on it is body text, which
# is why `[^ ]` cases such as `EOF_BOX_2` do not end the block.
OPENER_RE="(^|[^<])<<-?[[:space:]]*('${DELIM}'|\"${DELIM}\"|${DELIM})[[:space:]]*\$"
OPENERS="$(grep -c -E "$OPENER_RE" "$FILE" || true)"

if [ "$OPENERS" -eq 0 ]; then
  echo "::error title=extract-quoted-heredoc::no heredoc opening with delimiter '${DELIM}' in ${FILE}" >&2
  echo "  Looked for a line ending in <<${DELIM}, <<'${DELIM}' or <<\"${DELIM}\" (any spacing)." >&2
  exit 1
fi

if [ "$OPENERS" -gt 1 ]; then
  echo "::error title=extract-quoted-heredoc::${OPENERS} heredocs in ${FILE} use the delimiter '${DELIM}'; which one to extract is ambiguous" >&2
  grep -n -E "$OPENER_RE" "$FILE" | sed 's/^/    /' >&2
  exit 1
fi

BODY="$(awk -v delim="$DELIM" '
  BEGIN {
    opener = "(^|[^<])<<-?[ \t]*(\047" delim "\047|\"" delim "\"|" delim ")[ \t]*$"
    terminator = "^[ \t]*" delim "[ \t]*$"
  }
  # `<<-` strips leading tabs from the body and from the terminator, so an
  # extraction that kept them would not be the text bash feeds the command.
  !inside && $0 ~ opener {
    inside = 1
    dash = ($0 ~ "(^|[^<])<<-")
    next
  }
  inside && $0 ~ terminator { inside = 0; next }
  inside {
    line = $0
    if (dash) { sub(/^\t+/, "", line) }
    print line
  }
  END { if (inside) exit 3 }
' "$FILE")"
AWK_STATUS=$?

if [ "$AWK_STATUS" -eq 3 ]; then
  echo "::error title=extract-quoted-heredoc::the heredoc opened with '${DELIM}' in ${FILE} is never closed" >&2
  exit 1
fi

if [ "$AWK_STATUS" -ne 0 ]; then
  echo "::error title=extract-quoted-heredoc::awk failed while reading ${FILE} (status ${AWK_STATUS})" >&2
  exit 1
fi

# An empty body is what the old awk pattern produced on every run once shfmt had
# moved a space, and `test -s` in the caller was the only thing that noticed.
# Report it here instead, with the file and delimiter in the message.
if [ -z "$BODY" ]; then
  echo "::error title=extract-quoted-heredoc::the heredoc '${DELIM}' in ${FILE} is empty; nothing to check" >&2
  exit 1
fi

printf '%s\n' "$BODY"
