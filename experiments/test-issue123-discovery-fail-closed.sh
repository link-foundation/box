#!/usr/bin/env bash
# test-issue123-discovery-fail-closed.sh
#
# Issue #123, RC-17. A gate that could not enumerate its own inputs reported a
# clean tree.
#
# How it was found. The full experiment run of this branch reported
# test-issue121-git-hooks.sh failing on one assertion:
#
#   FAIL: run-shellcheck.sh does not see the hook; nothing lints it
#   PASS: run-shfmt.sh discovers .githooks/pre-commit
#
# The two lines run the identical discovery two statements apart, and the
# second one passed, so the file set had not changed - the answer had. The
# assertion could not say why, because it called the gate with `2>/dev/null`
# and threw away the only diagnostic there was; that is fixed in that suite.
# What the gate did with a discovery that came back short is what this suite is
# about:
#
#   collect_files() {
#     git ls-files -z --cached --others --exclude-standard --deduplicate ... \
#       | tr '\0' '\n' | grep -v '^dev/log/' | sort -u || true
#   }
#
# The trailing `|| true` turns a git that could not read the index into an
# empty list, and every caller then read that empty list as a fact about the
# repository rather than as a failure to ask it:
#
#   ==> No shell scripts to check
#   $ echo $?
#   0
#
# 201 tracked shell scripts, none of them read, and a green gate. It is the
# same sentence as every other root cause in this issue - a check reporting a
# verdict about data it never obtained - and the repository already knew it:
# check-py-syntax.sh, check-mjs-syntax.sh, check-awk-portability.sh,
# run-hadolint.sh and check-file-line-limits.sh each refuse an empty input set
# in so many words, and run-shfmt.sh even hands shfmt a deliberately
# misformatted canary so its silence cannot pass for a verdict. The guard was
# in five gates and missing from three, which is requirement B10 of this issue:
# a defect that exists in more than one place has to be fixed in all of them.
#
# What is asserted here, offline and without docker:
#
#   Part 1  the sweep - every gate under scripts/ci/ that discovers its own
#           inputs with `git ls-files` is either covered below or exempt in
#           writing, so a gate added later cannot quietly skip this
#   Part 2  a git that cannot enumerate: each gate must exit non-zero and say
#           so, rather than report a clean run over nothing
#   Part 3  a git that enumerates nothing: same requirement, different cause,
#           and the two are told apart in the message
#   Part 4  the mutation control - the pre-fix `|| true` shape restored in a
#           copy of each fixed gate must make Part 2 fail, or Part 2 proves
#           nothing
#   Part 7  the same question asked of the hook driver, which read the index
#           through a process substitution where git's status is unreachable
#
# Usage: bash experiments/test-issue123-discovery-fail-closed.sh

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

REAL_GIT="$(command -v git)"

# The gates this suite drives. A gate is here because it decides what to read
# by asking git, and therefore has an answer to give when git cannot say.
# check-workflow-yaml.sh reads .github/workflows/** like the four exempt below
# it, and is still driven here rather than exempted with them: it was written on
# this branch, after the empty-listing hole was known, so its behaviour on both
# failures is a claim this suite can check rather than one it has to take on
# trust. Reading workflows is not what earns an exemption.
GATES=(
  run-shellcheck.sh
  run-shfmt.sh
  check-heredoc-vars.sh
  check-py-syntax.sh
  check-mjs-syntax.sh
  check-awk-portability.sh
  run-hadolint.sh
  check-file-line-limits.sh
  check-workflow-yaml.sh
)

# Exempt, each for a reason that is not "we forgot":
#
#   detect-changes.sh          classifies a diff range to decide what to build.
#                              Its `git ls-files` is the fallback when no range
#                              resolves, not a checked file set - the same
#                              exemption check-workflow-path-coverage.mjs
#                              already records for it.
#   check-required-docs.sh     the requirement table is its input, not a glob:
#                              it names six documents and 24 headings, so an
#                              empty `git ls-files` cannot make it silent.
#   check-checkout-credentials.mjs
#   check-status-gate-covers-all-jobs.mjs
#   check-timeout-budgets.mjs
#   check-workflow-path-coverage.mjs
#                              all four read .github/workflows/**, and each
#                              already fails when that directory yields nothing
#                              (there is no repository shape where a workflow
#                              gate has no workflows and the run is healthy).
#   run-experiments.sh         discovers suites, and its own suite
#                              (test-issue115-experiment-runner.sh) pins that
#                              an empty discovery is an error there.
EXEMPT=(
  detect-changes.sh
  check-required-docs.sh
  check-checkout-credentials.mjs
  check-status-gate-covers-all-jobs.mjs
  check-timeout-budgets.mjs
  check-workflow-path-coverage.mjs
  run-experiments.sh
)

# Driven, but not by the GATES loop. run-precommit-checks.sh is the hook driver
# rather than a gate, and an *empty* listing is a legitimate answer for it - a
# commit really can stage nothing. Only the other half applies: a `git` that
# could not list must not arrive as "Nothing staged". It was exempt here until
# the same read was found in it (Part 7), which is the argument for keeping the
# exemption list short and the reasons specific.
DRIVEN_SEPARATELY=(
  run-precommit-checks.sh
)

echo "== Part 1: every git ls-files gate is covered or exempt =="

DISCOVERERS=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  DISCOVERERS+=("$(basename "$f")")
done < <(grep -rlE 'git +ls-files' "$ROOT/scripts/ci" 2>/dev/null | sort)

[ "${#DISCOVERERS[@]}" -ge 10 ] \
  && pass "found ${#DISCOVERERS[@]} scripts under scripts/ci/ that discover with git ls-files" \
  || fail "only found ${#DISCOVERERS[@]} discovering scripts; the grep above has drifted"

for name in "${DISCOVERERS[@]}"; do
  covered=0
  for g in "${GATES[@]}" "${EXEMPT[@]}" "${DRIVEN_SEPARATELY[@]}"; do
    [ "$g" = "$name" ] && covered=1 && break
  done
  [ "$covered" = "1" ] \
    && pass "$name is covered by this suite or exempt in writing" \
    || fail "$name discovers its inputs with git ls-files but is neither driven below nor exempt" \
      "add it to GATES, or to EXEMPT with the reason it cannot go silent"
done

# The exemption list is only honest while every name on it still exists.
for g in "${EXEMPT[@]}" "${DRIVEN_SEPARATELY[@]}"; do
  [ -f "$ROOT/scripts/ci/$g" ] \
    && pass "the exemption for $g still names a file in the tree" \
    || fail "EXEMPT names $g, which is not in scripts/ci/ - a stale exemption hides the next gate"
done

# --- the fixtures -------------------------------------------------------------

# A repository the gates can be run from, holding a copy of scripts/ci/ so each
# gate's REPO_ROOT (derived from $0) lands inside it, and `.gitignore` of `*`
# so `--cached` and `--others --exclude-standard` are both empty. Nothing is
# wrong with this git; it simply has nothing to report.
EMPTY_REPO="$WORK/empty-repo"
mkdir -p "$EMPTY_REPO/scripts/ci"
cp "$ROOT"/scripts/ci/*.sh "$ROOT"/scripts/ci/*.mjs "$EMPTY_REPO/scripts/ci/" 2>/dev/null
# hadolint reads its config before it discovers anything; without this it fails
# for the wrong reason and the assertion would pass without meaning it.
cp "$ROOT/.hadolint.yaml" "$EMPTY_REPO/.hadolint.yaml" 2>/dev/null || true
printf '*\n' >"$EMPTY_REPO/.gitignore"
(cd "$EMPTY_REPO" && "$REAL_GIT" init -q .) >/dev/null 2>&1

# A git that answers every question except the one that enumerates. `rev-parse`
# has to keep working, or the gates that anchor themselves first would fail for
# a reason that has nothing to do with discovery.
STUB_DIR="$WORK/stub-bin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/git" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "ls-files" ]; then
  echo "fatal: unable to read index file" >&2
  exit 128
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$STUB_DIR/git"

# run_gate <gate> <dir> [env...] - the gate's exit status on stdout's last line
# and its output in $GATE_OUT.
GATE_OUT=""
run_gate() { # run_gate <script-path> <cwd> <PATH-prefix-or-empty>
  local script="$1" dir="$2" prefix="${3:-}" rc=0
  if [ -n "$prefix" ]; then
    GATE_OUT="$(cd "$dir" && PATH="$prefix:$PATH" bash "$script" 2>&1)" || rc=$?
  else
    GATE_OUT="$(cd "$dir" && bash "$script" 2>&1)" || rc=$?
  fi
  return "$rc"
}

echo
echo "== Part 2: a git that cannot enumerate is not a clean tree =="

for g in "${GATES[@]}"; do
  rc=0
  run_gate "$ROOT/scripts/ci/$g" "$ROOT" "$STUB_DIR" || rc=$?
  if [ "$rc" -ne 0 ]; then
    pass "$g refuses to report on a repository git could not list (exit $rc)"
  else
    fail "$g exited 0 when git ls-files failed" "$(printf '%s' "$GATE_OUT" | head -2)"
  fi
  # Non-zero is necessary and not sufficient: the operator has to be told that
  # nothing was read, not merely that something went wrong.
  if printf '%s' "$GATE_OUT" | grep -qiE 'ls-files|not inside a git repository|could not|no files|no shell scripts|no Dockerfiles|verified nothing|no files matched'; then
    pass "and says which half of the answer is missing"
  else
    fail "$g failed without saying it read nothing" "$(printf '%s' "$GATE_OUT" | head -3)"
  fi
done

echo
echo "== Part 3: a git that enumerates nothing is not a clean tree either =="

for g in "${GATES[@]}"; do
  rc=0
  run_gate "$EMPTY_REPO/scripts/ci/$g" "$EMPTY_REPO" "" || rc=$?
  if [ "$rc" -ne 0 ]; then
    pass "$g refuses an empty input set (exit $rc)"
  else
    fail "$g exited 0 over zero files" "$(printf '%s' "$GATE_OUT" | head -2)"
  fi
done

# The two causes must not print the same sentence, or the next reader has to
# guess which one happened - which is how this root cause survived in the first
# place.
for g in run-shellcheck.sh run-shfmt.sh check-heredoc-vars.sh; do
  run_gate "$ROOT/scripts/ci/$g" "$ROOT" "$STUB_DIR" || true
  broken="$GATE_OUT"
  run_gate "$EMPTY_REPO/scripts/ci/$g" "$EMPTY_REPO" "" || true
  empty="$GATE_OUT"
  if printf '%s' "$broken" | grep -q 'git ls-files failed' \
    && printf '%s' "$empty" | grep -q 'matched no shell script'; then
    pass "$g distinguishes 'could not ask' from 'asked, and there is nothing'"
  else
    fail "$g gives the same message for both, so neither can be acted on"
  fi
done

echo
echo "== Part 4: the mutation control =="

# Each fixed gate, with the pre-fix shape put back: discovery that swallows
# git's status and callers that treat an empty list as a clean tree. Part 2 has
# to fail against these, or Part 2 is measuring nothing.
MUTANT_DIR="$WORK/mutants"
mkdir -p "$MUTANT_DIR/scripts/ci"
cp "$ROOT"/scripts/ci/*.sh "$ROOT"/scripts/ci/*.mjs "$MUTANT_DIR/scripts/ci/" 2>/dev/null

python3 - "$MUTANT_DIR/scripts/ci" <<'PY'
import io, os, re, sys

d = sys.argv[1]
for name in ("run-shellcheck.sh", "run-shfmt.sh"):
    p = os.path.join(d, name)
    s = io.open(p, encoding="utf-8").read()
    # collect_files as it was: the pipeline, and `|| true` swallowing git.
    s = re.sub(
        r"collect_files\(\) \{.*?\n\}\n",
        "collect_files() {\n"
        "  git ls-files -z --cached --others --exclude-standard --deduplicate '*.sh' '.githooks/*' \\\n"
        "    | tr '\\\\0' '\\\\n' | grep -v '^dev/log/' | sort -u || true\n"
        "}\n",
        s,
        count=1,
        flags=re.S,
    )
    # discover_or_exit as it was not: no refusal at all.
    s = re.sub(
        r"discover_or_exit\(\) \{.*?\n\}\n",
        "discover_or_exit() {\n  collect_files\n}\n",
        s,
        count=1,
        flags=re.S,
    )
    # and the caller's empty-set error back to the clean-run message.
    s = re.sub(
        r'echo "::error title=(?:shellcheck|shfmt)::no shell scripts to (?:check|format)[^"]*" >&2\n  exit 2\n',
        'echo "==> No shell scripts"\n  exit 0\n',
        s,
        count=1,
    )
    io.open(p, "w", encoding="utf-8").write(s)

p = os.path.join(d, "check-heredoc-vars.sh")
s = io.open(p, encoding="utf-8").read()
start = s.index("  if ! LISTING=\"$(")
end = s.index("  fi\nfi\n", start) + len("  fi\nfi\n")
s = s[:start] + "  while IFS= read -r f; do FILES+=(\"$f\"); done < <(git ls-files '*.sh' | grep -v '^dev/log/')\nfi\n" + s[end:]
io.open(p, "w", encoding="utf-8").write(s)
print("mutated")
PY

for g in run-shellcheck.sh run-shfmt.sh check-heredoc-vars.sh; do
  bash -n "$MUTANT_DIR/scripts/ci/$g" 2>/dev/null \
    && pass "the $g mutant is still a valid script" \
    || fail "the $g mutant does not parse; the mutation is testing nothing"
  rc=0
  run_gate "$MUTANT_DIR/scripts/ci/$g" "$ROOT" "$STUB_DIR" || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "and it exits 0 when git ls-files fails, which is the defect Part 2 catches"
  else
    fail "the $g mutant exited $rc; the mutation did not restore the defect" \
      "$(printf '%s' "$GATE_OUT" | head -3)"
  fi
done

echo
echo "== Part 5: the fix is where the run can see it =="

for g in run-shellcheck.sh run-shfmt.sh check-heredoc-vars.sh; do
  grep -q 'RC-17' "$ROOT/scripts/ci/$g" \
    && pass "$g records why its discovery may not fall back to silence" \
    || fail "$g carries the fix without the reason; the next reader will delete it"
done

# The pre-fix shape must not survive anywhere under scripts/, in this or any
# other gate: `git ls-files` with its status thrown away is the defect itself.
#
# Two things this sweep has to get right, both learned by getting them wrong
# here first:
#
#   Logical lines, not physical ones. run-hadolint.sh carried the defect with
#   its globs wrapped across three continuation lines, so `|| true` and
#   `ls-files` were never on the same physical line and a line-at-a-time grep
#   called the tree clean. That is this issue's defect class turned on the
#   sweep itself, so backslash continuations are joined first - the same
#   treatment test-issue123-apt-retry-defaults.sh gives apt's sources.
#
#   Comments are not code. The fixed gates explain the defect by quoting it,
#   and a sweep that cannot tell an explanation from an occurrence would have
#   to be silenced to stay green, which is how the shape comes back.
sweep_leaks() { # sweep_leaks <dir>
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Join continuations, drop whole-line comments, then look for the shape.
    sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "$f" \
      | grep -nE 'git +ls-files' \
      | grep -vE '^[0-9]+: *#' \
      | grep -E '\|\| *true' \
      | sed "s|^|$f:|" || true
  done < <(find "$1" -type f \( -name '*.sh' -o -name '*.bash' -o -name '*.mjs' \) 2>/dev/null | sort)
}

LEAKS="$(sweep_leaks "$ROOT/scripts")"
[ -z "$LEAKS" ] \
  && pass "no script under scripts/ ends a git ls-files pipeline with '|| true'" \
  || fail "a git ls-files failure is still swallowed" "$LEAKS"

# And the sweep above has to be able to fail.
PLANT="$WORK/plant"
mkdir -p "$PLANT"
printf '#!/usr/bin/env bash\ngit ls-files "*.sh" | sort || true\n' >"$PLANT/gate.sh"
# The shape that escaped the first version of this sweep: split across
# continuation lines, so `ls-files` and `|| true` never share a physical line.
cat >"$PLANT/gate3.sh" <<'PLANTED'
#!/usr/bin/env bash
git ls-files -z --cached \
  'Dockerfile' '*/Dockerfile' \
  | tr '\0' '\n' | sort -u || true
PLANTED
[ -n "$(sweep_leaks "$PLANT")" ] \
  && pass "and a planted offender is caught by the same expression" \
  || fail "the sweep expression does not match a planted '|| true', so its silence means nothing"

# The comment exclusion must not be a blanket one: a leak on a line that merely
# has a comment after it is still a leak.
printf '#!/usr/bin/env bash\ngit ls-files "*.sh" || true # trailing\n' >"$PLANT/gate2.sh"
[ "$(sweep_leaks "$PLANT" | wc -l)" -eq 3 ] \
  && pass "and the comment exclusion drops explanations, not code with a comment on it" \
  || fail "the comment exclusion is too broad; it would hide a real leak" \
    "$(sweep_leaks "$PLANT")"

# The continuation-joining half, stated on its own so a regression names itself.
[ -n "$(sweep_leaks "$PLANT" | grep gate3)" ] \
  && pass "and a leak split across continuation lines is caught too" \
  || fail "the sweep reads physical lines; a leak hides behind a backslash"

echo
echo "== Part 6: --list-inputs is an answer, not a guess =="

# The coverage gate reads --list-inputs as the authoritative list of what a gate
# reads. A gate that cannot enumerate and prints an empty list with exit 0 makes
# every one of its inputs look covered, which is this same false negative one
# layer up.
for g in "${GATES[@]}"; do
  grep -q -- '--list-inputs' "$ROOT/scripts/ci/$g" || continue
  rc=0
  GATE_OUT="$(cd "$ROOT" && PATH="$STUB_DIR:$PATH" bash "$ROOT/scripts/ci/$g" --list-inputs 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    pass "$g --list-inputs refuses rather than printing an empty list (exit $rc)"
  else
    fail "$g --list-inputs exited 0 when git could not enumerate" \
      "every input it reads would then look covered by any paths: filter"
  fi
  # And it must still answer normally, or the contract is broken the other way.
  n="$(cd "$ROOT" && bash "$ROOT/scripts/ci/$g" --list-inputs 2>/dev/null | wc -l)"
  [ "$n" -gt 0 ] \
    && pass "and answers with $n path(s) when git works" \
    || fail "$g --list-inputs prints nothing on a healthy repository"
done

# The consumer's half: a gate that refuses has to make the coverage gate refuse,
# not be recorded as a gate with no inputs.
if grep -q 'list-inputs failed' "$ROOT/scripts/ci/check-workflow-path-coverage.mjs" \
  && grep -q 'broken = true' "$ROOT/scripts/ci/check-workflow-path-coverage.mjs"; then
  pass "check-workflow-path-coverage.mjs turns a --list-inputs failure into its own error"
else
  fail "the coverage gate swallows a --list-inputs failure, so refusing there buys nothing"
fi

echo
echo "== Part 7: the driver reads the index the same way the gates read the tree =="

# run-precommit-checks.sh collected the staged paths with
#
#   done < <(git diff --cached --name-only -z ... 2>/dev/null)
#
# where git's status is unreachable by construction. A git that could not read
# the index therefore produced an empty array, and the driver printed
#   ==> Nothing staged; no checks to run
# and exited 0 - the gates' own false negative, in the script that runs them.
# An empty index is still a normal answer, so only the failing half is an
# error, and it is exit 2 ("could not run"): the hook does not block on that by
# design, and CI checks the commit regardless.

DRIVER="$ROOT/scripts/ci/run-precommit-checks.sh"

# A stub git that fails only the listing the driver depends on.
stub_git_failing() { # stub_git_failing <dir> <subcommand>
  mkdir -p "$1"
  cat >"$1/git" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "$2" ]; then
  echo "fatal: unable to read index file" >&2
  exit 128
fi
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$1/git"
}

stub_git_failing "$WORK/stub-diff" diff
stub_git_failing "$WORK/stub-lsfiles" ls-files

rc=0
OUT="$(cd "$ROOT" && PATH="$WORK/stub-diff:$PATH" bash "$DRIVER" 2>&1)" || rc=$?
[ "$rc" = "2" ] \
  && pass "a git that cannot read the index is 'could not run' (exit 2), not 'nothing staged'" \
  || fail "the driver exited $rc when git diff --cached failed" "$(printf '%s' "$OUT" | head -3)"
printf '%s' "$OUT" | grep -q 'could not list the staged files' \
  && pass "and names what it could not read, with git's own reason above it" \
  || fail "the driver failed without saying the listing is what failed" "$(printf '%s' "$OUT" | head -3)"
printf '%s' "$OUT" | grep -q 'Nothing staged' \
  && fail "the driver still reported 'Nothing staged' over an unreadable index" \
  || pass "and does not claim the commit was empty"

rc=0
OUT="$(cd "$ROOT" && PATH="$WORK/stub-lsfiles:$PATH" bash "$DRIVER" --worktree 2>&1)" || rc=$?
[ "$rc" = "2" ] \
  && pass "--worktree fails the same way when git ls-files cannot answer (exit 2)" \
  || fail "--worktree exited $rc when git ls-files failed" "$(printf '%s' "$OUT" | head -3)"
printf '%s' "$OUT" | grep -q "could not list this repository's files" \
  && pass "and says which listing it is" \
  || fail "--worktree failed without naming the listing" "$(printf '%s' "$OUT" | head -3)"

# The other half of the contract: a genuinely empty index is not an error, or
# every commit of an unrelated repository would be blocked by this.
EMPTY_INDEX="$WORK/empty-index"
mkdir -p "$EMPTY_INDEX"
(cd "$EMPTY_INDEX" && "$REAL_GIT" init -q . && "$REAL_GIT" config user.email t@e && "$REAL_GIT" config user.name t) >/dev/null 2>&1
rc=0
OUT="$(cd "$EMPTY_INDEX" && bash "$DRIVER" 2>&1)" || rc=$?
[ "$rc" = "0" ] \
  && pass "an index with nothing in it is still exit 0 - empty is a real answer here" \
  || fail "the driver exited $rc on an empty index" "$(printf '%s' "$OUT" | head -3)"
printf '%s' "$OUT" | grep -q 'Nothing staged' \
  && pass "and says so in those words" \
  || fail "the driver did not report an empty index as empty" "$(printf '%s' "$OUT" | head -3)"

# The mutation control: put the process-substitution form back and the first
# assertion of this part has to stop holding.
MUT="$WORK/driver-mutated.sh"
sed -e 's|^if ! LISTING="$("$LISTER")"; then|LISTING="$("$LISTER")" \|\| LISTING=""\nif false; then|' "$DRIVER" >"$MUT"
if ! grep -q 'if false; then' "$MUT"; then
  fail "the mutation did not apply; the guard's shape has changed" "re-read $DRIVER"
else
  pass "the mutation applied - the status check is discarded again"
  rc=0
  OUT="$(cd "$ROOT" && PATH="$WORK/stub-diff:$PATH" bash "$MUT" 2>&1)" || rc=$?
  { [ "$rc" = "0" ] && printf '%s' "$OUT" | grep -q 'Nothing staged'; } \
    && pass "and the pre-fix form reports an unreadable index as an empty commit" \
    || fail "discarding the status no longer reproduces the defect (exit $rc)" \
      "$(printf '%s' "$OUT" | head -3)"
fi

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
