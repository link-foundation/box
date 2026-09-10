#!/usr/bin/env bash
# test-issue123-artifact-upload-fail-closed.sh
#
# Issue #123. Both artifact uploads in this repository were declared
#
#   if: ${{ !cancelled() }}
#   if-no-files-found: warn
#
# and `warn` is the one value of that input that cannot fail a job:
# actions/upload-artifact documents it as "Output a warning but do not fail the
# action", against `error` ("Fail the action with an error message"). So the
# single outcome each of those steps exists to prevent - the evidence not being
# kept - was reported as a line in the log of the run whose evidence is missing,
# and the job stayed green. That is the same defect class as the rest of this
# issue: a check that cannot fail.
#
# `warn` was not arbitrary. `!cancelled()` is also true when the job failed
# before the producing step ran, and then there is legitimately nothing to
# upload - so `error` alone would turn every early failure into a second,
# misleading failure. The fix is to ask the narrower question: upload when the
# producing step actually ran, and require files when it did.
#
#   .github/workflows/scripts.yml            `Run every experiment suite` (id: suites)
#   .github/workflows/measure-disk-space.yml `Run disk space measurement`  (id: measure)
#
# Both conditions are written in the positive form
# (`outcome == 'success' || outcome == 'failure'`) rather than as
# `outcome != 'skipped'`, because the `steps` context holds only steps that
# "have an `id` specified and have already run"
# (https://docs.github.com/en/actions/reference/workflows-and-actions/contexts),
# so a step that never started has no entry at all and `!= 'skipped'` is true of
# that empty value - which would put the upload back in the failing-early case
# the `warn` was there for.
#
# What is asserted here:
#   1. every upload step in every tracked workflow is fail-closed, gated on a
#      producing step that exists in the same job, in the positive form;
#   2. the mutation controls: the pre-fix shape and three ways of getting the
#      fix subtly wrong are each reported by the same scanner;
#   3. the premise the fix rests on - that once each producing step has run, the
#      path it uploads is non-empty. Measured, not assumed: run-experiments.sh
#      is driven over fixture suites, and `tee` over a command that fails
#      immediately.
#
# Usage: bash experiments/test-issue123-artifact-upload-fail-closed.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

PASSED=0
FAILED=0

pass() {
  echo "PASS: $1"
  PASSED=$((PASSED + 1))
}
fail() {
  echo "FAIL: $1"
  FAILED=$((FAILED + 1))
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- the scanner -------------------------------------------------------------
#
# One record per `actions/upload-artifact` step:
#
#   <file>|<job>|<step name>|<if-no-files-found>|<if condition>
#
# Text-directed, like scripts/ci/check-status-gate-covers-all-jobs.mjs and for
# the same reason: no YAML parser is available to any tracked check, and the
# shapes asked about here are one line each.
scan_uploads() {
  awk '
    function flush(   nff, cond, name) {
      if (block ~ /uses:[ \t]*actions\/upload-artifact/) {
        nff = "(absent)"
        if (match(block, /if-no-files-found:[ \t]*[A-Za-z]+/)) {
          nff = substr(block, RSTART, RLENGTH)
          sub(/^.*:[ \t]*/, "", nff)
        }
        cond = "(none)"
        if (match(block, /\n[ \t]*if:[^\n]*/)) {
          cond = substr(block, RSTART + 1, RLENGTH - 1)
          sub(/^[ \t]*if:[ \t]*/, "", cond)
        }
        name = "(unnamed)"
        if (match(block, /- name:[^\n]*/)) {
          name = substr(block, RSTART, RLENGTH)
          sub(/^- name:[ \t]*/, "", name)
        }
        printf "%s|%s|%s|%s|%s\n", FILENAME, job, name, nff, cond
      }
      block = ""
    }
    /^jobs:[ \t]*$/ { injobs = 1; next }
    injobs && /^  [A-Za-z0-9_-]+:[ \t]*$/ {
      flush()
      job = $0
      sub(/^  /, "", job)
      sub(/:[ \t]*$/, "", job)
      next
    }
    /^[ \t]*- / { flush() }
    { block = block "\n" $0 }
    END { flush() }
  ' "$1"
}

# Every `id:` declared in a job, as "<job> <id>".
scan_step_ids() {
  awk '
    /^jobs:[ \t]*$/ { injobs = 1; next }
    injobs && /^  [A-Za-z0-9_-]+:[ \t]*$/ {
      job = $0
      sub(/^  /, "", job)
      sub(/:[ \t]*$/, "", job)
      next
    }
    /^[ \t]*id:[ \t]*[A-Za-z0-9_-]+[ \t]*$/ {
      id = $0
      sub(/^[ \t]*id:[ \t]*/, "", id)
      sub(/[ \t]*$/, "", id)
      print job, id
    }
  ' "$1"
}

echo "=== Part 1: every upload in the tree is fail-closed ==="

mapfile -t WORKFLOWS < <(git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml' '.github/actions/*/action.yml')
if [ "${#WORKFLOWS[@]}" -gt 0 ]; then
  pass "found ${#WORKFLOWS[@]} tracked workflow/action file(s) to scan"
else
  fail "found tracked workflow/action files to scan"
fi

: >"$TMP/uploads.txt"
for wf in "${WORKFLOWS[@]}"; do
  scan_uploads "$wf" >>"$TMP/uploads.txt"
done

UPLOADS="$(wc -l <"$TMP/uploads.txt")"
if [ "$UPLOADS" -ge 1 ]; then
  pass "the scanner finds $UPLOADS upload-artifact step(s)"
else
  fail "the scanner finds at least one upload-artifact step (found none - the scanner is broken, not the tree)"
fi

# The two known sites, by name, so a rename cannot quietly drop one from the
# policy below.
for want in "Upload suite logs" "Upload measurement artifacts"; do
  if cut -d'|' -f3 "$TMP/uploads.txt" | grep -qxF "$want"; then
    pass "the scanner sees the '$want' step"
  else
    fail "the scanner sees the '$want' step"
  fi
done

while IFS='|' read -r file job name nff cond; do
  [ -n "$file" ] || continue
  where="$file / $job / $name"

  case "$nff" in
    error) pass "$where: if-no-files-found is 'error'" ;;
    *) fail "$where: if-no-files-found is '$nff', which cannot fail the job" ;;
  esac

  # The condition has to name a producing step, in the positive form.
  step_id=""
  if [[ "$cond" =~ steps\.([A-Za-z0-9_-]+)\.outcome ]]; then
    step_id="${BASH_REMATCH[1]}"
  fi
  if [ -n "$step_id" ]; then
    pass "$where: gated on a producing step (steps.$step_id.outcome)"
  else
    fail "$where: gated on a producing step (condition: $cond)"
  fi

  if [[ "$cond" == *"!= 'skipped'"* ]]; then
    fail "$where: uses the negative form, which is also true when the step never ran"
  else
    pass "$where: does not rely on '!= '\''skipped'\'''"
  fi

  if [[ "$cond" == *"== 'success'"* && "$cond" == *"== 'failure'"* ]]; then
    pass "$where: accepts both outcomes a step that ran can have"
  else
    fail "$where: accepts both outcomes a step that ran can have (condition: $cond)"
  fi

  # ...and the step it names has to exist, in the same job.
  if [ -n "$step_id" ]; then
    if scan_step_ids "$file" | grep -qxF "$job $step_id"; then
      pass "$where: '$step_id' is a step id declared in job '$job'"
    else
      fail "$where: '$step_id' is a step id declared in job '$job'"
    fi
  fi

  # `!cancelled()` stays: a job killed by timeout-minutes is cancelled, and the
  # upload would then run against a tree the runner is tearing down.
  if [[ "$cond" == *'!cancelled()'* ]]; then
    pass "$where: still skips a cancelled job"
  else
    fail "$where: still skips a cancelled job (condition: $cond)"
  fi
done <"$TMP/uploads.txt"

echo
echo "=== Part 2: the mutation controls ==="

mutate() {
  local label="$1" body="$2" expect="$3" got
  printf '%s\n' "$body" >"$TMP/fixture.yml"
  got="$(scan_uploads "$TMP/fixture.yml")"
  if [ -z "$got" ]; then
    fail "$label (the scanner found no upload step in the fixture at all)"
    return
  fi
  if grep -qF "$expect" <<<"$got"; then
    pass "$label"
  else
    fail "$label (scanned: $got)"
  fi
}

# The pre-fix shape, verbatim from the tree before this branch.
mutate "the pre-fix shape reports if-no-files-found: warn" \
  'jobs:
  demo:
    steps:
      - name: Run every experiment suite
        run: bash scripts/ci/run-experiments.sh

      - name: Upload suite logs
        if: ${{ !cancelled() }}
        uses: actions/upload-artifact@v7
        with:
          name: experiment-logs
          path: /tmp/experiment-logs/
          if-no-files-found: warn' \
  '|warn|'

# The input omitted entirely: the action defaults to `warn`, so this is the
# same defect written in fewer characters.
mutate "an omitted if-no-files-found is reported as absent" \
  'jobs:
  demo:
    steps:
      - name: Upload suite logs
        if: ${{ !cancelled() }}
        uses: actions/upload-artifact@v7
        with:
          path: /tmp/experiment-logs/' \
  '|(absent)|'

# The negative form, which is true for a step that never ran.
mutate "the negative form is reported as written" \
  "jobs:
  demo:
    steps:
      - name: Upload suite logs
        if: \${{ !cancelled() && steps.suites.outcome != 'skipped' }}
        uses: actions/upload-artifact@v7
        with:
          if-no-files-found: error" \
  "!= 'skipped'"

# A condition naming a step id that does not exist: the scanner has to surface
# the id so the cross-check above can fail.
printf '%s\n' "jobs:
  demo:
    steps:
      - name: Upload suite logs
        if: \${{ !cancelled() && steps.typo.outcome == 'success' }}
        uses: actions/upload-artifact@v7
        with:
          if-no-files-found: error" >"$TMP/typo.yml"
if scan_uploads "$TMP/typo.yml" | grep -qF 'steps.typo.outcome' \
  && ! scan_step_ids "$TMP/typo.yml" | grep -qxF 'demo typo'; then
  pass "a condition naming an undeclared step id is caught by the cross-check"
else
  fail "a condition naming an undeclared step id is caught by the cross-check"
fi

# And the shipped shape passes its own policy, so the fixtures above are
# testing the scanner rather than the tree.
mutate "the shipped shape reports if-no-files-found: error" \
  "jobs:
  demo:
    steps:
      - name: Run every experiment suite
        id: suites
        run: bash scripts/ci/run-experiments.sh

      - name: Upload suite logs
        if: \${{ !cancelled() && (steps.suites.outcome == 'success' || steps.suites.outcome == 'failure') }}
        uses: actions/upload-artifact@v7
        with:
          if-no-files-found: error" \
  '|error|'

echo
echo "=== Part 3: the premise - once the producing step has run, there are files ==="

# scripts.yml: run-experiments.sh creates LOG_DIR before the first suite and
# writes one log per suite, so a passing run and a failing run both leave the
# directory non-empty. Driven over fixtures via the runner's own overrides
# rather than over the real suites, which take about 106 seconds.
mkdir -p "$TMP/suites"
cat >"$TMP/suites/aaa-passing.sh" <<'FIX'
#!/usr/bin/env bash
echo "this suite passes"
FIX
cat >"$TMP/suites/zzz-failing.sh" <<'FIX'
#!/usr/bin/env bash
echo "this suite fails"
exit 1
FIX

EXPERIMENTS_DIR="$TMP/suites" LOG_DIR="$TMP/logs" \
  bash scripts/ci/run-experiments.sh >"$TMP/runner.log" 2>&1
runner_status=$?

if [ "$runner_status" -ne 0 ]; then
  pass "a failing suite makes the producing step fail (exit $runner_status)"
else
  fail "a failing suite makes the producing step fail (exit 0)"
fi

if [ -d "$TMP/logs" ]; then
  pass "the producing step created the directory the upload names"
else
  fail "the producing step created the directory the upload names"
fi

log_count="$(find "$TMP/logs" -type f -name '*.log' | wc -l)"
if [ "$log_count" -eq 2 ]; then
  pass "one log per suite, for the passing and the failing one alike ($log_count)"
else
  fail "one log per suite, for the passing and the failing one alike (found $log_count)"
fi

# The interesting half: the log of the suite that failed is the one the upload
# exists for.
if [ -s "$TMP/logs/zzz-failing.log" ] && grep -qF 'this suite fails' "$TMP/logs/zzz-failing.log"; then
  pass "the failing suite's own output is in the artifact path"
else
  fail "the failing suite's own output is in the artifact path"
fi

# measure-disk-space.yml: `| tee measurement.log` creates the file when the step
# starts, so the file exists however early the measurement dies.
(
  cd "$TMP" || exit 1
  # A command that fails before writing a byte, which is the worst case.
  bash -c 'set -o pipefail; false | tee measurement.log' >/dev/null 2>&1
)
if [ -f "$TMP/measurement.log" ]; then
  pass "tee creates measurement.log even when the measurement fails immediately"
else
  fail "tee creates measurement.log even when the measurement fails immediately"
fi

# ...and the shipped step still has both halves of that premise.
MDS=".github/workflows/measure-disk-space.yml"
if grep -qF '| tee measurement.log' "$MDS"; then
  pass "$MDS still pipes the measurement through tee"
else
  fail "$MDS still pipes the measurement through tee"
fi
if grep -qE '^[[:space:]]+id: measure$' "$MDS"; then
  pass "$MDS still declares id: measure on the measuring step"
else
  fail "$MDS still declares id: measure on the measuring step"
fi

SCRIPTS=".github/workflows/scripts.yml"
if grep -qE '^[[:space:]]+id: suites$' "$SCRIPTS"; then
  pass "$SCRIPTS declares id: suites on the suite-running step"
else
  fail "$SCRIPTS declares id: suites on the suite-running step"
fi

echo
echo "=== $PASSED passed, $FAILED failed ==="
[ "$FAILED" -eq 0 ]
