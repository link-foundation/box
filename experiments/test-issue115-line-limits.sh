#!/usr/bin/env bash
# test-issue115-line-limits.sh
#
# Fixtures for scripts/ci/check-file-line-limits.sh, the port of the reference
# template's file-size gate (issue #115, R3/R5).
#
# The gate exists because .github/workflows/release.yml reached 3135 lines and
# that size was itself a root cause (RC-8): ten near-identical build jobs, so a
# fix applied to one survived nowhere else. A gate that never fires is worth
# nothing, and a gate that fires on a quoted upstream file is worse than
# nothing - it teaches everyone to raise the limit. So both directions are
# pinned here: it fails on a file over the limit, and it stays quiet on the
# evidence copies that are deliberately exempt.
#
# Every case runs against a throwaway git repository, so the assertions do not
# depend on the current size of any real file.
#
# Usage: bash experiments/test-issue115-line-limits.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/ci/check-file-line-limits.sh"

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

[ -f "$SCRIPT" ] || {
  echo "ERR: $SCRIPT not found" >&2
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# lines N FILE - write a file of exactly N lines.
lines() {
  local n="$1" file="$2"
  mkdir -p "$(dirname "$file")"
  seq 1 "$n" >"$file"
}

# repo NAME - a fresh git repository with everything in it committed.
# Tracked-only is the point: an untracked build artefact must not be able to
# fail the gate.
repo() {
  local dir="$TMP/$1"
  mkdir -p "$dir"
  git -C "$dir" init --quiet 2>/dev/null
  git -C "$dir" config user.email ci@example.com
  git -C "$dir" config user.name CI
  echo "$dir"
}

commit() {
  git -C "$1" add -A
  git -C "$1" -c commit.gpgsign=false commit --quiet -m fixture
}

# run DIR ENV... - run the gate in DIR, leaving $OUT and $STATUS.
OUT=""
STATUS=0
run() {
  local dir="$1"
  shift
  OUT="$(cd "$dir" && env "$@" bash "$SCRIPT" 2>&1)"
  STATUS=$?
}

echo "== Part 1: a file over the limit fails, with an annotation =="

W="$(repo over)"
lines 1501 "$W/scripts/huge.sh"
lines 10 "$W/README.md"
commit "$W"
run "$W"

if [ "$STATUS" -eq 1 ]; then
  pass "1501 lines exits 1"
else
  fail "1501 lines exits 1 (got $STATUS)"
  printf '%s\n' "$OUT" | sed 's/^/      /' >&2
fi

if printf '%s' "$OUT" | grep -q '::error file=scripts/huge.sh::File has 1501 lines'; then
  pass "the failure names the file and the count in a GitHub annotation"
else
  fail "the failure names the file and the count in a GitHub annotation"
  printf '%s\n' "$OUT" | sed 's/^/      /' >&2
fi

# The remedy differs by file kind, and advice that does not apply is advice
# nobody follows.
W="$(repo over-workflow)"
lines 1501 "$W/.github/workflows/release.yml"
commit "$W"
run "$W"
if printf '%s' "$OUT" | grep -q 'reusable workflow'; then
  pass "a workflow over the limit is told to extract a reusable workflow"
else
  fail "a workflow over the limit is told to extract a reusable workflow"
fi

echo ""
echo "== Part 2: the real pre-split release.yml is what this gate is for =="

# The exact file this repository shipped on main at 42be663, 3135 lines. If the
# gate would not have failed on it, it would not have prevented RC-8 and there
# is no reason to trust it on the next one.
PRE_SPLIT="$ROOT/dev/log/issues/115/pulls/116/analysis/release.yml.pre-split"
if [ -f "$PRE_SPLIT" ]; then
  W="$(repo pre-split)"
  mkdir -p "$W/.github/workflows"
  cp "$PRE_SPLIT" "$W/.github/workflows/release.yml"
  commit "$W"
  run "$W"
  if [ "$STATUS" -eq 1 ]; then
    pass "the 3135-line release.yml that motivated this gate fails it"
  else
    fail "the 3135-line release.yml that motivated this gate fails it (got $STATUS)"
  fi
else
  fail "the pre-split release.yml snapshot is missing; the gate is unproven against the file it exists for"
fi

echo ""
echo "== Part 3: the warning threshold fires before the limit does =="

W="$(repo warn)"
lines 1400 "$W/docs/long.md"
commit "$W"
run "$W"

if [ "$STATUS" -eq 0 ]; then
  pass "1400 lines still exits 0"
else
  fail "1400 lines still exits 0 (got $STATUS)"
fi

if printf '%s' "$OUT" | grep -q '::warning file=docs/long.md::File has 1400 lines'; then
  pass "1400 lines is annotated as a warning"
else
  fail "1400 lines is annotated as a warning"
  printf '%s\n' "$OUT" | sed 's/^/      /' >&2
fi

W="$(repo quiet)"
lines 1349 "$W/docs/ok.md"
commit "$W"
run "$W"
if [ "$STATUS" -eq 0 ] && ! printf '%s' "$OUT" | grep -q '::warning'; then
  pass "1349 lines says nothing at all"
else
  fail "1349 lines says nothing at all (status $STATUS)"
  printf '%s\n' "$OUT" | sed 's/^/      /' >&2
fi

echo ""
echo "== Part 4: the exemptions are the evidence copies, and nothing else =="

# Every exempt path holds a verbatim copy of another project's file. Reflowing
# a quotation to fit a limit destroys the thing it was kept for.
for path in \
  dev/log/issues/115/pulls/116/logs/huge.md \
  docs/case-studies/issue-108/data/rust-template-release.yml \
  docs/case-studies/issue-90/templates/js-template-release.yml \
  docs/case-studies/issue-23/template-release.yml; do
  W="$(repo "exempt-$(echo "$path" | tr / -)")"
  lines 5000 "$W/$path"
  lines 10 "$W/README.md"
  commit "$W"
  run "$W"
  if [ "$STATUS" -eq 0 ]; then
    pass "5000 lines under $(dirname "$path") is exempt"
  else
    fail "5000 lines under $(dirname "$path") is exempt (got $STATUS)"
  fi
done

# The exemption must not leak: a file our own hands maintain is checked even
# when it sits next to the quoted ones.
W="$(repo exempt-boundary)"
lines 1501 "$W/docs/case-studies/issue-115/CASE-STUDY.md"
commit "$W"
run "$W"
if [ "$STATUS" -eq 1 ]; then
  pass "a case study we wrote ourselves is still checked"
else
  fail "a case study we wrote ourselves is still checked (got $STATUS)"
fi

echo ""
echo "== Part 5: only tracked, only text we maintain =="

W="$(repo untracked)"
lines 10 "$W/README.md"
commit "$W"
lines 5000 "$W/build-output.md"
run "$W"
if [ "$STATUS" -eq 0 ]; then
  pass "an untracked file cannot fail the gate"
else
  fail "an untracked file cannot fail the gate (got $STATUS)"
fi

W="$(repo binary)"
lines 10 "$W/README.md"
lines 5000 "$W/data.csv"
lines 5000 "$W/docs/image.svg"
commit "$W"
run "$W"
if [ "$STATUS" -eq 0 ]; then
  pass "generated and data formats are out of scope"
else
  fail "generated and data formats are out of scope (got $STATUS)"
fi

W="$(repo extensions)"
for ext in sh md yml yaml mjs js cjs py rb; do
  lines 1501 "$W/over.$ext"
done
commit "$W"
run "$W"
COUNT="$(printf '%s\n' "$OUT" | grep -c '::error file=over\.')"
if [ "$COUNT" -eq 9 ]; then
  pass "all nine maintained extensions are checked"
else
  fail "all nine maintained extensions are checked (annotated $COUNT of 9)"
  printf '%s\n' "$OUT" | sed 's/^/      /' >&2
fi

echo ""
echo "== Part 6: the gate cannot pass by examining nothing (RC-16) =="

W="$(repo empty)"
lines 10 "$W/notes.txt"
commit "$W"
run "$W"
if [ "$STATUS" -eq 2 ] && printf '%s' "$OUT" | grep -q 'verified nothing'; then
  pass "a checkout with no matching file is an error, not a pass"
else
  fail "a checkout with no matching file is an error, not a pass (got $STATUS)"
  printf '%s\n' "$OUT" | sed 's/^/      /' >&2
fi

OUT="$(cd "$TMP" && bash "$SCRIPT" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 2 ] && printf '%s' "$OUT" | grep -q 'not inside a git repository'; then
  pass "running outside a git repository is an error, not a pass"
else
  fail "running outside a git repository is an error, not a pass (got $STATUS)"
fi

W="$(repo misuse)"
lines 10 "$W/README.md"
commit "$W"
OUT="$(cd "$W" && bash "$SCRIPT" --nonsense 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 2 ]; then
  pass "an unknown option is a usage error"
else
  fail "an unknown option is a usage error (got $STATUS)"
fi

echo ""
echo "== Part 7: the thresholds are configurable, and verbose is off by default =="

W="$(repo override)"
lines 200 "$W/scripts/small.sh"
commit "$W"
run "$W" LIMIT=100
if [ "$STATUS" -eq 1 ]; then
  pass "LIMIT lowers the bar"
else
  fail "LIMIT lowers the bar (got $STATUS)"
fi

run "$W" LIMIT=5000 WARN_THRESHOLD=100
if [ "$STATUS" -eq 0 ] && printf '%s' "$OUT" | grep -q '::warning'; then
  pass "WARN_THRESHOLD warns without failing"
else
  fail "WARN_THRESHOLD warns without failing (got $STATUS)"
fi

run "$W"
if ! printf '%s' "$OUT" | grep -q '^+ '; then
  pass "no shell trace by default"
else
  fail "the script traces by default"
fi

run "$W" BOX_VERBOSE=1
if printf '%s' "$OUT" | grep -q '^+ '; then
  pass "BOX_VERBOSE=1 traces every command"
else
  fail "BOX_VERBOSE=1 does not trace"
fi

run "$W"
LISTED="$(cd "$W" && bash "$SCRIPT" --list)"
if [ "$LISTED" = "scripts/small.sh" ]; then
  pass "--list prints exactly the files that would be checked"
else
  fail "--list prints exactly the files that would be checked (got: $LISTED)"
fi

echo ""
echo "== Part 8: the gate runs in CI =="

# The defect this whole pull request is about is a check that exists and never
# runs, so the wiring is asserted rather than assumed.
# `run:` lines only. Six workflows mention the script in a comment, and a
# comment is not a caller - counting one would be the false positive this
# repository keeps finding (a check that looks wired and never executes).
CALLERS="$(grep -rl 'run: bash scripts/ci/check-file-line-limits.sh' "$ROOT/.github/workflows/" || true)"
if [ -n "$CALLERS" ]; then
  pass "a workflow calls the gate ($(printf '%s\n' "$CALLERS" | xargs -n1 basename | tr '\n' ' '))"
else
  fail "no workflow calls the gate; it would only ever run on a laptop"
fi

echo ""
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
