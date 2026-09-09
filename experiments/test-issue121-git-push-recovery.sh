#!/usr/bin/env bash
# test-issue121-git-push-recovery.sh
#
# Issue #121, CI/CD best practice 10. Three jobs in this repository wrote to
# main with a bare `git push origin main`:
#
#   .github/workflows/release.yml         (the manual version bump)
#   scripts/release/apply-changesets.sh   (the changeset version bump)
#   .github/workflows/measure-disk-space.yml (the measurement commit)
#
# A concurrency group orders writers; it does not rebase them. `actions/checkout`
# checks out `github.sha`, so the second writer in the queue is behind the branch
# the instant the first one lands and its push is rejected. The measurement job
# runs about 18 minutes before it pushes, which is a wide window to lose.
#
# And the two rejections that print the same word need opposite recoveries:
#
#   ! [rejected]        main -> main (non-fast-forward)          -> rebase
#   remote: error: GH013: Repository rule violations found ...   -> pull request
#
# Answering a GH013 with a rebase is what kills a release *after* the version
# bump has been committed on the runner, with a log that blames a race that
# never happened.
#
# This suite runs the real scripts against stub `git` and `gh` binaries on PATH,
# so no network, no repository and no credentials are involved.
#
# Usage: bash experiments/test-issue121-git-push-recovery.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

REPO_ROOT="$PWD"
CLASSIFIER="scripts/release/git-push-failure-classifier.sh"
PUSHER="scripts/release/git-push-with-retry.sh"
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

# --- Part 1: the classifier -------------------------------------------------

echo "=== Part 1: the classifier tells the two rejections apart ==="

# shellcheck source=scripts/release/git-push-failure-classifier.sh
source "$CLASSIFIER"

# These four are transcribed from a run, not from memory: reproduce them with
#   bash experiments/reproduce-issue121-push-rejection-texts.sh
# whose output is archived at
#   dev/log/issues/121/pulls/122/push-rejection/git-push-rejection-texts.txt
RACE_OUTPUT=$'To github.com:link-foundation/box.git\n ! [rejected]        HEAD -> main (fetch first)\nerror: failed to push some refs\nhint: Updates were rejected because the remote contains work that you do not\nhint: have locally.'
RULE_OUTPUT=$'remote: error: GH013: Repository rule violations found for refs/heads/main.\nremote: error: - Changes must be made through a pull request.\nTo github.com:link-foundation/box.git\n ! [remote rejected] HEAD -> main (pre-receive hook declined)\nerror: failed to push some refs'
GH006_OUTPUT=$'remote: error: GH006: Protected branch update failed for refs/heads/main.\n ! [remote rejected] main -> main (protected branch hook declined)'
AUTH_OUTPUT=$'remote: Invalid username or token. Password authentication is not supported.\nfatal: Authentication failed for https://github.com/link-foundation/box/'
# Case 4 of the reproduction: a single push, one ref behind and one ref declined
# by the rule, so the output carries both signals at once. This is the output
# that decides whether the classifier's ordering is real or decorative.
MIXED_OUTPUT=$'remote: error: GH013: Repository rule violations found for refs/heads/main.\nremote: error: - Changes must be made through a pull request.\nremote: error: hook declined to update refs/heads/main\nTo github.com:link-foundation/box.git\n ! [rejected]        HEAD -> topic (fetch first)\n ! [remote rejected] HEAD -> main (hook declined)\nerror: failed to push some refs\nhint: Updates were rejected because the remote contains work that you do not\nhint: have locally.'

if is_non_fast_forward_rejection "$RACE_OUTPUT"; then
  pass "a non-fast-forward rejection is classified as a lost race"
else
  fail "a non-fast-forward rejection is classified as a lost race"
fi

if ! is_repository_rule_rejection "$RACE_OUTPUT"; then
  pass "a non-fast-forward rejection is not classified as a repository rule"
else
  fail "a non-fast-forward rejection is not classified as a repository rule"
fi

if is_repository_rule_rejection "$RULE_OUTPUT"; then
  pass "a GH013 rejection is classified as a repository rule"
else
  fail "a GH013 rejection is classified as a repository rule"
fi

# A GH013 on its own says "[remote rejected]", which shares no substring with
# the race patterns -- so this one would hold even without the ordering.
if ! is_non_fast_forward_rejection "$RULE_OUTPUT"; then
  pass "a GH013 rejection alone is not read as a lost race"
else
  fail "a GH013 rejection alone is not read as a lost race"
fi

# This is the assertion that actually pins the ordering down. Case 4 of the
# reproduction is a real push whose output is BOTH: "! [rejected] ... (fetch
# first)" and "Updates were rejected" sit in the same capture as the GH013.
# Classify it as a race and the job rebases, which cannot satisfy a rule on
# main; the rebase succeeds, the second push is declined identically, and the
# log blames a race. So the rule has to win.
if is_repository_rule_rejection "$MIXED_OUTPUT"; then
  pass "an output carrying both signals is classified as a repository rule"
else
  fail "an output carrying both signals is classified as a repository rule"
fi
if ! is_non_fast_forward_rejection "$MIXED_OUTPUT"; then
  pass "an output carrying both signals is NOT read as a lost race (rule wins)"
else
  fail "an output carrying both signals is NOT read as a lost race (rule wins)"
fi

if is_repository_rule_rejection "$GH006_OUTPUT" && ! is_non_fast_forward_rejection "$GH006_OUTPUT"; then
  pass "a GH006 protected-branch rejection is classified as a repository rule"
else
  fail "a GH006 protected-branch rejection is classified as a repository rule"
fi

if ! is_repository_rule_rejection "$AUTH_OUTPUT" && ! is_non_fast_forward_rejection "$AUTH_OUTPUT"; then
  pass "an authentication failure is neither, so no retry can claim to fix it"
else
  fail "an authentication failure is neither, so no retry can claim to fix it"
fi

if is_repository_rule_rejection "$(printf '%s' "$RULE_OUTPUT" | tr '[:lower:]' '[:upper:]')"; then
  pass "classification is case-insensitive (git and forges differ on casing)"
else
  fail "classification is case-insensitive (git and forges differ on casing)"
fi

# --- Part 2: the push helper against stub git/gh ----------------------------

echo
echo "=== Part 2: the recoveries, driven end to end against stubs ==="

# Each scenario gets a scratch PATH whose `git` and `gh` are scripts that
# record their argv and answer from a scripted list of outcomes.
make_stubs() {
  local dir="$1" push_script="$2"
  mkdir -p "$dir/bin"
  cat >"$dir/bin/git" <<STUB
#!/usr/bin/env bash
echo "git \$*" >> "$dir/git.log"
case "\$1" in
  push) $push_script ;;
  *) exit 0 ;;
esac
STUB
  cat >"$dir/bin/gh" <<STUB
#!/usr/bin/env bash
echo "gh \$*" >> "$dir/gh.log"
case "\$2" in
  list) echo "" ;;
  create) echo "https://github.com/link-foundation/box/pull/999" ;;
  merge) [ -f "$dir/merge-ok" ] || { echo "Pull request is not mergeable" >&2; exit 1; }; ;;
esac
exit 0
STUB
  chmod +x "$dir/bin/git" "$dir/bin/gh"
}

run_pusher() {
  local dir="$1"
  shift
  (
    cd "$REPO_ROOT" || exit 1
    PATH="$dir/bin:$PATH" \
      GIT_PUSH_RETRY_DELAY=0 GIT_PUSH_MERGE_DELAY=0 GIT_PUSH_MERGE_ATTEMPTS=2 \
      GITHUB_RUN_ID=42 \
      bash "$PUSHER" origin main "2.9.0" >"$dir/out.log" 2>&1
  )
}

# Scenario A: the push succeeds on the first attempt.
A="$(mktemp -d)"
make_stubs "$A" 'exit 0'
run_pusher "$A"
A_EXIT=$?
if [ "$A_EXIT" -eq 0 ]; then
  pass "a push that succeeds exits 0"
else
  fail "a push that succeeds exits 0 (got $A_EXIT)"
fi
if [ "$(grep -c '^git push' "$A/git.log")" -eq 1 ] && ! grep -q 'pull --rebase' "$A/git.log"; then
  pass "a push that succeeds pushes once and does not rebase"
else
  fail "a push that succeeds pushes once and does not rebase"
fi

# Scenario B: lost race on the first attempt, success after the rebase.
B="$(mktemp -d)"
make_stubs "$B" "if [ -f \"$B/pushed-once\" ]; then exit 0; fi; touch \"$B/pushed-once\"; printf '%s\n' ' ! [rejected]        main -> main (non-fast-forward)' >&2; exit 1"
run_pusher "$B"
B_EXIT=$?
if [ "$B_EXIT" -eq 0 ]; then
  pass "a lost race recovers and exits 0"
else
  fail "a lost race recovers and exits 0 (got $B_EXIT)"
fi
if grep -q 'git pull --rebase origin main' "$B/git.log"; then
  pass "a lost race rebases onto the remote branch before retrying"
else
  fail "a lost race rebases onto the remote branch before retrying"
fi
# Never --force, never --force-with-lease: both turn a lost race into a silent
# deletion of whatever the writer ahead of us landed.
if ! grep -qE 'force' "$B/git.log"; then
  pass "the retry never force-pushes"
else
  fail "the retry never force-pushes"
fi
if [ "$(grep -c '^git push' "$B/git.log")" -eq 2 ]; then
  pass "a lost race pushes exactly twice"
else
  fail "a lost race pushes exactly twice (got $(grep -c '^git push' "$B/git.log"))"
fi

# Scenario C: a repository rule declines every direct push.
C="$(mktemp -d)"
make_stubs "$C" "case \"\$3\" in HEAD:main) printf '%s\n' 'remote: error: GH013: Repository rule violations found for refs/heads/main.' 'remote: - Changes must be made through a pull request.' >&2; exit 1 ;; *) exit 0 ;; esac"
touch "$C/merge-ok"
run_pusher "$C"
C_EXIT=$?
if [ "$C_EXIT" -eq 0 ]; then
  pass "a repository-rule rejection lands through a pull request and exits 0"
else
  fail "a repository-rule rejection lands through a pull request and exits 0 (got $C_EXIT)"
fi
if ! grep -q 'pull --rebase' "$C/git.log"; then
  pass "a repository-rule rejection is never answered with a rebase"
else
  fail "a repository-rule rejection is never answered with a rebase"
fi
if grep -q 'git push origin HEAD:release/2.9.0-42' "$C/git.log"; then
  pass "the fallback branch name carries the label and the run id"
else
  fail "the fallback branch name carries the label and the run id"
  cat "$C/git.log"
fi
# A `deletion` / `non_fast_forward` rule on ~ALL forbids deleting any ref, so
# the temporary branch is left in place rather than cleaned up.
if ! grep -qE 'push .*--delete|branch -D' "$C/git.log"; then
  pass "the fallback never deletes the branch it created"
else
  fail "the fallback never deletes the branch it created"
fi
# allowed_merge_methods may be ["merge"] only.
if grep -q 'gh pr merge .* --merge' "$C/gh.log" && ! grep -qE 'gh pr merge .*--(squash|rebase)' "$C/gh.log"; then
  pass "the fallback merges with --merge, assuming neither squash nor rebase"
else
  fail "the fallback merges with --merge, assuming neither squash nor rebase"
fi
if grep -q 'git checkout -B main origin/main' "$C/git.log"; then
  pass "the checkout is fast-forwarded to the merged branch so the job continues"
else
  fail "the checkout is fast-forwarded to the merged branch so the job continues"
fi

# Scenario D: mergeability is not computed yet on the first poll.
D="$(mktemp -d)"
make_stubs "$D" "case \"\$3\" in HEAD:main) printf '%s\n' 'remote: error: GH013: Repository rule violations found for refs/heads/main.' >&2; exit 1 ;; *) exit 0 ;; esac"
cat >"$D/bin/gh" <<STUB
#!/usr/bin/env bash
echo "gh \$*" >> "$D/gh.log"
case "\$2" in
  list) echo "" ;;
  create) echo "https://github.com/link-foundation/box/pull/999" ;;
  merge)
    if [ -f "$D/tried" ]; then exit 0; fi
    touch "$D/tried"
    echo "Pull request is not mergeable" >&2
    exit 1
    ;;
esac
exit 0
STUB
chmod +x "$D/bin/gh"
run_pusher "$D"
D_EXIT=$?
if [ "$D_EXIT" -eq 0 ]; then
  pass "a 'not mergeable yet' answer is polled again rather than treated as failure"
else
  fail "a 'not mergeable yet' answer is polled again rather than treated as failure (got $D_EXIT)"
fi

# Scenario E: an authentication failure must not be retried or reinterpreted.
E="$(mktemp -d)"
make_stubs "$E" "printf '%s\n' 'fatal: Authentication failed for https://github.com/link-foundation/box/' >&2; exit 1"
run_pusher "$E"
E_EXIT=$?
if [ "$E_EXIT" -ne 0 ]; then
  pass "an authentication failure fails the job"
else
  fail "an authentication failure fails the job"
fi
if [ "$(grep -c '^git push' "$E/git.log")" -eq 1 ] && ! grep -q 'pull --rebase' "$E/git.log"; then
  pass "an authentication failure is not retried and not rebased"
else
  fail "an authentication failure is not retried and not rebased"
fi
if grep -q 'neither a lost race nor a repository rule' "$E/out.log"; then
  pass "an authentication failure names the real cause instead of a race"
else
  fail "an authentication failure names the real cause instead of a race"
fi

# Scenario F: losing the race every time is bounded, and stays an error.
F="$(mktemp -d)"
make_stubs "$F" "printf '%s\n' ' ! [rejected]        main -> main (non-fast-forward)' >&2; exit 1"
run_pusher "$F"
F_EXIT=$?
if [ "$F_EXIT" -ne 0 ]; then
  pass "losing the race every time fails the job rather than looping"
else
  fail "losing the race every time fails the job rather than looping"
fi
if [ "$(grep -c '^git push' "$F/git.log")" -eq 3 ]; then
  pass "the retries are bounded by GIT_PUSH_MAX_ATTEMPTS (3 by default)"
else
  fail "the retries are bounded by GIT_PUSH_MAX_ATTEMPTS (got $(grep -c '^git push' "$F/git.log") pushes)"
fi

rm -rf "$A" "$B" "$C" "$D" "$E" "$F"

# --- Part 3: every writer of main uses it -----------------------------------

echo
echo "=== Part 3: no writer of main is left with a bare push ==="

BARE=0
while IFS= read -r hit; do
  echo "  bare push: $hit"
  BARE=$((BARE + 1))
done < <(grep -rnE '^[^#]*git push +(origin|"?\$\{?REMOTE)' \
  .github/workflows scripts --include='*.yml' --include='*.sh' \
  | grep -v 'scripts/release/git-push-with-retry.sh' || true)

if [ "$BARE" -eq 0 ]; then
  pass "no workflow or script pushes to a shared branch without the helper"
else
  fail "no workflow or script pushes to a shared branch without the helper ($BARE found)"
fi

for site in .github/workflows/release.yml .github/workflows/measure-disk-space.yml scripts/release/apply-changesets.sh; do
  if grep -q 'git-push-with-retry.sh' "$site"; then
    pass "$site pushes through the helper"
  else
    fail "$site pushes through the helper"
  fi
done

# The fallback opens a pull request, which needs the permission to do so.
for wf in .github/workflows/release.yml .github/workflows/measure-disk-space.yml; do
  if grep -q 'pull-requests: write' "$wf"; then
    pass "$wf grants pull-requests: write for the fallback path"
  else
    fail "$wf grants pull-requests: write for the fallback path"
  fi
done

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
