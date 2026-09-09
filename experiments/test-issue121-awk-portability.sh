#!/usr/bin/env bash
# test-issue121-awk-portability.sh
#
# Issue #121. Fixtures for scripts/ci/check-awk-portability.sh, plus the
# regression that produced it.
#
# The defect: a suite written for this branch extracted a YAML block with
# `awk '/^\s+run: \|/,0'`. `\s` is a GNU extension; mawk - the default awk on
# Debian and Ubuntu, and what runs in this repository's containers - does not
# implement it, matches nothing, and says nothing. The assertion passed on a
# file full of injections. On GitHub's ubuntu-24.04 image, where awk is gawk,
# the same line matched and then over-reported, because `,0` never closes a
# range. So the check gave three different answers - silent, correct, wrong -
# depending on the machine, and the silent one was the developer's.
# experiments/reproduce-issue121-awk-run-block-range.sh demonstrates both halves
# under whichever awk is installed.
#
# A checker is only worth having if it can fail, so most of what follows feeds
# it fixtures that must be reported and fixtures that must not.
#
# Usage: bash experiments/test-issue121-awk-portability.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
CHECK="$ROOT/scripts/ci/check-awk-portability.sh"

PASS=0
FAIL=0
pass() {
  PASS=$((PASS + 1))
  echo "PASS: $1"
}
fail() {
  FAIL=$((FAIL + 1))
  echo "FAIL: $1"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Writes $2 to a fixture file and reports whether the checker flagged it.
# Prints "flagged" or "clean"; anything else is a checker crash and shows up as
# a mismatch in the assertion that called it.
verdict() {
  local name="$1" body="$2"
  printf '%s\n' "$body" >"$WORK/$name"
  if (cd "$WORK" && bash "$CHECK" "$name" >/dev/null 2>&1); then
    echo "clean"
  else
    echo "flagged"
  fi
}

expect() {
  local want="$1" name="$2" body="$3" label="$4" got
  got="$(verdict "$name" "$body")"
  if [ "$got" = "$want" ]; then
    pass "$label"
  else
    fail "$label (expected $want, got $got)"
    printf '%s\n' "$body" | sed 's/^/    /'
    (cd "$WORK" && bash "$CHECK" "$name" 2>&1 | sed 's/^/    /')
  fi
}

echo "=== Part 1: the escapes mawk does not implement ==="

expect flagged a.sh 'awk '"'"'/^\s+run:/ { print }'"'"' file.yml' \
  "\\s in an awk program is reported"
expect flagged b.sh 'awk '"'"'$0 ~ /\w+/ { print }'"'"' file' \
  "\\w in an awk program is reported"
expect flagged c.sh 'awk '"'"'/\<word\>/ { print }'"'"' file' \
  "gawk word boundaries \\< \\> are reported"
expect flagged d.sh 'awk '"'"'/\y/ { print }'"'"' file' \
  "gawk's \\y word boundary is reported"
expect flagged e.sh 'awk '"'"'/[0-9]\d/ { print }'"'"' file' \
  "\\d - which is not even a gawk extension - is reported"
expect flagged f.sh 'awk '"'"'/\S/ { print }'"'"' file' \
  "\\S in an awk program is reported"

echo
echo "=== Part 2: what must not be reported ==="

expect clean g.sh 'awk '"'"'/^[[:space:]]+run:/ { print }'"'"' file.yml' \
  "a POSIX bracket expression is not reported"
expect clean h.sh 'awk '"'"'/^[ \t]+run:/ { print }'"'"' file.yml' \
  "\\t inside a bracket expression is not reported"
expect clean i.sh 'awk '"'"'{ printf "%s\n", $1 }'"'"' file' \
  "\\n in a printf format is not reported"
expect clean j.sh 'grep foo file | sed '"'"'s/\s\+/ /g'"'"'' \
  "\\s in a sed script is not reported"
expect clean k.sh 'awk '"'"'{ print }'"'"' file | sed '"'"'s/\s//'"'"'' \
  "\\s in the sed on the far side of a pipe from awk is not reported"
expect clean l.sh '# awk '"'"'/\s/'"'"' is what this used to do' \
  "an awk program quoted in a comment is not reported"
expect clean m.sh 'echo "  awk '"'"'/^\s+run:/'"'"' file"' \
  "an awk program quoted inside an echo is not reported"
expect clean n.sh 'gawk '"'"'/^\s+run:/ { print }'"'"' file' \
  "naming gawk is the supported way to use its extensions"
expect clean o.sh 'mawk '"'"'{ print }'"'"' file' \
  "an explicit mawk invocation is not scanned either"

echo
echo "=== Part 3: the shape the scanner originally missed ==="

# The defect that prompted the check was written inside a command substitution
# inside a double-quoted assignment. The first version of this scanner saw the
# opening `"` and classified the whole line as a string, so it read the one
# line it existed to catch as prose. `$( )` re-enters code.
expect flagged p.sh 'OUT="$(awk '"'"'/^\s+run: \|/,0'"'"' file.yml | grep -n x)"' \
  "awk inside \$( ) inside a double-quoted assignment is reported"
expect flagged q.sh 'RESULT=$(awk '"'"'/\s/ { print }'"'"' file)' \
  "awk inside a bare \$( ) is reported"
expect flagged r.sh 'if [ "$(awk '"'"'/\w/ { print }'"'"' f)" = x ]; then :; fi' \
  "awk inside a command substitution in a test is reported"

echo
echo "=== Part 4: the suppression is visible ==="

expect clean s.sh '# awk-portability: ignore
awk '"'"'/^\s+run:/ { print }'"'"' file.yml' \
  "a finding directly under the ignore directive is suppressed"

SUPPRESSED_OUT="$(cd "$WORK" && bash "$CHECK" s.sh 2>&1)"
if printf '%s' "$SUPPRESSED_OUT" | grep -q "suppressed with"; then
  pass "a suppressed finding is still counted and printed"
else
  fail "a suppressed finding is still counted and printed"
  printf '%s\n' "$SUPPRESSED_OUT" | sed 's/^/    /'
fi

expect flagged t.sh '# awk-portability: ignore
echo unrelated
awk '"'"'/^\s+run:/ { print }'"'"' file.yml' \
  "the directive suppresses one finding, not the rest of the file"

echo
echo "=== Part 5: the repository itself ==="

if bash "$CHECK" >"$WORK/repo.out" 2>&1; then
  pass "no tracked file carries a GNU-only escape in an awk program"
else
  fail "no tracked file carries a GNU-only escape in an awk program"
  sed 's/^/    /' "$WORK/repo.out"
fi

if grep -q 'file(s) mentioning awk checked' "$WORK/repo.out"; then
  CHECKED="$(sed -n 's/.*(\([0-9]\+\) file(s) mentioning awk checked.*/\1/p' "$WORK/repo.out")"
  if [ "${CHECKED:-0}" -ge 20 ]; then
    pass "the repository sweep reached ${CHECKED} files, so discovery is not empty"
  else
    fail "the repository sweep only reached ${CHECKED:-0} files"
  fi
else
  fail "the repository sweep reports how many files it read"
fi

# Reporting success about a file it never opened is the failure mode this whole
# branch is about, so an unreadable path is an error, not a skip.
UNREADABLE_OUT="$(cd "$WORK" && bash "$CHECK" /nonexistent-path-for-this-test 2>&1)"
UNREADABLE_RC=$?
if [ "$UNREADABLE_RC" -ne 0 ] && printf '%s' "$UNREADABLE_OUT" | grep -q "Could not read this file"; then
  pass "a path that cannot be read is an error, not a silent skip"
else
  fail "a path that cannot be read is an error, not a silent skip (exit ${UNREADABLE_RC})"
  printf '%s\n' "$UNREADABLE_OUT" | sed 's/^/    /'
fi

echo
echo "=== Part 6: the extractor that replaced the broken range ==="

# experiments/test-issue121-workflow-audit-scope.sh now bounds a `run:` block by
# indentation instead of by `,0`. Its own fixtures are asserted there; what
# matters here is that the broken spelling has not come back.
if bash "$CHECK" "experiments/test-issue121-workflow-audit-scope.sh" >"$WORK/audit.out" 2>&1; then
  pass "the workflow-audit suite carries no GNU-only escape in a live awk program"
else
  fail "the workflow-audit suite carries no GNU-only escape in a live awk program"
  sed 's/^/    /' "$WORK/audit.out"
fi

if grep -q '^run_block_lines()' "$ROOT/experiments/test-issue121-workflow-audit-scope.sh"; then
  pass "the workflow-audit suite bounds a run: block by indentation instead of by ,0"
else
  fail "the workflow-audit suite bounds a run: block by indentation instead of by ,0"
fi

if bash "$ROOT/experiments/reproduce-issue121-awk-run-block-range.sh" >"$WORK/repro.out" 2>&1; then
  pass "the reproduction still demonstrates the defect on this awk"
else
  fail "the reproduction still demonstrates the defect on this awk"
  sed 's/^/    /' "$WORK/repro.out"
fi

echo
echo "=== Part 7: the check runs in CI ==="

if grep -rq 'check-awk-portability.sh' "$ROOT/.github/workflows"; then
  pass "check-awk-portability.sh runs in CI"
else
  fail "check-awk-portability.sh is not referenced by any workflow"
fi

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
