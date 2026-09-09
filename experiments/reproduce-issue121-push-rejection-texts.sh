#!/usr/bin/env bash
# reproduce-issue121-push-rejection-texts.sh
#
# Ground truth for scripts/release/git-push-failure-classifier.sh: what git
# actually prints when a push is refused, for each way a push can be refused.
#
# The classifier has to tell a lost race (rebase and retry) from a repository
# rule violation (land through a pull request), and both print "rejected". The
# strings the classifier matches on should come from a run, not from memory, so
# this reproduces all four cases against local bare repositories whose hooks
# emit GitHub's own GH013 wording. No network, no credentials, no remote is
# touched -- and in particular nothing here pushes to a real branch.
#
# Case 4 is the one that motivates the ordering inside the classifier: a single
# push whose output carries BOTH signals at once.
#
# Every experiments/*.sh is a check that must exit 0, so this does not merely
# print the transcript: it asserts that each case still produces the strings the
# classifier matches on, and runs the classifier over the captured output. If a
# future git changes the wording of a rejection, this fails here rather than in
# a release.
#
# Usage: bash experiments/reproduce-issue121-push-rejection-texts.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# shellcheck source=scripts/release/git-push-failure-classifier.sh
source scripts/release/git-push-failure-classifier.sh

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

# Assert that a captured push output contains a string, then that the classifier
# reaches the expected verdict on it.
check_case() {
  local name="$1" output="$2" expect_rule="$3" expect_race="$4"
  shift 4
  local needle
  for needle in "$@"; do
    case "$output" in
      *"$needle"*) pass "$name still prints: $needle" ;;
      *) fail "$name no longer prints: $needle" ;;
    esac
  done
  if [ "$expect_rule" = yes ]; then
    is_repository_rule_rejection "$output" \
      && pass "$name classifies as a repository rule" \
      || fail "$name classifies as a repository rule"
  else
    is_repository_rule_rejection "$output" \
      && fail "$name does not classify as a repository rule" \
      || pass "$name does not classify as a repository rule"
  fi
  if [ "$expect_race" = yes ]; then
    is_non_fast_forward_rejection "$output" \
      && pass "$name classifies as a lost race" \
      || fail "$name classifies as a lost race"
  else
    is_non_fast_forward_rejection "$output" \
      && fail "$name does not classify as a lost race" \
      || pass "$name does not classify as a lost race"
  fi
}

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

git_q() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }

# A hook that refuses refs/heads/main the way a GitHub ruleset does.
write_rule_hook() {
  cat >"$1" <<'HOOK'
#!/bin/sh
if [ "${1:-refs/heads/main}" = "refs/heads/main" ]; then
  echo "error: GH013: Repository rule violations found for refs/heads/main." >&2
  echo "error: - Changes must be made through a pull request." >&2
  exit 1
fi
exit 0
HOOK
  chmod +x "$1"
}

echo "===== CASE 1: push accepted ====="
git_q init -q --bare "$W/r1.git"
git_q clone -q "$W/r1.git" "$W/c1" 2>/dev/null
CASE1="$(
  cd "$W/c1" || exit 1
  echo one >f.txt
  git_q add f.txt
  git_q commit -qm base
  git_q push origin HEAD:refs/heads/main 2>&1
)"
echo "$CASE1"
check_case "an accepted push" "$CASE1" no no '[new branch]'

echo
echo "===== CASE 2: lost race -- the remote branch advanced (rebase fixes it) ====="
git_q init -q --bare "$W/r2.git"
git_q clone -q "$W/r2.git" "$W/c2a" 2>/dev/null
(
  cd "$W/c2a" || exit 1
  echo one >f.txt
  git_q add f.txt
  git_q commit -qm base
  git_q push -q origin HEAD:refs/heads/main
)
git_q clone -q "$W/r2.git" "$W/c2b" 2>/dev/null
(
  cd "$W/c2b" || exit 1
  echo two >>f.txt
  git_q commit -qam second
  git_q push -q origin HEAD:refs/heads/main
)
CASE2="$(
  cd "$W/c2a" || exit 1
  echo three >>f.txt
  git_q commit -qam divergent
  git_q push origin HEAD:refs/heads/main 2>&1
)"
echo "$CASE2"
check_case "a lost race" "$CASE2" no yes \
  '! [rejected]' 'fetch first' 'Updates were rejected'

echo
echo "===== CASE 3: repository rule -- no rebase can ever satisfy it ====="
git_q init -q --bare "$W/r3.git"
write_rule_hook "$W/r3.git/hooks/pre-receive"
git_q clone -q "$W/r3.git" "$W/c3" 2>/dev/null
CASE3="$(
  cd "$W/c3" || exit 1
  echo one >f.txt
  git_q add f.txt
  git_q commit -qm base
  git_q push origin HEAD:refs/heads/main 2>&1
)"
echo "$CASE3"
check_case "a repository rule rejection" "$CASE3" yes no \
  'GH013' 'Changes must be made through a pull request' '! [remote rejected]'

echo
echo "===== CASE 4: BOTH at once -- one ref behind, one ref rule-declined ====="
echo "(this is why the classifier tests for a rule BEFORE it tests for a race)"
git_q init -q --bare "$W/r4.git"
write_rule_hook "$W/r4.git/hooks/update"
git_q clone -q "$W/r4.git" "$W/c4a" 2>/dev/null
(
  cd "$W/c4a" || exit 1
  echo one >f.txt
  git_q add f.txt
  git_q commit -qm base
  git_q push -q origin HEAD:refs/heads/topic
)
git_q clone -q "$W/r4.git" "$W/c4b" 2>/dev/null
(
  cd "$W/c4b" || exit 1
  git_q checkout -q topic
  echo two >>f.txt
  git_q commit -qam second
  git_q push -q origin HEAD:refs/heads/topic
)
CASE4="$(
  cd "$W/c4a" || exit 1
  echo three >>f.txt
  git_q commit -qam divergent
  git_q push origin HEAD:refs/heads/topic HEAD:refs/heads/main 2>&1
)"
echo "$CASE4"
# Both signals in one capture, and the rule has to win: rebasing would satisfy
# the topic ref and change nothing about main.
check_case "a mixed rejection" "$CASE4" yes no \
  '! [rejected]' 'Updates were rejected' 'GH013' '! [remote rejected]'

echo
echo "===== Summary ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
