#!/usr/bin/env bash
# test-issue121-git-hooks.sh
#
# Issue #121, hive-mind best practice #8 ("local quality gates prevent broken
# commits from reaching CI"). Fixtures for the three files that adopt it:
#
#   scripts/install-git-hooks.sh      points core.hooksPath at .githooks/
#   .githooks/pre-commit              delegates, and nothing else
#   scripts/ci/run-precommit-checks.sh runs the gates over the staged content
#
# The reference template installs hooks with husky and opens its installer with
# the finding this suite is mostly about: "husky exits 0 for every failure it
# has, including '.git can't be found', so the exit code proves nothing."
# Part 1 reproduces exactly that shape against our installer - a git that
# accepts the write and does not record it - and asserts the installer notices.
#
# Every gate is stubbed. The point of these fixtures is the wiring - which gate
# runs for which staged file, and which tree it reads - and stubs make that
# observable and fast; each gate's own behaviour has its own suite already, and
# driving docker and npx from here would make this suite untestable offline.
#
# What it asserts:
#   Part 1  the installer verifies the outcome, not its own exit code
#   Part 2  --check, --uninstall, and misuse
#   Part 3  git really runs the hook, and both bypasses work
#   Part 4  the gates read the INDEX, not the working tree
#   Part 5  scoping: which staged files summon which gate
#   Part 6  a gate that fails blocks; a gate that cannot run does not
#   Part 7  the wiring: every gate the hook runs is also run by a workflow,
#           and the hook file itself is linted by something
#
# Usage: bash experiments/test-issue121-git-hooks.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
REPO_ROOT="$PWD"
INSTALLER="$REPO_ROOT/scripts/install-git-hooks.sh"
HOOK="$REPO_ROOT/.githooks/pre-commit"
CHECKS="$REPO_ROOT/scripts/ci/run-precommit-checks.sh"

PASS=0
FAIL=0

pass() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
  [ $# -gt 1 ] && printf '      %s\n' "${@:2}" >&2
  return 0
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for f in "$INSTALLER" "$HOOK" "$CHECKS"; do
  if [ ! -x "$f" ]; then
    fail "${f#"$REPO_ROOT"/} is missing or not executable"
    echo "passed: $PASS"
    echo "failed: $FAIL"
    exit 1
  fi
done
pass "the installer, the hook and the checks runner all exist and are executable"

# new_repo <name> — a git repository carrying the three real files.
new_repo() {
  local dir="$WORK/$1"
  mkdir -p "$dir/scripts/ci" "$dir/.githooks"
  cp "$INSTALLER" "$dir/scripts/install-git-hooks.sh"
  cp "$HOOK" "$dir/.githooks/pre-commit"
  cp "$CHECKS" "$dir/scripts/ci/run-precommit-checks.sh"
  chmod +x "$dir/scripts/install-git-hooks.sh" "$dir/.githooks/pre-commit" \
    "$dir/scripts/ci/run-precommit-checks.sh"
  (
    cd "$dir" || exit 1
    git init -q .
    git config user.email fixture@example.invalid
    git config user.name fixture
    git config commit.gpgsign false
  ) || return 1
  printf '%s' "$dir"
}

# ---------------------------------------------------------------------------
echo
echo "== Part 1: the installer verifies the outcome, not its own exit code =="

REPO="$(new_repo install-basic)"
OUT="$( (cd "$REPO" && bash scripts/install-git-hooks.sh) 2>&1)"
STATUS=$?
[ "$STATUS" -eq 0 ] \
  && pass "a fresh repository installs cleanly (exit 0)" \
  || fail "install exited $STATUS" "$OUT"

CONFIGURED="$(cd "$REPO" && git config --get core.hooksPath)"
[ "$CONFIGURED" = ".githooks" ] \
  && pass "core.hooksPath now names .githooks" \
  || fail "core.hooksPath is '$CONFIGURED'"

grep -q "core.hooksPath = .githooks" <<<"$OUT" \
  && pass "and the installer prints the value it read back" \
  || fail "the installer did not report the configured value" "$OUT"

# The template's finding, reproduced: a config write that exits 0 and records
# nothing. This is what husky does when it cannot find .git, and what git
# itself does when the value lands in a config file this clone does not read.
STUB="$WORK/stub-bin"
mkdir -p "$STUB"
cat >"$STUB/git" <<'STUB_EOF'
#!/usr/bin/env bash
# Real git for everything except the one write under test, which is accepted
# and dropped - the "exit 0, did nothing" failure the verification exists for.
if [ "${1:-}" = "config" ] && [ "${2:-}" = "--local" ] && [ "${3:-}" = "core.hooksPath" ]; then
  exit 0
fi
exec /usr/bin/env -u PATH_STUBBED "$REAL_GIT" "$@"
STUB_EOF
chmod +x "$STUB/git"
REAL_GIT="$(command -v git)"
export REAL_GIT

REPO="$(new_repo install-silent-noop)"
OUT="$( (cd "$REPO" && PATH="$STUB:$PATH" bash scripts/install-git-hooks.sh) 2>&1)"
STATUS=$?
[ "$STATUS" -eq 1 ] \
  && pass "a config write that exits 0 and records nothing fails the install" \
  || fail "expected exit 1 from the unverified install, got $STATUS" "$OUT"

grep -q "git hooks were not installed" <<<"$OUT" \
  && pass "and says the hooks were not installed, naming what it read instead" \
  || fail "the failure did not name the outcome" "$OUT"

# The other half of "installed" that git checks silently: an executable bit.
REPO="$(new_repo install-not-executable)"
chmod -x "$REPO/.githooks/pre-commit"
OUT="$( (cd "$REPO" && bash scripts/install-git-hooks.sh) 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 0 ] && [ -x "$REPO/.githooks/pre-commit" ]; then
  pass "a non-executable hook is made executable rather than left inert"
else
  fail "expected the installer to fix the mode; exit $STATUS" "$OUT"
fi

REPO="$(new_repo install-no-hook)"
rm "$REPO/.githooks/pre-commit"
OUT="$( (cd "$REPO" && bash scripts/install-git-hooks.sh) 2>&1)"
STATUS=$?
[ "$STATUS" -eq 2 ] \
  && pass "a missing hook file is 'could not run' (exit 2), not a silent success" \
  || fail "expected exit 2 with no hook to install, got $STATUS" "$OUT"

REPO="$(new_repo install-existing-hooks)"
mkdir -p "$REPO/.git/hooks"
printf '#!/bin/sh\nexit 0\n' >"$REPO/.git/hooks/pre-push"
OUT="$( (cd "$REPO" && bash scripts/install-git-hooks.sh) 2>&1)"
grep -q "pre-push" <<<"$OUT" \
  && pass "a hand-written .git/hooks/ hook is named before core.hooksPath hides it" \
  || fail "installing over an existing .git/hooks did not warn" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "== Part 2: --check, --uninstall, and misuse =="

REPO="$(new_repo modes)"
OUT="$( (cd "$REPO" && bash scripts/install-git-hooks.sh --check) 2>&1)"
STATUS=$?
[ "$STATUS" -eq 1 ] \
  && pass "--check reports 'not installed' before installing (exit 1)" \
  || fail "--check exited $STATUS on a fresh repository" "$OUT"

(cd "$REPO" && bash scripts/install-git-hooks.sh) >/dev/null 2>&1
OUT="$( (cd "$REPO" && bash scripts/install-git-hooks.sh --check) 2>&1)"
STATUS=$?
[ "$STATUS" -eq 0 ] \
  && pass "--check reports 'installed' afterwards (exit 0)" \
  || fail "--check exited $STATUS after installing" "$OUT"

chmod -x "$REPO/.githooks/pre-commit"
OUT="$( (cd "$REPO" && bash scripts/install-git-hooks.sh --check) 2>&1)"
STATUS=$?
[ "$STATUS" -eq 1 ] \
  && pass "--check fails when the hook exists but git could not execute it" \
  || fail "--check passed over a non-executable hook (exit $STATUS)" "$OUT"
chmod +x "$REPO/.githooks/pre-commit"

OUT="$( (cd "$REPO" && bash scripts/install-git-hooks.sh --uninstall) 2>&1)"
STATUS=$?
LEFT="$(cd "$REPO" && git config --get core.hooksPath 2>/dev/null || true)"
if [ "$STATUS" -eq 0 ] && [ -z "$LEFT" ]; then
  pass "--uninstall unsets core.hooksPath and confirms it is gone"
else
  fail "--uninstall exited $STATUS leaving core.hooksPath='$LEFT'" "$OUT"
fi

OUT="$( (cd "$REPO" && bash scripts/install-git-hooks.sh --uninstall) 2>&1)"
[ $? -eq 0 ] \
  && pass "--uninstall twice is not an error" \
  || fail "a second --uninstall failed" "$OUT"

OUT="$( (cd "$REPO" && bash scripts/install-git-hooks.sh --nonsense) 2>&1)"
STATUS=$?
[ "$STATUS" -eq 2 ] \
  && pass "an unknown option exits 2" \
  || fail "unknown option exited $STATUS" "$OUT"

OUTSIDE="$WORK/not-a-repo"
mkdir -p "$OUTSIDE"
OUT="$( (cd "$OUTSIDE" && bash "$INSTALLER") 2>&1)"
STATUS=$?
[ "$STATUS" -eq 2 ] \
  && pass "outside a git repository the installer exits 2" \
  || fail "outside a repository the installer exited $STATUS" "$OUT"

OUT="$( (cd "$OUTSIDE" && bash "$CHECKS") 2>&1)"
STATUS=$?
[ "$STATUS" -eq 2 ] \
  && pass "and so does the checks runner" \
  || fail "the checks runner exited $STATUS outside a repository" "$OUT"

OUT="$( (cd "$OUTSIDE" && bash "$CHECKS" --nonsense) 2>&1)"
STATUS=$?
[ "$STATUS" -eq 2 ] \
  && pass "an unknown option to the checks runner exits 2" \
  || fail "unknown option to the checks runner exited $STATUS" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "== Part 3: git really runs the hook, and both bypasses work =="

# The hook's own contract, with the checks runner replaced by a recorder: git
# invokes it at all, its exit status decides the commit, and the two documented
# bypasses skip it.
hook_repo() { # hook_repo <name> <exit-code>
  local dir
  dir="$(new_repo "$1")"
  cat >"$dir/scripts/ci/run-precommit-checks.sh" <<STUB
#!/usr/bin/env bash
echo ran >>"$dir/hook-ran"
exit $2
STUB
  chmod +x "$dir/scripts/ci/run-precommit-checks.sh"
  (cd "$dir" && bash scripts/install-git-hooks.sh) >/dev/null 2>&1
  printf '%s' "$dir"
}

REPO="$(hook_repo hook-blocks 1)"
(cd "$REPO" && git add -A && git commit -qm "should be blocked") >/dev/null 2>&1
STATUS=$?
if [ "$STATUS" -ne 0 ] && [ -f "$REPO/hook-ran" ]; then
  pass "git runs the installed hook, and a non-zero hook blocks the commit"
else
  fail "commit exited $STATUS; hook-ran present: $([ -f "$REPO/hook-ran" ] && echo yes || echo no)"
fi
(cd "$REPO" && git rev-parse --verify --quiet HEAD >/dev/null) \
  && fail "the blocked commit was recorded anyway" \
  || pass "and no commit was recorded"

rm -f "$REPO/hook-ran"
(cd "$REPO" && git commit -qm "bypassed" --no-verify) >/dev/null 2>&1
STATUS=$?
if [ "$STATUS" -eq 0 ] && [ ! -f "$REPO/hook-ran" ]; then
  pass "git commit --no-verify skips the hook and commits"
else
  fail "--no-verify exited $STATUS; hook-ran present: $([ -f "$REPO/hook-ran" ] && echo yes || echo no)"
fi

REPO="$(hook_repo hook-env-bypass 1)"
OUT="$( (cd "$REPO" && git add -A && BOX_SKIP_HOOKS=1 git commit -qm skipped) 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 0 ] && [ ! -f "$REPO/hook-ran" ]; then
  pass "BOX_SKIP_HOOKS=1 skips the checks and commits"
else
  fail "BOX_SKIP_HOOKS=1 exited $STATUS" "$OUT"
fi

REPO="$(hook_repo hook-passes 0)"
(cd "$REPO" && git add -A && git commit -qm "allowed") >/dev/null 2>&1
[ $? -eq 0 ] \
  && pass "a passing hook lets the commit through" \
  || fail "a passing hook blocked the commit"

# An old checkout - git bisect, a branch from before the script existed - has
# the hooksPath but not the script. That must not make the tree uncommittable.
REPO="$(hook_repo hook-missing-script 1)"
rm "$REPO/scripts/ci/run-precommit-checks.sh"
(cd "$REPO" && git add -A && git commit -qm "no checks script") >/dev/null 2>&1
[ $? -eq 0 ] \
  && pass "a checkout without the checks script still commits" \
  || fail "a missing checks script made the repository uncommittable"

# ---------------------------------------------------------------------------
echo
echo "== Part 4: the gates read the INDEX, not the working tree =="

# From here on the gates are recorders: each writes its name, its arguments and
# the content it was given into $RECORD.
stubbed_repo() { # stubbed_repo <name>
  local dir
  dir="$(new_repo "$1")"
  mkdir -p "$dir/scripts/ci" "$dir/exits"
  local gate
  for gate in run-shfmt run-shellcheck check-heredoc-vars check-awk-portability \
    check-mjs-syntax check-py-syntax check-required-docs check-file-line-limits \
    run-secretlint; do
    cat >"$dir/scripts/ci/$gate.sh" <<'STUB_EOF'
#!/usr/bin/env bash
name="$(basename "$0" .sh)"
{
  printf 'GATE %s\n' "$name"
  printf 'ARGS %s\n' "$*"
  for f in "$@"; do
    case "$f" in -*) continue ;; esac
    [ -f "$f" ] && printf 'SAW %s=%s\n' "$f" "$(tr -d "\n" <"$f")"
  done
} >>"$RECORD"
if [ -f "$EXITS/$name" ]; then exit "$(cat "$EXITS/$name")"; fi
exit 0
STUB_EOF
    chmod +x "$dir/scripts/ci/$gate.sh"
  done
  for gate in check-status-gate-covers-all-jobs check-timeout-budgets \
    check-workflow-path-coverage; do
    cat >"$dir/scripts/ci/$gate.mjs" <<'STUB_EOF'
import { appendFileSync, readFileSync, existsSync } from 'node:fs';
import { basename } from 'node:path';
const name = basename(process.argv[1], '.mjs');
appendFileSync(
  process.env.RECORD,
  `GATE ${name}\nARGS ${process.argv.slice(2).join(' ')}\n`
);
const override = `${process.env.EXITS}/${name}`;
if (existsSync(override)) {
  process.exit(Number(readFileSync(override, 'utf8').trim()));
}
STUB_EOF
  done
  # Commit the scaffolding, so what a test stages afterwards is exactly the
  # file it is about. Staging the stubs themselves would make every scope test
  # look like a commit touching every file type at once.
  (cd "$dir" && git add -A -f && git commit -qm scaffold) >/dev/null 2>&1
  printf '%s' "$dir"
}

record_of() { cat "$1/record" 2>/dev/null || true; }
ran() { grep -q "^GATE $2$" "$1/record" 2>/dev/null; }

REPO="$(stubbed_repo staged-vs-worktree)"
export RECORD="$REPO/record" EXITS="$REPO/exits"
printf 'staged\n' >"$REPO/subject.sh"
(cd "$REPO" && git add subject.sh) >/dev/null
printf 'worktree\n' >"$REPO/subject.sh" # staged and working tree now disagree

(cd "$REPO" && bash scripts/ci/run-precommit-checks.sh) >"$REPO/out" 2>&1
STATUS=$?
[ "$STATUS" -eq 0 ] \
  && pass "a clean staged tree passes even while the working tree differs" \
  || fail "exit $STATUS" "$(cat "$REPO/out")"

if grep -q '^SAW subject.sh=staged$' "$REPO/record"; then
  pass "the gates were handed the STAGED content, not the working tree's"
else
  fail "the gates read the wrong tree" "$(record_of "$REPO")"
fi

: >"$REPO/record"
(cd "$REPO" && bash scripts/ci/run-precommit-checks.sh --worktree) >/dev/null 2>&1
grep -q '^SAW subject.sh=worktree$' "$REPO/record" \
  && pass "--worktree reads the working tree instead, on purpose" \
  || fail "--worktree did not read the working tree" "$(record_of "$REPO")"

# The mirror is built with `git add -A -f`: .gitignore excludes *.log here and
# in the real repository, which also tracks *.log files under docs/case-studies.
# Without the force those files are absent from the mirror's file list and are
# checked by nothing - a hole that would be invisible from the outside.
REPO="$(stubbed_repo ignored-but-tracked)"
export RECORD="$REPO/record" EXITS="$REPO/exits"
cat >"$REPO/scripts/ci/check-file-line-limits.sh" <<'STUB_EOF'
#!/usr/bin/env bash
printf 'LSFILES %s\n' "$(git ls-files | tr '\n' ' ')" >>"$RECORD"
STUB_EOF
chmod +x "$REPO/scripts/ci/check-file-line-limits.sh"
printf '*.log\n' >"$REPO/.gitignore"
printf 'evidence\n' >"$REPO/run.log"
printf 'x\n' >"$REPO/a.sh"
(cd "$REPO" && git add -A -f && bash scripts/ci/run-precommit-checks.sh) >/dev/null 2>&1
grep -q 'LSFILES.*run\.log' "$REPO/record" \
  && pass "a tracked file that .gitignore would exclude is still in the mirror" \
  || fail "the mirror dropped a tracked but ignored file" "$(record_of "$REPO")"

# The very first commit of a repository has no HEAD to diff the index against.
# `git diff --cached HEAD` is a fatal error there, so the staged list would come
# back empty and every gate would be skipped - a hook that passes a commit it
# never looked at.
REPO="$(new_repo initial-commit)"
export RECORD="$REPO/record" EXITS="$REPO/exits"
mkdir -p "$REPO/exits"
cat >"$REPO/scripts/ci/run-secretlint.sh" <<'STUB_EOF'
#!/usr/bin/env bash
printf 'GATE run-secretlint\nARGS %s\n' "$*" >>"$RECORD"
STUB_EOF
chmod +x "$REPO/scripts/ci/run-secretlint.sh"
printf 'first\n' >"$REPO/a.md"
(cd "$REPO" && git add a.md scripts/ci/run-secretlint.sh \
  && bash scripts/ci/run-precommit-checks.sh) >/dev/null 2>&1
grep -q '^GATE run-secretlint$' "$REPO/record" \
  && pass "a repository with no HEAD yet still has its first commit checked" \
  || fail "the initial commit ran no gates" "$(record_of "$REPO")"

REPO="$(stubbed_repo nothing-staged)"
export RECORD="$REPO/record" EXITS="$REPO/exits"
OUT="$( (cd "$REPO" && bash scripts/ci/run-precommit-checks.sh) 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 0 ] && [ ! -s "$REPO/record" ]; then
  pass "an empty index runs no gates and exits 0"
else
  fail "empty index exited $STATUS having run $(record_of "$REPO")" "$OUT"
fi

# ---------------------------------------------------------------------------
echo
echo "== Part 5: scoping - which staged files summon which gate =="

scoped_run() { # scoped_run <name> <path> [content]
  local dir
  dir="$(stubbed_repo "$1")"
  export RECORD="$dir/record" EXITS="$dir/exits"
  mkdir -p "$dir/$(dirname "$2")"
  printf '%s\n' "${3:-x}" >"$dir/$2"
  (cd "$dir" && git add -f "$2" && bash scripts/ci/run-precommit-checks.sh) >"$dir/out" 2>&1
  printf '%s' "$dir"
}

REPO="$(scoped_run scope-shell tool.sh)"
for gate in run-shfmt run-shellcheck check-heredoc-vars check-awk-portability; do
  ran "$REPO" "$gate" \
    && pass "a staged shell script runs $gate" \
    || fail "$gate did not run for a shell script" "$(record_of "$REPO")"
done
ran "$REPO" check-mjs-syntax \
  && fail "check-mjs-syntax ran for a shell-only commit" \
  || pass "and does not run check-mjs-syntax"

REPO="$(scoped_run scope-markdown notes.md)"
ran "$REPO" run-shellcheck \
  && fail "shellcheck ran for a markdown-only commit" \
  || pass "a markdown-only commit does not pay for shellcheck"
ran "$REPO" check-required-docs \
  && pass "but it does run check-required-docs" \
  || fail "check-required-docs did not run for a markdown commit" "$(record_of "$REPO")"
ran "$REPO" check-workflow-path-coverage \
  && fail "path coverage ran for a commit touching neither workflows nor checkers" \
  || pass "and not path coverage, which reads neither side of a markdown change"

REPO="$(scoped_run scope-mjs tool.mjs)"
ran "$REPO" check-mjs-syntax \
  && pass "a staged .mjs runs check-mjs-syntax" \
  || fail "check-mjs-syntax did not run" "$(record_of "$REPO")"

REPO="$(scoped_run scope-py tool.py)"
ran "$REPO" check-py-syntax \
  && pass "a staged .py runs check-py-syntax" \
  || fail "check-py-syntax did not run" "$(record_of "$REPO")"
ran "$REPO" check-mjs-syntax \
  && fail "check-mjs-syntax ran for a Python-only commit" \
  || pass "and not the JavaScript parser, which would have nothing to say"

REPO="$(scoped_run scope-workflow .github/workflows/ci.yml)"
for gate in check-status-gate-covers-all-jobs check-timeout-budgets; do
  ran "$REPO" "$gate" \
    && pass "a staged workflow runs $gate" \
    || fail "$gate did not run for a workflow" "$(record_of "$REPO")"
done
grep -q '^ARGS .*\.github/workflows/ci\.yml' "$REPO/record" \
  && pass "and both are handed the workflow files themselves" \
  || fail "the workflow checkers got no workflow list" "$(record_of "$REPO")"
ran "$REPO" check-workflow-path-coverage \
  && pass "and a staged workflow runs check-workflow-path-coverage" \
  || fail "path coverage did not run for a workflow" "$(record_of "$REPO")"

# The other half of that gate: it compares what a workflow's filter matches
# against what the checkers it runs read, so editing either side can open the
# gap. A commit touching only scripts/ci has to run it too.
REPO="$(scoped_run scope-ci-script scripts/ci/some-new-gate.sh)"
ran "$REPO" check-workflow-path-coverage \
  && pass "and so does a staged scripts/ci checker, the filter's other half" \
  || fail "path coverage did not run for a staged checker" "$(record_of "$REPO")"

REPO="$(scoped_run scope-secrets anything.txt)"
ran "$REPO" run-secretlint \
  && pass "secretlint runs whatever the staged file is" \
  || fail "secretlint did not run" "$(record_of "$REPO")"
grep -q '^ARGS anything.txt$' "$REPO/record" \
  && pass "and is given the staged paths rather than the whole tree" \
  || fail "secretlint was not scoped to the staged paths" "$(record_of "$REPO")"
# ...and the file-size limit does not: .txt is not a size-limited extension, so
# running it would re-measure files this commit does not touch.
ran "$REPO" check-file-line-limits \
  && fail "the file-size limit ran for a file whose extension it does not check" \
  || pass "while the file-size limit is scoped to the extensions it measures"

REPO="$(scoped_run scope-sized doc.md)"
ran "$REPO" check-file-line-limits \
  && pass "a staged markdown file does run the file-size limit" \
  || fail "the file-size limit did not run for a markdown file" "$(record_of "$REPO")"

REPO="$(scoped_run scope-dev-log dev/log/issues/1/notes.sh)"
ran "$REPO" run-shellcheck \
  && fail "a shell file under dev/log was linted; CI exempts that tree" \
  || pass "a shell file under dev/log is not linted, matching CI's exemption"
ran "$REPO" run-secretlint \
  && pass "but it IS scanned for secrets - that is where downloaded logs land" \
  || fail "dev/log was excluded from the secret scan" "$(record_of "$REPO")"

# ---------------------------------------------------------------------------
echo
echo "== Part 6: failing blocks; unable-to-run does not =="

REPO="$(stubbed_repo verdicts)"
export RECORD="$REPO/record" EXITS="$REPO/exits"
printf 'x\n' >"$REPO/tool.sh"
(cd "$REPO" && git add tool.sh) >/dev/null

echo 1 >"$REPO/exits/run-shellcheck"
OUT="$( (cd "$REPO" && bash scripts/ci/run-precommit-checks.sh) 2>&1)"
STATUS=$?
[ "$STATUS" -eq 1 ] \
  && pass "a gate that reports a violation blocks the commit" \
  || fail "a failing gate exited $STATUS" "$OUT"
grep -q "failed on the staged content: shellcheck" <<<"$OUT" \
  && pass "and the summary names it" \
  || fail "the failing gate was not named" "$OUT"
grep -q -- "--no-verify" <<<"$OUT" \
  && pass "and the failure says how to commit anyway" \
  || fail "no bypass instruction in the failure" "$OUT"

echo 2 >"$REPO/exits/run-shellcheck"
OUT="$( (cd "$REPO" && bash scripts/ci/run-precommit-checks.sh) 2>&1)"
STATUS=$?
[ "$STATUS" -eq 0 ] \
  && pass "a gate that could not run (exit 2) does not block the commit" \
  || fail "an unavailable gate exited $STATUS - docker being down is not a defect" "$OUT"
grep -q "could not run" <<<"$OUT" \
  && pass "and says so out loud rather than passing silently" \
  || fail "an unavailable gate was silent" "$OUT"
grep -q "CI" <<<"$OUT" \
  && pass "naming CI as the place it will still be checked" \
  || fail "the warning does not say where the check still happens" "$OUT"
rm -f "$REPO/exits/run-shellcheck"

# ---------------------------------------------------------------------------
echo
echo "== Part 7: the wiring =="

# Every gate the hook runs must also be run by a workflow. The hook is an
# accelerator; if a check existed only here it would be one `--no-verify` away
# from never running, which is the shape of defect this issue is about.
GATES="$(grep -oE '^ *gate [a-z-]+ (bash|node) scripts/ci/[A-Za-z0-9._-]+' "$CHECKS" \
  | awk '{print $NF}' | sort -u)"
GATE_COUNT=0
while IFS= read -r script; do
  [ -n "$script" ] || continue
  GATE_COUNT=$((GATE_COUNT + 1))
  [ -f "$REPO_ROOT/$script" ] \
    && pass "$script exists" \
    || fail "the hook calls $script, which is not in the tree"
  if grep -rqF "$script" "$REPO_ROOT/.github/workflows/"; then
    pass "$script is also run by a workflow"
  else
    fail "$script runs in the hook but in no workflow"
  fi
done <<<"$GATES"
[ "$GATE_COUNT" -ge 12 ] \
  && pass "and the hook runs $GATE_COUNT distinct gates" \
  || fail "only found $GATE_COUNT gates in $CHECKS; the grep above has drifted"

# git requires an extensionless hook name, so every `*.sh` glob misses it.
for linter in run-shellcheck run-shfmt; do
  if bash "$REPO_ROOT/scripts/ci/$linter.sh" --list 2>/dev/null | grep -qx '.githooks/pre-commit'; then
    pass "$linter.sh discovers .githooks/pre-commit"
  else
    fail "$linter.sh does not see the hook; nothing lints it"
  fi
done

while IFS= read -r hookfile; do
  [ -n "$hookfile" ] || continue
  head -1 "$REPO_ROOT/$hookfile" | grep -q '^#!.*sh' \
    && pass "$hookfile is a shell script, as the linters' glob assumes" \
    || fail "$hookfile is not a shell script but is linted as one"
done < <(cd "$REPO_ROOT" && git ls-files '.githooks/*')

grep -q 'docs/LOCAL-CHECKS.md' "$REPO_ROOT/README.md" \
  && pass "README.md points at docs/LOCAL-CHECKS.md" \
  || fail "the hook is documented in a file nothing links to"

grep -q 'install-git-hooks.sh' "$REPO_ROOT/docs/LOCAL-CHECKS.md" \
  && pass "and that document tells a developer how to install the hook" \
  || fail "docs/LOCAL-CHECKS.md does not name the installer"

if grep -q "SKIP_SUITES\[$(basename "$0")\]" "$REPO_ROOT/scripts/ci/run-experiments.sh"; then
  fail "this suite is in run-experiments.sh's skip list"
else
  pass "this suite is discovered and run by scripts/ci/run-experiments.sh"
fi

echo
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
