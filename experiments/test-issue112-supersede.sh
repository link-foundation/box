#!/usr/bin/env bash
#
# Regression test for the CI/CD half of issue #112:
#   "We must fix our CI/CD, so previous commits skip execution in pull requests,
#    if multiple are committed in the order. So we only execute on last commit,
#    and reduce resource waste on all previous commits."
#
# Reproduction (PR #113, 2026-09-05): four commits were pushed within twelve
# minutes. The workflow-level `concurrency` group with cancel-in-progress: true
# did NOT stop the oldest one — run 33959630651 (commit 53c4258) was still
# starting matrix jobs at 10:29 while the runs for 4f06a6c, 981b61e and f07e411
# sat `pending` behind it and were cancelled one by one without ever executing a
# step. So the repository was paying for the superseded commit and testing none
# of the newer ones.
#
# Part 1 exercises scripts/ci/supersede.sh against a stubbed GitHub API:
#   - `cancel-older` cancels exactly the live runs of EARLIER commits;
#   - it never cancels itself, a newer run, a finished run, the same commit,
#     or a same-named branch on another fork;
#   - `stop-if-superseded` is a no-op while the run's commit is still the head;
#   - `stop-if-superseded` cancels its own run once the head has moved on;
#   - non-pull_request events do nothing at all;
#   - every failure mode (API down, read-only fork token) fails OPEN.
#
# Part 2 asserts the wiring in .github/workflows/release.yml, so a new expensive
# job cannot be added without the guard.
#
# Exit non-zero on the first failed assertion.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/ci/supersede.sh"
WF="$ROOT/.github/workflows/release.yml"

[ -f "$SCRIPT" ] || {
  echo "ERR: $SCRIPT not found" >&2
  exit 1
}

pass=0
fail=0

ok() {
  echo "  ok: $1"
  pass=$((pass + 1))
}
bad() {
  echo "  FAIL: $1" >&2
  fail=$((fail + 1))
}

check() {
  local label="$1" expected="$2" got="$3"
  if [ "$expected" = "$got" ]; then
    ok "$label"
  else
    bad "$label — expected [$expected], got [$got]"
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- The API stub -------------------------------------------------------------
# Stands in for `gh api`. GETs are answered from fixture files; every cancel POST
# appends its path to $STUB_CALLS so assertions can look at exactly what the
# script tried to cancel.
cat >"$TMP/api-stub.sh" <<'STUB'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "--method" ]; then
  echo "$3" >> "$STUB_CALLS"
  exit "${STUB_CANCEL_EXIT:-0}"
fi
[ "${STUB_GET_EXIT:-0}" = "0" ] || exit "$STUB_GET_EXIT"
case "$1" in
  *"/actions/workflows/"*"/runs"*) cat "$STUB_RUNS_JSON" ;;
  # A single run: STUB_RUN_STATUS decides whether the graceful cancel "worked".
  *"/actions/runs/"*)              printf '{"status": "%s"}\n' "${STUB_RUN_STATUS:-completed}" ;;
  *"/pulls/"*)                     cat "$STUB_PULL_JSON" ;;
  *) echo "stub: unexpected path $1" >&2; exit 1 ;;
esac
STUB

export SUPERSEDE_API="bash $TMP/api-stub.sh"
export SUPERSEDE_WAIT_SECONDS=0
export SUPERSEDE_FORCE_AFTER_SECONDS=0
export STUB_RUNS_JSON="$TMP/runs.json"
export STUB_PULL_JSON="$TMP/pull.json"

# Fixture: this run is #40, commit dddd (the newest). Everything else is a
# deliberate near-miss except runs 1001/1002.
cat >"$STUB_RUNS_JSON" <<'JSON'
{
  "workflow_runs": [
    {"id": 1001, "run_number": 37, "status": "in_progress", "head_sha": "aaaaaaaaaaaa",
     "head_repository": {"id": 7}},
    {"id": 1002, "run_number": 38, "status": "queued", "head_sha": "bbbbbbbbbbbb",
     "head_repository": {"id": 7}},
    {"id": 1003, "run_number": 39, "status": "completed", "head_sha": "cccccccccccc",
     "head_repository": {"id": 7}},
    {"id": 1004, "run_number": 40, "status": "in_progress", "head_sha": "dddddddddddd",
     "head_repository": {"id": 7}},
    {"id": 1005, "run_number": 41, "status": "in_progress", "head_sha": "eeeeeeeeeeee",
     "head_repository": {"id": 7}},
    {"id": 1006, "run_number": 36, "status": "in_progress", "head_sha": "dddddddddddd",
     "head_repository": {"id": 7}},
    {"id": 1007, "run_number": 35, "status": "in_progress", "head_sha": "ffffffffffff",
     "head_repository": {"id": 99}}
  ]
}
JSON

cat >"$STUB_PULL_JSON" <<'JSON'
{"number": 113, "head": {"sha": "dddddddddddd"}}
JSON

# Environment of a pull_request run for commit dddd, run #40, id 1004.
pr_env() {
  export GITHUB_EVENT_NAME=pull_request
  export GITHUB_REPOSITORY=link-foundation/box
  export GITHUB_RUN_ID=1004
  export GITHUB_RUN_NUMBER=40
  export GITHUB_WORKFLOW_REF='link-foundation/box/.github/workflows/release.yml@refs/pull/113/merge'
  export PR_NUMBER=113
  export PR_HEAD_SHA=dddddddddddd
  export PR_HEAD_BRANCH=issue-112-7f66cda6879b
  export PR_HEAD_REPO_ID=7
  export STUB_CALLS="$TMP/calls.txt"
  export STUB_CANCEL_EXIT=0
  export STUB_GET_EXIT=0
  export STUB_RUN_STATUS=completed
  # Reset the fixtures too: `VAR=x out="$(...)"` in the assertions below is two
  # assignments, not a command prefix, so the override would otherwise stick.
  export STUB_RUNS_JSON="$TMP/runs.json"
  export STUB_PULL_JSON="$TMP/pull.json"
  # Exported here so the `VAR=... out="$(...)"` overrides below reach the script
  # (a plain assignment only inherits the export flag a variable already has).
  export SUPERSEDE_WATCH_INTERVAL_SECONDS=1
  export SUPERSEDE_WATCH_MAX_SECONDS=4
  : >"$STUB_CALLS"
}

cancelled_ids() {
  sed -n 's#.*/actions/runs/\([0-9]*\)/cancel$#\1#p' "$STUB_CALLS" | sort | tr '\n' ' ' | sed 's/ $//'
}

forced_ids() {
  sed -n 's#.*/actions/runs/\([0-9]*\)/force-cancel$#\1#p' "$STUB_CALLS" | sort | tr '\n' ' ' | sed 's/ $//'
}

echo "=== Part 1: scripts/ci/supersede.sh against a stubbed GitHub API ==="

echo "--- cancel-older ---"
pr_env
out="$(bash "$SCRIPT" cancel-older 2>&1)" || bad "cancel-older exited non-zero"
check "cancels exactly the live runs of earlier commits" "1001 1002" "$(cancelled_ids)"
case "$out" in
  *"cancelled 2 superseded run(s)"*) ok "reports how many runs it cancelled" ;;
  *) bad "missing summary line in output: $out" ;;
esac

# The near-misses, spelled out one by one so a future filter change says which
# guarantee it broke.
for id in 1003 1004 1005 1006 1007; do
  case " $(cancelled_ids) " in
    *" $id "*) bad "run $id must NOT be cancelled" ;;
    *)
      case "$id" in
        1003) ok "a finished run is left alone" ;;
        1004) ok "the run never cancels itself in cancel-older" ;;
        1005) ok "a NEWER run is left alone" ;;
        1006) ok "an older run for the SAME commit is left alone" ;;
        1007) ok "a same-branch run from a different fork is left alone" ;;
      esac
      ;;
  esac
done

pr_env
printf '{"workflow_runs": []}' >"$TMP/empty.json"
STUB_RUNS_JSON="$TMP/empty.json" out="$(bash "$SCRIPT" cancel-older 2>&1)"
check "nothing to cancel when this is the only run" "" "$(cancelled_ids)"
case "$out" in
  *"no superseded runs"*) ok "says so when there is nothing to cancel" ;;
  *) bad "expected a 'no superseded runs' line: $out" ;;
esac

pr_env
STUB_GET_EXIT=1 bash "$SCRIPT" cancel-older >/dev/null 2>&1 \
  && ok "an unreachable API is not fatal (fails open)" \
  || bad "cancel-older must exit 0 when the API is unreachable"
check "an unreachable API cancels nothing" "" "$(cancelled_ids)"

pr_env
STUB_CANCEL_EXIT=1 bash "$SCRIPT" cancel-older >/dev/null 2>&1 \
  && ok "a read-only fork token is not fatal (fails open)" \
  || bad "cancel-older must exit 0 when the cancel is refused"

# The reason force-cancel exists here: on 2026-09-05 run 33959630651 accepted a
# graceful cancel at 10:40:57 and its dind-full job still finished green at
# 10:49:25; POST .../force-cancel stopped the same run within seconds.
pr_env
check "a run that stops on its own is not force-cancelled" "" "$(forced_ids)"
out="$(bash "$SCRIPT" cancel-older 2>&1)"
check "a graceful cancel that works needs no force" "" "$(forced_ids)"

pr_env
STUB_RUN_STATUS=in_progress
out="$(bash "$SCRIPT" cancel-older 2>&1)"
check "a run that ignores the cancel is force-cancelled" "1001 1002" "$(forced_ids)"
check "the graceful cancel is still tried first" "1001 1002" "$(cancelled_ids)"
case "$out" in
  *"force-cancelled"*) ok "logs the escalation to force-cancel" ;;
  *) bad "expected a 'force-cancelled' line: $out" ;;
esac

echo "--- stop-if-superseded ---"
pr_env
out="$(bash "$SCRIPT" stop-if-superseded 2>&1)" || bad "stop-if-superseded exited non-zero"
check "does not cancel while its commit is still the head" "" "$(cancelled_ids)"
case "$out" in
  *"still the head"*) ok "logs that the commit is current" ;;
  *) bad "expected a 'still the head' line: $out" ;;
esac

pr_env
PR_HEAD_SHA=aaaaaaaaaaaa
out="$(bash "$SCRIPT" stop-if-superseded 2>&1)" || bad "stop-if-superseded exited non-zero"
check "cancels its OWN run once the head moved on" "1004" "$(cancelled_ids)"
case "$out" in
  *"has moved on: aaaaaaa -> ddddddd"*) ok "logs the commit it was superseded by" ;;
  *) bad "expected the 'has moved on' line: $out" ;;
esac

pr_env
PR_HEAD_SHA=aaaaaaaaaaaa
STUB_RUN_STATUS=in_progress
out="$(bash "$SCRIPT" stop-if-superseded 2>&1)"
check "force-cancels its own run when the cancel is ignored" "1004" "$(forced_ids)"

pr_env
PR_HEAD_SHA=aaaaaaaaaaaa
STUB_GET_EXIT=1 bash "$SCRIPT" stop-if-superseded >/dev/null 2>&1 \
  && ok "an unreachable API lets the job proceed (fails open)" \
  || bad "stop-if-superseded must exit 0 when the API is unreachable"
check "an unreachable API cancels nothing" "" "$(cancelled_ids)"

pr_env
printf '{"number": 113}' >"$TMP/nohead.json"
PR_HEAD_SHA=aaaaaaaaaaaa STUB_PULL_JSON="$TMP/nohead.json" \
  bash "$SCRIPT" stop-if-superseded >/dev/null 2>&1 \
  && ok "a payload without a head is not fatal (fails open)" \
  || bad "stop-if-superseded must exit 0 on an unparseable payload"
check "a payload without a head cancels nothing" "" "$(cancelled_ids)"

echo "--- watch ---"
# `cancel-older` needs a runner, and a superseded run holding the account's job
# concurrency is exactly why none is free (run 33962058501 queued >10 min behind
# its predecessor). The watcher cancels the run from inside a job that already
# holds a slot, so one cancel frees them all.

pr_env
out="$(bash "$SCRIPT" watch 2>&1)" || bad "watch exited non-zero"
check "polls without cancelling while the commit is still the head" "" "$(cancelled_ids)"
case "$out" in
  *"stopped watching after"*) ok "watch gives up at SUPERSEDE_WATCH_MAX_SECONDS" ;;
  *) bad "expected a 'stopped watching' line: $out" ;;
esac

pr_env
PR_HEAD_SHA=aaaaaaaaaaaa
out="$(bash "$SCRIPT" watch 2>&1)"
check "cancels the whole run as soon as the head moves on" "1004" "$(cancelled_ids)"
case "$out" in
  *"has moved on: aaaaaaa -> ddddddd"*) ok "watch logs the superseding commit" ;;
  *) bad "expected the 'has moved on' line: $out" ;;
esac

pr_env
PR_HEAD_SHA=aaaaaaaaaaaa
STUB_RUN_STATUS=in_progress
out="$(bash "$SCRIPT" watch 2>&1)"
check "watch escalates to force-cancel too" "1004" "$(forced_ids)"

# A transient API failure must not end the watch: it has to survive to see the
# commit that supersedes this one.
pr_env
STUB_GET_EXIT=1 bash "$SCRIPT" watch >/dev/null 2>&1 \
  && ok "an unreachable API keeps the job running (fails open)" \
  || bad "watch must exit 0 when the API is unreachable"
check "an unreachable API cancels nothing" "" "$(cancelled_ids)"

echo "--- events other than pull_request ---"
for mode in cancel-older stop-if-superseded watch; do
  pr_env
  GITHUB_EVENT_NAME=push bash "$SCRIPT" "$mode" >/dev/null 2>&1 \
    && ok "$mode is a no-op on push" \
    || bad "$mode must exit 0 on push"
  check "$mode cancels nothing on push" "" "$(cancelled_ids)"
done

pr_env
bash "$SCRIPT" nonsense >/dev/null 2>&1 \
  && bad "an unknown mode must be a usage error" \
  || ok "an unknown mode is a usage error"

echo ""
echo "=== Part 2: release.yml wiring ==="

wf_check() {
  local label="$1" cmd="$2"
  if eval "$cmd"; then ok "$label"; else bad "$label"; fi
}

# The unique concurrency group is what lets a newer PR run start at all: with a
# shared group the newer run is `pending` and cannot cancel its predecessor.
wf_check "pull_request runs get a per-run concurrency group" \
  "grep -q 'pr-{1}-run-{2}' '$WF'"
wf_check "non-PR runs keep the one-run-per-ref group" \
  "grep -q \"format('{0}-{1}', github.workflow, github.ref)\" '$WF'"
wf_check "cancel-superseded job is defined" \
  "grep -q '^  cancel-superseded:\$' '$WF'"
wf_check "cancel-superseded calls the script" \
  "grep -q 'supersede.sh cancel-older' '$WF'"
wf_check "cancel-superseded has no needs (it must start immediately)" \
  "! sed -n '/^  cancel-superseded:\$/,/^  [a-z]/p' '$WF' | grep -q '^    needs:'"

# Every expensive PR job must self-check, because a matrix job can start long
# after the run was created (run 33959630651 started `pr-test / full` 26 minutes
# in, for a commit superseded 22 minutes earlier).
for job in pr-test-version-policy pr-test-js pr-test-essentials pr-test-language pr-test-full pr-test-dind; do
  body="$(sed -n "/^  ${job}:\$/,/^  [a-z0-9-]*:\$/p" "$WF")"
  if grep -q 'supersede.sh stop-if-superseded' <<<"$body"; then
    ok "$job guards against a superseded commit"
  else
    bad "$job is missing the stop-if-superseded guard"
  fi
  if grep -q 'actions: write' <<<"$body"; then
    ok "$job may cancel its run (actions: write)"
  else
    bad "$job lacks the actions: write permission the guard needs"
  fi
  # The one-shot guard only covers the moment the job starts; the watcher covers
  # the hour after it, which is when the run is holding the runners.
  if grep -q 'supersede.sh watch' <<<"$body"; then
    ok "$job keeps watching for superseding commits"
  else
    bad "$job does not start the background watcher"
  fi
  # The guard is worthless after the runner has already done the work, so it has
  # to be the very first step after the checkout it needs.
  second_step="$(grep -n '^      - \(name\|uses\):' <<<"$body" | sed -n '2p' | cut -d: -f1 || true)"
  guard_line="$(grep -n 'stop-if-superseded' <<<"$body" | head -n1 | cut -d: -f1 || true)"
  if [ -n "$second_step" ] && [ -n "$guard_line" ] && [ "$guard_line" -gt "$second_step" ] \
    && [ "$((guard_line - second_step))" -le 6 ]; then
    ok "$job checks before it spends anything (guard is the first step after checkout)"
  else
    bad "$job checks too late (guard at line ${guard_line:-none} of the job, second step at ${second_step:-none})"
  fi
done

echo ""
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
