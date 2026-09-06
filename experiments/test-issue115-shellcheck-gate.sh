#!/usr/bin/env bash
# test-issue115-shellcheck-gate.sh
#
# Issue #115: nothing linted the repository's own shell scripts.
#
# actionlint bundles shellcheck, but it only applies it to the `run:` blocks
# inside .github/workflows/**. The 75 tracked *.sh files that build, measure and
# release the boxes had no linter at all, and ten findings were sitting in the
# tree when the gate was added - among them `for installed in $(ls -1 ...)` in
# both ubuntu/24.04/js/install.sh and ubuntu/24.04/java/install.sh, feeding a
# word-split version name straight to `nvm uninstall` / `sdk uninstall`.
#
# A gate is only worth having if it fails on the defects it claims to catch, so
# this suite checks the runner against fixtures of each class that was actually
# found, and against a clean script, before trusting its verdict on the repo.
#
# Usage: bash experiments/test-issue115-shellcheck-gate.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

RUNNER="scripts/ci/run-shellcheck.sh"
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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Assertions below match $OUT with bash's own == / =~ instead of piping it
# into grep: a pipeline forks, and a fork that fails under load (this suite
# runs beside docker builds) reports "the gate did not catch SC2045" when the
# gate caught it - a false positive of exactly the kind issue #115 is about.
# run_on FILE - lint a single file, capturing combined output in $OUT.
OUT=""
run_on() {
  OUT="$(bash "$RUNNER" "$1" 2>&1)"
}

echo "== Part 1: the runner exists and is itself clean =="

if [ -x "$RUNNER" ]; then
  pass "$RUNNER is executable"
else
  fail "$RUNNER is executable"
fi

if run_on "$RUNNER"; then
  pass "the runner passes its own check"
else
  fail "the runner passes its own check"
  echo "$OUT" | sed 's/^/      /' >&2
fi

echo ""
echo "== Part 2: false-negative fixtures - each defect class must fail =="

# One fixture per class of finding that was actually present in this repository
# before the gate existed, named by its shellcheck code.
declare -a FIXTURES=(
  "SC2045|iterating over ls output|"'for f in $(ls -1 /tmp); do echo "$f"; done'
  "SC2010|ls piped into grep|"'echo "$(ls -1 /tmp | grep -v "^current$" | head -n1)"'
  "SC2064|trap expanded at install time|"'d=$(mktemp -d); trap "rm -rf $d" EXIT'
  "SC2155|declare and assign masking a return value|"'f() { local v=$(false); echo "$v"; }'
  "SC2034|unused variable|"'UNUSED_ON_PURPOSE=1'
)

for fixture in "${FIXTURES[@]}"; do
  code="${fixture%%|*}"
  rest="${fixture#*|}"
  label="${rest%%|*}"
  body="${rest#*|}"
  file="$TMP/fixture-${code}.sh"
  printf '#!/usr/bin/env bash\n%s\n' "$body" >"$file"

  if run_on "$file"; then
    fail "$code ($label) is rejected"
  elif [[ "$OUT" == *"[$code]"* ]]; then
    pass "$code ($label) is rejected"
  else
    fail "$code ($label) is rejected with the expected code"
    echo "$OUT" | sed 's/^/      /' >&2
  fi
done

echo ""
echo "== Part 3: false-positive fixture - correct shell must pass =="

# The corrected form of every fixture above, written the way the repository
# now writes it.
cat >"$TMP/clean.sh" <<'CLEAN'
#!/usr/bin/env bash
set -euo pipefail
d="$(mktemp -d)"
trap 'rm -rf "$d"' EXIT
newest() {
  local root="$1" entry name
  [ -d "$root" ] || return 0
  for entry in "$root"/*; do
    [ -d "$entry" ] || continue
    name="$(basename "$entry")"
    printf '%s\n' "$name"
  done
}
first="$(newest /tmp | head -n1)"
echo "$first"
CLEAN

if run_on "$TMP/clean.sh"; then
  pass "the corrected form of every fixture passes"
else
  fail "the corrected form of every fixture passes"
  echo "$OUT" | sed 's/^/      /' >&2
fi

echo ""
echo "== Part 4: findings are reported as GitHub annotations =="

run_on "$TMP/fixture-SC2045.sh"
if [[ "$OUT" =~ (^|$'\n')::error\ file=[^,]+,line=[0-9]+,col=[0-9]+:: ]]; then
  pass "each finding is emitted as ::error file=...,line=...,col=..."
else
  fail "each finding is emitted as ::error file=...,line=...,col=..."
  echo "$OUT" | sed 's/^/      /' >&2
fi

if [[ "$OUT" == *"Reproduce locally with: bash scripts/ci/run-shellcheck.sh"* ]]; then
  pass "the failure message names the command that reproduces it"
else
  fail "the failure message names the command that reproduces it"
fi

echo ""
echo "== Part 5: the file set is discovered, not listed =="

LISTED="$(bash "$RUNNER" --list)"
# The same discovery the runner performs: tracked plus untracked-but-not-ignored,
# so a script that is written but not yet committed is linted rather than first
# failing in CI.
EXPECTED="$(git ls-files --cached --others --exclude-standard --deduplicate '*.sh' \
  | grep -vc '^dev/log/')"
LISTED_COUNT="$(printf '%s\n' "$LISTED" | grep -c .)"

if [ "$LISTED_COUNT" = "$EXPECTED" ]; then
  pass "every tracked or newly added *.sh outside dev/log/ is listed ($EXPECTED file(s))"
else
  fail "every tracked or newly added *.sh outside dev/log/ is listed (listed $LISTED_COUNT, expected $EXPECTED)"
fi

if printf '%s\n' "$LISTED" | grep -q '^dev/log/'; then
  fail "vendored evidence under dev/log/ is excluded"
else
  pass "vendored evidence under dev/log/ is excluded"
fi

# Discovery is the point: a suite that hardcodes filenames stops covering the
# next script somebody adds. Spot-check the three trees that matter.
for expected in scripts/ci/run-shellcheck.sh ubuntu/24.04/common.sh experiments/test-issue115-registry-split.sh; do
  if printf '%s\n' "$LISTED" | grep -qx "$expected"; then
    pass "$expected is covered"
  else
    fail "$expected is covered"
  fi
done

echo ""
echo "== Part 6: the repository is clean today =="

if OUT="$(bash "$RUNNER" 2>&1)"; then
  pass "every tracked shell script passes shellcheck --severity=warning"
else
  fail "every tracked shell script passes shellcheck --severity=warning"
  echo "$OUT" | sed 's/^/      /' >&2
fi

echo ""
echo "================================"
echo "Passed: $PASS"
echo "Failed: $FAIL"
echo "================================"
[ "$FAIL" -eq 0 ]
