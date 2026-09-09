#!/usr/bin/env bash
# test-issue121-checkout-credentials.sh
#
# Issue #121. Fixtures for scripts/ci/check-checkout-credentials.mjs.
#
# The gap it closes: `actions/checkout` writes the job's token into the
# repository's git configuration and, unless told otherwise, leaves it there
# for every later step in the job. Thirty of this repository's fifty-five
# checkouts said nothing, so thirty jobs kept it — `js / build-js-amd64` for
# 427 seconds, `Measure Component Disk Space` for 886, against 1.1-2.1s in the
# jobs that had been hardened. zizmor audits exactly this (`artipacked`) and
# ran on every one of them, but reports at severity Low and the gate floors at
# medium: the audit fired thirty times and was filtered out thirty times.
# experiments/reproduce-issue121-checkout-credentials.sh measures all of it.
#
# What the checker asserts is not "always drop the credential" — three jobs
# here do push and must keep it. It is that the setting is a decision, that the
# decision is written down, and that it matches what the job actually does,
# with "does" derived by following the job's `run:` blocks into the scripts
# they call rather than from a list somebody has to remember to update.
#
# Every fixture builds a throwaway git repository, because the checker
# discovers workflows with `git ls-files` and anchors at the repository root —
# both of which are answers about the repository it is standing in.
#
# Usage: bash experiments/test-issue121-checkout-credentials.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
CHECK="$ROOT/scripts/ci/check-checkout-credentials.mjs"

PASS=0
FAIL=0
pass() {
  PASS=$((PASS + 1))
  echo "PASS: $1"
}
fail() {
  FAIL=$((FAIL + 1))
  echo "FAIL: $1"
}

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node is not installed; this suite drives a checker written in JavaScript."
  exit 0
fi

if [ ! -f "$CHECK" ]; then
  echo "FAIL: $CHECK does not exist"
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SEQ=0
LAST_OUT=""
LAST_RC=0

new_repo() {
  SEQ=$((SEQ + 1))
  REPO="$WORK/repo-$SEQ"
  mkdir -p "$REPO/.github/workflows" "$REPO/scripts"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email fixture@example.invalid
  git -C "$REPO" config user.name fixture
}

# Writes a file from stdin and stages it, so `git ls-files` discovers it.
put() {
  local path="$1"
  mkdir -p "$REPO/$(dirname "$path")"
  cat >"$REPO/$path"
  git -C "$REPO" add -f -- "$path"
}

run_check() {
  local dir="${RUN_IN:-$REPO}"
  LAST_OUT="$(cd "$dir" && node "$CHECK" "$@" 2>&1)"
  LAST_RC=$?
}

expect_rc() {
  local want="$1" label="$2"
  if [ "$LAST_RC" -eq "$want" ]; then
    pass "$label"
  else
    fail "$label (expected exit $want, got $LAST_RC)"
    printf '%s\n' "$LAST_OUT" | sed 's/^/    /'
  fi
}

expect_mentions() {
  local needle="$1" label="$2"
  if printf '%s\n' "$LAST_OUT" | grep -qF -- "$needle"; then
    pass "$label"
  else
    fail "$label (output does not mention '$needle')"
    printf '%s\n' "$LAST_OUT" | sed 's/^/    /'
  fi
}

expect_silent_about() {
  local needle="$1" label="$2"
  if printf '%s\n' "$LAST_OUT" | grep -qF -- "$needle"; then
    fail "$label (output mentions '$needle')"
    printf '%s\n' "$LAST_OUT" | sed 's/^/    /'
  else
    pass "$label"
  fi
}

# A workflow with one job, one checkout, and whatever the caller wants the job
# to do afterwards. $1 is the `with:` body of the checkout (possibly empty),
# the rest is the body of the following `run:` step.
workflow() { # workflow <path> <job> <persist-line> <run-line>...
  local path="$1" job="$2" persist="$3"
  shift 3
  {
    echo 'name: Fixture'
    echo 'on: [push]'
    echo 'jobs:'
    echo "  $job:"
    echo '    runs-on: ubuntu-24.04'
    echo '    steps:'
    echo '      - uses: actions/checkout@v6'
    if [ -n "$persist" ]; then
      echo '        with:'
      echo "          persist-credentials: $persist"
    fi
    echo '      - name: Do the work'
    echo '        run: |'
    local line
    for line in "$@"; do
      echo "          $line"
    done
  } | put "$path"
}

echo "== Part 1: the setting has to be there at all =="
echo

new_repo
workflow .github/workflows/read.yml build false 'make test'
run_check
expect_rc 0 "a non-pushing job that drops the credential passes"
expect_mentions '1 checkout step(s)' "and says how many checkouts it looked at"

new_repo
workflow .github/workflows/read.yml build '' 'make test'
run_check
expect_rc 1 "a checkout that says nothing fails"
expect_mentions '::error file=.github/workflows/read.yml,line=7,' "annotated at the checkout's own line"
expect_mentions 'title=check-checkout-credentials' "with a title, so the annotation says which gate"
expect_mentions 'set `persist-credentials: false`' "and says which setting this job wants"
expect_mentions 'read.yml:build' "naming the job, since the credential is a job-scoped thing"

echo
echo "== Part 2: the setting has to match what the job does =="
echo

new_repo
workflow .github/workflows/write.yml release true 'git push origin main'
run_check
expect_rc 0 "a pushing job that keeps the credential passes"

new_repo
workflow .github/workflows/write.yml release false 'git push origin main'
run_check
expect_rc 1 "a pushing job that drops it fails"
expect_mentions 'that push has no credential' "explaining that the push would have nothing to authenticate with"

new_repo
workflow .github/workflows/read.yml build true 'make test'
run_check
expect_rc 1 "a non-pushing job that keeps it fails too"
expect_mentions 'nothing in .github/workflows/read.yml:build writes to the remote' \
  "saying why keeping it buys nothing"

new_repo
workflow .github/workflows/write.yml release '' 'git push origin main'
run_check
expect_rc 1 "a silent checkout in a pushing job still fails"
expect_mentions 'say so with `persist-credentials: true`' \
  "but is told to keep the credential, not to drop it"

echo
echo "== Part 3: what counts as writing to the remote =="
echo

# The push this repository actually makes is never spelled `git push`: it goes
# through a retry wrapper, three levels down from the workflow.
new_repo
printf '#!/usr/bin/env bash\ngit push "$@"\n' | put scripts/git-push-with-retry.sh
workflow .github/workflows/write.yml release true 'bash scripts/git-push-with-retry.sh origin main'
run_check
expect_rc 0 "a push through git-push-with-retry.sh counts as a push"

new_repo
printf '#!/usr/bin/env bash\ngit push origin main\n' | put scripts/release/publish.sh
workflow .github/workflows/write.yml release true 'bash scripts/release/publish.sh'
run_check
expect_rc 0 "a push inside a script the job calls counts as a push"

new_repo
printf '#!/usr/bin/env bash\nbash scripts/inner.sh\n' | put scripts/outer.sh
printf '#!/usr/bin/env bash\ngit push origin main\n' | put scripts/inner.sh
workflow .github/workflows/write.yml release true 'bash scripts/outer.sh'
run_check
expect_rc 0 "and so does one two scripts deep, because the search is transitive"

# measure-disk-space.yml explains its push in prose two hundred lines above
# making it, and release.yml says "Not a bare `git push`" immediately before
# calling the wrapper. Read either as code and the classification is right by
# accident, which is not the same as being right.
new_repo
workflow .github/workflows/read.yml build false '# a comment about git push, which is not a git push' 'make test'
run_check
expect_rc 0 "a git push named only in a comment is not a push"

new_repo
printf '#!/usr/bin/env bash\n# git push is what this file does not do\ntrue\n' | put scripts/notes.sh
workflow .github/workflows/read.yml build false 'bash scripts/notes.sh'
run_check
expect_rc 0 "nor one named only in a comment inside a called script"

# The checker is itself one of the scripts a workflow runs, so its own prose
# gets read as the job's code. Its doc comment says "a `git push` anywhere in
# that closure", and that one sentence classified every job that runs the gate
# as a job that pushes - the gate failing its own repository, on its own text.
new_repo
printf '%s\n' \
  '/**' \
  ' * A checker whose prose mentions git push without doing one.' \
  ' */' \
  "const PATTERN = /\\bgit\\s+push\\b/;" \
  'console.log(PATTERN.source);' | put scripts/ci/check-thing.mjs
workflow .github/workflows/read.yml build false 'node scripts/ci/check-thing.mjs'
run_check
expect_rc 0 "a git push in a JavaScript doc comment is prose, not a push"

new_repo
printf '%s\n' \
  '#!/usr/bin/env node' \
  '// this file talks about git push in a line comment' \
  'console.log("nothing to see");' | put scripts/ci/check-thing.mjs
workflow .github/workflows/read.yml build false 'node scripts/ci/check-thing.mjs'
run_check
expect_rc 0 "nor is one in a // line comment"

new_repo
printf '%s\n' \
  '#!/usr/bin/env node' \
  'import { execFileSync } from "node:child_process";' \
  'execFileSync("git", ["push"]);' \
  'const literal = `git push origin main`;' | put scripts/ci/publish.mjs
workflow .github/workflows/write.yml release true 'node scripts/ci/publish.mjs' \
  'echo done'
run_check
expect_rc 0 "but a git push in JavaScript code outside a comment still counts"

# A cycle between two scripts must not hang the checker.
new_repo
printf '#!/usr/bin/env bash\nbash scripts/b.sh\n' | put scripts/a.sh
printf '#!/usr/bin/env bash\nbash scripts/a.sh\n' | put scripts/b.sh
workflow .github/workflows/read.yml build false 'bash scripts/a.sh'
run_check
expect_rc 0 "two scripts that call each other terminate instead of recursing forever"

echo
echo "== Part 4: reading the workflow correctly =="
echo

# Jobs are separate units: one job pushing must not excuse the other's checkout.
new_repo
{
  echo 'name: Fixture'
  echo 'on: [push]'
  echo 'jobs:'
  echo '  publish:'
  echo '    runs-on: ubuntu-24.04'
  echo '    steps:'
  echo '      - uses: actions/checkout@v6'
  echo '        with:'
  echo '          persist-credentials: true'
  echo '      - run: git push origin main'
  echo '  build:'
  echo '    runs-on: ubuntu-24.04'
  echo '    steps:'
  echo '      - uses: actions/checkout@v6'
  echo '        with:'
  echo '          persist-credentials: true'
  echo '      - run: make test'
} | put .github/workflows/two.yml
run_check
expect_rc 1 "a pushing job does not excuse the checkout of a job beside it"
expect_mentions 'line=14' "the second job's checkout is the one reported"
expect_silent_about 'line=7' "and the first job's, which is correct, is not"

# The step's `with:` block ends where the next step begins. A checker that
# scanned a fixed number of lines forward would read the next step's settings.
new_repo
{
  echo 'name: Fixture'
  echo 'on: [push]'
  echo 'jobs:'
  echo '  build:'
  echo '    runs-on: ubuntu-24.04'
  echo '    steps:'
  echo '      - uses: actions/checkout@v6'
  echo '      - uses: some/other-action@v1'
  echo '        with:'
  echo '          persist-credentials: false'
  echo '      - run: make test'
} | put .github/workflows/next.yml
run_check
expect_rc 1 "a setting on the next step does not count as this step's"
expect_mentions 'line=7' "the silent checkout is still reported"

# ...and a long `with:` block on the checkout itself is read whole.
new_repo
{
  echo 'name: Fixture'
  echo 'on: [push]'
  echo 'jobs:'
  echo '  build:'
  echo '    runs-on: ubuntu-24.04'
  echo '    steps:'
  echo '      - uses: actions/checkout@v6'
  echo '        with:'
  echo '          fetch-depth: 0'
  echo '          ref: main'
  echo '          submodules: recursive'
  echo '          lfs: true'
  echo '          sparse-checkout: |'
  echo '            scripts'
  echo '            .github'
  echo '          path: checkout'
  echo '          clean: true'
  echo '          filter: tree:0'
  echo '          persist-credentials: false'
  echo '      - run: make test'
} | put .github/workflows/long.yml
run_check
expect_rc 0 "a persist-credentials twelve lines into a with: block is still found"

# A checkout under an `if:`, with the `uses:` not the first line of the step.
new_repo
{
  echo 'name: Fixture'
  echo 'on: [push]'
  echo 'jobs:'
  echo '  build:'
  echo '    runs-on: ubuntu-24.04'
  echo '    steps:'
  echo '      - name: Checkout repository'
  echo "        if: steps.check.outputs.should_build == 'true'"
  echo '        uses: actions/checkout@v6'
  echo '        with:'
  echo '          persist-credentials: false'
  echo '      - run: make test'
} | put .github/workflows/conditional.yml
run_check
expect_rc 0 "a checkout behind a name and an if: is read as one step"

# A composite action has no `jobs:` and runs inside the caller's job, with the
# caller's credentials; the same question applies to it.
new_repo
{
  echo 'name: Fixture action'
  echo 'runs:'
  echo '  using: composite'
  echo '  steps:'
  echo '    - uses: actions/checkout@v6'
  echo '      shell: bash'
} | put .github/actions/thing/action.yml
run_check
expect_rc 1 "a composite action's checkout is checked too"
expect_mentions '.github/actions/thing/action.yml' "and named by its own path"

new_repo
{
  echo 'name: Fixture action'
  echo 'runs:'
  echo '  using: composite'
  echo '  steps:'
  echo '    - uses: actions/checkout@v6'
  echo '      with:'
  echo '        persist-credentials: false'
} | put .github/actions/thing/action.yml
run_check
expect_rc 0 "and passes once it says so"

# A job key with a trailing comment is still a job key. When the reader did not
# recognise one, the job's steps went into the job above it - or, for the first
# job, into nothing at all, and its checkout was never examined.
new_repo
{
  echo 'name: Fixture'
  echo 'on: [push]'
  echo 'jobs:'
  echo '  build:  # the first job, annotated'
  echo '    runs-on: ubuntu-24.04'
  echo '    steps:'
  echo '      - uses: actions/checkout@v6'
  echo '      - run: make test'
} | put .github/workflows/commented.yml
run_check
expect_rc 1 "a checkout under a job key with a trailing comment is still examined"
expect_mentions 'commented.yml:build' "and attributed to that job by name"

# ...and when a job key is unrecognisable for some other reason, the checker
# says it could not read the file rather than reporting the checkouts it did
# manage to find. A clean result off a partial read is the false negative this
# whole pull request is about, and this checker is not exempt from it.
new_repo
{
  echo 'name: Fixture'
  echo 'on: [push]'
  echo 'jobs:'
  echo '  "quoted-job":'
  echo '    runs-on: ubuntu-24.04'
  echo '    steps:'
  echo '      - uses: actions/checkout@v6'
  echo '        with:'
  echo '          persist-credentials: false'
  echo '      - run: make test'
} | put .github/workflows/unreadable.yml
run_check
expect_rc 2 "a checkout that lands in no job makes the check exit 2, not pass"
expect_mentions 'declares 1 checkout step(s) but only 0' "counting both sides so the gap is visible"
expect_mentions 'reporting instead' "and saying it chose to report rather than pass over it"

# A workflow with no checkout at all is not an offender.
new_repo
{
  echo 'name: Fixture'
  echo 'on: [push]'
  echo 'jobs:'
  echo '  build:'
  echo '    runs-on: ubuntu-24.04'
  echo '    steps:'
  echo '      - run: echo no checkout here'
} | put .github/workflows/none.yml
run_check
expect_rc 0 "a workflow that never checks out is fine"
expect_mentions '0 checkout step(s)' "and is counted as zero, not skipped silently"

echo
echo "== Part 5: the box gate contract =="
echo

new_repo
workflow .github/workflows/a.yml build false 'make test'
workflow .github/workflows/b.yml build false 'make test'
{
  echo 'name: Fixture action'
  echo 'runs:'
  echo '  using: composite'
  echo '  steps:'
  echo '    - run: true'
  echo '      shell: bash'
} | put .github/actions/thing/action.yml
run_check --list-inputs
expect_rc 0 "--list-inputs exits 0"
if [ "$(printf '%s\n' "$LAST_OUT" | sort)" = "$(printf '%s\n' \
  .github/actions/thing/action.yml .github/workflows/a.yml .github/workflows/b.yml)" ]; then
  pass "--list-inputs prints the discovered set and nothing else, one path per line"
else
  fail "--list-inputs printed something other than the discovered set"
  printf '%s\n' "$LAST_OUT" | sed 's/^/    /'
fi

run_check
expect_silent_about '[checkout]' "the per-checkout trace is off by default"
run_check --verbose
expect_mentions '[checkout]' "and on with --verbose"
expect_mentions 'does not push' "saying, per checkout, what it concluded about the job"

run_check .github/workflows/a.yml
expect_rc 0 "an explicit file argument is accepted"
expect_mentions '1 file(s)' "and narrows the check to it"

run_check --nonsense
expect_rc 2 "an unknown option exits 2 - misuse, not a finding"
expect_mentions "unknown option '--nonsense'" "and says which option"

RUN_IN="$WORK" run_check
expect_rc 2 "outside a git repository it exits 2 rather than reporting nothing"
expect_mentions 'not inside a git repository' "and says why it could not run"

# `git ls-files` answers about the current directory, so a gate that does not
# anchor at the root reports "nothing found" from a subdirectory - the exact
# false negative class this pull request is about.
new_repo
workflow .github/workflows/read.yml build '' 'make test'
mkdir -p "$REPO/scripts/ci"
RUN_IN="$REPO/scripts/ci" run_check
expect_rc 1 "run from a subdirectory it still finds the workflow"
expect_mentions 'file=.github/workflows/read.yml' "and annotates a path relative to the repository root"

# An empty repository means the check verified nothing; that is a 2, not a 0.
new_repo
run_check
expect_rc 2 "a repository with no workflows exits 2, not a silent success"
expect_mentions 'this check verified nothing' "and says so"

echo
echo "== Part 6: this repository, and the mutations that must break it =="
echo

RUN_IN="$ROOT" run_check
expect_rc 0 "the gate passes on this repository"

MIRROR="$WORK/mirror"
git -C "$ROOT" ls-files -z -- .github scripts | tar -C "$ROOT" --null -T - -cf - | (mkdir -p "$MIRROR" && tar -C "$MIRROR" -xf -)
git -C "$MIRROR" init -q
git -C "$MIRROR" config user.email fixture@example.invalid
git -C "$MIRROR" config user.name fixture
git -C "$MIRROR" add -A

# Dropping one `persist-credentials: false` from a real workflow has to be
# caught: a gate that passes on the tree it was written against and would pass
# on the regression too is the thing this issue is about.
TARGET="$MIRROR/.github/workflows/pr-tests.yml"
MUT_LINE="$(grep -n 'persist-credentials: false' "$TARGET" | head -1 | cut -d: -f1)"
sed -i "${MUT_LINE}d" "$TARGET"
RUN_IN="$MIRROR" run_check
expect_rc 1 "removing one persist-credentials line from pr-tests.yml is caught"
expect_mentions 'file=.github/workflows/pr-tests.yml' "and the mutated file is the one named"

git -C "$MIRROR" checkout -q -- .github/workflows/pr-tests.yml
sed -i 's/persist-credentials: true/persist-credentials: false/' "$MIRROR/.github/workflows/release.yml"
RUN_IN="$MIRROR" run_check
expect_rc 1 "dropping the credential in the two release jobs that push is caught"
expect_mentions 'writes to the remote, but this checkout drops the job token' \
  "and reported as a broken push, not as missing hardening"

git -C "$MIRROR" checkout -q -- .github/workflows/release.yml
sed -i 's/persist-credentials: false/persist-credentials: true/' "$MIRROR/.github/workflows/scripts.yml"
RUN_IN="$MIRROR" run_check
expect_rc 1 "keeping the credential in a job that does not push is caught"

echo
echo "== Part 7: the fix stays wired in =="
echo

REPRO="$ROOT/experiments/reproduce-issue121-checkout-credentials.sh"
if [ -x "$REPRO" ]; then
  pass "the reproduction exists and is executable"
  if bash "$REPRO" >"$WORK/repro.log" 2>&1; then
    if grep -q '^Closed:' "$WORK/repro.log"; then
      pass "and reports the class closed against the current tree"
    else
      fail "the reproduction no longer reports the class closed"
      sed 's/^/    /' "$WORK/repro.log"
    fi
  else
    fail "the reproduction exited non-zero"
    sed 's/^/    /' "$WORK/repro.log"
  fi
else
  fail "experiments/reproduce-issue121-checkout-credentials.sh is missing"
fi

if grep -rqF 'check-checkout-credentials.mjs' "$ROOT/.github/workflows"; then
  pass "check-checkout-credentials.mjs is called by a workflow"
else
  fail "the gate is not called by any workflow, so it checks nothing"
fi

if grep -rqF 'test-issue121-checkout-credentials.sh' "$ROOT/.github/workflows"; then
  pass "these fixtures run in CI too"
else
  fail "these fixtures are not called by any workflow"
fi

if grep -qF 'check-checkout-credentials.mjs' "$ROOT/scripts/ci/run-precommit-checks.sh"; then
  pass "and the pre-commit hook runs the gate before the commit exists"
else
  fail "the pre-commit hook does not run it"
fi

# The comment that started this: it claimed every checkout dropped the
# credential while thirty did not, and nothing could contradict it.
if grep -qF 'Every checkout in this repository sets' "$ROOT/scripts/ci/simulate-fresh-merge.sh"; then
  fail "simulate-fresh-merge.sh still carries the claim that was false for thirty checkouts"
else
  pass "simulate-fresh-merge.sh no longer claims something no check could contradict"
fi

echo ""
echo "Passed: $PASS, Failed: $FAIL"
[ "$FAIL" -eq 0 ]
