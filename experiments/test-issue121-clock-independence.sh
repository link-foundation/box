#!/usr/bin/env bash
# test-issue121-clock-independence.sh
#
# Issue #121: "Check for all false positives, false negatives, warnings and
# errors in CI/CD and fix them all."
#
# The first one found was a check that could only pass on one day.
# experiments/test-issue119-image-tags.sh asserted "the date tag defaults to
# today in UTC", but its run() helper pinned IMAGE_TAGS_DATE=20260908 on every
# call, so the assertion compared the pin against `date -u +%Y%m%d`. It passed
# on 2026-09-08 and failed from 2026-09-09 00:00 UTC onwards - a green run that
# meant nothing, followed by a red run that blamed working release tooling.
# Run 34293699072 of the Scripts workflow is where it landed.
#
# A suite whose result depends on the wall clock is a false negative waiting for
# the calendar, so this one runs the clock-reading suites against a stopped
# clock. Two dates far apart, plus a run across a UTC midnight, and a suite that
# disagrees with itself is the defect - whichever answer it gave today.
#
# How it works: a `date` stub is put first on PATH. It forwards to the real date
# with `--date=@<epoch>` prepended, so a caller's own `--date`/`-d` still wins
# (GNU date takes the last one) and every other flag behaves normally.
#
# What it asserts:
#   Part 1  the stub itself moves the clock, so a green result means something
#   Part 2  every suite that reads the clock passes at any date it is given
#   Part 3  scripts/release/image-tags.sh follows the clock it is given
#
# Usage: bash experiments/test-issue121-clock-independence.sh
#        BOX_VERBOSE=1 bash experiments/test-issue121-clock-independence.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

BOX_VERBOSE="${BOX_VERBOSE:-0}"
PASS=0
FAIL=0

pass() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
  [ $# -gt 1 ] && printf '      %s\n' "${@:2}" >&2
  return 0
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REAL_DATE="$(command -v date)"
if [ -z "$REAL_DATE" ]; then
  echo "::error title=test-issue121-clock-independence::no date(1) on PATH" >&2
  exit 2
fi

mkdir -p "$TMP/bin"
cat >"$TMP/bin/date" <<STUB
#!/usr/bin/env bash
# Stopped clock. --date is prepended, so a caller that names its own date still
# gets it: GNU date honours the last --date on the command line.
exec "$REAL_DATE" --date="@\${BOX_FAKE_EPOCH:?BOX_FAKE_EPOCH is required}" "\$@"
STUB
chmod +x "$TMP/bin/date"

# Dates to hold the clock at. The first two are far enough apart that a suite
# with a hard-coded date cannot match both; the third is 23:59:30 UTC, which is
# where a suite that reads the clock twice comes apart.
declare -a CLOCKS=(
  "1577880000:2020-01-01 12:00:00 UTC"
  "1924948800:2030-12-31 12:00:00 UTC"
  "1893455970:2029-12-31 23:59:30 UTC"
)

echo "=== Part 1: the stub moves the clock ==="

for clock in "${CLOCKS[@]}"; do
  epoch="${clock%%:*}"
  label="${clock#*:}"
  got="$(PATH="$TMP/bin:$PATH" BOX_FAKE_EPOCH="$epoch" date -u +%Y%m%d)"
  want="$("$REAL_DATE" -u -d "@$epoch" +%Y%m%d)"
  if [ "$got" = "$want" ]; then
    pass "the clock stops at $label ($want)"
  else
    fail "the clock stops at $label ($want)" "got: $got"
  fi
done

# A stub that silently forwarded the live clock would make every assertion below
# vacuous, which is the same defect this suite exists to catch.
if [ "$(PATH="$TMP/bin:$PATH" BOX_FAKE_EPOCH=1577880000 date -u +%Y%m%d)" \
  != "$("$REAL_DATE" -u +%Y%m%d)" ]; then
  pass "a stopped clock does not read today, so a pass below is not vacuous"
else
  fail "a stopped clock does not read today, so a pass below is not vacuous" \
    "the stub returned today's date for 2020-01-01"
fi

# An explicit date on the command line still wins, so a script that computes a
# date from a value it was handed keeps working under the stub.
if [ "$(PATH="$TMP/bin:$PATH" BOX_FAKE_EPOCH=1577880000 date -u -d @1000000000 +%Y%m%d)" = "20010909" ]; then
  pass "a caller that names its own date still gets it"
else
  fail "a caller that names its own date still gets it" \
    "got: $(PATH="$TMP/bin:$PATH" BOX_FAKE_EPOCH=1577880000 date -u -d @1000000000 +%Y%m%d)"
fi

echo
echo "=== Part 2: the suites that read the clock ==="

# Discovered, not listed: a suite added tomorrow that reads the clock is checked
# without anyone remembering to add it here. `date` inside a command
# substitution or a pipeline is what makes a suite clock-dependent; the word in
# a comment or a message is not.
mapfile -t CLOCK_SUITES < <(
  grep -lE '\$\(\s*date[ )]|`date[ `]|\| *date | date -u ' experiments/*.sh 2>/dev/null \
    | grep -v 'test-issue121-clock-independence.sh' | sort
)

if [ "${#CLOCK_SUITES[@]}" -eq 0 ]; then
  fail "at least one suite reads the clock" \
    "the discovery pattern matched nothing, so Part 2 checks nothing"
else
  pass "found ${#CLOCK_SUITES[@]} suite(s) that read the clock: $(printf '%s ' "${CLOCK_SUITES[@]##*/}")"
fi

for suite in "${CLOCK_SUITES[@]}"; do
  base="$(basename "$suite")"
  for clock in "${CLOCKS[@]}"; do
    epoch="${clock%%:*}"
    label="${clock#*:}"
    log="$TMP/${base%.sh}-$epoch.log"
    if PATH="$TMP/bin:$PATH" BOX_FAKE_EPOCH="$epoch" \
      timeout 120 bash "$suite" >"$log" 2>&1; then
      pass "$base passes with the clock at $label"
      [ "$BOX_VERBOSE" = "1" ] && sed 's/^/      /' "$log"
    else
      status=$?
      fail "$base passes with the clock at $label" \
        "exit $status" \
        "$(grep -E '^(FAIL|      )' "$log" | head -6)"
    fi
  done
done

echo
echo "=== Part 3: the tag list follows the clock it is given ==="

# The production script is the one that must read the clock: a release with no
# date named tags today's date, and "today" is whatever the runner's clock says.
# If this stopped answering, the pin in the suites above would be hiding it.
for clock in "${CLOCKS[@]}"; do
  epoch="${clock%%:*}"
  label="${clock#*:}"
  want="$("$REAL_DATE" -u -d "@$epoch" +%Y%m%d)"
  got="$(cd "$TMP" && PATH="$TMP/bin:$PATH" BOX_FAKE_EPOCH="$epoch" \
    VERSION=2.7.0 GITHUB_SHA=fd4742b9c8e7a6b5c4d3e2f1a0b9c8d7e6f5a4b3 \
    bash "$OLDPWD/scripts/release/image-tags.sh" 2>/dev/null)"
  if printf '%s\n' "$got" | grep -qxF "$want"; then
    pass "image-tags.sh tags $want with the clock at $label"
  else
    fail "image-tags.sh tags $want with the clock at $label" \
      "got: $(printf '%s' "$got" | tr '\n' ' ')"
  fi
done

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
