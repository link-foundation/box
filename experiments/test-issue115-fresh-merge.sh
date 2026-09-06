#!/usr/bin/env bash
# test-issue115-fresh-merge.sh
#
# Issue #115, best practice #7: "validate the actual merge result".
#
# For a `pull_request` event GitHub checks out `refs/pull/N/merge`, a merge
# commit it computed when the pull request was last synchronised. It is not
# recomputed when the base branch moves, so a check can be green against a
# merge result that no longer exists - a false positive that only shows up
# after the merge button is pressed, on `main`, where it is most expensive.
#
# scripts/ci/simulate-fresh-merge.sh merges the base tip in first. This suite
# drives it against real throwaway git repositories (no network, no GitHub) and
# pins the wiring in the workflows.
#
# Usage: bash experiments/test-issue115-fresh-merge.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
REPO_ROOT="$PWD"

SCRIPT="$REPO_ROOT/scripts/ci/simulate-fresh-merge.sh"
ACTION="$REPO_ROOT/.github/actions/simulate-fresh-merge/action.yml"
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

for f in "$SCRIPT" "$ACTION"; do
  if [ -f "$f" ]; then
    pass "$(basename "$(dirname "$f")")/$(basename "$f") exists"
  else
    fail "$f is missing"
  fi
done

if [ "$FAIL" -gt 0 ]; then
  echo
  echo "passed: $PASS"
  echo "failed: $FAIL"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
git config --global init.defaultBranch main
git config --global user.name test
git config --global user.email test@example.com

# scenario NAME - build an "upstream" repository with a commit on main and a
# branch `feature` carrying a commit of its own, then clone it into a work tree
# the way a runner would. Echoes the work tree path.
#
# The branch needs its own commit before the clone, or the fixture is a
# tautology: with `feature` sitting exactly on the fork point, a depth-1 clone
# still contains the merge base, and the shallow case below can never fail.
# Real pull requests have their own history; so does this one.
#
# The clone is deliberately shallow (--depth 1), because that is what
# actions/checkout does by default and it is the case the template's script
# does not handle: a shallow HEAD has no common ancestor with a freshly fetched
# base tip, and the merge fails with "refusing to merge unrelated histories" -
# not a conflict, and it must not be reported as one.
#
# The remote is addressed as file://, not as a path: `git clone --depth` is
# *silently* ignored for a local-path clone ("warning: --depth is ignored in
# local clones"), and a fixture that is not shallow cannot exercise the
# deepening it claims to test. Writing this suite the obvious way produced
# exactly that - an assertion that could only ever have passed if the script
# printed the message unconditionally.
scenario() {
  local name="$1" depth="${2:-1}"
  local up="$TMP/$name-upstream" work="$TMP/$name-work"

  git init --quiet --bare "$up"
  local seed="$TMP/$name-seed"
  git init --quiet "$seed"
  (
    cd "$seed" || exit 1
    echo base >shared.txt
    echo "unrelated" >other.txt
    git add -A && git commit --quiet -m "base"
    git checkout --quiet -b feature
    echo "branch history" >history.txt
    git add -A && git commit --quiet -m "work on the branch"
    git checkout --quiet main
    git remote add origin "$up"
    git push --quiet origin main feature
  ) >/dev/null 2>&1

  git clone --quiet --depth "$depth" --branch feature "file://$up" "$work" 2>/dev/null
  printf '%s' "$work"
}

# advance_base NAME CONTENT FILE - add a commit to main in the upstream repo.
advance_base() {
  local name="$1" content="$2" file="$3"
  local seed="$TMP/$name-seed"
  (
    cd "$seed" || exit 1
    git checkout --quiet main
    printf '%s\n' "$content" >"$file"
    git add -A && git commit --quiet -m "base moves on"
    git push --quiet origin main
  ) >/dev/null 2>&1
}

# advance_branch NAME CONTENT FILE - add a commit to the feature branch in the
# checked-out work tree, as a pull request author would.
advance_branch() {
  local work="$1" content="$2" file="$3"
  (
    cd "$work" || exit 1
    printf '%s\n' "$content" >"$file"
    git add -A && git commit --quiet -m "pull request work"
  ) >/dev/null 2>&1
}

# simulate WORK - run the script in WORK, leaving output in $OUT, status in
# $STATUS.
OUT=""
STATUS=0
simulate() {
  OUT="$(cd "$1" && BASE_REF=main FETCH_DELAY=0 bash "$SCRIPT" 2>&1)"
  STATUS=$?
}

echo "== Part 1: nothing to do when the preview is already current =="

W="$(scenario uptodate)"
simulate "$W"
if [ "$STATUS" -eq 0 ]; then
  pass "an up-to-date branch exits 0"
else
  fail "an up-to-date branch exits 0 (got $STATUS)"
  printf '%s\n' "$OUT" | sed 's/^/      /' >&2
fi

case "$OUT" in
  *"Nothing to do"*) pass "and says so, instead of making an empty merge commit" ;;
  *)
    fail "and says so"
    printf '%s\n' "$OUT" | sed 's/^/      /' >&2
    ;;
esac

echo ""
echo "== Part 2: a moved base branch is merged in (the false positive) =="

W="$(scenario moved)"
advance_branch "$W" "feature change" feature.txt
advance_base moved "base change" other.txt
simulate "$W"

if [ "$STATUS" -eq 0 ]; then
  pass "a fast-forwardable base merges cleanly and exits 0"
else
  fail "a fast-forwardable base merges cleanly and exits 0 (got $STATUS)"
  printf '%s\n' "$OUT" | sed 's/^/      /' >&2
fi

# The point of the whole exercise: the base branch's change has to be present
# in the tree the checks then run against.
if [ -f "$W/other.txt" ] && grep -q 'base change' "$W/other.txt"; then
  pass "the base branch's commit is in the working tree the checks will see"
else
  fail "the base branch's commit is NOT in the working tree; the checks would report on a stale preview"
fi

if [ -f "$W/feature.txt" ]; then
  pass "the pull request's own change survives the merge"
else
  fail "the pull request's own change was lost"
fi

# A shallow clone is the default; if deepening did not happen the merge above
# would have failed with "unrelated histories".
case "$OUT" in
  *"deepening"*) pass "the shallow checkout was deepened first" ;;
  *) fail "the shallow checkout was not deepened; the merge would be an unrelated-histories error" ;;
esac

if ! printf '%s' "$OUT" | grep -q 'unrelated histories'; then
  pass "no unrelated-histories error"
else
  fail "the merge hit unrelated histories"
fi

# Control: the same merge, on the same fixture, without the deepening. If this
# succeeded, the assertions above would be passing for a reason unrelated to
# the code they claim to cover.
# The divergent commit on the branch matters: without one the merge is a
# fast-forward, which needs no merge base and succeeds even on a shallow
# clone. Only a real three-way merge exposes the missing history.
CONTROL="$(scenario control)"
advance_branch "$CONTROL" "feature change" feature.txt
advance_base control "base change" other.txt
CONTROL_OUT="$(
  cd "$CONTROL" || exit 1
  git fetch --no-tags --quiet origin '+refs/heads/main:refs/remotes/origin/main'
  git -c user.email=t@e.com -c user.name=t merge origin/main --no-edit 2>&1
)"
if printf '%s' "$CONTROL_OUT" | grep -q 'unrelated histories'; then
  pass "and without the deepening that same merge fails, so the step is load-bearing"
else
  fail "the control merge succeeded without deepening; this fixture proves nothing"
  printf '%s\n' "$CONTROL_OUT" | sed 's/^/      /' >&2
fi

echo ""
echo "== Part 3: a real conflict fails, loudly and reversibly =="

W="$(scenario conflict)"
advance_branch "$W" "ours" shared.txt
advance_base conflict "theirs" shared.txt
simulate "$W"

if [ "$STATUS" -eq 1 ]; then
  pass "a conflicting merge exits 1"
else
  fail "a conflicting merge exits 1 (got $STATUS)"
  printf '%s\n' "$OUT" | sed 's/^/      /' >&2
fi

case "$OUT" in
  *"::error title=Merge conflict::"*) pass "the conflict is annotated as an error" ;;
  *)
    fail "the conflict is annotated as an error"
    printf '%s\n' "$OUT" | sed 's/^/      /' >&2
    ;;
esac

case "$OUT" in
  *shared.txt*) pass "the conflicting path is named" ;;
  *) fail "the conflicting path is named" ;;
esac

# The merge is aborted, so a later step that inspects the tree sees a sane
# checkout rather than conflict markers in every file.
if [ ! -f "$W/.git/MERGE_HEAD" ] && ! grep -rq '<<<<<<<' "$W/shared.txt"; then
  pass "the failed merge is aborted; no conflict markers are left in the tree"
else
  fail "the failed merge is left half-applied"
fi

case "$OUT" in
  *"git merge origin/main"*) pass "the failure says how to reproduce it locally" ;;
  *) fail "the failure says how to reproduce it locally" ;;
esac

echo ""
echo "== Part 4: misuse is refused, not guessed at =="

W="$(scenario misuse)"
OUT="$(cd "$W" && FETCH_DELAY=0 bash "$SCRIPT" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 2 ] && printf '%s' "$OUT" | grep -q '::error'; then
  pass "a missing BASE_REF exits 2 with an annotation"
else
  fail "a missing BASE_REF exits 2 with an annotation (got $STATUS)"
fi

OUT="$(cd "$TMP" && BASE_REF=main FETCH_DELAY=0 bash "$SCRIPT" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 2 ]; then
  pass "running outside a git repository exits 2"
else
  fail "running outside a git repository exits 2 (got $STATUS)"
fi

W="$(scenario nobase)"
OUT="$(cd "$W" && BASE_REF=does-not-exist FETCH_DELAY=0 bash "$SCRIPT" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 2 ] && printf '%s' "$OUT" | grep -q 'cannot fetch'; then
  pass "a base branch that does not exist exits 2, not 1"
else
  fail "a base branch that does not exist exits 2, not 1 (got $STATUS)"
fi

# The fetch is retried because sixteen jobs now depend on it; a check that
# fails on someone else's network blip is the false positive this repository
# is trying to remove.
if [ "$(printf '%s' "$OUT" | grep -c 'retrying in')" -eq 2 ]; then
  pass "a failing fetch is retried FETCH_RETRIES times before giving up"
else
  fail "a failing fetch is retried (saw $(printf '%s' "$OUT" | grep -c 'retrying in') retry messages)"
fi

OUT="$(cd "$W" && BASE_REF=does-not-exist FETCH_RETRIES=1 FETCH_DELAY=0 bash "$SCRIPT" 2>&1)"
if ! printf '%s' "$OUT" | grep -q 'retrying in'; then
  pass "FETCH_RETRIES=1 makes exactly one attempt"
else
  fail "FETCH_RETRIES=1 still retries"
fi

echo ""
echo "== Part 5: verbose mode is off by default =="

W="$(scenario verbose)"
advance_base verbose "base change" other.txt
QUIET="$(cd "$W" && BASE_REF=main FETCH_DELAY=0 bash "$SCRIPT" 2>&1)"
TRACED="$(cd "$(scenario verbose2)" && BASE_REF=main FETCH_DELAY=0 BOX_VERBOSE=1 bash "$SCRIPT" 2>&1)"

if ! printf '%s' "$QUIET" | grep -q '^\+ git'; then
  pass "no shell trace by default"
else
  fail "the script traces by default"
fi

if printf '%s' "$TRACED" | grep -q '^\+ git'; then
  pass "BOX_VERBOSE=1 traces every git command"
else
  fail "BOX_VERBOSE=1 does not trace"
fi

echo ""
echo "== Part 6: every pull-request check runs it =="

# A gate nothing calls is the false negative this repository keeps finding, so
# the wiring is asserted rather than assumed. Every workflow that reacts to a
# pull_request event must invoke the action in each job that checks the tree
# out - listed explicitly, because a new job that skips it is exactly the drift
# worth catching.
declare -A EXPECTED=(
  ['.github/workflows/dockerfiles.yml']=1
  ['.github/workflows/links.yml']=1
  ['.github/workflows/measure-disk-space.yml']=1
  ['.github/workflows/scripts.yml']=3
  ['.github/workflows/security.yml']=2
  ['.github/workflows/workflows.yml']=2
  ['.github/workflows/release.yml']=6
)

for wf in "${!EXPECTED[@]}"; do
  want="${EXPECTED[$wf]}"
  got="$(grep -c 'uses: ./.github/actions/simulate-fresh-merge' "$REPO_ROOT/$wf")"
  if [ "$got" -eq "$want" ]; then
    pass "$(basename "$wf") calls the action in all $want of its checks"
  else
    fail "$(basename "$wf") calls the action $got times, expected $want"
  fi
done

# release.yml's six are the pr-test tier. version-check, changeset-check and
# detect-changes are deliberately excluded: they diff the pull request against
# its base, and merging the base in first would change what they measure.
if [ "$(grep -c '^  pr-test[a-z0-9-]*:' "$REPO_ROOT/.github/workflows/release.yml")" -eq 6 ]; then
  pass "the pr-test tier still has the six jobs the count above assumes"
else
  fail "the pr-test tier changed size; update the expected count with it"
fi

if grep -q "if: github.event_name == 'pull_request'" "$ACTION"; then
  pass "the action is a no-op outside a pull request"
else
  fail "the action would try to merge on a push to main"
fi

echo ""
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
