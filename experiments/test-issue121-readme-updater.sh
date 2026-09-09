#!/usr/bin/env bash
# test-issue121-readme-updater.sh
#
# Issue #121. Fixtures for scripts/update-readme-sizes.sh, the script
# measure-disk-space.yml runs on main and whose output it commits back to the
# repository (.github/workflows/measure-disk-space.yml, "Update README with
# component sizes" -> "Commit measurement results").
#
# Three defects this suite pins, all measured before the fix; the transcripts
# are in dev/log/issues/121/pulls/122/readme-updater/:
#
#   1. A README without the <!-- COMPONENT_SIZES_START --> markers took the
#      "add the section" branch, which read /tmp/markdown_table_content.txt -
#      a file that branch only wrote three lines *later*. With no leftover from
#      an earlier run the script died with a Python traceback naming a path in
#      /tmp, and the job that commits the README failed with no indication that
#      the README was the subject.
#   2. With a leftover from an earlier run - the same fixed path, reused by
#      every invocation on the machine - the same branch exited 0 and wrote
#      *that* run's table into this README. Wrong numbers, published, green.
#   3. `--readme-file` and `--json-file` were parsed into shell variables that
#      were never exported, while the Python blocks doing the actual read and
#      write took their paths from the environment with `README.md` and
#      `data/disk-space-measurements.json` as defaults. So the script announced
#      "Updating README at: <the file you asked for>", then rewrote the
#      repository's README.md instead and reported success.
#
# Usage: bash experiments/test-issue121-readme-updater.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
UPDATER="$ROOT/scripts/update-readme-sizes.sh"

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

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 is not installed; the updater renders its table with it."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A case is a miniature repository: the updater where it expects to be, a
# data/ directory, and a README. Everything runs with the case as the working
# directory, which is how measure-disk-space.yml calls it.
new_case() {
  local name="$1"
  local dir="$WORK/$name"
  mkdir -p "$dir/scripts" "$dir/data"
  cp "$UPDATER" "$dir/scripts/update-readme-sizes.sh"
  cat >"$dir/data/disk-space-measurements.json" <<'JSON'
{"generated_at": "2026-09-09T00:00:00Z", "total_size_mb": 12.5,
 "components": [{"name": "Fixture Runtime", "category": "Runtime", "size_bytes": 10485760, "size_mb": 10.0},
                {"name": "Fixture Tool", "category": "Build Tools", "size_bytes": 2621440, "size_mb": 2.5}]}
JSON
  cat >"$dir/README.md" <<'MD'
# Fixture

## Environment

Some prose.

<!-- COMPONENT_SIZES_START -->
## Component Sizes

_Last updated: 1999-01-01T00:00:00Z_

**Total installation size: 999.0 MB**

| Component | Category | Size (MB) |
|-----------|----------|-----------|
| Stale | System | 999.0 |
<!-- COMPONENT_SIZES_END -->

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md)

## License

MIT
MD
  echo "$dir"
}

run_case() {
  local dir="$1"
  shift
  (cd "$dir" && bash scripts/update-readme-sizes.sh "$@" >"$dir/out.log" 2>&1)
}

echo "=== Part 1: the refresh path, which is the one CI takes ==="

CASE="$(new_case refresh)"
run_case "$CASE"
RC=$?
[ "$RC" -eq 0 ] && pass "a README with markers is updated and exits 0" \
  || fail "expected exit 0, got $RC: $(sed 's/^/    /' "$CASE/out.log")"

grep -q '^\*\*Total installation size: 12.5 MB\*\*$' "$CASE/README.md" \
  && pass "the table carries the JSON's total, not the stale one" \
  || fail "the refreshed table does not carry the JSON's total"

grep -q 'Total installation size: 999.0 MB' "$CASE/README.md" \
  && fail "the stale table survived the refresh" \
  || pass "the stale table is gone"

[ "$(grep -c 'COMPONENT_SIZES_START' "$CASE/README.md")" = "1" ] \
  && [ "$(grep -c 'COMPONENT_SIZES_END' "$CASE/README.md")" = "1" ] \
  && pass "exactly one pair of markers is left behind" \
  || fail "the markers were duplicated or dropped"

cp "$CASE/README.md" "$CASE/first.md"
run_case "$CASE"
if diff -q "$CASE/first.md" "$CASE/README.md" >/dev/null 2>&1; then
  pass "a second run with the same JSON changes nothing"
else
  fail "the updater is not idempotent"
  diff "$CASE/first.md" "$CASE/README.md" | sed 's/^/    /'
fi

echo ""
echo "=== Part 2: a README that has lost its markers ==="

CASE="$(new_case insert)"
grep -v 'COMPONENT_SIZES' "$CASE/README.md" >"$CASE/README.tmp" && mv "$CASE/README.tmp" "$CASE/README.md"
rm -f /tmp/markdown_table_content.txt
run_case "$CASE"
RC=$?
[ "$RC" -eq 0 ] && pass "the section is added instead of the script dying" \
  || fail "expected exit 0, got $RC: $(sed 's/^/    /' "$CASE/out.log")"

grep -q 'COMPONENT_SIZES_START' "$CASE/README.md" \
  && grep -q 'COMPONENT_SIZES_END' "$CASE/README.md" \
  && pass "both markers are restored" \
  || fail "the markers were not restored"

grep -q '^\*\*Total installation size: 12.5 MB\*\*$' "$CASE/README.md" \
  && pass "the inserted table is this run's" \
  || fail "the inserted table is not this run's"

if [ "$(grep -n 'COMPONENT_SIZES_START' "$CASE/README.md" | cut -d: -f1)" -lt \
  "$(grep -n '^## License' "$CASE/README.md" | cut -d: -f1)" ]; then
  pass "the section is placed before '## License'"
else
  fail "the section is not placed before '## License'"
fi

# The insert path is the one that must survive the README losing its markers,
# so it gets the same second-run check as the refresh path.
cp "$CASE/README.md" "$CASE/first.md"
run_case "$CASE"
if diff -q "$CASE/first.md" "$CASE/README.md" >/dev/null 2>&1; then
  pass "the run after an insert changes nothing"
else
  fail "insert followed by refresh is not idempotent"
  diff "$CASE/first.md" "$CASE/README.md" | sed 's/^/    /'
fi

echo ""
echo "=== Part 3: no other run's numbers can reach this README ==="

CASE="$(new_case leftover)"
grep -v 'COMPONENT_SIZES' "$CASE/README.md" >"$CASE/README.tmp" && mv "$CASE/README.tmp" "$CASE/README.md"
printf '## Component Sizes\n\n**Total installation size: 4321.0 MB**\n' >/tmp/markdown_table_content.txt
run_case "$CASE"
RC=$?
rm -f /tmp/markdown_table_content.txt
[ "$RC" -eq 0 ] && pass "a leftover in /tmp does not stop the run" \
  || fail "expected exit 0, got $RC: $(sed 's/^/    /' "$CASE/out.log")"

grep -q '4321.0 MB' "$CASE/README.md" \
  && fail "another run's table was written into this README" \
  || pass "the leftover table was not used"

grep -q '^\*\*Total installation size: 12.5 MB\*\*$' "$CASE/README.md" \
  && pass "this run's table was written instead" \
  || fail "this run's table is missing"

grep -q '/tmp/markdown_table_content.txt' "$UPDATER" \
  && fail "the updater still names a fixed path in /tmp, which every run shares" \
  || pass "the updater uses no fixed path in /tmp"

echo ""
echo "=== Part 4: the flags write where they say they write ==="

CASE="$(new_case flags)"
cp "$CASE/README.md" "$CASE/other.md"
cp "$CASE/README.md" "$CASE/readme.before"
run_case "$CASE" --readme-file "$CASE/other.md"
RC=$?
[ "$RC" -eq 0 ] && pass "--readme-file exits 0" \
  || fail "expected exit 0, got $RC: $(sed 's/^/    /' "$CASE/out.log")"

grep -q '^\*\*Total installation size: 12.5 MB\*\*$' "$CASE/other.md" \
  && pass "--readme-file updates the file it names" \
  || fail "--readme-file did not update the file it names"

if diff -q "$CASE/readme.before" "$CASE/README.md" >/dev/null 2>&1; then
  pass "and leaves the repository's own README.md alone"
else
  fail "--readme-file rewrote README.md instead of the file it names"
fi

CASE="$(new_case jsonflag)"
sed 's/12.5/34.5/' "$CASE/data/disk-space-measurements.json" >"$CASE/other.json"
run_case "$CASE" --json-file "$CASE/other.json"
grep -q '^\*\*Total installation size: 34.5 MB\*\*$' "$CASE/README.md" \
  && pass "--json-file reads the file it names" \
  || fail "--json-file was ignored"

# measure-disk-space.yml passes both paths through the environment, so that
# calling convention has to keep working exactly as it does today.
CASE="$(new_case envvars)"
cp "$CASE/README.md" "$CASE/other.md"
(cd "$CASE" && README_FILE="other.md" JSON_FILE="data/disk-space-measurements.json" \
  bash scripts/update-readme-sizes.sh >"$CASE/out.log" 2>&1)
grep -q '^\*\*Total installation size: 12.5 MB\*\*$' "$CASE/other.md" \
  && pass "README_FILE and JSON_FILE from the environment still work" \
  || fail "the environment calling convention broke: $(sed 's/^/    /' "$CASE/out.log")"

echo ""
echo "=== Part 5: misuse is refused, not guessed at ==="

CASE="$(new_case nojson)"
rm -f "$CASE/data/disk-space-measurements.json"
run_case "$CASE"
RC=$?
[ "$RC" -ne 0 ] && pass "a missing JSON file is an error" \
  || fail "a missing JSON file exited 0"
grep -q 'disk-space-measurements.json' "$CASE/out.log" \
  && pass "and the message names the file it looked for" \
  || fail "the message does not name the missing file"

CASE="$(new_case noreadme)"
rm -f "$CASE/README.md"
run_case "$CASE"
RC=$?
[ "$RC" -ne 0 ] && pass "a missing README is an error" \
  || fail "a missing README exited 0"

CASE="$(new_case badflag)"
run_case "$CASE" --not-an-option
RC=$?
[ "$RC" -ne 0 ] && pass "an unknown option is refused" \
  || fail "an unknown option was accepted"

echo ""
echo "=== Part 6: the workflow that runs it ==="

WF="$ROOT/.github/workflows/measure-disk-space.yml"
grep -q 'update-readme-sizes.sh' "$WF" \
  && pass "measure-disk-space.yml runs the updater" \
  || fail "no workflow runs the updater"

grep -q 'README_FILE:' "$WF" && grep -q 'JSON_FILE:' "$WF" \
  && pass "and passes both paths in the environment, as Part 4 assumes" \
  || fail "the workflow no longer passes both paths; revisit Part 4"

echo ""
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
