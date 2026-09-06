#!/usr/bin/env bash
# test-issue115-shfmt-gate.sh
#
# Issue #115, template best practice #3 ("automated code formatting"): the
# reference template runs prettier over a JavaScript repository; this
# repository is written in shell and had no formatter at all. 74 of its 98
# tracked scripts disagreed with any single consistent style.
#
# scripts/ci/run-shfmt.sh closes that, and this suite is the reason to believe
# it. Two properties matter and neither is visible from a green check:
#
#   1. it fails on the styles that were actually in the tree (four-space
#      indents, `a; b` on one line, unindented `case` arms);
#   2. it cannot pass by accident. shfmt is easy to invoke in a way that
#      examines nothing - a wrong mount path, a stale image, a tool missing
#      from PATH - and every one of those exits 0 with no output, which is
#      indistinguishable from "everything is formatted". That is RC-16, the
#      recurring defect of this whole pull request, so the runner carries a
#      canary and Part 5 proves the canary works by breaking the formatter on
#      purpose.
#
# Usage: bash experiments/test-issue115-shfmt-gate.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

RUNNER="scripts/ci/run-shfmt.sh"
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

# Fixtures live inside the repository, not in /tmp: the runner reaches shfmt
# through a container that mounts the repository root, so a path outside it
# does not exist as far as the formatter is concerned. They are removed as soon
# as each assertion is done, because Part 7 checks the whole discovered tree and
# an orphaned fixture would fail it - as a real finding, which is worse than no
# finding at all.
FIXTURES=()
cleanup() {
  local f
  for f in ${FIXTURES[@]+"${FIXTURES[@]}"}; do
    rm -f "$f"
  done
}
trap cleanup EXIT

# new_fixture CONTENT -> prints a repo-relative path
new_fixture() {
  local path
  path="$(mktemp "$PWD/.shfmt-fixture-XXXXXX.sh")"
  printf '%s' "$1" >"$path"
  FIXTURES+=("$path")
  printf '%s\n' "${path#"$PWD"/}"
}

OUT=""
STATUS=0
run_on() {
  OUT="$(bash "$RUNNER" "$@" 2>&1)"
  STATUS=$?
}

echo "== Part 1: the runner exists and satisfies its own rule =="

if [ -x "$RUNNER" ]; then
  pass "$RUNNER is executable"
else
  fail "$RUNNER is executable"
fi

run_on "$RUNNER"
if [ "$STATUS" -eq 0 ]; then
  pass "the runner is formatted by its own style"
else
  fail "the runner is formatted by its own style (exit $STATUS)"
  echo "$OUT" | sed 's/^/      /' >&2
fi

echo ""
echo "== Part 2: false-negative fixtures - each style that was in the tree is rejected =="

# One fixture per style this repository actually used before the reformat.
# LABEL|BODY, body written with real newlines by printf.
declare -a CASES=(
  "four-space indent|if true; then\n    echo hi\nfi\n"
  "two statements on one line|x=1; y=2\necho \"\$x\$y\"\n"
  "unindented case arms|case \"\$1\" in\n-v) echo v ;;\n*) echo o ;;\nesac\n"
  "operator at end of a continued line|true &&\n  echo yes\n"
  "space before a redirection target|: > /dev/null\n"
)

for entry in "${CASES[@]}"; do
  label="${entry%%|*}"
  body="${entry#*|}"
  # shellcheck disable=SC2059  # the fixture bodies carry the escapes on purpose
  file="$(new_fixture "$(printf "#!/usr/bin/env bash\n$body")")"

  run_on "$file"
  if [ "$STATUS" -eq 1 ]; then
    pass "$label is rejected"
  else
    fail "$label is rejected (exit $STATUS)"
    echo "$OUT" | sed 's/^/      /' >&2
  fi

  if [[ "$OUT" == *"::error file=${file},line=1::"* ]]; then
    pass "$label is annotated on the file"
  else
    fail "$label is annotated on the file"
    echo "$OUT" | sed 's/^/      /' >&2
  fi

  rm -f "$file"
done

echo ""
echo "== Part 3: false-positive fixture - already-formatted shell passes =="

CLEAN="$(new_fixture '#!/usr/bin/env bash
set -euo pipefail

greet() {
  local name="$1"
  case "$name" in
    -*)
      echo "not a name" >&2
      return 2
      ;;
    *) echo "hello, $name" ;;
  esac
}

if greet world \
  && greet again; then
  : >/dev/null
fi
')"

run_on "$CLEAN"
if [ "$STATUS" -eq 0 ]; then
  pass "a file already in the style passes untouched"
else
  fail "a file already in the style passes untouched (exit $STATUS)"
  echo "$OUT" | sed 's/^/      /' >&2
fi
rm -f "$CLEAN"

echo ""
echo "== Part 4: --fix rewrites the file and does not change what it does =="

BEHAVE="$(new_fixture '#!/usr/bin/env bash
set -euo pipefail
total=0
for n in 1 2 3; do total=$((total + n)); done
case "$total" in
6) echo "six" ;;
*) echo "not six" ;;
esac
printf "%s\n" "$total"
')"

BEFORE="$(bash "$BEHAVE" 2>&1)"

run_on "$BEHAVE"
if [ "$STATUS" -eq 1 ]; then
  pass "the fixture starts out unformatted"
else
  fail "the fixture starts out unformatted (exit $STATUS)"
fi

run_on --fix "$BEHAVE"
if [ "$STATUS" -eq 0 ]; then
  pass "--fix exits 0"
else
  fail "--fix exits 0 (exit $STATUS)"
  echo "$OUT" | sed 's/^/      /' >&2
fi

run_on "$BEHAVE"
if [ "$STATUS" -eq 0 ]; then
  pass "the same file passes the check after --fix"
else
  fail "the same file passes the check after --fix (exit $STATUS)"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# The formatter runs in a container when shfmt is not on PATH, and a container
# writing as root leaves a tree the person who ran the formatter cannot edit.
# That is exactly what happened the first time this suite ran: the assertion
# below reported "reformatting changed the output" because reading the file
# back said "Permission denied". Checked explicitly now, so the next occurrence
# says what it means.
if [ -O "$BEHAVE" ] && [ -w "$BEHAVE" ]; then
  pass "--fix leaves the file owned by, and writable to, the caller"
else
  fail "--fix leaves the file owned by, and writable to, the caller ($(ls -l "$BEHAVE"))"
fi

AFTER="$(bash "$BEHAVE" 2>&1)"
if [ "$BEFORE" = "$AFTER" ]; then
  pass "reformatting did not change the script's output"
else
  fail "reformatting did not change the script's output"
  echo "      before: $BEFORE" >&2
  echo "      after:  $AFTER" >&2
fi

# Idempotence. A formatter whose output is not a fixed point turns every commit
# into a diff, and the check would then never be satisfiable.
CHECKSUM_ONE="$(cksum <"$BEHAVE")"
run_on --fix "$BEHAVE"
if [ "$CHECKSUM_ONE" = "$(cksum <"$BEHAVE")" ]; then
  pass "--fix is idempotent"
else
  fail "--fix is idempotent"
fi
rm -f "$BEHAVE"

echo ""
echo "== Part 5: a formatter that examines nothing must not report success =="

# The whole point of the canary in run-shfmt.sh. Each fake below is a way the
# real invocation can silently stop looking at the files: shfmt replaced by
# something that prints nothing, and shfmt absent altogether. Neither may exit
# 0, because 0 means "these files are formatted".
FAKEBIN="$(mktemp -d)"

cat >"$FAKEBIN/shfmt" <<'FAKE'
#!/usr/bin/env bash
# Prints nothing, claims success - a wrong mount path, an empty file set, or a
# tool that silently ignored its arguments all look exactly like this.
exit 0
FAKE
chmod +x "$FAKEBIN/shfmt"

MISFORMATTED="$(new_fixture "$(printf '#!/usr/bin/env bash\nif true; then\n    echo hi\nfi\n')")"

OUT="$(PATH="$FAKEBIN:$PATH" bash "$RUNNER" "$MISFORMATTED" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 2 ]; then
  pass "a silent formatter exits 2, not 0"
else
  fail "a silent formatter exits 2, not 0 (exit $STATUS)"
  echo "$OUT" | sed 's/^/      /' >&2
fi

if [[ "$OUT" == *"self-check failed"* ]]; then
  pass "the silent formatter is named as a self-check failure"
else
  fail "the silent formatter is named as a self-check failure"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# Same fixture, real formatter: proves the assertion above failed because of
# the fake and not because the fixture was somehow acceptable.
run_on "$MISFORMATTED"
if [ "$STATUS" -eq 1 ]; then
  pass "the same fixture is a plain exit-1 finding under the real formatter"
else
  fail "the same fixture is a plain exit-1 finding under the real formatter (exit $STATUS)"
fi

# Neither shfmt nor docker reachable. Only dirname is linked into the fake
# PATH, which is all the runner needs before it decides it cannot run.
# `bash` and `dirname` are resolved here, before PATH is replaced: with an
# empty PATH the shell cannot even find the interpreter, and the 127 that
# produces would be mistaken for the runner's own verdict.
BASH_BIN="$(command -v bash)"
NOTOOLS="$(mktemp -d)"
ln -s "$(command -v dirname)" "$NOTOOLS/dirname"
OUT="$(PATH="$NOTOOLS" "$BASH_BIN" "$RUNNER" "$MISFORMATTED" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 2 ] && [[ "$OUT" == *"shfmt unavailable"* ]]; then
  pass "no formatter available exits 2 and says so"
else
  fail "no formatter available exits 2 and says so (exit $STATUS)"
  echo "$OUT" | sed 's/^/      /' >&2
fi

rm -rf "$FAKEBIN" "$NOTOOLS"
rm -f "$MISFORMATTED"

echo ""
echo "== Part 6: the file set is discovered, and misuse is rejected =="

LISTED="$(bash "$RUNNER" --list)"
EXPECTED="$(git ls-files --cached --others --exclude-standard --deduplicate '*.sh' \
  | grep -vc '^dev/log/')"
LISTED_COUNT="$(printf '%s\n' "$LISTED" | grep -c .)"

if [ "$LISTED_COUNT" = "$EXPECTED" ]; then
  pass "every tracked or newly added *.sh outside dev/log/ is listed ($EXPECTED file(s))"
else
  fail "every tracked or newly added *.sh outside dev/log/ is listed (listed $LISTED_COUNT, expected $EXPECTED)"
fi

if printf '%s\n' "$LISTED" | grep -q '^dev/log/'; then
  fail "vendored evidence under dev/log/ is excluded"
else
  pass "vendored evidence under dev/log/ is excluded"
fi

for expected in scripts/ci/run-shfmt.sh ubuntu/24.04/common.sh experiments/test-issue115-shfmt-gate.sh; do
  if printf '%s\n' "$LISTED" | grep -qx "$expected"; then
    pass "$expected is covered"
  else
    fail "$expected is covered"
  fi
done

run_on --no-such-option
if [ "$STATUS" -eq 2 ]; then
  pass "an unknown option exits 2 (misuse), not 1 (a finding)"
else
  fail "an unknown option exits 2 (misuse), not 1 (exit $STATUS)"
fi

echo ""
echo "== Part 7: the repository is formatted today =="

run_on
if [ "$STATUS" -eq 0 ]; then
  pass "every discovered shell script matches shfmt -i 2 -ci -bn"
else
  fail "every discovered shell script matches shfmt -i 2 -ci -bn (exit $STATUS)"
  echo "$OUT" | tail -40 | sed 's/^/      /' >&2
fi

echo ""
echo "== Part 8: the one construct the formatter is not safe on =="

# shfmt formats an array subscript as an arithmetic expression, and bash does
# not evaluate the subscript of an associative array. So an unquoted key that
# contains what looks like an operator survives the round trip as a *different
# key*: `[node-lts-integration-test.sh]` in scripts/ci/run-experiments.sh came
# back as `[node - lts - integration - test.sh]`, three skip entries stopped
# matching, and nothing reported anything. Upstream declines to change this:
# mvdan/sh#1343, #1273 and #1367 were all closed pointing at the README
# caveat "when indexing Bash associative arrays, always use quotes", because
# the static parser cannot tell a literal key from arithmetic. So the
# invariant that keeps it from recurring here is that no subscript is left
# unquoted.
# A subscript containing an operator is the risky shape; quoted keys are
# safe, so lines whose subscript opens with a quote are filtered out.
UNQUOTED="$(bash "$RUNNER" --list \
  | xargs grep -nE '^[[:space:]]*\[[^]]*[-+*/%][^]]*\]=' 2>/dev/null \
  | grep -vE "\\[['\"]" || true)"

if [ -z "$UNQUOTED" ]; then
  pass "no unquoted associative-array subscript is left for the formatter to rewrite"
else
  fail "an unquoted associative-array subscript can be silently rewritten - quote it"
  printf '%s\n' "$UNQUOTED" | sed 's/^/      /' >&2
fi

# And the demonstration, so the paragraph above is checkable rather than
# folklore. The key is assembled at fixture-writing time rather than written
# out literally, because a literal here would be flagged by the scan directly
# above - the suite would report its own fixture as a finding.
KEY="a-b.sh"
SUBSCRIPT="$(new_fixture "$(printf '%s\ndeclare -A M=(\n  [%s]="one"\n)\nk="%s"\necho "${M[$k]:-missing}"\n' '#!/usr/bin/env bash' "$KEY" "$KEY")")"

# The lookup goes through a variable, exactly as run-experiments.sh looked its
# skip entries up: that is why the formatter could rewrite the declaration
# without rewriting anything that reads it, and why nothing broke visibly.
if [ "$(bash "$SUBSCRIPT")" = "one" ]; then
  pass "the fixture finds its key before the formatter touches it"
else
  fail "the fixture finds its key before the formatter touches it"
fi

run_on --fix "$SUBSCRIPT"
if grep -q 'a - b.sh' "$SUBSCRIPT"; then
  pass "the formatter demonstrably rewrites an unquoted subscript"
  if [ "$(bash "$SUBSCRIPT")" = "missing" ]; then
    pass "and the rewrite silently changes what the script does"
  else
    fail "and the rewrite silently changes what the script does"
    sed 's/^/      /' "$SUBSCRIPT" >&2
  fi
else
  # Not a failure of this repository: it would mean shfmt fixed it upstream,
  # at which point the invariant above is belt and braces rather than the only
  # thing standing between the skip list and silence.
  pass "the formatter no longer rewrites unquoted subscripts (fixed upstream)"
  pass "and the rewrite silently changes what the script does (moot; not reproduced)"
fi
rm -f "$SUBSCRIPT"

echo ""
echo "== Part 9: the gate is wired into CI =="

WF=".github/workflows/scripts.yml"
if grep -q 'scripts/ci/run-shfmt.sh' "$WF"; then
  pass "$WF runs the formatter check"
else
  fail "$WF runs the formatter check"
fi

if grep -q 'experiments/test-issue115-shfmt-gate.sh' "$WF"; then
  pass "$WF runs this suite alongside it"
else
  fail "$WF runs this suite alongside it"
fi

# A check that only runs on `push` reports after the merge, which is too late
# to stop anything.
if grep -q 'pull_request:' "$WF"; then
  pass "$WF is triggered by pull_request"
else
  fail "$WF is triggered by pull_request"
fi

echo ""
echo "================================"
echo "Passed: $PASS"
echo "Failed: $FAIL"
echo "================================"
[ "$FAIL" -eq 0 ]
