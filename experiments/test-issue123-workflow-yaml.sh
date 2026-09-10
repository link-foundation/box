#!/usr/bin/env bash
# test-issue123-workflow-yaml.sh
#
# The gate that establishes the floor the other workflow gates assume.
#
# This branch's own edit left three orphan lines in release-full.yml:
#
#   run: bash scripts/release/release-version.sh
#     echo "Building version: $VERSION"
#
# The file was not YAML. Eleven pre-commit gates passed it, including the four
# that read workflows, and each of those four printed a verdict about it. Part 2
# below reproduces that: the same four checkers, the same broken file, exit 0.
#
# Offline. Needs ruby (stdlib psych) and reports "could not run" without it.

set -uo pipefail

PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$REPO_ROOT/scripts/ci/check-workflow-yaml.sh"

# Annotation markers in captured output are defanged before they are echoed:
# this suite runs in CI, and a reproduction that printed a real `::error` would
# annotate the run with the defect it is demonstrating.
no() { sed -e 's/::/:_:/g' -e 's/##\[/#_[/g' <<<"$1"; }

check() { # check <label> <true|false> [detail]
  if [ "$2" = "true" ]; then
    PASS=$((PASS + 1))
    echo "  ok   $1"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL $1"
    [ -n "${3:-}" ] && echo "       $(no "$3")"
  fi
}

bool() { if "$@" >/dev/null 2>&1; then echo true; else echo false; fi; }

contains() { case "$1" in *"$2"*) echo true ;; *) echo false ;; esac }

if ! command -v ruby >/dev/null 2>&1 || ! ruby -ryaml -e '' >/dev/null 2>&1; then
  echo "SKIP: ruby with psych is not available, so the gate could not be exercised"
  exit 0
fi

# A workflow tree with one file in it, written from a heredoc.
fixture() { # fixture <name> <<'YAML'
  local dir="$WORK/$1"
  mkdir -p "$dir/.github/workflows"
  cat >"$dir/.github/workflows/w.yml"
  echo "$dir/.github/workflows/w.yml"
}

echo "== Part 1: the break that shipped =="

BROKEN="$(
  fixture broken <<'YAML'
name: Release
on: push
jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - name: Get latest version
        id: version
        run: bash scripts/release/release-version.sh
          echo "Building version: $VERSION"
YAML
)"

OUT="$(bash "$GATE" "$BROKEN" 2>&1)"
STATUS=$?
check "the orphan line under a non-block run: is reported" "$(bool test "$STATUS" -eq 1)" "exit=$STATUS"
check "  the annotation names the file" "$(contains "$OUT" "$BROKEN")"
check "  and the line the parser stopped at" "$(contains "$OUT" 'line=10')" "$OUT"
check "  and says what was wrong in the parser's own words" \
  "$(contains "$OUT" 'mapping values are not allowed in this context')" "$OUT"
check "  the parser's ::-bearing class name cannot open an annotation" \
  "$(bool grep -qv 'Psych::SyntaxError' <<<"$OUT")" "$OUT"
check "  and the summary counts the file" "$(contains "$OUT" '1 of 1 file(s) do not parse as YAML')" "$OUT"

FIXED="$(sed '/echo "Building version/d' "$BROKEN")"
printf '%s\n' "$FIXED" >"$BROKEN"
check "removing the orphan is the whole fix" "$(bool bash "$GATE" "$BROKEN")"

echo
echo "== Part 2: why the gates already there did not catch it =="

# The same broken file, handed to each checker the way run-precommit-checks.sh
# hands it to them. Every one of these exiting 0 is the reason this gate exists;
# they are not defective - a line-oriented reader cannot ask this question - but
# the assumption has to be established somewhere.
BROKEN2="$(
  fixture broken2 <<'YAML'
name: Release
on: push
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-24.04
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v5
        with:
          persist-credentials: false
      - name: Get latest version
        run: bash scripts/release/release-version.sh
          echo "Building version: $VERSION"
  status:
    runs-on: ubuntu-24.04
    needs: [build]
    if: always()
    timeout-minutes: 5
    steps:
      - run: echo ok
YAML
)"

check "the file really is unparseable" \
  "$(bool bash -c '! ruby -ryaml -e "YAML.load_file(ARGV[0])" "$1" 2>/dev/null' _ "$BROKEN2")"

for checker in check-status-gate-covers-all-jobs.mjs check-timeout-budgets.mjs; do
  if command -v node >/dev/null 2>&1; then
    (cd "$REPO_ROOT" && node "scripts/ci/$checker" "$BROKEN2" >/dev/null 2>&1)
    RC=$?
    check "  $checker returns 0 on it, as measured" "$(bool test "$RC" -eq 0)" "exit=$RC"
  fi
done

check "  and this gate is the one that returns non-zero" \
  "$(bool bash -c '! bash "$1" "$2" >/dev/null 2>&1' _ "$GATE" "$BROKEN2")"

echo
echo "== Part 3: the limits, stated where they are pinned =="

# A continuation line with no colon is a legal plain scalar. The header says so;
# this is the assertion that keeps the header honest.
SCALAR="$(
  fixture scalar <<'YAML'
name: x
on: push
jobs:
  a:
    steps:
      - run: bash scripts/release/release-version.sh
          echo hello
YAML
)"
check "a colon-free orphan parses, and this gate says so" "$(bool bash "$GATE" "$SCALAR")"
check "  which is why the header calls YAML validity the floor, not the ceiling" \
  "$(bool grep -q 'the floor, not the ceiling' "$GATE")"

echo
echo "== Part 4: refusing to pass over what it could not read =="

MISSING="$WORK/nope/.github/workflows/w.yml"
bash "$GATE" "$MISSING" >/dev/null 2>&1
check "an unreadable file is 'could not run' (exit 2), not a pass" "$(bool test $? -eq 2)"

EMPTY="$WORK/empty"
mkdir -p "$EMPTY"
(cd "$EMPTY" && git init -q . && bash "$GATE" >/dev/null 2>&1)
check "a repository with no workflows verifies nothing and says so (exit 2)" "$(bool test $? -eq 2)"

OUT="$(cd "$EMPTY" && bash "$GATE" 2>&1)"
check "  naming the reason rather than exiting quietly" \
  "$(contains "$OUT" 'this check verified nothing')" "$OUT"

echo
echo "== Part 5: the whole repository, and the wiring =="

check "every tracked workflow and composite action parses" \
  "$(bool bash -c 'cd "$1" && bash scripts/ci/check-workflow-yaml.sh >/dev/null 2>&1' _ "$REPO_ROOT")"

COUNT="$(cd "$REPO_ROOT" && bash scripts/ci/check-workflow-yaml.sh 2>/dev/null | sed -n 's/^check-workflow-yaml: \([0-9]*\) .*/\1/p')"
TRACKED="$(cd "$REPO_ROOT" && git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml' '.github/actions/*.yml' '.github/actions/*.yaml' | wc -l)"
check "it reads all $TRACKED of them, not a subset" \
  "$(bool test "$COUNT" = "$TRACKED")" "gate=$COUNT tracked=$TRACKED"

# --list-inputs, and the anchoring that makes its answer a repository-relative
# path. Without both, check-workflow-path-coverage.mjs cannot verify that any
# workflow's `paths:` filter re-runs this gate - it exits 2 and the pre-commit
# hook, which treats "could not run" as "does not block", lets the commit past.
INPUTS="$(cd "$REPO_ROOT" && bash "$GATE" --list-inputs)"
check "--list-inputs answers with one path per line" \
  "$(bool test "$(wc -l <<<"$INPUTS")" = "$TRACKED")" "$INPUTS"
check "  and every path is repository-relative" \
  "$(bool bash -c 'grep -qv "^/" <<<"$1" && ! grep -q "^\\.\\./" <<<"$1"' _ "$INPUTS")" "$INPUTS"
check "  and names the composite actions, not workflows alone" \
  "$(contains "$INPUTS" '.github/actions/')" "$INPUTS"

# Run from a subdirectory, an unanchored `git ls-files` lists that subtree alone
# and the gate exits 0 over a fraction of the repository (issue #121).
SUB="$(cd "$REPO_ROOT/scripts/ci" && bash "$GATE" --list-inputs | wc -l)"
check "run from a subdirectory it still reads all $TRACKED files" \
  "$(bool test "$SUB" = "$TRACKED")" "from scripts/ci: $SUB"

check "path-coverage can therefore check this gate's paths filter" \
  "$(bool bash -c 'cd "$1" && node scripts/ci/check-workflow-path-coverage.mjs >/dev/null 2>&1' _ "$REPO_ROOT")"

bash "$GATE" --nope >/dev/null 2>&1
UNKNOWN=$?
check "an unknown option exits 2 rather than checking a subset" \
  "$(bool test "$UNKNOWN" -eq 2)" "exit=$UNKNOWN"

check "the pre-commit hook runs this gate" \
  "$(bool grep -q 'gate workflow-yaml bash scripts/ci/check-workflow-yaml.sh' "$REPO_ROOT/scripts/ci/run-precommit-checks.sh")"
check "  and a workflow runs it too, so the hook's tolerance is not a hole" \
  "$(bool grep -rq 'run: bash scripts/ci/check-workflow-yaml.sh' "$REPO_ROOT/.github/workflows/")"
check "  and that workflow re-runs when the gate itself is edited" \
  "$(bool grep -q "scripts/ci/check-workflow-yaml.sh'" "$REPO_ROOT/.github/workflows/workflows.yml")"
check "this suite is discovered and run by scripts/ci/run-experiments.sh" \
  "$(bool grep -rq 'test-issue123-workflow-yaml.sh' "$REPO_ROOT/.github/workflows/workflows.yml")"

echo
echo "== ${PASS} passed, ${FAIL} failed =="
[ "$FAIL" -eq 0 ]
