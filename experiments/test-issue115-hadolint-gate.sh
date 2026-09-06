#!/usr/bin/env bash
# test-issue115-hadolint-gate.sh
#
# Issue #115. The Dockerfiles are what this repository ships and nothing linted
# them. The defect that proves the gap: ubuntu/24.04/js/Dockerfile ran
#
#   apt install -y curl git sudo ca-certificates unzip
#
# and apt answers a non-interactive caller with
#
#   WARNING: apt does not have a stable CLI interface. Use with caution in scripts.
#
# (reproduce: docker run --rm ubuntu:24.04 bash -c 'apt list --installed 2>&1 >/dev/null | head -2')
#
# So every JS box build printed a warning that no check collected, and nine
# install scripts did the same at image build time.
#
# This suite pins the gate and the policy behind it. It is static: no docker, so
# it runs everywhere the other suites do.
#
# Usage: bash experiments/test-issue115-hadolint-gate.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

RUNNER="scripts/ci/run-hadolint.sh"
CONFIG=".hadolint.yaml"
WORKFLOW=".github/workflows/dockerfiles.yml"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- 1. the gate exists and is wired up ---------------------------------------

for f in "$RUNNER" "$CONFIG" "$WORKFLOW"; do
  if [ -f "$f" ]; then
    pass "$f exists"
  else
    fail "$f is missing"
  fi
done

if [ "$FAIL" -gt 0 ]; then
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

if grep -q "run-hadolint.sh" "$WORKFLOW"; then
  pass "the workflow runs the shared runner rather than its own inline command"
else
  fail "the workflow does not call scripts/ci/run-hadolint.sh"
fi

if grep -q "test-issue115-hadolint-gate.sh" "$WORKFLOW"; then
  pass "the workflow also runs this suite, so the gate's own fixtures are checked"
else
  fail "the workflow does not run this suite"
fi

# --- 2. discovery, not a hand-written list ------------------------------------

RUNNER_SRC="$(cat "$RUNNER")"

if [[ "$RUNNER_SRC" == *"git ls-files"* ]]; then
  pass "the file set comes from git, so a new Dockerfile is linted the moment it lands"
else
  fail "the runner hardcodes its file list; a new Dockerfile would go unchecked"
fi

if [[ "$RUNNER_SRC" == *"grep -v '^dev/log/'"* ]]; then
  pass "dev/log/ is excluded (verbatim copies of other projects' files)"
else
  fail "the runner would lint the vendored evidence tree in dev/log/"
fi

LISTED="$(bash "$RUNNER" --list 2>/dev/null)"
LISTED_COUNT="$(printf '%s\n' "$LISTED" | grep -c .)"
TRACKED_COUNT="$(git ls-files | grep -E '(^|/)Dockerfile(\.|$)|\.Dockerfile$' | grep -vc '^dev/log/')"

if [ "$LISTED_COUNT" -eq "$TRACKED_COUNT" ]; then
  pass "the runner lists all $TRACKED_COUNT tracked Dockerfiles outside dev/log/"
else
  fail "the runner lists $LISTED_COUNT of $TRACKED_COUNT tracked Dockerfiles"
fi

for expected in ubuntu/24.04/js/Dockerfile ubuntu/24.04/full-box/Dockerfile Dockerfile; do
  if grep -Fqx -- "$expected" <<< "$LISTED"; then
    pass "$expected is in the checked set"
  else
    fail "$expected is not in the checked set"
  fi
done

if grep -Fq "dev/log/" <<< "$LISTED"; then
  fail "the checked set includes dev/log/"
else
  pass "the checked set excludes dev/log/"
fi

# --- 3. the failure threshold is hadolint's, not the runner's ------------------

# The runner used to count every printed line as a finding, so an `info`-level
# style suggestion failed the job just as hard as a real defect - a false
# positive. The verdict comes from hadolint's own exit code now.
if [[ "$RUNNER_SRC" == *'[ "$status" -eq 0 ] || FAILURES=$((FAILURES + 1))'* ]]; then
  pass "the verdict is hadolint's exit code, not a line count"
else
  fail "the runner decides pass/fail itself; info-level notes would fail the job"
fi

if [[ "$RUNNER_SRC" == *"gh_level=\"notice\""* ]]; then
  pass "advisory findings are annotated as notices, not errors"
else
  fail "advisory findings are reported at error level"
fi

if grep -q '^failure-threshold: warning' "$CONFIG"; then
  pass "the threshold is 'warning', matching the shellcheck gate's bar"
else
  fail "$CONFIG does not set failure-threshold: warning"
fi

# Every suppressed rule must carry its reason in the file, so a future reader
# can tell a considered exception from an inherited one.
IGNORED="$(awk '/^ignored:/ {inlist=1; next} inlist && /^  - / {print $2}' "$CONFIG")"
if [ -n "$IGNORED" ]; then
  for code in $IGNORED; do
    if grep -q "# $code " "$CONFIG"; then
      pass "$code is suppressed with a stated reason"
    else
      fail "$code is suppressed with no reason in $CONFIG"
    fi
  done
else
  pass "no rules are suppressed"
fi

# --- 4. the policy the gate exists to protect: no bare `apt` ------------------

# apt's own manual page says its CLI is not stable and should not be scripted;
# hadolint reports it as DL3027, and it is the defect that motivated this gate.
# The check covers *every* tracked file, not just the Dockerfiles, because the
# install scripts run inside the same builds and printed the same warning.
# Prose mentions apt too ("apt update failed"), so comments and quoted strings
# are stripped before the search: only apt in command position counts.
strip_prose() {
  sed -E 's/#.*$//; s/"[^"]*"//g; s/'"'"'[^'"'"']*'"'"'//g'
}

# A detector that matches nothing would pass this suite silently, so it is
# checked against a fixture first: real invocations caught, prose and apt-get
# left alone.
FIXTURE="$(printf '%s\n' \
  'RUN apt install -y curl' \
  '# apt install foo' \
  'log_warning "apt update failed"' \
  'apt-get install -y x' \
  'sudo apt upgrade')"
FIXTURE_HITS="$(printf '%s\n' "$FIXTURE" | strip_prose \
  | grep -cE '(^|[^-[:alnum:]_.])apt +(install|update|upgrade|remove|purge|autoremove)([ \t]|$)' \
  || true)"
if [ "$FIXTURE_HITS" -eq 2 ]; then
  pass "the detector finds bare apt and ignores comments, prose and apt-get"
else
  fail "the detector matched $FIXTURE_HITS of the fixture's 2 real invocations"
fi

BARE_APT=""
while IFS= read -r file; do
  hits="$(strip_prose < "$file" \
    | grep -nE '(^|[^-[:alnum:]_.])apt +(install|update|upgrade|remove|purge|autoremove)([ \t]|$)' \
    || true)"
  [ -n "$hits" ] || continue
  BARE_APT="$BARE_APT$(printf '%s\n' "$hits" | sed "s|^|$file:|")\n"
done < <(git ls-files \
  | grep -vE '^(dev/log|docs)/' \
  | grep -vE '\.md$' \
  | grep -vE 'experiments/test-issue115-hadolint-gate\.sh')
BARE_APT="$(printf '%b' "$BARE_APT" | grep . || true)"

if [ -z "$BARE_APT" ]; then
  pass "no tracked file invokes bare 'apt' (it warns on every non-interactive run)"
else
  fail "bare 'apt' invocations survive:"
  printf '%s\n' "$BARE_APT" | sed 's/^/    /'
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
