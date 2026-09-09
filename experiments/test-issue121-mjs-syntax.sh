#!/usr/bin/env bash
# test-issue121-mjs-syntax.sh
#
# Issue #121. Fixtures for scripts/ci/check-mjs-syntax.sh.
#
# The gap it closes: of the 14 tracked JavaScript modules outside dev/log/ and
# docs/, ten were named by no workflow and no suite, so no run ever parsed
# them; two of the remaining four only execute on the path where the links
# check has already failed, which is the worst time to discover that the
# recovery script does not parse.
# experiments/reproduce-issue121-mjs-syntax-gap.sh measures both halves.
#
# A gate is only worth having if it can fail, so most of what follows is
# fixtures that must be reported and fixtures that must not.
#
# Usage: bash experiments/test-issue121-mjs-syntax.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
CHECK="$ROOT/scripts/ci/check-mjs-syntax.sh"

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
  echo "SKIP: node is not installed; this suite drives a checker that parses JavaScript."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Writes $2 to a fixture and reports whether the checker flagged it. Prints
# "flagged" or "clean"; anything else is a crash, and shows up as a mismatch in
# the assertion that called it.
verdict() {
  local name="$1" body="$2"
  printf '%s\n' "$body" >"$WORK/$name"
  if (cd "$WORK" && bash "$CHECK" "$name" >/dev/null 2>&1); then
    echo "clean"
  else
    echo "flagged"
  fi
}

expect() {
  local want="$1" name="$2" body="$3" label="$4" got
  got="$(verdict "$name" "$body")"
  if [ "$got" = "$want" ]; then
    pass "$label"
  else
    fail "$label (expected $want, got $got)"
    printf '%s\n' "$body" | sed 's/^/    /'
    (cd "$WORK" && bash "$CHECK" "$name" 2>&1 | sed 's/^/    /')
  fi
}

echo "=== Part 1: a module that does not parse is reported ==="

expect flagged unclosed.mjs 'export function f() {
  return { ok: true,
}' \
  "an unclosed object literal is reported"
expect flagged token.mjs 'const = 1;' \
  "a stray assignment is reported"
expect flagged string.mjs 'const s = "never closed;
console.log(s);' \
  "an unterminated string is reported"
expect flagged template.mjs 'const s = `never closed;
console.log(s);' \
  "an unterminated template literal is reported"
expect flagged reserved.mjs 'const class = 1;' \
  "a reserved word used as a name is reported"

echo ""
echo "=== Part 2: valid modules are not reported ==="

expect clean modern.mjs 'const r = await Promise.resolve({ a: 1 });
console.log(r?.a ?? 0);
class C {
  #x = 1;
  get x() {
    return this.#x;
  }
}
console.log(new C().x);' \
  "top-level await, optional chaining and private fields are accepted"
expect clean shebang.mjs '#!/usr/bin/env node
console.log("hello");' \
  "a shebang line is not a syntax error"
expect clean cjs.js 'const path = require("node:path");
module.exports = { path };' \
  "a CommonJS .js file is accepted"
expect clean esm.js 'import path from "node:path";
console.log(path.sep);' \
  "an ESM .js file is accepted"
expect clean empty.mjs '' \
  "an empty module is accepted"

echo ""
echo "=== Part 3: relative imports are resolved, bare specifiers are not ==="

expect flagged missing-import.mjs 'import { classify } from "./gone.mjs";
console.log(classify);' \
  "an import of a file that does not exist is reported"
expect flagged missing-dynamic.mjs 'const m = await import("./also-gone.mjs");
console.log(m);' \
  "a dynamic import of a file that does not exist is reported"
expect flagged missing-reexport.mjs 'export { classify } from "./nowhere.mjs";' \
  "a re-export from a file that does not exist is reported"

printf 'export const classify = 1;\n' >"$WORK/present.mjs"
expect clean resolves.mjs 'import { classify } from "./present.mjs";
console.log(classify);' \
  "an import that resolves is not reported"
expect clean builtins.mjs 'import { readFileSync } from "node:fs";
import path from "node:path";
console.log(readFileSync, path);' \
  "node: builtins are not resolved against the filesystem"
expect clean bare.mjs 'import lychee from "lychee-runner";
console.log(lychee);' \
  "a bare package specifier is not resolved against the filesystem"
expect clean computed.mjs 'const name = "helpers.mjs";
const m = await import("./" + name);
console.log(m);' \
  "a specifier built at run time is left alone, as the header says"

echo ""
echo "=== Part 4: the check cannot pass by accident ==="

MISSING_OUT="$(bash "$CHECK" "$WORK/not-a-file.mjs" 2>&1)"
MISSING_RC=$?
if [ "$MISSING_RC" -ne 0 ] && printf '%s' "$MISSING_OUT" | grep -q 'Not a readable file'; then
  pass "a file that is not there is a finding, not a silent skip"
else
  fail "a file that is not there should be a finding (exit $MISSING_RC)"
  printf '%s\n' "$MISSING_OUT" | sed 's/^/    /'
fi

NONODE_OUT="$(PATH=/var/empty /bin/bash "$CHECK" 2>&1)"
NONODE_RC=$?
if [ "$NONODE_RC" -eq 2 ] && printf '%s' "$NONODE_OUT" | grep -q 'node is not on PATH'; then
  pass "no node on PATH exits 2 instead of reporting a clean tree"
else
  fail "no node on PATH should exit 2 (exit $NONODE_RC)"
  printf '%s\n' "$NONODE_OUT" | sed 's/^/    /'
fi

BADOPT_RC=0
bash "$CHECK" --nonsense >/dev/null 2>&1 || BADOPT_RC=$?
if [ "$BADOPT_RC" -eq 2 ]; then
  pass "an unknown option exits 2, not 0"
else
  fail "an unknown option should exit 2 (exit $BADOPT_RC)"
fi

printf 'console.log(1);\n' >"$WORK/quiet.mjs"
QUIET_OUT="$(cd "$WORK" && bash "$CHECK" quiet.mjs 2>&1)"
VERBOSE_OUT="$(cd "$WORK" && bash "$CHECK" --verbose quiet.mjs 2>&1)"
if printf '%s' "$QUIET_OUT" | grep -q '\[parse\]'; then
  fail "verbose mode is off by default"
else
  pass "verbose mode is off by default"
fi
if printf '%s' "$VERBOSE_OUT" | grep -q '\[parse\] quiet.mjs'; then
  pass "--verbose names each file as it is parsed"
else
  fail "--verbose should name each file as it is parsed"
  printf '%s\n' "$VERBOSE_OUT" | sed 's/^/    /'
fi
if printf '%s' "$VERBOSE_OUT" | grep -q '\[import\]'; then
  fail "--verbose reports an import this fixture does not have"
else
  pass "--verbose reports no import for a module that has none"
fi

echo ""
echo "=== Part 5: the repository itself ==="

SWEEP_OUT="$(cd "$ROOT" && bash "$CHECK" --verbose 2>&1)"
SWEEP_RC=$?
if [ "$SWEEP_RC" -eq 0 ]; then
  pass "every tracked JavaScript module in this repository parses"
else
  fail "the repository sweep failed (exit $SWEEP_RC)"
  printf '%s\n' "$SWEEP_OUT" | sed 's/^/    /'
fi

SWEEP_COUNT="$(printf '%s\n' "$SWEEP_OUT" | grep -c '\[parse\]')"
if [ "$SWEEP_COUNT" -ge 14 ]; then
  pass "the sweep reached $SWEEP_COUNT modules, so discovery is not empty"
else
  fail "the sweep only reached $SWEEP_COUNT modules; discovery looks broken"
fi

if printf '%s\n' "$SWEEP_OUT" | grep -q 'dev/log/'; then
  fail "the sweep should not read dev/log/, which holds other projects' sources"
else
  pass "dev/log/ is excluded, as the header says"
fi

for module in scripts/ci/recheck-broken-links.mjs scripts/language-tops/aggregate.mjs; do
  if printf '%s\n' "$SWEEP_OUT" | grep -qF "[parse] $module"; then
    pass "the sweep covers $module"
  else
    fail "the sweep missed $module"
  fi
done

REPRO_RC=0
bash "$ROOT/experiments/reproduce-issue121-mjs-syntax-gap.sh" >"$WORK/repro.log" 2>&1 || REPRO_RC=$?
if [ "$REPRO_RC" -eq 0 ]; then
  pass "the reproduction still holds: the shell gates pass a module that does not parse"
else
  fail "the reproduction exited $REPRO_RC"
  sed 's/^/    /' "$WORK/repro.log"
fi

echo ""
echo "=== Part 6: the gate runs in CI ==="

if grep -rqF 'check-mjs-syntax.sh' "$ROOT/.github/workflows"; then
  pass "check-mjs-syntax.sh is called by a workflow"
else
  fail "check-mjs-syntax.sh is not called by any workflow, so it checks nothing"
fi

if grep -rqF 'test-issue121-mjs-syntax.sh' "$ROOT/.github/workflows"; then
  pass "these fixtures run in CI too"
else
  fail "these fixtures are not called by any workflow"
fi

# ---------------------------------------------------------------------------
echo
echo "== The --list-inputs contract =="
#
# The discovered set, one repository-relative path per line, nothing else, exit
# 0. scripts/ci/check-workflow-path-coverage.mjs reads it to decide whether a
# workflow's `paths:` filter can be matched by the files this gate reads. A
# gate that answers this wrongly makes that check wrong in whichever direction
# the error points: paths the filter cannot match are reported as unreachable
# when they are fine, or - worse - the real inputs are never compared at all
# and a job that can never start goes on looking like a clean tree (issue #121).

CONTRACT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT_GATE="scripts/ci/check-mjs-syntax.sh"
CONTRACT_RC=0
CONTRACT_OUT="$(cd "$CONTRACT_ROOT" && bash "$CONTRACT_ROOT/$CONTRACT_GATE" --list-inputs 2>&1)" || CONTRACT_RC=$?

[ "$CONTRACT_RC" -eq 0 ] \
  && pass "--list-inputs exits 0" \
  || fail "--list-inputs exited $CONTRACT_RC"

CONTRACT_COUNT="$(printf '%s\n' "$CONTRACT_OUT" | grep -c .)"
[ "$CONTRACT_COUNT" -gt 0 ] \
  && pass "--list-inputs names $CONTRACT_COUNT input(s)" \
  || fail "--list-inputs named nothing, so the coverage check compares an empty set"

# Paths only: no banner, no count, no option echo, no blank line. Anything else
# here is read by the coverage gate as a file name and matched against `paths:`
# patterns, where it can only ever be a finding about a file that is not there.
CONTRACT_STRAY=""
while IFS= read -r contract_line; do
  if [ -z "$contract_line" ]; then
    CONTRACT_STRAY="(a blank line)"
    break
  fi
  case "$contract_line" in
    -*)
      CONTRACT_STRAY="$contract_line"
      break
      ;;
  esac
  if [ ! -f "$CONTRACT_ROOT/$contract_line" ]; then
    CONTRACT_STRAY="$contract_line"
    break
  fi
done <<<"$CONTRACT_OUT"
[ -z "$CONTRACT_STRAY" ] \
  && pass "every line is a repository-relative path that exists" \
  || fail "--list-inputs printed something that is not a tracked path" "$CONTRACT_STRAY"

CONTRACT_DUPES="$(printf '%s\n' "$CONTRACT_OUT" | sort | uniq -d)"
[ -z "$CONTRACT_DUPES" ] \
  && pass "and names each of them once" \
  || fail "--list-inputs repeats a path" "$CONTRACT_DUPES"

printf '%s\n' "$CONTRACT_OUT" | grep -qx -- 'scripts/ci/check-status-gate-covers-all-jobs.mjs' \
  && pass "and names scripts/ci/check-status-gate-covers-all-jobs.mjs, which this gate demonstrably reads" \
  || fail "--list-inputs omits scripts/ci/check-status-gate-covers-all-jobs.mjs"

# dev/log holds downloaded evidence and verbatim copies of other projects'
# files. They are not ours to fix, and every gate here excludes them.
printf '%s\n' "$CONTRACT_OUT" | grep -q '^dev/log/' \
  && fail "--list-inputs includes the vendored evidence tree" \
  || pass "and excludes dev/log, as the sweep itself does"

# `git ls-files` answers about the current directory. Run from a subdirectory
# it lists that subtree alone, with paths relative to it - so a gate that does
# not anchor at the top level first sweeps a fraction of the tree, exits 0 over
# it, and answers this contract with paths that no repository-root pattern can
# match. experiments/reproduce-issue121-subdirectory-discovery.sh measures it
# for every gate at once; this is the assertion for this one.
CONTRACT_SUB="$(cd "$CONTRACT_ROOT/scripts" && bash "$CONTRACT_ROOT/$CONTRACT_GATE" --list-inputs 2>&1)" || true
[ "$CONTRACT_SUB" = "$CONTRACT_OUT" ] \
  && pass "and gives the same answer from a subdirectory, being about the repository" \
  || fail "--list-inputs reports on whichever directory it is started from" \
    "$(printf '%s\n' "$CONTRACT_SUB" | head -3)"

echo ""
echo "Passed: $PASS, Failed: $FAIL"
[ "$FAIL" -eq 0 ]
