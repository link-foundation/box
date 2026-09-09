#!/usr/bin/env bash
# test-issue121-py-syntax.sh
#
# Issue #121. Fixtures for scripts/ci/check-py-syntax.sh.
#
# The gap it closes: three tracked *.py files outside dev/log/, parsed by
# nothing. shellcheck and shfmt take *.sh, run-experiments.sh discovers *.sh,
# and the pyflakes bundled in actionlint's image reads workflow `run:` blocks,
# not the files those blocks call. Two of the three decide what happens to a
# three-hour disk measurement.
#
# A gate is only worth having if it can fail, so most of what follows is
# fixtures that must be reported and fixtures that must not.
#
# Usage: bash experiments/test-issue121-py-syntax.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
CHECK="$ROOT/scripts/ci/check-py-syntax.sh"

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

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 is not installed; this suite drives a checker that compiles Python."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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

echo "=== Part 1: a file that does not compile is reported ==="

expect flagged unclosed.py 'def f():
    return {"ok": True,
' \
  "an unclosed dict literal is reported"
expect flagged colon.py 'def broken(:
    pass' \
  "a malformed parameter list is reported"
expect flagged indent.py 'def f():
pass' \
  "a missing indent is reported"
expect flagged string.py 's = "never closed
print(s)' \
  "an unterminated string is reported"
expect flagged py2.py 'print "hello"' \
  "Python 2 print syntax is reported, because this repository runs python3"

echo ""
echo "=== Part 2: valid Python is not reported ==="

expect clean ok.py 'import json


def main(path):
    with open(path) as handle:
        return json.load(handle)
' \
  "an ordinary module is clean"
expect clean fstring.py 'name = "box"
print(f"{name!r} {1 + 2:>4}")' \
  "an f-string with a conversion and a format spec is clean"
expect clean walrus.py 'values = [1, 2, 3]
if (total := sum(values)) > 2:
    print(total)' \
  "the walrus operator is clean"
expect clean typed.py 'def f(x: int | None = None) -> str:
    match x:
        case None:
            return "none"
        case _:
            return str(x)' \
  "match statements and union annotations are clean"
expect clean empty.py '' \
  "an empty file is clean"

# A NameError is a runtime fact, not a syntax one. Reporting it here would be a
# false positive from a parser, and the header says so out loud.
expect clean runtime.py 'print(undefined_name)' \
  "an undefined name is NOT reported: this is a parse, not an execution"
expect clean missing-import.py 'import a_package_that_is_not_installed' \
  "an unimportable module is NOT reported, for the same reason"

echo ""
echo "=== Part 3: the annotation says where ==="

printf 'x = 1\ny = 2\ndef broken(:\n    pass\n' >"$WORK/where.py"
OUT="$(cd "$WORK" && bash "$CHECK" where.py 2>&1)"

if printf '%s\n' "$OUT" | grep -q '^::error file=where.py,line=3'; then
  pass "the annotation carries the file and the line the error is on"
else
  fail "the annotation does not point at line 3"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi

if printf '%s\n' "$OUT" | grep -q 'title=Python syntax error'; then
  pass "and a title that names the defect"
else
  fail "the annotation has no Python syntax error title"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi

# A path is passed in argv, never interpolated into the program text, so a file
# whose name contains a quote cannot change what is compiled.
printf 'x = (\n' >"$WORK/qu'ote.py"
QUOTED_OUT="$(cd "$WORK" && bash "$CHECK" "qu'ote.py" 2>&1)"
if printf '%s\n' "$QUOTED_OUT" | grep -q "^::error file=qu'ote.py"; then
  pass "a file name containing a quote is reported, not executed"
else
  fail "a file name containing a quote was mishandled"
  printf '%s\n' "$QUOTED_OUT" | sed 's/^/    /'
fi

echo ""
echo "=== Part 4: it does not litter the tree ==="

printf 'x = 1\n' >"$WORK/cached.py"
(cd "$WORK" && bash "$CHECK" cached.py >/dev/null 2>&1)
if [ -d "$WORK/__pycache__" ]; then
  fail "compiling wrote a __pycache__ directory into the tree"
else
  pass "no __pycache__ is written: compile() is called directly, not py_compile"
fi

echo ""
echo "=== Part 5: usage, discovery and exit codes ==="

(cd "$WORK" && bash "$CHECK" --not-an-option >/dev/null 2>&1)
if [ "$?" -eq 2 ]; then
  pass "an unknown option exits 2 (could not run), not 1 (found a problem)"
else
  fail "an unknown option did not exit 2"
fi

(cd "$WORK" && bash "$CHECK" missing-file.py >/dev/null 2>&1)
if [ "$?" -eq 1 ]; then
  pass "a named file that is not there is a finding, not a silent pass"
else
  fail "a missing file was not reported"
fi

INPUTS="$(cd "$ROOT" && bash "$CHECK" --list-inputs)"
if [ -n "$INPUTS" ] && ! printf '%s\n' "$INPUTS" | grep -qv '\.py$'; then
  pass "--list-inputs prints paths and nothing else"
else
  fail "--list-inputs printed something that is not a .py path"
  printf '%s\n' "$INPUTS" | sed 's/^/    /'
fi

if printf '%s\n' "$INPUTS" | grep -qx 'scripts/ci/validate-measurements.py'; then
  pass "and it covers the validator that decides a measurement's fate"
else
  fail "--list-inputs does not name scripts/ci/validate-measurements.py"
fi

if printf '%s\n' "$INPUTS" | grep -q '^dev/log/'; then
  fail "dev/log/ is not excluded; those are other projects' sources"
else
  pass "dev/log/ is excluded, as the header says"
fi

# The whole point of --list-inputs: something else reads it. If the discovery
# and the listing ever diverge, the coverage gate is checking a set the gate
# does not use.
SWEEP="$(cd "$ROOT" && bash "$CHECK" --verbose 2>&1 | sed -n 's/^  \[parse\] //p')"
if [ "$(printf '%s\n' "$SWEEP" | sort)" = "$(printf '%s\n' "$INPUTS" | sort)" ]; then
  pass "--list-inputs names exactly the files the checker parses"
else
  fail "--list-inputs and the actual sweep disagree"
  diff <(printf '%s\n' "$SWEEP" | sort) <(printf '%s\n' "$INPUTS" | sort) | sed 's/^/    /'
fi

echo ""
echo "=== Part 6: the repository is clean, and the gate runs in CI ==="

if (cd "$ROOT" && bash "$CHECK" >/dev/null 2>&1); then
  pass "every tracked Python file in this repository compiles"
else
  fail "the repository does not pass its own Python syntax gate"
  (cd "$ROOT" && bash "$CHECK" 2>&1 | sed 's/^/    /')
fi

if grep -rqF 'check-py-syntax.sh' "$ROOT/.github/workflows"; then
  pass "check-py-syntax.sh is called by a workflow"
else
  fail "check-py-syntax.sh is not called by any workflow, so it checks nothing"
fi

if grep -rqF 'test-issue121-py-syntax.sh' "$ROOT/.github/workflows"; then
  pass "these fixtures run in CI too"
else
  fail "these fixtures are not called by any workflow"
fi

if grep -qF 'check-py-syntax.sh' "$ROOT/scripts/ci/run-precommit-checks.sh"; then
  pass "and the pre-commit hook runs it before the commit exists"
else
  fail "the pre-commit hook does not run it"
fi

echo ""
echo "Passed: $PASS, Failed: $FAIL"
[ "$FAIL" -eq 0 ]
