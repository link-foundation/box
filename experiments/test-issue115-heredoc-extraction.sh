#!/usr/bin/env bash
# test-issue115-heredoc-extraction.sh
#
# Issue #115, RC-22. `measure-disk-space.yml` syntax-checks the script that
# `scripts/measure-disk-space.sh` writes for the unprivileged `box` user. That
# script lives inside a quoted heredoc, so it has to be extracted first, and the
# extraction was an inline awk pattern that hardcoded one spelling of the
# opener:
#
#     awk '/^cat > \/tmp\/box-measure\.sh <</{flag=1; next} /^EOF_BOX/{flag=0} flag'
#
# shfmt (commit 55416af, this pull request) then reformatted the script and
# wrote the same redirection as `cat >/tmp/box-measure.sh <<'EOF_BOX'`. Nothing
# about the program changed; the spacing did. awk printed nothing, and the job
# failed with "could not extract the generated script" on every push - run
# 34009149532 among them.
#
# The replacement, scripts/ci/extract-quoted-heredoc.sh, matches the redirection
# bash parses instead of the formatting it happens to have. This suite pins that
# behaviour: every spelling of the opener that bash accepts, every failure that
# used to be silent, and the wiring that makes the workflow use it.
#
# Usage: bash experiments/test-issue115-heredoc-extraction.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/ci/extract-quoted-heredoc.sh"

PASS=0
FAIL=0
pass() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

OUT=""
STATUS=0
# run FILE DELIM [ENV=VALUE...] - leaves stdout in $OUT, stderr in $ERR.
ERR=""
run() {
  local file="$1" delim="$2"
  shift 2
  OUT="$(env "$@" bash "$SCRIPT" "$file" "$delim" 2>"$TMP/stderr")"
  STATUS=$?
  ERR="$(cat "$TMP/stderr")"
}

echo "== Part 1: the real script extracts, and the old pattern no longer does =="

REAL="$ROOT/scripts/measure-disk-space.sh"

run "$REAL" EOF_BOX
if [ "$STATUS" -eq 0 ]; then
  pass "extracting EOF_BOX from scripts/measure-disk-space.sh exits 0"
else
  fail "extracting EOF_BOX from scripts/measure-disk-space.sh exits 0 (got $STATUS)"
  printf '%s\n' "$ERR" | sed 's/^/      /' >&2
fi

LINES="$(printf '%s\n' "$OUT" | wc -l)"
if [ "$LINES" -gt 100 ]; then
  pass "the extracted body is the generated script, not a fragment ($LINES lines)"
else
  fail "the extracted body is the generated script, not a fragment (got $LINES lines)"
fi

printf '%s\n' "$OUT" >"$TMP/real-body.sh"
if bash -n "$TMP/real-body.sh" 2>"$TMP/syntax"; then
  pass "the extracted body is syntactically valid bash"
else
  fail "the extracted body is syntactically valid bash"
  sed 's/^/      /' "$TMP/syntax" >&2
fi

# The delimiters themselves must not be in the output: `EOF_BOX` on a line of
# its own is not valid bash, so a body that still contained it would fail the
# check above for the wrong reason.
if ! grep -qx 'EOF_BOX' "$TMP/real-body.sh" && ! grep -q "cat >.*box-measure" "$TMP/real-body.sh"; then
  pass "neither the opener nor the terminator is included in the body"
else
  fail "neither the opener nor the terminator is included in the body"
fi

# The regression, reproduced. This is the exact expression the workflow used;
# against today's shfmt-formatted script it produces nothing. If a future commit
# reformats the opener back to the spaced form this assertion fails, and that is
# correct: it would mean the reproduction no longer reproduces and the assertion
# has stopped testing anything.
OLD_AWK="$(awk '/^cat > \/tmp\/box-measure\.sh <</{flag=1; next} /^EOF_BOX/{flag=0} flag' "$REAL")"
if [ -z "$OLD_AWK" ]; then
  pass "the historical awk pattern extracts nothing from the current script (the bug)"
else
  fail "the historical awk pattern extracts nothing from the current script (the bug)"
fi

echo ""
echo "== Part 2: every opener spelling bash accepts is accepted here =="

# fixture NAME OPENER - a two-line body between OPENER and the terminator.
fixture() {
  local name="$1" opener="$2"
  {
    printf '%s\n' "#!/usr/bin/env bash"
    printf '%s\n' "$opener"
    printf '%s\n' "echo one"
    printf '%s\n' "echo two"
    printf '%s\n' "EOF_BOX"
    printf '%s\n' "echo after"
  } >"$TMP/$name"
  echo "$TMP/$name"
}

check_two_lines() {
  local label="$1" file="$2"
  run "$file" EOF_BOX
  if [ "$STATUS" -eq 0 ] && [ "$OUT" = "echo one
echo two" ]; then
    pass "$label"
  else
    fail "$label (status=$STATUS, output=$(printf '%s' "$OUT" | tr '\n' '|'))"
    printf '%s\n' "$ERR" | sed 's/^/      /' >&2
  fi
}

check_two_lines "shfmt spelling: cat >file <<'EOF_BOX'" \
  "$(fixture shfmt.sh "cat >/tmp/box-measure.sh <<'EOF_BOX'")"
check_two_lines "historical spelling: cat > file << 'EOF_BOX'" \
  "$(fixture spaced.sh "cat > /tmp/box-measure.sh << 'EOF_BOX'")"
check_two_lines "double-quoted delimiter" \
  "$(fixture dquote.sh 'cat >/tmp/x.sh <<"EOF_BOX"')"
check_two_lines "unquoted delimiter (expansion happens, extraction is the same)" \
  "$(fixture bare.sh 'cat >/tmp/x.sh <<EOF_BOX')"
check_two_lines "a redirection this script never has to understand: tee -a a b" \
  "$(fixture tee.sh "tee -a /tmp/a /tmp/b <<'EOF_BOX'")"
check_two_lines "the opener is indented inside a function" \
  "$(fixture indented.sh "  cat >\"\$TMP/x.sh\" <<'EOF_BOX'")"

# `<<-` strips leading tabs from the body and from the terminator, so the
# terminator may be indented. Written with printf so the tabs survive an editor.
printf '#!/usr/bin/env bash\n\tcat >/tmp/x.sh <<-'"'"'EOF_BOX'"'"'\n\techo one\n\techo two\n\tEOF_BOX\n' >"$TMP/dash.sh"
check_two_lines "<<- with a tab-indented terminator" "$TMP/dash.sh"

# A line that merely starts with the delimiter is body text.
{
  printf '%s\n' "cat >/tmp/x.sh <<'EOF_BOX'"
  printf '%s\n' "echo one"
  printf '%s\n' "EOF_BOX_NOT_THE_END=1"
  printf '%s\n' "echo two"
  printf '%s\n' "EOF_BOX"
} >"$TMP/prefix.sh"
run "$TMP/prefix.sh" EOF_BOX
if [ "$STATUS" -eq 0 ] && [ "$(printf '%s\n' "$OUT" | wc -l)" -eq 3 ]; then
  pass "a body line that starts with the delimiter does not end the block"
else
  fail "a body line that starts with the delimiter does not end the block (status=$STATUS)"
fi

echo ""
echo "== Part 3: a herestring is not a heredoc =="

# `<<<'EOF_BOX'` shares two characters with `<<'EOF_BOX'`. Reading it as an
# opener would swallow the rest of the file as a body and report success.
{
  printf '%s\n' "#!/usr/bin/env bash"
  printf '%s\n' "grep -q x <<<'EOF_BOX'"
  printf '%s\n' "echo after"
} >"$TMP/herestring.sh"
run "$TMP/herestring.sh" EOF_BOX
if [ "$STATUS" -eq 1 ] && printf '%s' "$ERR" | grep -q 'no heredoc opening'; then
  pass "a <<<'EOF_BOX' herestring is not mistaken for an opener"
else
  fail "a <<<'EOF_BOX' herestring is not mistaken for an opener (status=$STATUS)"
  printf '%s\n' "$ERR" | sed 's/^/      /' >&2
fi

echo ""
echo "== Part 4: the failures that used to be silent are now loud =="

# Every one of these produced an empty file and the caller's generic
# "could not extract the generated script", which said nothing about which of
# them had happened.
{
  printf '%s\n' "#!/usr/bin/env bash"
  printf '%s\n' "echo nothing to see"
} >"$TMP/absent.sh"
run "$TMP/absent.sh" EOF_BOX
if [ "$STATUS" -eq 1 ] && printf '%s' "$ERR" | grep -q "no heredoc opening with delimiter 'EOF_BOX'"; then
  pass "a missing opener exits 1 and names the delimiter and the file"
else
  fail "a missing opener exits 1 and names the delimiter and the file (status=$STATUS)"
fi

{
  printf '%s\n' "cat >/tmp/a.sh <<'EOF_BOX'"
  printf '%s\n' "echo one"
  printf '%s\n' "EOF_BOX"
  printf '%s\n' "cat >/tmp/b.sh <<'EOF_BOX'"
  printf '%s\n' "echo two"
  printf '%s\n' "EOF_BOX"
} >"$TMP/twice.sh"
run "$TMP/twice.sh" EOF_BOX
if [ "$STATUS" -eq 1 ] && printf '%s' "$ERR" | grep -q 'ambiguous'; then
  pass "two heredocs with one delimiter is an error, not a silent first-match"
else
  fail "two heredocs with one delimiter is an error, not a silent first-match (status=$STATUS)"
fi

{
  printf '%s\n' "cat >/tmp/a.sh <<'EOF_BOX'"
  printf '%s\n' "echo one"
} >"$TMP/unterminated.sh"
run "$TMP/unterminated.sh" EOF_BOX
if [ "$STATUS" -eq 1 ] && printf '%s' "$ERR" | grep -q 'never closed'; then
  pass "an unterminated heredoc exits 1 and says so"
else
  fail "an unterminated heredoc exits 1 and says so (status=$STATUS)"
fi

{
  printf '%s\n' "cat >/tmp/a.sh <<'EOF_BOX'"
  printf '%s\n' "EOF_BOX"
} >"$TMP/empty.sh"
run "$TMP/empty.sh" EOF_BOX
if [ "$STATUS" -eq 1 ] && printf '%s' "$ERR" | grep -q 'is empty'; then
  pass "an empty body exits 1 rather than reporting a successful extraction of nothing"
else
  fail "an empty body exits 1 rather than reporting a successful extraction of nothing (status=$STATUS)"
fi

echo ""
echo "== Part 5: misuse is rejected with a distinct code =="

OUT="$(bash "$SCRIPT" 2>"$TMP/stderr")"
if [ "$?" -eq 2 ] && grep -q 'expected 2 arguments' "$TMP/stderr"; then
  pass "no arguments exits 2"
else
  fail "no arguments exits 2"
fi

OUT="$(bash "$SCRIPT" "$REAL" 2>"$TMP/stderr")"
[ "$?" -eq 2 ] && pass "one argument exits 2" || fail "one argument exits 2"

OUT="$(bash "$SCRIPT" "$TMP/does-not-exist.sh" EOF_BOX 2>"$TMP/stderr")"
if [ "$?" -eq 2 ] && grep -q 'cannot read' "$TMP/stderr"; then
  pass "an unreadable file exits 2 (not 1: nothing was searched)"
else
  fail "an unreadable file exits 2 (not 1: nothing was searched)"
fi

# A delimiter with regex metacharacters would otherwise be interpolated into the
# patterns and match something else entirely.
OUT="$(bash "$SCRIPT" "$REAL" 'EOF.*' 2>"$TMP/stderr")"
if [ "$?" -eq 2 ] && grep -q 'not a usable heredoc delimiter' "$TMP/stderr"; then
  pass "a delimiter containing regex metacharacters exits 2"
else
  fail "a delimiter containing regex metacharacters exits 2"
fi

bash "$SCRIPT" --help >"$TMP/help" 2>&1
if [ "$?" -eq 0 ] && grep -q 'Exit codes:' "$TMP/help"; then
  pass "--help exits 0 and documents the exit codes"
else
  fail "--help exits 0 and documents the exit codes"
fi

echo ""
echo "== Part 6: the trace is off by default =="

run "$TMP/shfmt.sh" EOF_BOX
if ! printf '%s' "$ERR" | grep -q '^+ '; then
  pass "no trace on stderr by default"
else
  fail "no trace on stderr by default"
fi

run "$TMP/shfmt.sh" EOF_BOX BOX_VERBOSE=1
if printf '%s' "$ERR" | grep -q '^+ '; then
  pass "BOX_VERBOSE=1 traces every command"
else
  fail "BOX_VERBOSE=1 traces every command"
fi

echo ""
echo "== Part 7: the workflow actually calls it =="

# `run:` lines only. A comment naming the script is documentation, not a caller,
# and counting one would be the vacuous pass this repository keeps finding.
CALLERS="$(grep -rl 'extract-quoted-heredoc\.sh' "$ROOT/.github/workflows/" 2>/dev/null | xargs -r grep -l 'run: *|\?' 2>/dev/null || true)"
if grep -q 'extract-quoted-heredoc\.sh' "$ROOT/.github/workflows/measure-disk-space.yml"; then
  pass "measure-disk-space.yml references the extraction script"
else
  fail "measure-disk-space.yml references the extraction script"
fi

# The step must run it, not merely mention it: pull the step's `run:` block and
# look there.
STEP="$(awk '/name: Syntax-check the generated box-user script/{flag=1} flag{print} flag && /bash -n/{exit}' \
  "$ROOT/.github/workflows/measure-disk-space.yml")"
if printf '%s' "$STEP" | grep -q 'extract-quoted-heredoc\.sh'; then
  pass "the syntax-check step runs the extraction script"
else
  fail "the syntax-check step runs the extraction script"
  printf '%s\n' "$STEP" | sed 's/^/      /' >&2
fi

# And the pattern that broke must not come back anywhere in the workflows.
if ! grep -rn "box-measure\\\\\.sh <<" "$ROOT/.github/workflows/" >/dev/null 2>&1; then
  pass "no workflow greps the heredoc opener by its formatting any more"
else
  fail "no workflow greps the heredoc opener by its formatting any more"
  grep -rn "box-measure\\\\\.sh <<" "$ROOT/.github/workflows/" | sed 's/^/      /' >&2
fi

if [ -n "$CALLERS" ]; then
  pass "the script is wired into a workflow ($(basename "$CALLERS"))"
else
  fail "the script is wired into a workflow"
fi

echo ""
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
