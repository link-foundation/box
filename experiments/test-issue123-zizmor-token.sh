#!/usr/bin/env bash
# test-issue123-zizmor-token.sh
#
# Issue #123. The Workflows run on 1d9fb3e was green and printed this twice -
# once per zizmor pass (run 34366975873, log lines 729 and 767):
#
#   WARN audit: zizmor: zizmor is running in offline mode by default; some
#   audits and auto-fixes will not be available. see
#   https://docs.zizmor.sh/usage/#operating-modes for details
#
# Since 1.0 zizmor runs offline unless it is given a GitHub API token, and both
# passes were `docker run` invocations that passed none - `docker run` forwards
# no environment, so even a job holding GITHUB_TOKEN handed the container
# nothing. Every audit that needs the GitHub API was therefore skipped, and
# `known-vulnerable-actions` - which asks the GitHub Advisory Database whether a
# pinned action has a published advisory - is the one audit here that can catch
# a supply-chain compromise of an action this repository already trusts. The job
# reported "No findings to report" about a question it never asked.
#
# The measured difference is in experiments/reproduce-issue123-zizmor-offline-audits.sh,
# which runs both modes over a fixture pinning `tj-actions/changed-files@v44`
# (CVE-2025-30066): offline reports 2 high findings and no
# known-vulnerable-actions, online reports 3 and names it. That suite needs
# docker, a network and a token; this one needs none of the three.
#
# What is asserted here:
#   1. the shipped workflow gives both passes a token and goes through the runner
#   2. scripts/ci/run-zizmor.sh refuses to report success from an offline run
#   3. the mutation control: the pre-fix command line - no `-e GH_TOKEN` - puts
#      the analyser back in offline mode, which is what made the check silent
#   4. no other tracked caller runs the analyser without a token
#
# The docker stub used below is a model of two documented behaviours: `docker
# run` passes an environment variable into the container only when it is named
# with `-e`, and zizmor prints the offline banner when it has no token. The real
# thing is measured by the reproduce suite; what is tested here is what this
# repository does with each answer.
#
# Usage: bash experiments/test-issue123-zizmor-token.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

WORKFLOW=".github/workflows/workflows.yml"
RUNNER="scripts/ci/run-zizmor.sh"
BANNER="zizmor is running in offline mode by default; some audits and auto-fixes will not be available."

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

# A stub `docker` that behaves the way the real one does for the one detail
# this is about: the container's environment holds GH_TOKEN only if the command
# line named it with `-e`. It writes the argv and the token it could see to
# files, and prints zizmor's banner when it ends up without one.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
: >"$STUB_ARGV"
printf '%s\n' "$@" >>"$STUB_ARGV"

want=0
forwarded=""
for arg in "$@"; do
  if [ "$want" = 1 ]; then
    case "$arg" in
      GH_TOKEN) forwarded="${GH_TOKEN:-}" ;;
      GH_TOKEN=*) forwarded="${arg#GH_TOKEN=}" ;;
    esac
    want=0
    continue
  fi
  [ "$arg" = "-e" ] && want=1
done
printf '%s' "$forwarded" >"$STUB_TOKEN_SEEN"

if [ -z "$forwarded" ]; then
  echo " WARN audit: zizmor: zizmor is running in offline mode by default; some audits and auto-fixes will not be available. see https://docs.zizmor.sh/usage/#operating-modes for details" >&2
fi
echo "No findings to report. Good job! (246 ignored, 248 suppressed)"
exit "${STUB_EXIT:-0}"
STUB
chmod +x "$TMP/bin/docker"

export STUB_ARGV="$TMP/argv.txt"
export STUB_TOKEN_SEEN="$TMP/token-seen.txt"

# Runs the runner with the stub in front of the real docker. Output goes to a
# file rather than a command substitution: a helper read with $(...) runs in a
# subshell, and counts made there are discarded.
run_runner() {
  local status
  PATH="$TMP/bin:$PATH" bash "$RUNNER" "$@" >"$TMP/out.log" 2>&1
  status=$?
  echo "$status" >"$TMP/status"
  return 0
}

says() {
  if grep -qF "$2" "$TMP/out.log"; then
    pass "$1"
  else
    fail "$1 (output: $(tr '\n' ' ' <"$TMP/out.log" | cut -c1-200))"
  fi
}

says_not() {
  if grep -qF "$2" "$TMP/out.log"; then
    fail "$1"
  else
    pass "$1"
  fi
}

exits() {
  local want="$2" got
  got="$(cat "$TMP/status")"
  if [ "$got" = "$want" ]; then
    pass "$1"
  else
    fail "$1 (exit $got, want $want)"
  fi
}

echo "=== Part 1: the shipped workflow hands both passes a token ==="

if [ -f "$RUNNER" ] && [ -x "$RUNNER" ]; then
  pass "$RUNNER exists and is executable"
else
  fail "$RUNNER exists and is executable"
fi

RUNNER_STEPS="$(grep -c 'bash scripts/ci/run-zizmor.sh' "$WORKFLOW")"
if [ "$RUNNER_STEPS" -eq 2 ]; then
  pass "$WORKFLOW runs exactly the two passes, both through the runner"
else
  fail "$WORKFLOW runs exactly the two passes, both through the runner (found $RUNNER_STEPS)"
fi

# One `env: GH_TOKEN:` per pass. Counting is the point: a token on the first
# step and not the second is exactly the half-fix this is guarding against.
TOKEN_BINDINGS="$(grep -c 'GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}' "$WORKFLOW")"
if [ "$TOKEN_BINDINGS" -eq 2 ]; then
  pass "both zizmor steps bind GH_TOKEN from secrets.GITHUB_TOKEN"
else
  fail "both zizmor steps bind GH_TOKEN from secrets.GITHUB_TOKEN (found $TOKEN_BINDINGS)"
fi

for pass_name in regular pedantic; do
  if bash "$RUNNER" --print "$pass_name" | grep -qF -- '-e GH_TOKEN'; then
    pass "the $pass_name pass names GH_TOKEN on the docker command line"
  else
    fail "the $pass_name pass names GH_TOKEN on the docker command line"
  fi
done

# The local escape hatch must stay local.
if ! grep -rn 'ZIZMOR_ALLOW_OFFLINE' .github/ >/dev/null 2>&1; then
  pass "no workflow sets ZIZMOR_ALLOW_OFFLINE"
else
  fail "no workflow sets ZIZMOR_ALLOW_OFFLINE"
fi

echo
echo "=== Part 2: an offline run is a failure, not a line in the log ==="

GH_TOKEN=ghs_stub GITHUB_TOKEN='' run_runner regular
exits "a run that reports no findings and no banner passes" 0
says_not "the passing run says nothing about offline mode" "ran offline"
if [ "$(cat "$STUB_TOKEN_SEEN")" = "ghs_stub" ]; then
  pass "the token reaches the container's environment"
else
  fail "the token reaches the container's environment (saw '$(cat "$STUB_TOKEN_SEEN")')"
fi

# GITHUB_TOKEN alone: the name a workflow author reaches for first.
GH_TOKEN='' GITHUB_TOKEN=ghs_from_github_token run_runner regular
exits "GITHUB_TOKEN is accepted when GH_TOKEN is unset" 0
if [ "$(cat "$STUB_TOKEN_SEEN")" = "ghs_from_github_token" ]; then
  pass "GITHUB_TOKEN is forwarded under the name zizmor reads"
else
  fail "GITHUB_TOKEN is forwarded under the name zizmor reads (saw '$(cat "$STUB_TOKEN_SEEN")')"
fi

# The reproduction: an analyser that exits 0 and says it was offline. Before
# this fix that was the whole of the CI job's evidence, and it was green.
cat >"$TMP/bin/docker-offline" <<'STUB'
#!/usr/bin/env bash
echo " WARN audit: zizmor: zizmor is running in offline mode by default; some audits and auto-fixes will not be available. see https://docs.zizmor.sh/usage/#operating-modes for details" >&2
echo "No findings to report. Good job! (246 ignored, 248 suppressed)"
exit 0
STUB
chmod +x "$TMP/bin/docker-offline"

GH_TOKEN=ghs_stub ZIZMOR_DOCKER="$TMP/bin/docker-offline" run_runner regular
exits "an analyser that says it ran offline fails the job" 1
says "the failure names the audit that did not run" "known-vulnerable-actions"
says "the failure is an error annotation" "::error title=zizmor ran offline"

GH_TOKEN=ghs_stub ZIZMOR_ALLOW_OFFLINE=1 ZIZMOR_DOCKER="$TMP/bin/docker-offline" run_runner regular
exits "ZIZMOR_ALLOW_OFFLINE=1 downgrades it for a local run" 0
says "and says so rather than passing silently" "::notice title=zizmor ran offline"

# No token at all: refused before docker is even started, because a run that
# cannot ask the API is not a run worth waiting for.
: >"$STUB_ARGV"
GH_TOKEN='' GITHUB_TOKEN='' run_runner regular
exits "a missing token fails before anything is analysed" 1
says "the missing-token error explains what is silently skipped" "known-vulnerable-actions"
if [ ! -s "$STUB_ARGV" ]; then
  pass "the analyser is not started at all without a token"
else
  fail "the analyser is not started at all without a token"
fi

GH_TOKEN='' GITHUB_TOKEN='' ZIZMOR_ALLOW_OFFLINE=1 run_runner regular
exits "ZIZMOR_ALLOW_OFFLINE=1 allows a local run with no token" 0
says "the tokenless local run is announced" "::notice title=zizmor is running offline"

# And that run must omit the flag rather than forward an empty value: zizmor
# refuses one - "invalid value '' for '--gh-token <GH_TOKEN>': GitHub token
# cannot be empty" - so `-e GH_TOKEN` with nothing behind it turns an allowed
# offline run into a usage error two minutes into the job.
if ! grep -qx -- '-e' "$STUB_ARGV"; then
  pass "a tokenless run passes no -e flag rather than an empty token"
else
  fail "a tokenless run passes no -e flag rather than an empty token"
fi

# zizmor's own exit code has to survive the wrapper, or the wrapper becomes the
# next check that cannot fail.
GH_TOKEN=ghs_stub STUB_EXIT=14 run_runner regular
exits "findings reported by zizmor still fail the job" 14

GH_TOKEN=ghs_stub run_runner --print regular
exits "--print is inert" 0
says "--print shows the command that would run" "zizmor"

GH_TOKEN=ghs_stub run_runner nonsense
exits "an unknown pass is a usage error" 2

GH_TOKEN=ghs_stub run_runner
exits "no pass at all is a usage error" 2

echo
echo "=== Part 3: the mutation control - the pre-fix command line ==="

# The command the workflow used to run, verbatim except for the stub: no
# `-e GH_TOKEN`. The stub models docker's forwarding rule, so this is the shape
# of the defect, and it is the shape the runner no longer produces.
PATH="$TMP/bin:$PATH" GH_TOKEN=ghs_stub docker run --rm -v "$PWD:/repo" -w /repo \
  ghcr.io/zizmorcore/zizmor:1.30.0 \
  --min-confidence medium --min-severity medium --no-progress --format plain \
  --config .github/zizmor.yml .github/workflows .github/actions \
  >"$TMP/prefix.log" 2>&1
PREFIX_STATUS=$?

if [ "$PREFIX_STATUS" -eq 0 ]; then
  pass "the pre-fix invocation exits 0, which is why the run was green"
else
  fail "the pre-fix invocation exits 0, which is why the run was green (exit $PREFIX_STATUS)"
fi

if grep -qF "$BANNER" "$TMP/prefix.log"; then
  pass "the pre-fix invocation prints the offline banner, exactly as run 34366975873 did"
else
  fail "the pre-fix invocation prints the offline banner, exactly as run 34366975873 did"
fi

if [ ! -s "$TMP/token-seen.txt" ]; then
  pass "the pre-fix invocation leaves the container with no token"
else
  fail "the pre-fix invocation leaves the container with no token"
fi

echo
echo "=== Part 4: every tracked caller of the analyser passes a token ==="

# The same defect in more than one place is the reason issue #123 asks for the
# whole codebase. dev/log holds verbatim copies of other projects' files
# collected as evidence, and docs quote the historical command.
CALLERS="$(git ls-files | grep -vE '^(dev/log|docs)/' \
  | xargs grep -l 'zizmorcore/zizmor:' 2>/dev/null || true)"

if [ -n "$CALLERS" ]; then
  pass "found tracked callers of the analyser to check"
else
  fail "found tracked callers of the analyser to check"
fi

while IFS= read -r caller; do
  [ -z "$caller" ] && continue
  if grep -q -- '-e GH_TOKEN' "$caller"; then
    pass "$caller passes GH_TOKEN into the container"
  elif grep -q 'run-zizmor.sh' "$caller"; then
    pass "$caller goes through the runner, which passes the token"
  else
    fail "$caller runs the analyser without a token, so its online audits are silently skipped"
  fi
done <<<"$CALLERS"

echo
echo "=== Summary ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"
[ "$FAILED" -eq 0 ]
