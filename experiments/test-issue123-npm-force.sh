#!/usr/bin/env bash
# test-issue123-npm-force.sh
#
# Issue #123. `npm install -g ... --force` printed a warning that meant nothing.
#
# The defect. Every JS build job in the nine runs the issue lists printed
#
#   npm warn using --force Recommended protections disabled.
#
# from ubuntu/24.04/js/install.sh, which had carried `--force` on the Playwright
# install since issue #84 (2026-04-06; the same line is in
# docs/case-studies/issue-84/ci-logs/run-24024582176.log:4781). npm means that
# warning literally - `--force` makes it ignore engine mismatches, overwrite
# conflicting bin links and skip several safety checks - so a reader has to
# decide, on every green build, whether a protection npm disabled is the reason
# something later broke. Two plausible reasons for the flag existed:
#
#   1. a bin conflict, since `playwright` and `@playwright/test` both declare a
#      bin named `playwright`;
#   2. the retry, since run_with_retry re-runs the identical command over the
#      tree a failed attempt left behind.
#
# Both were measured, over both images the JS component builds on, with and
# without the flag, in the fresh / reinstall / shipped-npm shapes:
# dev/log/issues/123/pulls/124/npm-force/measurement.txt, produced by
# experiments/issue-123/measure-npm-force.sh. Twelve runs, twelve `exit=0`,
# twelve `Version 1.63.0`. The flag bought nothing and cost a warning, so it is
# gone.
#
# What is asserted here is offline and takes no docker: that the shipped line
# no longer carries the flag and still carries the retry, that no other tracked
# script passes `--force` to npm, that the sweep enforcing this would catch a
# reintroduction, and that the measurement the decision rests on says what this
# header says it says.
#
# Usage: bash experiments/test-issue123-npm-force.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"

PASS=0
FAIL=0
pass() {
  PASS=$((PASS + 1))
  echo "PASS: $1"
}
fail() {
  FAIL=$((FAIL + 1))
  echo "FAIL: $1"
  [ $# -gt 1 ] && printf '      %s\n' "$2"
  return 0
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

INSTALL="ubuntu/24.04/js/install.sh"
MEASUREMENT="dev/log/issues/123/pulls/124/npm-force/measurement.txt"

echo "=== 1. the shipped Playwright install ==="

line="$(command grep -n 'npm install -g playwright' "$INSTALL" | head -n1)"
[ -n "$line" ] \
  && pass "$INSTALL still installs the Playwright CLIs (${line%%:*})" \
  || fail "no 'npm install -g playwright' line in $INSTALL"

case "$line" in
  *--force*) fail "the Playwright install still passes --force" "$line" ;;
  *) pass "and does not pass --force" ;;
esac

case "$line" in
  *run_with_retry*) pass "and still runs through run_with_retry" ;;
  *) fail "dropping --force also dropped the retry" "$line" ;;
esac

case "$line" in
  *--no-fund*) pass "and still passes --no-fund" ;;
  *) fail "the install lost --no-fund" "$line" ;;
esac

echo
echo "=== 2. no tracked script passes --force to npm ==="

# `npm` and the flag can be separated by other arguments, so this matches an
# npm command line that carries --force anywhere in it. It deliberately does
# not match `brew link --force` or `git push --force-with-lease`, which are
# different tools making a different claim.
NPM_FORCE='(^|[;&|]|[[:space:]])npm[[:space:]]+[^;&|]*--force([[:space:]]|$)'

sweep() {
  local root="$1"
  git -C "$ROOT" ls-files -- "$root" 2>/dev/null | while read -r f; do
    [ -f "$ROOT/$f" ] || continue
    command grep -HnE "$NPM_FORCE" "$ROOT/$f" 2>/dev/null
  done
}

# The evidence tree quotes the retired line by design, and this suite's own
# header does too, so both are excluded by path rather than by pattern.
offenders="$(sweep 'ubuntu' && sweep 'scripts' && sweep '.github')"
[ -z "$offenders" ] \
  && pass "no npm invocation under ubuntu/, scripts/ or .github/ passes --force" \
  || fail "an npm invocation still passes --force" "$offenders"

echo
echo "=== 3. the sweep would catch a reintroduction ==="

mkdir -p "$WORK/planted"
cat >"$WORK/planted/install.sh" <<'PLANT'
#!/usr/bin/env bash
run_with_retry npm install -g playwright @playwright/test --no-fund --force
npm ci
brew link --overwrite --force php
git push --force-with-lease origin main
PLANT

planted="$(command grep -cE "$NPM_FORCE" "$WORK/planted/install.sh")"
[ "$planted" -eq 1 ] \
  && pass "the pattern finds the reintroduced npm --force" \
  || fail "the pattern found $planted lines in the fixture, expected 1"

# The three decoys in the same fixture must not be among them: `npm ci` carries
# no flag, and the brew and git lines are other tools' --force.
hit="$(command grep -E "$NPM_FORCE" "$WORK/planted/install.sh")"
case "$hit" in
  *brew* | *git\ push*) fail "the pattern matched another tool's --force" "$hit" ;;
  *) pass "and leaves brew's and git's --force alone" ;;
esac

echo
echo "=== 4. the measurement the decision rests on ==="

if [ ! -f "$MEASUREMENT" ]; then
  fail "the measurement $MEASUREMENT is missing"
else
  pass "the measurement is committed at $MEASUREMENT"

  sections="$(command grep -c '^### ' "$MEASUREMENT")"
  [ "$sections" -eq 12 ] \
    && pass "it records 12 sections (2 images x 3 scenarios x with/without the flag)" \
    || fail "it records $sections sections, expected 12"

  ok="$(command grep -c '^  exit=0$' "$MEASUREMENT")"
  bad="$(command grep -cE '^  exit=[1-9]' "$MEASUREMENT")"
  { [ "$ok" -eq 12 ] && [ "$bad" -eq 0 ]; } \
    && pass "every one of the 12 installs exited 0" \
    || fail "$ok sections exited 0 and $bad exited non-zero, expected 12 and 0"

  versions="$(command grep -c '^  Version 1\.63\.0$' "$MEASUREMENT")"
  [ "$versions" -eq 12 ] \
    && pass "and every one of them produced a working 'playwright --version'" \
    || fail "$versions sections reported a Playwright version, expected 12"

  # The claim being pinned is the one the fix makes: the flag changes the log
  # and nothing else. Six sections ran with it, six without, and the warning
  # appears in exactly the six that asked for it.
  present="$(command grep -c '^  force-warning: present' "$MEASUREMENT")"
  absent="$(command grep -c '^  force-warning: absent$' "$MEASUREMENT")"
  { [ "$present" -eq 6 ] && [ "$absent" -eq 6 ]; } \
    && pass "the warning appears in exactly the 6 --force runs and no others" \
    || fail "the warning was present in $present runs and absent in $absent, expected 6 and 6"

  command grep -q 'npm warn using --force Recommended protections disabled\.' "$MEASUREMENT" \
    && pass "and the recorded text is the line the CI logs carried" \
    || fail "the measurement does not quote the warning the CI logs carried"

  # A measurement over one npm proves nothing about the npm the build uses:
  # install.sh self-updates npm before this line, so the `shipped` scenario has
  # to have run a different version from the images' own.
  npms="$(command grep -oE '^  npm [0-9]+\.[0-9]+\.[0-9]+' "$MEASUREMENT" | sort -u | wc -l)"
  [ "$npms" -ge 3 ] \
    && pass "and it exercised $npms npm versions, including the self-updated one" \
    || fail "the measurement only exercised $npms npm version(s), expected at least 3"
fi

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
