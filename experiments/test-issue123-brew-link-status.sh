#!/usr/bin/env bash
# test-issue123-brew-link-status.sh
#
# Issue #123. A filter that became an exit status.
#
# The defect. Four scripts linked Homebrew's PHP with
#
#   brew link --overwrite --force php 2>&1 | grep -v "Warning" || true
#
# ubuntu/24.04/full-box/install.sh, ubuntu/24.04/php/install.sh (through a
# `timeout`), scripts/measure-disk-space.sh and
# scripts/ubuntu-24-server-install.sh. `brew link` prints "Warning:" lines on a
# link that worked, so filtering them is reasonable; ending the pipeline with
# the filter is not. A pipeline's status is its last command's, so the status
# reported was grep's opinion of the *text*, and `|| true` then discarded even
# that. Three failures are invisible in the old shape:
#
#   - brew exits non-zero and says why: grep prints the reason and exits 0, so
#     the script carries on as though the link succeeded;
#   - brew exits non-zero saying only "Warning:" lines: grep deletes all of
#     them, exits 1, `|| true` swallows it, and the step is silent;
#   - the `timeout` at ubuntu/24.04/php/install.sh returns 124 - the hang issue
#     #53 was opened about - and the next line logs "brew link completed".
#
# The shipped shape keeps the filter on the output and the status on brew.
#
# Every assertion is offline: `brew` and `timeout` are stubs on PATH, so no
# Homebrew is installed and no network is used.
#
# Usage: bash experiments/test-issue123-brew-link-status.sh

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

# A brew stub whose behaviour is set per case by three environment variables.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/brew" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_WARNINGS:-}" ] && printf '%s\n' "$STUB_WARNINGS"
[ -n "${STUB_ERRORS:-}" ] && printf '%s\n' "$STUB_ERRORS"
exit "${STUB_EXIT:-0}"
STUB
chmod +x "$WORK/bin/brew"

# Both shapes run with the same stub, the same helpers and the same input.
HARNESS='log_warning() { echo "[!] $1"; }
export PATH="'"$WORK"'/bin:$PATH"
'

RETIRED='brew link --overwrite --force php 2>&1 | grep -v "Warning" || true'

SHIPPED='brew_link_out=""
brew_link_status=0
brew_link_out="$(brew link --overwrite --force php 2>&1)" || brew_link_status=$?
if [ "$brew_link_status" -eq 0 ]; then
  printf "%s\n" "$brew_link_out" | grep -v "^Warning" || true
else
  printf "%s\n" "$brew_link_out"
  log_warning "brew link --overwrite --force php failed (exit $brew_link_status)"
fi'

OUT=""
STATUS=0
run_shape() {
  local shape="$1"
  OUT="$(env STUB_EXIT="${STUB_EXIT:-0}" STUB_WARNINGS="${STUB_WARNINGS:-}" \
    STUB_ERRORS="${STUB_ERRORS:-}" bash -c "set -uo pipefail
$HARNESS
$shape" 2>&1)"
  STATUS=$?
}

WARN_TEXT='Warning: php 8.4.1 is already linked
Warning: Skipping /usr/local/bin/php'
ERR_TEXT='Error: Could not symlink bin/php'

echo "=== 1. the retired shape, reproduced ==="

STUB_EXIT=1 STUB_WARNINGS="$WARN_TEXT" STUB_ERRORS="$ERR_TEXT" run_shape "$RETIRED"
[ "$STATUS" -eq 0 ] \
  && pass "a failing brew link left the retired shape with status 0" \
  || fail "the retired shape reported status $STATUS, expected 0"

STUB_EXIT=1 STUB_WARNINGS="$WARN_TEXT" STUB_ERRORS="" run_shape "$RETIRED"
{ [ "$STATUS" -eq 0 ] && [ -z "$OUT" ]; } \
  && pass "and when brew failed saying only 'Warning:' lines, printed nothing at all" \
  || fail "the warnings-only failure produced status $STATUS and output '$OUT'"

STUB_EXIT=124 STUB_WARNINGS="" STUB_ERRORS="" run_shape "$RETIRED"
{ [ "$STATUS" -eq 0 ] && [ -z "$OUT" ]; } \
  && pass "and a 124 (the issue #53 hang, through 'timeout') was equally silent" \
  || fail "the timeout case produced status $STATUS and output '$OUT'"

echo
echo "=== 2. the shipped shape answers all three ==="

STUB_EXIT=1 STUB_WARNINGS="$WARN_TEXT" STUB_ERRORS="$ERR_TEXT" run_shape "$SHIPPED"
case "$OUT" in
  *"failed (exit 1)"*) pass "a failing brew link is reported with its status" ;;
  *) fail "the shipped shape did not report the failure" "$OUT" ;;
esac
case "$OUT" in
  *"Could not symlink"*) pass "and brew's own reason survives the filter" ;;
  *) fail "brew's reason was filtered away" "$OUT" ;;
esac
case "$OUT" in
  *"is already linked"*) pass "and on a failure the Warning lines are kept too, because they may be the reason" ;;
  *) fail "the failure path dropped the Warning lines" "$OUT" ;;
esac

STUB_EXIT=1 STUB_WARNINGS="$WARN_TEXT" STUB_ERRORS="" run_shape "$SHIPPED"
case "$OUT" in
  *"failed (exit 1)"*) pass "a warnings-only failure is reported rather than silent" ;;
  *) fail "the warnings-only failure is still silent" "$OUT" ;;
esac

STUB_EXIT=124 STUB_WARNINGS="" STUB_ERRORS="" run_shape "$SHIPPED"
case "$OUT" in
  *"failed (exit 124)"*) pass "and a 124 names its own status" ;;
  *) fail "the 124 case is not reported" "$OUT" ;;
esac

echo
echo "=== 3. and stays quiet when the link works ==="

STUB_EXIT=0 STUB_WARNINGS="$WARN_TEXT" STUB_ERRORS="" run_shape "$SHIPPED"
{ [ "$STATUS" -eq 0 ] && [ -z "${OUT//[[:space:]]/}" ]; } \
  && pass "a successful link with only Warning output prints nothing and exits 0" \
  || fail "the success path produced status $STATUS and output '$OUT'"

STUB_EXIT=0 STUB_WARNINGS="Linked 12 files" STUB_ERRORS="" run_shape "$SHIPPED"
case "$OUT" in
  *"Linked 12 files"*) pass "and a successful link's non-warning output is still printed" ;;
  *) fail "the success path swallowed brew's report" "$OUT" ;;
esac

# The old filter deleted any line *containing* "Warning"; the shipped one is
# anchored, so a line that merely mentions one survives.
STUB_EXIT=0 STUB_WARNINGS="php: 3 deprecations, 0 Warnings suppressed" STUB_ERRORS="" run_shape "$SHIPPED"
case "$OUT" in
  *"deprecations"*) pass "and a line that merely mentions a warning is not deleted with them" ;;
  *) fail "the anchored filter still deleted a mentioning line" "$OUT" ;;
esac

echo
echo "=== 4. no tracked script has the retired shape ==="

# `brew link` whose status is thrown away by a trailing filter. Written as two
# conditions so it catches the `timeout ... brew link` site too.
offenders=""
while read -r f; do
  [ -f "$ROOT/$f" ] || continue
  hits="$(command grep -nE 'brew link[^|]*\|[^|]*grep' "$ROOT/$f" 2>/dev/null)"
  [ -n "$hits" ] && offenders="$offenders$f: $hits"$'\n'
done < <(git -C "$ROOT" ls-files -- ubuntu scripts .github experiments)

[ -z "$offenders" ] \
  && pass "no tracked script pipes brew link into a filter" \
  || fail "a brew link still ends in a filter" "$offenders"

# Four sites had it; all four must now capture the status.
sites=0
while read -r f; do
  command grep -q 'brew link --overwrite --force' "$ROOT/$f" 2>/dev/null || continue
  sites=$((sites + 1))
  command grep -q 'brew_link_status' "$ROOT/$f" \
    || fail "$f links with brew but does not capture the status"
done < <(git -C "$ROOT" ls-files -- ubuntu scripts)

[ "$sites" -eq 4 ] \
  && pass "and all $sites brew link sites capture brew's own status" \
  || fail "found $sites brew link sites, expected 4"

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
