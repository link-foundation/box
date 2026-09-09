#!/usr/bin/env bash
# test-issue121-required-docs.sh
#
# Issue #121: "Check for all false positives, false negatives, warnings and
# errors in CI/CD and fix them all", and its instruction to adopt what the
# reference templates already do. This is the fixtures suite for
# scripts/ci/check-required-docs.sh, the port of the js template's gate of the
# same name (hive-mind principle #12, "documentation validation").
#
# The rules it protects are not decorative. scripts/update-readme-sizes.sh
# inserts the generated component-sizes section before `## License`, falling
# back to `## Documentation`, and measure-disk-space.yml commits the result to
# main; scripts/release/preflight-credentials.sh sends an operator holding a
# rejected credential to "the 'Releasing' section of README.md". Rename any of
# those headings and nothing anywhere reports it.
#
# Every assertion runs against a throwaway git repository built from the
# checker's own `--list` output, so the fixtures cannot drift from the table
# they are testing: adding a document or a section to the checker adds it to
# these trees automatically.
#
# What it asserts:
#   Part 1  a complete tree passes, quietly, and --verbose is what names things
#   Part 2  a missing document, an untracked one and an empty one each fail
#   Part 3  a renamed section fails, and the annotation names file and heading
#   Part 4  the component-size markers: missing, doubled, reversed
#   Part 5  a docs/ path named in scripts/ or .github/ must exist, and the two
#           forms that must not fire: a URL, and a bare name
#   Part 6  usage: --list is machine-readable, an unknown option exits 2,
#           outside a git repository exits 2
#   Part 7  the wiring: a workflow runs the checker, and this suite is
#           discovered by run-experiments.sh
#
# Usage: bash experiments/test-issue121-required-docs.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
REPO_ROOT="$PWD"
CHECKER="$REPO_ROOT/scripts/ci/check-required-docs.sh"

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

if [ ! -x "$CHECKER" ]; then
  fail "scripts/ci/check-required-docs.sh is missing or not executable"
  echo "passed: $PASS"
  echo "failed: $FAIL"
  exit 1
fi
pass "scripts/ci/check-required-docs.sh exists and is executable"

# A tree that satisfies the checker, built from the checker's own table.
new_repo() {
  local name="$1"
  local dir="$WORK/$name"
  mkdir -p "$dir"
  (
    cd "$dir" || exit 1
    git init -q .
    git config user.email fixture@example.invalid
    git config user.name fixture
    mkdir -p scripts/ci .github/workflows
    cp "$CHECKER" scripts/ci/check-required-docs.sh
  ) || return 1

  # One file per required document, carrying every section the table asks for.
  local path section previous=""
  while IFS="$(printf '\t')" read -r path section; do
    [ -n "$path" ] || continue
    if [ "$path" != "$previous" ]; then
      mkdir -p "$dir/$(dirname "$path")"
      printf '# %s\n\n' "$(basename "$path" .md)" >"$dir/$path"
      previous="$path"
    fi
    [ -n "$section" ] || continue
    printf '## %s\n\nfixture text\n\n' "$section" >>"$dir/$path"
  done < <(bash "$CHECKER" --list)

  # The markers rule 3 checks, in order and once each.
  printf '<!-- COMPONENT_SIZES_START -->\n\n| Component | Size |\n\n<!-- COMPONENT_SIZES_END -->\n' >>"$dir/README.md"

  (cd "$dir" && git add -A && git commit -qm fixture) || return 1
  echo "$dir"
}

run_check() {
  local dir="$1"
  shift
  (cd "$dir" && bash scripts/ci/check-required-docs.sh "$@" >"$dir/out.log" 2>&1)
}

echo ""
echo "== Part 1: a complete tree passes =="

BASE="$(new_repo base)" || fail "could not build the fixture repository"
if run_check "$BASE"; then
  pass "a tree with every document, section and marker exits 0"
else
  fail "a complete tree was rejected" "$(cat "$BASE/out.log")"
fi

if ! grep -q '^  \[doc\]' "$BASE/out.log"; then
  pass "the quiet run does not list every document"
else
  fail "the checker is verbose by default"
fi

run_check "$BASE" --verbose
if grep -q '^  \[doc\] README.md' "$BASE/out.log" && grep -q '^  \[section\] README.md' "$BASE/out.log"; then
  pass "--verbose names the documents and the sections"
else
  fail "--verbose printed nothing about README.md" "$(cat "$BASE/out.log")"
fi

if grep -q '^  \[markers\] README.md' "$BASE/out.log"; then
  pass "--verbose names the marker pair it found"
else
  fail "--verbose said nothing about the markers"
fi

echo ""
echo "== Part 2: a document that is not there =="

D="$(new_repo missing-doc)"
rm "$D/ARCHITECTURE.md"
if ! run_check "$D"; then
  pass "a deleted required document fails the check"
else
  fail "a deleted required document passed"
fi
if grep -q '::error file=ARCHITECTURE.md,title=Required document is missing::' "$D/out.log"; then
  pass "and is annotated against the path that is missing"
else
  fail "no annotation named ARCHITECTURE.md" "$(cat "$D/out.log")"
fi

D="$(new_repo untracked-doc)"
(cd "$D" && git rm -q --cached REQUIREMENTS.md >/dev/null)
if ! run_check "$D" && grep -q 'Required document is untracked' "$D/out.log"; then
  pass "a document present but untracked fails: a fresh checkout would not have it"
else
  fail "an untracked required document passed" "$(cat "$D/out.log")"
fi

D="$(new_repo empty-doc)"
: >"$D/REQUIREMENTS.md"
if ! run_check "$D" && grep -q 'Required document is empty' "$D/out.log"; then
  pass "an emptied document fails"
else
  fail "an empty required document passed" "$(cat "$D/out.log")"
fi

echo ""
echo "== Part 3: the headings other code depends on =="

# The two update-readme-sizes.sh inserts before, and the one
# preflight-credentials.sh names in an error message.
for section in License Documentation Releasing; do
  D="$(new_repo "renamed-$section")"
  sed -i "s|^## ${section}$|## ${section} and other things|" "$D/README.md"
  (cd "$D" && git commit -qam rename)
  if ! run_check "$D"; then
    pass "renaming README's '## ${section}' fails the check"
  else
    fail "renaming '## ${section}' passed"
  fi
  if grep -q "::error file=README.md,title=Required section is missing::README.md no longer has a '## ${section}' heading" "$D/out.log"; then
    pass "and the annotation names the file and the heading"
  else
    fail "the annotation for '## ${section}' is missing or unclear" "$(cat "$D/out.log")"
  fi
done

# A heading is matched whole: `## Licensexyz` is not `## License`.
D="$(new_repo substring-heading)"
sed -i 's|^## License$|## Licensing|' "$D/README.md"
if ! run_check "$D" && grep -q "'## License' heading" "$D/out.log"; then
  pass "a heading that merely starts with the required text does not satisfy it"
else
  fail "'## Licensing' was accepted for '## License'" "$(cat "$D/out.log")"
fi

# A heading at another level is not the one the consumers grep for.
D="$(new_repo wrong-level-heading)"
sed -i 's|^## Releasing$|### Releasing|' "$D/README.md"
if ! run_check "$D" && grep -q "'## Releasing' heading" "$D/out.log"; then
  pass "demoting a required heading to ### fails, as the consumers' greps would"
else
  fail "'### Releasing' was accepted for '## Releasing'" "$(cat "$D/out.log")"
fi

echo ""
echo "== Part 4: the markers measure-disk-space.yml writes between =="

D="$(new_repo no-markers)"
sed -i '/COMPONENT_SIZES/d' "$D/README.md"
if ! run_check "$D" && grep -q 'Component-size markers are not a single pair' "$D/out.log"; then
  pass "a README with no markers fails"
else
  fail "a README with no markers passed" "$(cat "$D/out.log")"
fi

D="$(new_repo doubled-markers)"
printf '<!-- COMPONENT_SIZES_START -->\n<!-- COMPONENT_SIZES_END -->\n' >>"$D/README.md"
if ! run_check "$D" && grep -q 'Found 2 start and 2 end marker' "$D/out.log"; then
  pass "a second marker pair fails, and the count is in the message"
else
  fail "a doubled marker pair passed" "$(cat "$D/out.log")"
fi

D="$(new_repo reversed-markers)"
python3 - "$D/README.md" <<'PY'
import sys
p = sys.argv[1]
text = open(p).read()
text = text.replace('<!-- COMPONENT_SIZES_START -->', '@@S@@').replace('<!-- COMPONENT_SIZES_END -->', '<!-- COMPONENT_SIZES_START -->').replace('@@S@@', '<!-- COMPONENT_SIZES_END -->')
open(p, 'w').write(text)
PY
if ! run_check "$D" && grep -q 'Component-size markers are out of order' "$D/out.log"; then
  pass "an end marker before its start marker fails"
else
  fail "reversed markers passed" "$(cat "$D/out.log")"
fi

echo ""
echo "== Part 5: the documents the code sends people to =="

D="$(new_repo mention-missing)"
cat >"$D/scripts/ci/example.sh" <<'FIXTURE'
#!/usr/bin/env bash
# Rotate the credential and re-run: see docs/NOT-THERE.md for the procedure.
echo hello
FIXTURE
(cd "$D" && git add -A && git commit -qm mention)
if ! run_check "$D"; then
  pass "a script naming a documentation path that does not exist fails"
else
  fail "a missing docs/ path named in a script passed"
fi
if grep -q '::error file=scripts/ci/example.sh,line=2,title=Documentation path does not exist::' "$D/out.log"; then
  pass "and the annotation carries the file and the line that names it"
else
  fail "the annotation is missing its file or line" "$(cat "$D/out.log")"
fi

D="$(new_repo mention-workflow)"
cat >"$D/.github/workflows/example.yml" <<'FIXTURE'
name: Example
on: [push]
jobs:
  a:
    runs-on: ubuntu-24.04
    steps:
      # The budgets are explained in docs/GONE.md.
      - run: 'true'
FIXTURE
(cd "$D" && git add -A && git commit -qm mention)
if ! run_check "$D" && grep -q 'file=.github/workflows/example.yml' "$D/out.log"; then
  pass ".github/ is scanned for documentation paths too, not only scripts/"
else
  fail "a missing docs/ path named in a workflow passed" "$(cat "$D/out.log")"
fi

D="$(new_repo mention-present)"
cat >"$D/scripts/ci/example.sh" <<'FIXTURE'
#!/usr/bin/env bash
# The rule is in docs/CI-TIMEOUT-BUDGETS.md.
echo hello
FIXTURE
(cd "$D" && git add -A && git commit -qm mention)
if run_check "$D"; then
  pass "a docs/ path that does exist does not fire"
else
  fail "a script naming an existing document was rejected" "$(cat "$D/out.log")"
fi

D="$(new_repo mention-url)"
cat >"$D/scripts/ci/example.sh" <<'FIXTURE'
#!/usr/bin/env bash
# Best practices: https://github.com/link-assistant/hive-mind/blob/main/docs/CI-CD-BEST-PRACTICES.md
# and https://example.invalid/docs/SOMETHING-ELSE.md
echo hello
FIXTURE
(cd "$D" && git add -A && git commit -qm mention)
if run_check "$D"; then
  pass "another project's documents, named in a URL, are not resolved against this tree"
else
  fail "a URL was read as a path in this repository" "$(cat "$D/out.log")"
fi

# Deliberately out of scope, and asserted so: a bare name in a comment may be an
# example, another project's file, or a path relative to a directory named two
# lines earlier. Firing on all three is the false positive this issue is about,
# and it fired on two sentences of the checker's own documentation while the
# rule was wider than this.
D="$(new_repo mention-bare-name)"
cat >"$D/scripts/ci/example.sh" <<'FIXTURE'
#!/usr/bin/env bash
# See CHANGELOG.md for the release history, or lychee/out.md after a run.
echo hello
FIXTURE
(cd "$D" && git add -A && git commit -qm mention)
if run_check "$D"; then
  pass "a name without a docs/ prefix is out of scope, not a finding"
else
  fail "a bare name or a run-time artifact path was read as a claim about the tree" "$(cat "$D/out.log")"
fi

echo ""
echo "== Part 6: usage =="

LIST_OUT="$(bash "$CHECKER" --list)"
if printf '%s\n' "$LIST_OUT" | grep -qP '^README\.md\tLicense$'; then
  pass "--list prints path<TAB>section lines"
else
  fail "--list output is not the documented shape" "$LIST_OUT"
fi

if [ "$(printf '%s\n' "$LIST_OUT" | cut -f1 | sort -u | wc -l)" -ge 4 ]; then
  pass "--list covers every document in the table"
else
  fail "--list named fewer documents than the table holds"
fi

bash "$CHECKER" --nonsense >"$WORK/usage.log" 2>&1
if [ "$?" -eq 2 ] && grep -q 'unknown argument' "$WORK/usage.log"; then
  pass "an unknown option exits 2, not 1: misuse is not a finding"
else
  fail "an unknown option did not exit 2" "$(cat "$WORK/usage.log")"
fi

mkdir -p "$WORK/not-a-repo"
(cd "$WORK/not-a-repo" && GIT_CEILING_DIRECTORIES="$WORK" bash "$CHECKER" >"$WORK/norepo.log" 2>&1)
if [ "$?" -eq 2 ]; then
  pass "running outside a git repository exits 2"
else
  fail "running outside a git repository did not exit 2" "$(cat "$WORK/norepo.log")"
fi

echo ""
echo "== Part 7: the gate is wired into CI =="

if grep -rq 'check-required-docs.sh' "$REPO_ROOT/.github/workflows/"; then
  pass "a workflow runs the checker"
else
  fail "nothing in .github/workflows runs check-required-docs.sh"
fi

if grep -q "test-issue121-required-docs.sh" "$REPO_ROOT/scripts/ci/run-experiments.sh" 2>/dev/null; then
  fail "this suite is listed in run-experiments.sh; discovery is supposed to find it"
else
  pass "this suite is found by run-experiments.sh's discovery, not by a list"
fi

echo ""
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
