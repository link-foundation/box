#!/usr/bin/env bash
# test-issue121-links-recheck.sh
#
# The links gate re-asks the URLs no host answered, and nothing else.
#
# Why this exists (issue #121). lychee classifies an error by the phase it
# happened in and answers `false` for the connect phase, so `--max-retries`
# never applies to a connection reset (lycheeverse/lychee#2297). A healthy host
# that resets one connection - routine for a CI address range talking to a
# rate-limiting or load-shedding host - is reported broken without a retry, and
# the links gate fails on it. That is a false positive, and the cheap fix for
# it (an .lycheeignore entry) turns a real 404 on that host into permanent
# silence.
#
# The re-check is therefore allowed to downgrade a failure, and the assertions
# here are about the limits of that permission:
#
#   1. a failure a host answered (a status code, "Rejected status code") is
#      never re-asked and never recovered;
#   2. `all_recovered` - the output that skips the failing step - is written
#      only when the *whole* report was failures no host answered and every one
#      of them answers now. The reference template writes it while answered
#      failures are still in the report, which ends the job green with a 404 in
#      it; reproduced against the template's own script by
#      experiments/issue-121-template-recheck/, reported upstream as
#      js-ai-driven-development-pipeline-template#184 and
#      rust-ai-driven-development-pipeline-template#170, and deliberately
#      not copied;
#   3. the workflow reads that output with `!= 'true'`, so a skipped or crashed
#      re-check fails safe;
#   4. the Wayback step skips a recovered URL rather than looking it up.
#
# Offline: the "network" is a python3 http.server on 127.0.0.1. No suite here
# reaches the internet.
#
# Usage: bash experiments/test-issue121-links-recheck.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

RECHECK="scripts/ci/recheck-broken-links.mjs"
ARCHIVE="scripts/ci/check-web-archive.mjs"
WORKFLOW=".github/workflows/links.yml"

PASS=0
FAIL=0
pass() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
  if [ $# -gt 1 ]; then
    shift
    printf '      %s\n' "$@"
  fi
}

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node is not installed; this suite drives two .mjs scripts."
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 is not installed; this suite serves the stand-in host."
  exit 0
fi

for f in "$RECHECK" "$ARCHIVE" "$WORKFLOW"; do
  if [ -f "$f" ]; then
    pass "$f exists"
  else
    fail "$f is missing"
  fi
done

if [ "$FAIL" -gt 0 ]; then
  echo
  echo "$PASS passed, $FAIL failed"
  exit 1
fi

TMP="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

echo
echo "== Part 1: the parser tells an answered failure from an unanswered one =="

node --input-type=module -e '
import { parseLycheeFailures } from "./scripts/ci/recheck-broken-links.mjs";

const report = `
## Errors per input

### Errors in README.md

- [404] <https://example.com/gone> (at 4:1) | Rejected status code: 404 Not Found
- [500] <https://example.com/broken> (at 5:1) | Rejected status code: 500
- [ERROR] <https://example.com/reset> (at 6:1) | error sending request: connection reset by peer
- [TIMEOUT] <https://example.com/slow> (at 7:1) | Timeout
- [UNKNOWN] <https://example.com/odd> (at 8:1) | Unknown
- [ERROR] <file:///repo/missing.md> (at 9:1) | File not found
`;

const failures = parseLycheeFailures(report);
const by = (url) => failures.find((f) => f.url === url);
const cases = [
  ["a 404 marker is an answer", by("https://example.com/gone").answered === true],
  ["a 500 marker is an answer", by("https://example.com/broken").answered === true],
  ["[ERROR] is not an answer", by("https://example.com/reset").answered === false],
  ["[TIMEOUT] is not an answer", by("https://example.com/slow").answered === false],
  ["[UNKNOWN] is not an answer", by("https://example.com/odd").answered === false],
  ["a missing local file is parsed too", by("file:///repo/missing.md") !== undefined],
  ["every entry is parsed", failures.length === 6],
];

for (const [label, ok] of cases) {
  console.log(`${ok ? "PASS" : "FAIL"}: ${label}`);
}
process.exit(cases.every(([, ok]) => ok) ? 0 : 1)
' >"$TMP/parse.out" 2>&1
sed 's/^/  /' "$TMP/parse.out"
PASS=$((PASS + $(grep -c '^PASS' "$TMP/parse.out")))
FAIL=$((FAIL + $(grep -c '^FAIL' "$TMP/parse.out")))

echo
echo "== Part 2: all_recovered means the whole report was noise =="

node --input-type=module -e '
import { allRecovered, parseAcceptRanges, extractLycheeRequestOptions }
  from "./scripts/ci/recheck-broken-links.mjs";

const cases = [
  ["nothing but unanswered failures, all recovered -> true",
    allRecovered({ finalFailureCount: 0, unansweredCount: 2, recoveredCount: 2, stillBrokenCount: 0 }) === true],
  ["an answered failure is still in the report -> false",
    allRecovered({ finalFailureCount: 1, unansweredCount: 1, recoveredCount: 1, stillBrokenCount: 0 }) === false],
  ["a URL that never answered the re-check either -> false",
    allRecovered({ finalFailureCount: 0, unansweredCount: 2, recoveredCount: 1, stillBrokenCount: 1 }) === false],
  ["nothing was re-asked at all -> false",
    allRecovered({ finalFailureCount: 0, unansweredCount: 0, recoveredCount: 0, stillBrokenCount: 0 }) === false],

  ["the accept list accepts a 200", parseAcceptRanges("100..=103,200..=299")(200) === true],
  ["the accept list rejects a 404", parseAcceptRanges("100..=103,200..=299")(404) === false],
  ["a bare status in the list is accepted", parseAcceptRanges("200..=299,429")(429) === true],
  ["a workflow without --accept gets lychees default",
    extractLycheeRequestOptions("args: --no-progress").accept === "100..=103,200..=299"],
  ["a workflow with --accept is read from the workflow",
    extractLycheeRequestOptions("args: --accept 200..=299,429").accept === "200..=299,429"],
];

for (const [label, ok] of cases) {
  console.log(`${ok ? "PASS" : "FAIL"}: ${label}`);
}
process.exit(cases.every(([, ok]) => ok) ? 0 : 1)
' >"$TMP/unit.out" 2>&1
sed 's/^/  /' "$TMP/unit.out"
PASS=$((PASS + $(grep -c '^PASS' "$TMP/unit.out")))
FAIL=$((FAIL + $(grep -c '^FAIL' "$TMP/unit.out")))

echo
echo "== Part 3: end to end, against a host that answers on 127.0.0.1 =="

PORT=8732
mkdir -p "$TMP/www"
echo ok >"$TMP/www/index.html"
(cd "$TMP/www" && exec python3 -m http.server "$PORT" --bind 127.0.0.1) >/dev/null 2>&1 &
SERVER_PID=$!
served=0
for _ in $(seq 1 50); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then
    served=1
    break
  fi
  sleep 0.1
done
if [ "$served" -eq 1 ]; then
  pass "the stand-in host answers on 127.0.0.1:$PORT"
else
  fail "could not start the stand-in host on 127.0.0.1:$PORT"
  echo
  echo "$PASS passed, $FAIL failed"
  exit 1
fi

# run_recheck <report-file> - run the re-check over a report, capturing its
# output and whatever it wrote to $GITHUB_OUTPUT. Output goes to files rather
# than to stdout: a helper called in $(...) runs in a subshell, and every
# pass/fail counted there would be discarded.
run_recheck() {
  : >"$TMP/github_output"
  rm -f "$TMP/recovered.txt"
  LYCHEE_OUTPUT="$1" \
    RECOVERED_OUTPUT="$TMP/recovered.txt" \
    LINKS_WORKFLOW="$WORKFLOW" \
    GITHUB_OUTPUT="$TMP/github_output" \
    RECHECK_BUDGET_SECONDS=20 \
    RECHECK_WAIT_MS=200 \
    node "$RECHECK" >"$TMP/recheck.out" 2>&1
  echo "$?" >"$TMP/recheck.rc"
}

# A report holding only a URL that refused lychee and answers now.
cat >"$TMP/only-unanswered.md" <<MD
## Errors per input

### Errors in README.md

- [ERROR] <http://127.0.0.1:$PORT/> (at 12:3) | error sending request: connection reset by peer
MD

# The same, plus one link a host answered 404 for.
cat >"$TMP/mixed.md" <<MD
## Errors per input

### Errors in README.md

- [404] <https://example.com/definitely-gone/> (at 48:130) | Rejected status code: 404 Not Found
- [ERROR] <http://127.0.0.1:$PORT/> (at 12:3) | error sending request: connection reset by peer
MD

# A report whose only failure is one a host answered.
cat >"$TMP/answered-only.md" <<MD
## Errors per input

### Errors in README.md

- [404] <https://example.com/definitely-gone/> (at 48:130) | Rejected status code: 404 Not Found
MD

run_recheck "$TMP/only-unanswered.md"
if [ "$(cat "$TMP/recheck.rc")" = "0" ]; then
  pass "the re-check exits 0 (it downgrades failures; it never raises one)"
else
  fail "the re-check exited $(cat "$TMP/recheck.rc")" "$(cat "$TMP/recheck.out")"
fi
if grep -qx 'all_recovered=true' "$TMP/github_output"; then
  pass "a report of nothing but unanswered failures, all healthy now, sets all_recovered=true"
else
  fail "all_recovered was not set for a report that was entirely noise" \
    "$(cat "$TMP/recheck.out")"
fi
if grep -qx "http://127.0.0.1:$PORT/" "$TMP/recovered.txt" 2>/dev/null; then
  pass "the recovered URL is written to the file the Wayback step reads"
else
  fail "the recovered URL was not written to RECOVERED_OUTPUT" \
    "$(cat "$TMP/recheck.out")"
fi

run_recheck "$TMP/mixed.md"
if grep -qx 'all_recovered=true' "$TMP/github_output"; then
  fail "all_recovered=true while a 404 is still in the report" \
    "This is the template's behaviour (see experiments/issue-121-template-recheck/)." \
    "$(cat "$TMP/recheck.out")"
else
  pass "a 404 alongside a recovered URL leaves all_recovered unset"
fi
if grep -q 'never answered lychee' "$TMP/recheck.out"; then
  pass "the recovered URL is still reported as recovered"
else
  fail "the recovered URL was not reported" "$(cat "$TMP/recheck.out")"
fi
if grep -q 'definitely-gone' "$TMP/recovered.txt" 2>/dev/null; then
  fail "the 404 URL was written to the recovered list"
else
  pass "the 404 URL is not in the recovered list"
fi

run_recheck "$TMP/answered-only.md"
if grep -q 'nothing to re-ask' "$TMP/recheck.out"; then
  pass "a report of answered failures only is not re-asked at all"
else
  fail "the re-check tried to re-ask an answered failure" "$(cat "$TMP/recheck.out")"
fi
if grep -qx 'all_recovered=true' "$TMP/github_output"; then
  fail "all_recovered=true for a report holding only a 404" "$(cat "$TMP/recheck.out")"
else
  pass "a report holding only a 404 leaves all_recovered unset"
fi

echo
echo "== Part 4: the Wayback step skips what the re-check recovered =="

printf 'http://127.0.0.1:%s/\n' "$PORT" >"$TMP/recovered-only.txt"
cat >"$TMP/wayback-in.md" <<MD
## Errors per input

### Errors in README.md

- [ERROR] <http://127.0.0.1:$PORT/> (at 12:3) | error sending request: connection reset by peer
MD

: >"$TMP/wayback_output"
LYCHEE_OUTPUT="$TMP/wayback-in.md" \
  RECOVERED_URLS="$TMP/recovered-only.txt" \
  GITHUB_OUTPUT="$TMP/wayback_output" \
  node "$ARCHIVE" >"$TMP/wayback.out" 2>&1
wayback_rc=$?

if [ "$wayback_rc" -eq 0 ]; then
  pass "the Wayback step passes when every broken URL was recovered (exit 0)"
else
  fail "the Wayback step exited $wayback_rc for a report of recovered URLs only" \
    "$(cat "$TMP/wayback.out")"
fi
if grep -q 'not broken' "$TMP/wayback.out"; then
  pass "it says why it skipped the URL"
else
  fail "it did not report the skipped URL" "$(cat "$TMP/wayback.out")"
fi
if grep -q 'archive.org' "$TMP/wayback.out"; then
  fail "it looked a recovered URL up in the Wayback Machine anyway" \
    "$(cat "$TMP/wayback.out")"
else
  pass "it does not look a recovered URL up in the Wayback Machine"
fi

echo
echo "== Part 5: the workflow reads the output so that a skip fails safe =="

assert_workflow() {
  if grep -qF -- "$2" "$WORKFLOW"; then
    pass "$1"
  else
    fail "$1" "not found in $WORKFLOW: $2"
  fi
}

assert_workflow "the re-check step runs the script" \
  "run: node scripts/ci/recheck-broken-links.mjs"
assert_workflow "the re-check step is addressable as steps.recheck" \
  "id: recheck"
assert_workflow "the re-check only runs when lychee failed" \
  "if: steps.lychee.outputs.exit_code != 0"
assert_workflow "the recovered list is handed to the Wayback step" \
  "RECOVERED_URLS: lychee/recovered.txt"
assert_workflow "the re-check writes the list the Wayback step reads" \
  "RECOVERED_OUTPUT: lychee/recovered.txt"

# `== 'false'` is the form that fails open: a skipped step leaves the output
# empty, which is neither 'true' nor 'false', so the consumer would skip too.
consumers="$(grep -c "all_recovered != 'true'" "$WORKFLOW")"
if [ "$consumers" -ge 2 ]; then
  pass "both consumers read all_recovered with != 'true' ($consumers)"
else
  fail "expected the Wayback step and the failing step to read all_recovered with != 'true'" \
    "found $consumers"
fi
if grep -q "all_recovered == 'false'" "$WORKFLOW"; then
  fail "a consumer reads all_recovered with == 'false', which fails open on a skipped step"
else
  pass "no consumer reads all_recovered with == 'false'"
fi
if grep -q "steps.recheck.outputs.all_recovered != 'true'" "$WORKFLOW" \
  && grep -q '!cancelled() && steps.lychee.outputs.exit_code != 0' "$WORKFLOW"; then
  pass "the failing step still runs on its own when the re-check recovered nothing"
else
  fail "the failing step's condition no longer names both lychee and the re-check"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
