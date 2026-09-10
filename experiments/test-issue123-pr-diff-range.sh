#!/usr/bin/env bash
# Assertions for issue #123: the three pull-request gates in release.yml must
# not read "git could not answer" as "nothing changed".
#
# Before this branch, .github/workflows/release.yml ran two jobs that each asked
#
#   git diff --name-only "origin/${GITHUB_BASE_REF}...HEAD"
#
# and threw the exit status away. `git diff` exits 128 and prints nothing when
# the range does not resolve - no `fetch-depth: 0` in the checkout, a base
# branch renamed or deleted while the pull request was open, a fetch that
# failed - and two of the three gates then reported the passing answer. The
# reproduction is experiments/issue-123/repro-version-gate-silent-pass.sh;
# these are the assertions that keep it fixed.
#
# Offline. No docker, no network: every fixture is a local git repository, and
# the one case that needs a remote uses a second local repository as one.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  echo "  ok   $1"
}

no() {
  FAIL=$((FAIL + 1))
  echo "  FAIL $1"
  # The detail is usually a gate's own output, which by the nature of what this
  # suite tests contains `::error::` and `::stop-commands::` - live workflow
  # commands if this suite is running inside a job. Defanged rather than
  # bracketed, because a `::stop-commands::` in the detail would otherwise mask
  # the tokens of the very block meant to contain it.
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed -e 's/::/:_:/g' -e 's/##\[/#_[/g' | sed 's/^/       /'
  return 0
}

check() {
  local desc="$1" cond="$2" detail="${3:-}"
  if [ "$cond" = "true" ]; then ok "$desc"; else no "$desc" "$detail"; fi
}

contains() {
  case "$1" in
    *"$2"*) echo true ;;
    *) echo false ;;
  esac
}

export GIT_AUTHOR_NAME=box GIT_AUTHOR_EMAIL=box@example.test
export GIT_COMMITTER_NAME=box GIT_COMMITTER_EMAIL=box@example.test
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

echo "== Part 1: every caller goes through the one helper =="

HELPER="$REPO_ROOT/scripts/release/pr-diff-range.sh"
check "scripts/release/pr-diff-range.sh exists" "$([ -f "$HELPER" ] && echo true || echo false)"

for fn in pr_base_ref pr_ensure_base_ref pr_range_error pr_changed_files pr_changed_files_with_status pr_diff; do
  check "helper defines ${fn}()" \
    "$(grep -qE "^${fn}\(\) \{" "$HELPER" && echo true || echo false)"
done

for caller in check-version.sh validate-changeset.sh check-changeset-required.sh; do
  check "scripts/release/${caller} sources pr-diff-range.sh" \
    "$(grep -q 'pr-diff-range.sh"$' "$REPO_ROOT/scripts/release/$caller" && echo true || echo false)"
done

# The sweep that stops a fourth site being added. Any tracked file computing the
# base-branch range by hand is a place the helper's failure handling does not
# reach; the helper itself and the evidence under experiments/issue-123/ and
# dev/log/ are the exceptions, because that is where the defect is recorded.
# `*.md` is excluded for the same reason and not as a convenience: prose that
# quotes the defective line - this branch's changeset, the case study - describes
# it rather than runs it, and a sweep for code that runs must not be satisfiable
# by rewording a sentence.
RAW_SITES="$(cd "$REPO_ROOT" && git grep -nE 'git (diff|log|rev-list)[^|]*origin/\$\{?[A-Za-z_]*BASE[A-Za-z_]*\}?\.\.\.?HEAD' -- \
  ':!scripts/release/pr-diff-range.sh' ':!experiments/*' ':!dev/log/*' ':!docs/*' ':!*.md' 2>/dev/null \
  | awk -F: '$3 !~ /^[[:space:]]*#/' || true)"
check "no tracked file builds the origin/BASE...HEAD range by hand" \
  "$([ -z "$RAW_SITES" ] && echo true || echo false)" "found: $RAW_SITES"

WORKFLOW="$REPO_ROOT/.github/workflows/release.yml"
check "release.yml's changeset-check step is one script call" \
  "$(grep -q 'run: bash scripts/release/check-changeset-required.sh' "$WORKFLOW" && echo true || echo false)"
check "release.yml's version-check step is one script call" \
  "$(grep -q 'run: bash scripts/release/check-version.sh' "$WORKFLOW" && echo true || echo false)"
check "release.yml no longer greps a diff inline" \
  "$(grep -q "CODE_CHANGES=\$(git diff" "$WORKFLOW" && echo false || echo true)"

# The gates are only correct because their jobs fetch the whole history. That
# coupling was invisible until the failure it causes was made loud, so it is
# asserted here beside the scripts that depend on it.
for job in version-check changeset-check; do
  block="$(awk -v job="  ${job}:" '$0 == job {inside = 1} inside && /^  [a-z]/ && $0 != job {exit} inside' "$WORKFLOW")"
  check "release.yml job ${job} checks out with fetch-depth: 0" \
    "$(contains "$block" 'fetch-depth: 0')"
done

echo
echo "== Part 2: with a range that resolves, each gate answers correctly =="

# origin/main: VERSION 1.0.0, one script, one workflow, an empty .changeset/.
build_origin() {
  local root="$WORK/$1"
  mkdir -p "$root"
  git init -q --bare --initial-branch=main "$root/origin"
  local seed="$root/seed"
  mkdir -p "$seed/.changeset" "$seed/scripts" "$seed/docs" "$seed/.github/actions/probe"
  git init -q --initial-branch=main "$seed"
  echo "1.0.0" >"$seed/VERSION"
  echo "seed" >"$seed/scripts/build.sh"
  echo "seed" >"$seed/docs/guide.md"
  echo "seed" >"$seed/.github/actions/probe/action.yml"
  echo "# changesets" >"$seed/.changeset/README.md"
  git -C "$seed" add -A
  git -C "$seed" commit -qm seed
  git -C "$seed" remote add origin "$root/origin"
  git -C "$seed" push -q origin main
  printf '%s\n' "$root"
}

# A branch off it, with whatever the caller writes into it.
branch_from() {
  local root="$1" name="$2"
  local work="$root/$name"
  git clone -q "$root/origin" "$work"
  git -C "$work" checkout -q -b "$name"
  printf '%s\n' "$work"
}

commit_all() {
  git -C "$1" add -A
  git -C "$1" commit -qm "${2:-change}"
}

# Run a gate the way the workflow does, and return its exit status in $STATUS
# with stdout+stderr in $OUT.
# SCRIPTS_ROOT is the shipped tree by default and a mutated copy of it in part 5.
SCRIPTS_ROOT="$REPO_ROOT/scripts"

gate() {
  local work="$1" script="$2" head_ref="${3:-feature}"
  OUT="$(cd "$work" && GITHUB_BASE_REF=main GITHUB_HEAD_REF="$head_ref" \
    bash "$SCRIPTS_ROOT/release/$script" 2>&1)"
  STATUS=$?
}

ROOT="$(build_origin resolves)"

W="$(branch_from "$ROOT" version-edited)"
echo "9.9.9" >"$W/VERSION"
commit_all "$W" "hand-edit the version"
gate "$W" check-version.sh
check "check-version.sh fails on a hand-edited VERSION" "$([ "$STATUS" = 1 ] && echo true || echo false)" "exit=$STATUS"
check "check-version.sh names the defect" "$(contains "$OUT" 'Manual VERSION change detected')"

W="$(branch_from "$ROOT" version-untouched)"
echo "change" >>"$W/scripts/build.sh"
commit_all "$W"
gate "$W" check-version.sh
check "check-version.sh passes when VERSION is untouched" "$([ "$STATUS" = 0 ] && echo true || echo false)" "exit=$STATUS $OUT"

W="$(branch_from "$ROOT" release-branch)"
echo "2.0.0" >"$W/VERSION"
commit_all "$W"
gate "$W" check-version.sh "changeset-release/main"
check "check-version.sh skips the pipeline's own release branch" \
  "$([ "$STATUS" = 0 ] && echo true || echo false)" "exit=$STATUS"
check "  and says so" "$(contains "$OUT" 'Skipping version check')"

W="$(branch_from "$ROOT" code-no-changeset)"
echo "change" >>"$W/scripts/build.sh"
commit_all "$W"
gate "$W" check-changeset-required.sh
check "changeset gate fails on a code change with no changeset" \
  "$([ "$STATUS" = 1 ] && echo true || echo false)" "exit=$STATUS"
check "  and names the defect" "$(contains "$OUT" 'No changeset found')"

W="$(branch_from "$ROOT" code-with-changeset)"
echo "change" >>"$W/scripts/build.sh"
printf -- '---\nbump: patch\n---\n\nA change.\n' >"$W/.changeset/fix.md"
commit_all "$W"
gate "$W" check-changeset-required.sh
check "changeset gate passes on a code change with a changeset" \
  "$([ "$STATUS" = 0 ] && echo true || echo false)" "exit=$STATUS $OUT"

W="$(branch_from "$ROOT" docs-only)"
echo "change" >>"$W/docs/guide.md"
commit_all "$W"
gate "$W" check-changeset-required.sh
check "changeset gate does not ask a docs-only pull request for one" \
  "$([ "$STATUS" = 0 ] && echo true || echo false)" "exit=$STATUS"
check "  and says why" "$(contains "$OUT" 'changeset not required')"

# The path list was widened when the step became a script: a composite action is
# executed by every release build, so changing one changes the pipeline exactly
# as changing a workflow does.
W="$(branch_from "$ROOT" composite-action)"
echo "change" >>"$W/.github/actions/probe/action.yml"
commit_all "$W"
gate "$W" check-changeset-required.sh
check "a change to a composite action needs a changeset" \
  "$([ "$STATUS" = 1 ] && echo true || echo false)" "exit=$STATUS"

W="$(branch_from "$ROOT" bad-bump)"
echo "change" >>"$W/scripts/build.sh"
printf -- '---\nbump: enormous\n---\n\nA change.\n' >"$W/.changeset/fix.md"
commit_all "$W"
gate "$W" check-changeset-required.sh
check "an unparseable bump type is rejected" "$([ "$STATUS" = 1 ] && echo true || echo false)" "exit=$STATUS"
check "  by the format check, not the presence check" "$(contains "$OUT" 'Invalid changeset format')"

# A changeset is the repository's own `.changeset/*.md` and nothing else. This
# pull request commits pinned copies of seven template repositories as evidence,
# six of which carry a `.changeset/` of their own written in the changesets
# format rather than this repository's `bump:` format - and the gate matched
# `.changeset/` anywhere in the path, so the release run failed on
# dev/log/issues/123/pulls/124/templates/go/.changeset/add-changeset-workflow.md.
# The assertion is written against a nested directory in general, not against
# dev/log/, because the anchor is what makes it right.
W="$(branch_from "$ROOT" foreign-changeset)"
mkdir -p "$W/dev/log/evidence/other-project/.changeset"
printf -- "---\n'other-project': minor\n---\n\nSomeone else's changeset.\n" \
  >"$W/dev/log/evidence/other-project/.changeset/their-change.md"
commit_all "$W"
gate "$W" validate-changeset.sh
check "a nested .changeset/ belonging to another project is not this gate's subject" \
  "$([ "$STATUS" = 1 ] && echo true || echo false)" "exit=$STATUS"
check "  it is reported as no changeset, not as an invalid one" \
  "$([ "$(contains "$OUT" 'Invalid changeset format')" = false ] && echo true || echo false)" "$OUT"
check "  and the gate never names the foreign file" \
  "$([ "$(contains "$OUT" 'their-change.md')" = false ] && echo true || echo false)"

# The same pull request, with the repository's own changeset added too: the
# foreign file must not make the real one fail either.
W="$(branch_from "$ROOT" foreign-plus-own)"
mkdir -p "$W/dev/log/evidence/other-project/.changeset"
printf -- "---\n'other-project': minor\n---\n\nSomeone else's changeset.\n" \
  >"$W/dev/log/evidence/other-project/.changeset/their-change.md"
printf -- '---\nbump: patch\n---\n\nA change.\n' >"$W/.changeset/fix.md"
echo "change" >>"$W/scripts/build.sh"
commit_all "$W"
gate "$W" check-changeset-required.sh
check "a foreign changeset beside a valid own one does not fail the release" \
  "$([ "$STATUS" = 0 ] && echo true || echo false)" "exit=$STATUS $OUT"

# A `.changeset/` subdirectory of the repository's own is not applied either:
# apply-changesets.sh reads it with `find -maxdepth 1`, so a file this gate
# validated below that depth would be a format nothing depends on.
W="$(branch_from "$ROOT" nested-own-changeset)"
mkdir -p "$W/.changeset/archive"
printf -- '---\nbump: enormous\n---\n\nArchived.\n' >"$W/.changeset/archive/old.md"
printf -- '---\nbump: patch\n---\n\nA change.\n' >"$W/.changeset/fix.md"
echo "change" >>"$W/scripts/build.sh"
commit_all "$W"
gate "$W" check-changeset-required.sh
check "a file below .changeset/ is not validated, because it is not applied" \
  "$([ "$STATUS" = 0 ] && echo true || echo false)" "exit=$STATUS $OUT"

# The gate agrees with the consumer about README.md, and about depth, in both
# directions: what apply-changesets.sh applies is exactly what this validates.
CONSUMER_GLOB="$(grep -c "maxdepth 1" "$REPO_ROOT/scripts/release/apply-changesets.sh")"
check "apply-changesets.sh still reads only the top level" \
  "$([ "$CONSUMER_GLOB" -ge 1 ] && echo true || echo false)" "matches=$CONSUMER_GLOB"
check "validate-changeset.sh anchors its path pattern at the repository root" \
  "$(contains "$(cat "$REPO_ROOT/scripts/release/validate-changeset.sh")" 'CHANGESET_PATH_REGEX="^')"

# A path with a space in it survives the status/path split. `git diff
# --name-status` is tab-separated; `awk '{print $2}'` was not.
W="$(branch_from "$ROOT" spaced-changeset)"
printf -- '---\nbump: enormous\n---\n\nA change.\n' >"$W/.changeset/a fix.md"
echo "change" >>"$W/scripts/build.sh"
commit_all "$W"
gate "$W" check-changeset-required.sh
check "a changeset path containing a space is still read whole" \
  "$(contains "$OUT" 'Invalid changeset format')" "exit=$STATUS $OUT"

# A path out of the pull request, printed by this gate, may be a workflow
# command: `[` is legal in a filename and `##[` anywhere in a physical line is
# read by the runner.
W="$(branch_from "$ROOT" hostile-path)"
mkdir -p "$W/scripts"
printf 'x\n' >"$W/scripts/##[error]injected.sh"
commit_all "$W"
gate "$W" check-changeset-required.sh
check "a hostile path is printed with command processing stopped" \
  "$(contains "$OUT" '::stop-commands::')"
STOPPED_FIRST=false
if printf '%s\n' "$OUT" | awk '/::stop-commands::/ { stopped = 1 } /##\[error\]injected/ { exit stopped ? 0 : 1 }'; then
  STOPPED_FIRST=true
fi
check "  the marker precedes the path" "$STOPPED_FIRST"

echo
echo "== Part 3: with a range that does not resolve, no gate reports success =="

# Exactly the state a checkout without fetch-depth: 0 leaves behind - the local
# ref is gone and the remote cannot be reached to restore it.
break_range() {
  git -C "$1" update-ref -d refs/remotes/origin/main
  git -C "$1" remote set-url origin "$WORK/no-such-remote"
}

for script in check-version.sh validate-changeset.sh check-changeset-required.sh; do
  W="$(branch_from "$ROOT" "broken-${script%.sh}")"
  echo "9.9.9" >"$W/VERSION"
  echo "change" >>"$W/scripts/build.sh"
  commit_all "$W"
  break_range "$W"
  gate "$W" "$script"
  check "${script} fails when git cannot compare" "$([ "$STATUS" = 1 ] && echo true || echo false)" "exit=$STATUS"
  check "  and says so rather than reporting the tree clean" \
    "$(contains "$OUT" 'Cannot compare this pull request against its base branch')"
  check "  and names the usual cause" "$(contains "$OUT" "fetch-depth: 0")"
done

# The annotation has to survive being called from a command substitution, which
# is how all three callers read the helper. On stdout it would be captured as
# the answer - the first draft of the helper exited 1 and printed nothing.
W="$(branch_from "$ROOT" stderr-check)"
echo "9.9.9" >"$W/VERSION"
commit_all "$W"
break_range "$W"
STDOUT_ONLY="$(cd "$W" && GITHUB_BASE_REF=main GITHUB_HEAD_REF=feature \
  bash "$SCRIPTS_ROOT/release/check-version.sh" 2>/dev/null)"
STDERR_ONLY="$(cd "$W" && GITHUB_BASE_REF=main GITHUB_HEAD_REF=feature \
  bash "$SCRIPTS_ROOT/release/check-version.sh" 2>&1 >/dev/null)"
check "the range error goes to stderr" "$(contains "$STDERR_ONLY" 'Cannot compare')"
check "  and not to stdout" \
  "$([ "$(contains "$STDOUT_ONLY" 'Cannot compare')" = false ] && echo true || echo false)"

echo
echo "== Part 4: a missing local ref is fetched rather than reported =="

# origin/main absent locally but the remote reachable: the helper must restore
# the ref and answer the question, not fail. This is the case that keeps the
# strictness from becoming a false positive of its own.
W="$(branch_from "$ROOT" refetch)"
echo "9.9.9" >"$W/VERSION"
commit_all "$W"
git -C "$W" update-ref -d refs/remotes/origin/main
gate "$W" check-version.sh
check "the helper fetches a base ref that is only missing locally" \
  "$([ "$STATUS" = 1 ] && echo true || echo false)" "exit=$STATUS"
check "  and answers the real question" "$(contains "$OUT" 'Manual VERSION change detected')"
check "  without complaining that it could not compare" \
  "$([ "$(contains "$OUT" 'Cannot compare')" = false ] && echo true || echo false)"

echo
echo "== Part 5: the trace says what the answer was computed from, and only on request =="

# Issue #123 cost a re-run to diagnose because a passing gate said nothing about
# which base ref it read or how many files came back: a right answer and a wrong
# one printed the same line. PR_DIFF_RANGE_VERBOSE=1 (or BOX_VERBOSE=1) makes the
# successful path name its own range. Default off, because a passing check should
# stay quiet, and on stderr, because every caller reads stdout through a command
# substitution.
W="$(branch_from "$ROOT" trace)"
echo "9.9.9" >"$W/VERSION"
commit_all "$W"

trace_run() {
  TRACE_OUT="$(cd "$W" && GITHUB_BASE_REF=main GITHUB_HEAD_REF=feature "$@" \
    bash "$SCRIPTS_ROOT/release/check-version.sh" 2>&1 >/dev/null)"
  TRACE_STDOUT="$(cd "$W" && GITHUB_BASE_REF=main GITHUB_HEAD_REF=feature "$@" \
    bash "$SCRIPTS_ROOT/release/check-version.sh" 2>/dev/null)"
}

trace_run env PR_DIFF_RANGE_VERBOSE=0
check "with the switch off the gate emits no trace" \
  "$([ "$(contains "$TRACE_OUT" '[pr-diff-range]')" = false ] && echo true || echo false)" \
  "$TRACE_OUT"

trace_run env PR_DIFF_RANGE_VERBOSE=1
check "with the switch on the trace names the range" \
  "$(contains "$TRACE_OUT" 'range origin/main...HEAD')"
check "  and how many paths came back" "$(contains "$TRACE_OUT" 'path(s) changed')"
check "  and reports the base ref it found" "$(contains "$TRACE_OUT" 'origin/main already present')"
check "  on stderr, never on stdout" \
  "$([ "$(contains "$TRACE_STDOUT" '[pr-diff-range]')" = false ] && echo true || echo false)" \
  "$TRACE_STDOUT"

# The repository-wide switch reaches this helper too, so one variable turns on
# tracing for a whole job rather than one script at a time.
trace_run env BOX_VERBOSE=1
check "BOX_VERBOSE=1 is the same switch" "$(contains "$TRACE_OUT" 'range origin/main...HEAD')"

# The script-specific name wins, so a job running with BOX_VERBOSE=1 can still
# silence this one helper.
trace_run env BOX_VERBOSE=1 PR_DIFF_RANGE_VERBOSE=0
check "  and PR_DIFF_RANGE_VERBOSE=0 overrides it" \
  "$([ "$(contains "$TRACE_OUT" '[pr-diff-range]')" = false ] && echo true || echo false)" \
  "$TRACE_OUT"

# A trace prints a branch name, and a branch name is text this repository does
# not write: `##[` anywhere in a physical line is a command to the runner. The
# name below never resolves, so this exercises the failure trace as well.
HOSTILE_BASE='main##[error]::set-output name=x::y'
TRACE_OUT="$(cd "$W" && GITHUB_BASE_REF="$HOSTILE_BASE" GITHUB_HEAD_REF=feature \
  PR_DIFF_RANGE_VERBOSE=1 bash "$SCRIPTS_ROOT/release/check-version.sh" 2>&1 >/dev/null)"
check "a hostile base branch name is printed with commands stopped" \
  "$(contains "$TRACE_OUT" '::stop-commands::')"
check "  and the gate refuses to answer for it" \
  "$(contains "$TRACE_OUT" 'Cannot compare')"

echo
echo "== Part 6: the assertions above fail when the fix is removed =="

# A suite that passes against the fixture rather than against the fix is worth
# nothing, and this defect class is exactly the one that produces such a suite:
# every assertion in part 3 is a claim about a path that is only taken when
# something has already gone wrong. Each mutation below puts one piece of the
# pre-issue-123 behaviour back into a copy of the shipped scripts, and the run
# has to notice - both that the mutation applied at all, and that it changes an
# outcome asserted above.
MUTATE_PY='
import pathlib, sys
path, old, new = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = path.read_text()
if old not in text:
    sys.exit(1)
path.write_text(text.replace(old, new))
'

# mutate NAME FILE OLD NEW [OLD NEW ...] - every pair has to apply, because a
# mutation that only half-lands leaves the fix partly in place and the assertion
# after it then proves nothing.
mutate() {
  local name="$1" file="$2"
  shift 2
  rm -rf "$WORK/mutant-${name}"
  mkdir -p "$WORK/mutant-${name}"
  cp -r "$REPO_ROOT/scripts" "$WORK/mutant-${name}/scripts"
  SCRIPTS_ROOT="$WORK/mutant-${name}/scripts"
  local applied=true
  while [ "$#" -ge 2 ]; do
    python3 -c "$MUTATE_PY" "$SCRIPTS_ROOT/$file" "$1" "$2" || applied=false
    shift 2
  done
  check "mutation ${name} applies to the shipped script" "$applied" \
    "text it replaces is no longer in ${file}, so what follows proves nothing"
}

restore() { SCRIPTS_ROOT="$REPO_ROOT/scripts"; }

# The mutation this whole branch is about: a range that does not resolve read as
# an empty answer, which is what `2>/dev/null || echo ""` did.
# Two edits, because the fix has two halves: the missing base ref is diagnosed
# before the diff runs, and the diff's own exit status is read after it.
mutate no-range-check release/pr-diff-range.sh \
  '  if ! pr_ensure_base_ref "$base"; then
    pr_range_error "$base" >&2
    return 1
  fi' \
  '  pr_ensure_base_ref "$base" || true' \
  '  if [ "$status" -ne 0 ]; then
    PR_DIFF_RANGE_DIAGNOSTIC="$out"
    pr_range_error "$base" >&2
    return 1
  fi' \
  '  if [ "$status" -ne 0 ]; then
    out=""
  fi'
W="$(branch_from "$ROOT" mutant-no-range-check)"
echo "9.9.9" >"$W/VERSION"
commit_all "$W"
break_range "$W"
gate "$W" check-version.sh
check "  removing the range check makes check-version.sh pass in silence" \
  "$([ "$STATUS" = 0 ] && echo true || echo false)" "exit=$STATUS $OUT"

# The mutation that was a real bug in the first draft of the helper: the
# annotation on stdout, where the caller's command substitution eats it.
mutate error-on-stdout release/pr-diff-range.sh \
  'pr_range_error "$base" >&2' 'pr_range_error "$base"'
W="$(branch_from "$ROOT" mutant-stdout)"
echo "9.9.9" >"$W/VERSION"
commit_all "$W"
break_range "$W"
gate "$W" check-version.sh
check "  printing the annotation to stdout loses it" \
  "$([ "$(contains "$OUT" 'Cannot compare')" = false ] && echo true || echo false)" "$OUT"

# The mutation that removes the log-injection guard added when the inline
# changeset step became a script.
mutate unguarded-print release/check-changeset-required.sh \
  'run_with_commands_stopped printf' 'printf'
W="$(branch_from "$ROOT" mutant-print)"
mkdir -p "$W/scripts"
printf 'x\n' >"$W/scripts/##[error]injected.sh"
commit_all "$W"
gate "$W" check-changeset-required.sh
check "  dropping the guard prints the hostile path unbracketed" \
  "$([ "$(contains "$OUT" '::stop-commands::')" = false ] && echo true || echo false)"

# The mutation that narrows the path set back to what the inline step used, so a
# composite action - executed by every release build - could change unannounced.
mutate narrow-paths release/check-changeset-required.sh \
  '|\.github/actions/|\.githooks/' ''
W="$(branch_from "$ROOT" mutant-paths)"
echo "change" >>"$W/.github/actions/probe/action.yml"
commit_all "$W"
gate "$W" check-changeset-required.sh
check "  narrowing the path set lets a composite action through" \
  "$([ "$STATUS" = 0 ] && echo true || echo false)" "exit=$STATUS"

restore

echo
echo "== ${PASS} passed, ${FAIL} failed =="
[ "$FAIL" -eq 0 ]
