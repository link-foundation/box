#!/usr/bin/env bash
# test-issue115-experiment-runner.sh
#
# Issue #115. scripts/ci/run-experiments.sh is the job that runs every other
# regression suite in this repository, and it was the one script with no suite
# of its own - so a defect in it silences all 37 checks at once, which is the
# worst false negative available here.
#
# That is not hypothetical. Adding shfmt (template best practice #3) reformatted
# the runner's skip list, and shfmt formats an array subscript as an arithmetic
# expression: `[node-lts-integration-test.sh]` became
# `[node - lts - integration - test.sh]`. Bash does not evaluate the subscript
# of an associative array, so the key quietly became a different string, all
# three exclusions stopped matching, and the run that was supposed to skip
# three environment-dependent suites ran them and reported two failures. No
# error, no warning: a list that matched nothing looked exactly like a list
# that had nothing to match.
#
# So this suite pins the runner's contract: the skip list applies, a skip entry
# that names nothing is an error, and a failing or hanging suite is reported as
# such rather than swallowed.
#
# Usage: bash experiments/test-issue115-experiment-runner.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
REPO_ROOT="$PWD"

RUNNER="scripts/ci/run-experiments.sh"
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
FIXTURE_RUNNERS=()
cleanup() {
  local f
  rm -rf "$TMP"
  for f in ${FIXTURE_RUNNERS[@]+"${FIXTURE_RUNNERS[@]}"}; do
    rm -f "$f"
  done
}
trap cleanup EXIT

echo "== Part 1: the skip list actually applies =="

LIST="$(bash "$RUNNER" --list 2>&1)"
SKIP_COUNT="$(printf '%s\n' "$LIST" | grep -c '^SKIP ')"
RUN_COUNT="$(printf '%s\n' "$LIST" | grep -c '^RUN ')"
DISCOVERED="$(find experiments -maxdepth 1 -name '*.sh' -type f | wc -l)"

# Derived from the runner's own list rather than written down here as a
# number. A hard-coded 3 is a check that fails the day somebody adds a
# justified exclusion - which says nothing about the runner and everything
# about this assertion - while still passing if an entry stops matching, since
# that lowers the count in the same direction. What the runner promises is that
# every declared exclusion applies, so that is what is compared.
DECLARED_SKIPS="$(grep -cE "^\s*\['[^']+'\]=" "$RUNNER")"

if [ "$DECLARED_SKIPS" -gt 0 ] && [ "$SKIP_COUNT" -eq "$DECLARED_SKIPS" ]; then
  pass "every one of the $DECLARED_SKIPS declared exclusions applies"
else
  fail "every one of the $DECLARED_SKIPS declared exclusions applies (skipped $SKIP_COUNT)"
  printf '%s\n' "$LIST" | sed 's/^/      /' >&2
fi

if [ "$((SKIP_COUNT + RUN_COUNT))" -eq "$DISCOVERED" ]; then
  pass "every discovered suite is either run or skipped ($DISCOVERED total)"
else
  fail "every discovered suite is either run or skipped (listed $((SKIP_COUNT + RUN_COUNT)), found $DISCOVERED)"
fi

# Each skip line carries its reason: an exclusion nobody can justify is the
# first step to a check that nobody runs.
JUSTIFIED="$(printf '%s\n' "$LIST" | grep '^SKIP ' | grep -c 'needs ')"
if [ "$JUSTIFIED" -eq "$SKIP_COUNT" ]; then
  pass "each of the $SKIP_COUNT skipped suites states what it needs"
else
  fail "each of the $SKIP_COUNT skipped suites states what it needs (only $JUSTIFIED do)"
fi

echo ""
echo "== Part 2: a skip entry that matches nothing is an error =="

# A copy of the runner with its first key mangled exactly the way shfmt
# mangled it. It lives under scripts/ci/ because the runner locates the
# repository root relative to its own path.
MANGLED="$(mktemp "$REPO_ROOT/scripts/ci/.runner-fixture-XXXXXX.sh")"
FIXTURE_RUNNERS+=("$MANGLED")
sed "s|\['node-lts-integration-test.sh'\]|[node - lts - integration - test.sh]|" \
  "$RUNNER" >"$MANGLED"

if ! grep -q '\[node - lts - integration - test.sh\]' "$MANGLED"; then
  fail "the fixture reproduces the mangled subscript"
else
  pass "the fixture reproduces the mangled subscript"
fi

OUT="$(bash "$MANGLED" --list 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 2 ]; then
  pass "a skip entry naming no file exits 2 (misuse), not 0"
else
  fail "a skip entry naming no file exits 2 (got $STATUS)"
  printf '%s\n' "$OUT" | sed 's/^/      /' >&2
fi

if [[ "$OUT" == *"::error title=run-experiments::"* ]]; then
  pass "the broken skip entry is annotated"
else
  fail "the broken skip entry is annotated"
  printf '%s\n' "$OUT" | sed 's/^/      /' >&2
fi

# The control: the same copy, unmangled, is fine. Without it the assertion
# above would also pass if the copy were simply broken.
CONTROL="$(mktemp "$REPO_ROOT/scripts/ci/.runner-fixture-XXXXXX.sh")"
FIXTURE_RUNNERS+=("$CONTROL")
cp "$RUNNER" "$CONTROL"
if bash "$CONTROL" --list >/dev/null 2>&1; then
  pass "an unmangled copy of the runner still lists normally"
else
  fail "an unmangled copy of the runner still lists normally"
fi

rm -f "$MANGLED" "$CONTROL"

echo ""
echo "== Part 3: a failing suite fails the run =="

SUITES_DIR="$TMP/suites"
mkdir -p "$SUITES_DIR"
printf '#!/usr/bin/env bash\nexit 0\n' >"$SUITES_DIR/aaa-passing.sh"

OUT="$(EXPERIMENTS_DIR="$SUITES_DIR" LOG_DIR="$TMP/logs" bash "$RUNNER" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 0 ] && [[ "$OUT" == *"passed:  1"* ]]; then
  pass "a passing suite is reported as passed and the run exits 0"
else
  fail "a passing suite is reported as passed and the run exits 0 (exit $STATUS)"
  printf '%s\n' "$OUT" | sed 's/^/      /' >&2
fi

printf '#!/usr/bin/env bash\necho "the reason it failed"\nexit 3\n' >"$SUITES_DIR/bbb-failing.sh"

OUT="$(EXPERIMENTS_DIR="$SUITES_DIR" LOG_DIR="$TMP/logs" bash "$RUNNER" 2>&1)"
STATUS=$?
if [ "$STATUS" -ne 0 ]; then
  pass "one failing suite fails the whole run"
else
  fail "one failing suite fails the whole run (exit $STATUS)"
  printf '%s\n' "$OUT" | sed 's/^/      /' >&2
fi

if [[ "$OUT" == *"::error file=$SUITES_DIR/bbb-failing.sh::Suite failed with exit status 3"* ]]; then
  pass "the failing suite is annotated with its file and exit status"
else
  fail "the failing suite is annotated with its file and exit status"
  printf '%s\n' "$OUT" | sed 's/^/      /' >&2
fi

# The output of a failing suite has to reach the log, or the annotation sends
# the reader to a file that GitHub deleted with the runner.
if [[ "$OUT" == *"the reason it failed"* ]]; then
  pass "the failing suite's own output is printed"
else
  fail "the failing suite's own output is printed"
fi

if [[ "$OUT" == *"passed:  1"* ]] && [[ "$OUT" == *"failed:  1"* ]]; then
  pass "the summary counts both outcomes"
else
  fail "the summary counts both outcomes"
fi

rm -f "$SUITES_DIR/bbb-failing.sh"

echo ""
echo "== Part 4: a hanging suite is killed and named =="

printf '#!/usr/bin/env bash\nsleep 30\n' >"$SUITES_DIR/ccc-hanging.sh"

OUT="$(SUITE_TIMEOUT=2 EXPERIMENTS_DIR="$SUITES_DIR" LOG_DIR="$TMP/logs" bash "$RUNNER" 2>&1)"
STATUS=$?
rm -f "$SUITES_DIR/ccc-hanging.sh"

if [ "$STATUS" -ne 0 ] && [[ "$OUT" == *"Suite timed out after 2s"* ]]; then
  pass "a suite that hangs is timed out and reported as a timeout, not a failure"
else
  fail "a suite that hangs is timed out and reported as a timeout (exit $STATUS)"
  printf '%s\n' "$OUT" | sed 's/^/      /' >&2
fi

echo ""
echo "== Part 5: a skipped suite is not executed =="

# Named after a real entry in the skip list, and destructive enough that a run
# would be obvious: if the skip stopped applying - the shfmt defect - the
# marker appears.
MARKER="$TMP/should-not-exist"
printf '#!/usr/bin/env bash\ntouch %q\n' "$MARKER" >"$SUITES_DIR/verify-full-box-tooling.sh"

OUT="$(EXPERIMENTS_DIR="$SUITES_DIR" LOG_DIR="$TMP/logs" bash "$RUNNER" 2>&1)"

if [ ! -e "$MARKER" ]; then
  pass "a suite on the skip list is not executed"
else
  fail "a suite on the skip list is executed anyway - the skip list is not applying"
fi

if [[ "$OUT" == *"SKIP verify-full-box-tooling.sh"* ]] && [[ "$OUT" == *"skipped: 1"* ]]; then
  pass "the skip is announced and counted"
else
  fail "the skip is announced and counted"
  printf '%s\n' "$OUT" | sed 's/^/      /' >&2
fi

rm -f "$SUITES_DIR/verify-full-box-tooling.sh"

echo ""
echo "== Part 6: an empty suite directory is an error, not a pass =="

# The failure mode this repository keeps finding: a discovery that finds
# nothing exits 0 and looks exactly like everything passing.
mkdir -p "$TMP/empty"
OUT="$(EXPERIMENTS_DIR="$TMP/empty" LOG_DIR="$TMP/logs" bash "$RUNNER" 2>&1)"
STATUS=$?
if [ "$STATUS" -ne 0 ] && [[ "$OUT" == *"discovery glob is wrong"* ]]; then
  pass "finding no suites at all fails loudly"
else
  fail "finding no suites at all fails loudly (exit $STATUS)"
  printf '%s\n' "$OUT" | sed 's/^/      /' >&2
fi

echo ""
echo "== Part 7: the runner is wired into CI =="

if grep -q 'bash scripts/ci/run-experiments.sh$' .github/workflows/scripts.yml; then
  pass "scripts.yml runs every suite"
else
  fail "scripts.yml runs every suite"
fi

if grep -q 'run-experiments.sh --list' .github/workflows/scripts.yml; then
  pass "scripts.yml prints the list first, so a shrinking suite set is visible"
else
  fail "scripts.yml prints the list first"
fi

# ---------------------------------------------------------------------------
echo
echo "== The --list-inputs contract =="
#
# The discovered set, one repository-relative path per line, nothing else, exit
# 0. scripts/ci/check-workflow-path-coverage.mjs reads it to decide whether a
# workflow's `paths:` filter can be matched by the files this gate reads. A
# gate that answers this wrongly makes that check wrong in whichever direction
# the error points: paths the filter cannot match are reported as unreachable
# when they are fine, or - worse - the real inputs are never compared at all
# and a job that can never start goes on looking like a clean tree (issue #121).

CONTRACT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT_GATE="scripts/ci/run-experiments.sh"
CONTRACT_RC=0
CONTRACT_OUT="$(cd "$CONTRACT_ROOT" && bash "$CONTRACT_ROOT/$CONTRACT_GATE" --list-inputs 2>&1)" || CONTRACT_RC=$?

[ "$CONTRACT_RC" -eq 0 ] \
  && pass "--list-inputs exits 0" \
  || fail "--list-inputs exited $CONTRACT_RC"

CONTRACT_COUNT="$(printf '%s\n' "$CONTRACT_OUT" | grep -c .)"
[ "$CONTRACT_COUNT" -gt 0 ] \
  && pass "--list-inputs names $CONTRACT_COUNT input(s)" \
  || fail "--list-inputs named nothing, so the coverage check compares an empty set"

# Paths only: no banner, no count, no option echo, no blank line. Anything else
# here is read by the coverage gate as a file name and matched against `paths:`
# patterns, where it can only ever be a finding about a file that is not there.
CONTRACT_STRAY=""
while IFS= read -r contract_line; do
  if [ -z "$contract_line" ]; then
    CONTRACT_STRAY="(a blank line)"
    break
  fi
  case "$contract_line" in
    -*)
      CONTRACT_STRAY="$contract_line"
      break
      ;;
  esac
  if [ ! -f "$CONTRACT_ROOT/$contract_line" ]; then
    CONTRACT_STRAY="$contract_line"
    break
  fi
done <<<"$CONTRACT_OUT"
[ -z "$CONTRACT_STRAY" ] \
  && pass "every line is a repository-relative path that exists" \
  || fail "--list-inputs printed something that is not a tracked path" "$CONTRACT_STRAY"

CONTRACT_DUPES="$(printf '%s\n' "$CONTRACT_OUT" | sort | uniq -d)"
[ -z "$CONTRACT_DUPES" ] \
  && pass "and names each of them once" \
  || fail "--list-inputs repeats a path" "$CONTRACT_DUPES"

printf '%s\n' "$CONTRACT_OUT" | grep -qx -- 'experiments/test-issue115-experiment-runner.sh' \
  && pass "and names experiments/test-issue115-experiment-runner.sh, which this gate demonstrably reads" \
  || fail "--list-inputs omits experiments/test-issue115-experiment-runner.sh"

# dev/log holds downloaded evidence and verbatim copies of other projects'
# files. They are not ours to fix, and every gate here excludes them.
printf '%s\n' "$CONTRACT_OUT" | grep -q '^dev/log/' \
  && fail "--list-inputs includes the vendored evidence tree" \
  || pass "and excludes dev/log, as the sweep itself does"

# `git ls-files` answers about the current directory. Run from a subdirectory
# it lists that subtree alone, with paths relative to it - so a gate that does
# not anchor at the top level first sweeps a fraction of the tree, exits 0 over
# it, and answers this contract with paths that no repository-root pattern can
# match. experiments/reproduce-issue121-subdirectory-discovery.sh measures it
# for every gate at once; this is the assertion for this one.
CONTRACT_SUB="$(cd "$CONTRACT_ROOT/scripts" && bash "$CONTRACT_ROOT/$CONTRACT_GATE" --list-inputs 2>&1)" || true
[ "$CONTRACT_SUB" = "$CONTRACT_OUT" ] \
  && pass "and gives the same answer from a subdirectory, being about the repository" \
  || fail "--list-inputs reports on whichever directory it is started from" \
    "$(printf '%s\n' "$CONTRACT_SUB" | head -3)"

echo ""
echo "================================"
echo "Passed: $PASS"
echo "Failed: $FAIL"
echo "================================"
[ "$FAIL" -eq 0 ]
