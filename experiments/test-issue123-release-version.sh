#!/usr/bin/env bash
# Assertions for issue #123: a release must not name itself after a version
# nothing read.
#
# Eighteen steps across the six release workflows read the VERSION file by hand,
# and sixteen of them opened with the same two lines:
#
#   git pull origin main || true
#   VERSION=$(tr -d '[:space:]' < VERSION)
#
# The runner's default shell is `bash -e {0}`, so a *missing* VERSION file did
# fail the step - by accident, through the failed redirection. An empty or
# whitespace-only one did not fail anything: `tr` reads it, exits 0, prints
# nothing, and the step writes `version=` to $GITHUB_OUTPUT. Downstream that
# empty string is an image tag in thirteen jobs, and in the two that *bump* the
# version it is arithmetic - `IFS='.' read` of an empty string leaves MAJOR
# unset, `$((MAJOR + 1))` makes it 1, and the release publishes 1.0.0 over a
# repository that is on 2.9.0.
#
# The `|| true` was the other half. Every one of those jobs checks out with
# `ref: main`, resolved against the remote after apply-changesets has pushed the
# bump, so the pull could only ever bring in a commit pushed *after* the release
# started - which makes the late jobs of a release build and tag a different
# tree from the early ones, with nothing in the log to say so.
#
# scripts/release/release-version.sh is the one reader. These are the
# assertions that keep it the only one.
#
# Offline. No docker, no network, no git remote: every fixture is a temporary
# directory holding a VERSION file.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$REPO_ROOT/scripts/release/release-version.sh"
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
  # The detail is this helper's own output, which is made of `::error::` and
  # `::stop-commands::` - live workflow commands if this suite runs inside a
  # job. Defanged rather than bracketed, because a `::stop-commands::` in the
  # detail would mask the tokens of the block meant to contain it.
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

bool() { if "$@"; then echo true; else echo false; fi; }

# Run the executed form in a directory of our own, with the environment the
# runner would give it. OUT is stdout only - the contract every caller relies on
# - ERR is the log, STATUS the exit code.
OUT='' ERR='' STATUS=0
run_helper() { # run_helper <dir> [args...]
  local dir="$1"
  shift
  OUT="$(cd "$dir" && bash "$HELPER" "$@" 2>"$WORK/err")"
  STATUS=$?
  ERR="$(cat "$WORK/err")"
}

# The sourced form, which is what apply-changesets.sh uses.
run_sourced() { # run_sourced <dir> <function> [args...]
  local dir="$1"
  shift
  OUT="$(cd "$dir" && bash -c 'source "$1"; shift; "$@"' _ "$HELPER" "$@" 2>"$WORK/err")"
  STATUS=$?
  ERR="$(cat "$WORK/err")"
}

fixture() { # fixture <name> [content]  -> prints the directory
  local dir="$WORK/$1"
  mkdir -p "$dir"
  if [ "$#" -ge 2 ]; then printf '%s' "$2" >"$dir/VERSION"; fi
  printf '%s' "$dir"
}

check "scripts/release/release-version.sh exists" "$(bool test -f "$HELPER")"
check "and is executable" "$(bool test -x "$HELPER")"

echo
echo "== Part 1: what this repository calls a version =="

# The shape is narrow on purpose: two callers bump it with arithmetic, and
# `3.0.0-rc.1` would make PATCH the string `0-rc`. A reader that accepted a
# shape its consumers cannot use would move the failure away from its cause.
for good in 2.9.0 0.0.0 10.20.30 2026.9.10; do
  check "'$good' is a version" \
    "$(bool bash -c 'source "$1"; version_is_sane "$2"' _ "$HELPER" "$good")"
done
for bad in '' ' ' 2.9 v2.9.0 2.9.0.1 3.0.0-rc.1 'not a version' '2.9.0 ' 'latest' '-' '2.9.x'; do
  check "'$bad' is refused" \
    "$(if bash -c 'source "$1"; version_is_sane "$2"' _ "$HELPER" "$bad"; then echo false; else echo true; fi)"
done

echo
echo "== Part 2: read_version_file - the file, and only the file =="

D="$(fixture good '2.9.0
')"
run_sourced "$D" read_version_file VERSION
check "a sane VERSION file is read" "$([ "$STATUS" = 0 ] && [ "$OUT" = "2.9.0" ] && echo true || echo false)" "exit=$STATUS out=$OUT"

D="$(fixture empty '')"
run_sourced "$D" read_version_file VERSION
check "an EMPTY VERSION file is an error, not an empty version" "$(bool test "$STATUS" -ne 0)" "exit=$STATUS out=[$OUT]"
check "  and nothing is printed on stdout" "$(bool test -z "$OUT")" "out=[$OUT]"
check "  and the annotation says it is empty" "$(contains "$ERR" 'VERSION: is empty')" "$ERR"

D="$(fixture blank '   
	
')"
run_sourced "$D" read_version_file VERSION
check "a whitespace-only VERSION file is the same error" "$(bool test "$STATUS" -ne 0)" "exit=$STATUS"

D="$(fixture garbage 'v2.9.0')"
run_sourced "$D" read_version_file VERSION
check "a VERSION file that is not a version is an error" "$(bool test "$STATUS" -ne 0)" "exit=$STATUS"
check "  and the annotation quotes what it found" "$(contains "$ERR" "holds 'v2.9.0'")" "$ERR"

D="$(fixture missing)"
run_sourced "$D" read_version_file VERSION
check "a missing VERSION file is an error" "$(bool test "$STATUS" -ne 0)" "exit=$STATUS"
check "  and says so, rather than 'is empty'" "$(contains "$ERR" 'does not exist')" "$ERR"

# read_version_file does not consult PIPELINE_VERSION, so it must not name it:
# a reader sent to check a setting that was never asked is sent to the wrong
# place, which is the same defect one level up.
D="$(fixture empty2 '')"
OUT="$(cd "$D" && PIPELINE_VERSION=9.9.9 bash -c 'source "$1"; read_version_file VERSION' _ "$HELPER" 2>"$WORK/err")"
check "read_version_file ignores PIPELINE_VERSION" "$(bool test -z "$OUT")"
check "  and its annotation does not mention it" \
  "$([ "$(contains "$(cat "$WORK/err")" 'PIPELINE_VERSION')" = false ] && echo true || echo false)" "$(cat "$WORK/err")"

echo
echo "== Part 3: resolve_release_version - the pipeline's answer, cross-checked =="

D="$(fixture agree '2.9.0')"
run_helper "$D" --no-output
check "no PIPELINE_VERSION falls back to the file" "$([ "$STATUS" = 0 ] && [ "$OUT" = 2.9.0 ] && echo true || echo false)" "exit=$STATUS out=$OUT"

OUT="$(cd "$D" && PIPELINE_VERSION=2.9.0 bash "$HELPER" --no-output 2>"$WORK/err")"
STATUS=$?
ERR="$(cat "$WORK/err")"
check "agreement is silent" "$([ "$STATUS" = 0 ] && [ "$OUT" = 2.9.0 ] && echo true || echo false)" "exit=$STATUS out=$OUT"
check "  no warning when the two sources agree" \
  "$([ "$(contains "$ERR" '::warning')" = false ] && echo true || echo false)" "$ERR"

OUT="$(cd "$D" && PIPELINE_VERSION=3.0.0 bash "$HELPER" --no-output 2>"$WORK/err")"
STATUS=$?
ERR="$(cat "$WORK/err")"
check "disagreement is not fatal - the release still has a version" "$(bool test "$STATUS" -eq 0)" "exit=$STATUS"
check "  and the pipeline's version wins, so one run carries one tag" "$(bool test "$OUT" = 3.0.0)" "out=$OUT"
check "  and it is warned about, naming both" \
  "$([ "$(contains "$ERR" '::warning title=release-version')" = true ] \
    && [ "$(contains "$ERR" '2.9.0')" = true ] \
    && [ "$(contains "$ERR" '3.0.0')" = true ] && echo true || echo false)" "$ERR"

D="$(fixture pipeline-only '')"
OUT="$(cd "$D" && PIPELINE_VERSION=2.9.0 bash "$HELPER" --no-output 2>"$WORK/err")"
STATUS=$?
check "an unusable file with a usable PIPELINE_VERSION still resolves" \
  "$([ "$STATUS" = 0 ] && [ "$OUT" = 2.9.0 ] && echo true || echo false)" "exit=$STATUS out=$OUT"

D="$(fixture neither '')"
OUT="$(cd "$D" && PIPELINE_VERSION='' bash "$HELPER" --no-output 2>"$WORK/err")"
STATUS=$?
ERR="$(cat "$WORK/err")"
check "neither source usable is an error" "$(bool test "$STATUS" -ne 0)" "exit=$STATUS"
check "  and the annotation reports the state of BOTH sources" \
  "$([ "$(contains "$ERR" 'VERSION: is empty')" = true ] \
    && [ "$(contains "$ERR" 'PIPELINE_VERSION: not set')" = true ] && echo true || echo false)" "$ERR"

OUT="$(cd "$D" && PIPELINE_VERSION='not a version' bash "$HELPER" --no-output 2>"$WORK/err")"
STATUS=$?
ERR="$(cat "$WORK/err")"
check "a PIPELINE_VERSION that is not a version is refused, not tagged with" "$(bool test "$STATUS" -ne 0)" "exit=$STATUS"
check "  and is quoted back as it was written, spaces and all" \
  "$(contains "$ERR" "holds 'not a version'")" "$ERR"

echo
echo "== Part 4: the executed form is a workflow step =="

D="$(fixture step '2.9.0')"
: >"$WORK/gh-output"
OUT="$(cd "$D" && GITHUB_OUTPUT="$WORK/gh-output" PIPELINE_VERSION=2.9.0 bash "$HELPER" 2>"$WORK/err")"
STATUS=$?
check "it writes the step output" "$(bool grep -qx 'version=2.9.0' "$WORK/gh-output")" "$(cat "$WORK/gh-output")"
check "  under the key a caller can rename" "$(bool test "$STATUS" -eq 0)"
: >"$WORK/gh-output"
(cd "$D" && GITHUB_OUTPUT="$WORK/gh-output" bash "$HELPER" --output release_version >/dev/null 2>&1)
check "  --output names the key" "$(bool grep -qx 'release_version=2.9.0' "$WORK/gh-output")" "$(cat "$WORK/gh-output")"
: >"$WORK/gh-output"
(cd "$D" && GITHUB_OUTPUT="$WORK/gh-output" bash "$HELPER" --no-output >/dev/null 2>&1)
check "  --no-output writes nothing" "$(bool test ! -s "$WORK/gh-output")" "$(cat "$WORK/gh-output")"

# The whole point of a helper whose answer is captured: stdout is the answer and
# nothing else. The human-readable line goes to stderr, which on a runner is the
# same step log.
run_helper "$D" --no-output
check "stdout is exactly the version" "$(bool test "$OUT" = "2.9.0")" "out=[$OUT]"
check "  and the log line a reader looks for is on stderr" "$(contains "$ERR" 'Detected version: 2.9.0')" "$ERR"

D="$(fixture badfile '')"
: >"$WORK/gh-output"
(cd "$D" && GITHUB_OUTPUT="$WORK/gh-output" bash "$HELPER" >/dev/null 2>&1)
STATUS=$?
check "a step that cannot resolve a version fails" "$(bool test "$STATUS" -ne 0)" "exit=$STATUS"
check "  and writes no step output for the next step to use" "$(bool test ! -s "$WORK/gh-output")" "$(cat "$WORK/gh-output")"

run_helper "$WORK" --nonsense
check "an unknown argument is exit 2, not a guess" "$(bool test "$STATUS" -eq 2)" "exit=$STATUS"

D="$(fixture elsewhere)"
mkdir -p "$D/sub"
printf '2.9.0' >"$D/sub/V"
run_helper "$D" --file sub/V --no-output
check "--file reads the file it is given" "$([ "$STATUS" = 0 ] && [ "$OUT" = 2.9.0 ] && echo true || echo false)" "exit=$STATUS out=$OUT"

echo
echo "== Part 5: the verbose switch, and its default =="

D="$(fixture verbose '2.9.0')"
run_helper "$D" --no-output
check "the trace is off by default" \
  "$([ "$(contains "$ERR" '[release-version]')" = false ] && echo true || echo false)" "$ERR"
OUT="$(cd "$D" && BOX_VERBOSE=1 PIPELINE_VERSION=2.9.0 bash "$HELPER" --no-output 2>"$WORK/err")"
ERR="$(cat "$WORK/err")"
check "BOX_VERBOSE=1 says which source was believed" "$(contains "$ERR" "using the pipeline's version 2.9.0")" "$ERR"
check "  and it does not contaminate stdout" "$(bool test "$OUT" = 2.9.0)" "out=[$OUT]"
OUT="$(cd "$D" && RELEASE_VERSION_VERBOSE=1 bash "$HELPER" --no-output 2>"$WORK/err")"
check "RELEASE_VERSION_VERBOSE=1 is the same switch" "$(contains "$(cat "$WORK/err")" '[release-version]')" "$(cat "$WORK/err")"

echo
echo "== Part 6: the wiring - every version step goes through the reader =="

WORKFLOWS=(release.yml release-js.yml release-essentials.yml release-languages.yml release-full.yml release-dind.yml)
for w in "${WORKFLOWS[@]}"; do
  check "$w has no hand-rolled VERSION read left" \
    "$(if grep -q "tr -d '\[:space:\]' < VERSION" "$REPO_ROOT/.github/workflows/$w"; then echo false; else echo true; fi)" \
    "$(grep -n "tr -d '\[:space:\]' < VERSION" "$REPO_ROOT/.github/workflows/$w")"
done

# The pull that could only ever bring in somebody else's later commit. The one
# survivor is release.yml's "Fetch latest changes", which runs *before* the
# version is read, is guarded by `version_bumped`, and already has no `|| true`.
# `awk -F: '$3 !~ ...'` drops comment lines: the fix's own explanation in
# release.yml quotes the line it removed, and a sweep for code that runs must
# not be satisfiable - in either direction - by prose about it.
SWALLOWED="$(cd "$REPO_ROOT" && git grep -n 'git pull origin main || true' -- .github/ scripts/ 2>/dev/null \
  | awk -F: '$3 !~ /^[[:space:]]*#/' || true)"
check "no release step swallows the result of a pull" \
  "$(bool test -z "$SWALLOWED")" "found: $SWALLOWED"

for w in release-js.yml release-essentials.yml release-languages.yml release-full.yml release-dind.yml; do
  STEPS="$(grep -c 'run: bash scripts/release/release-version.sh' "$REPO_ROOT/.github/workflows/$w")"
  HANDED="$(grep -c "PIPELINE_VERSION: \${{ fromJSON(inputs.changes)\['version'\] }}" "$REPO_ROOT/.github/workflows/$w")"
  check "$w: every version step is handed the pipeline's answer ($STEPS steps)" \
    "$([ "$STEPS" -gt 0 ] && [ "$STEPS" = "$HANDED" ] && echo true || echo false)" \
    "steps=$STEPS handed=$HANDED"
done

# The chain the fifteen build steps depend on: detect-changes must publish the
# version as a job output, and each call site must hand the whole output map to
# the called workflow. Break either and `fromJSON(inputs.changes)['version']` is
# an empty string, and every build job silently falls back to its own checkout.
REL="$REPO_ROOT/.github/workflows/release.yml"
check "detect-changes publishes the version as a job output" \
  "$(bool grep -qE '^ +version: \$\{\{ steps\.version\.outputs\.version \}\}$' "$REL")"
# Not a count - a count passes while the map is handed to the wrong five. Each
# call site is checked where it is: the `with:` block that follows the `uses:`
# line of that workflow.
for called in release-js release-essentials release-languages release-full release-dind; do
  BLOCK="$(grep -A 4 "uses: ./.github/workflows/${called}.yml" "$REL")"
  check "the ${called} call site is handed detect-changes' outputs" \
    "$(contains "$BLOCK" 'changes: ${{ toJSON(needs.detect-changes.outputs) }}')" "$BLOCK"
done
check "create-release is handed it too, so the notes and the images agree" \
  "$(bool grep -q 'PIPELINE_VERSION: ${{ needs.detect-changes.outputs.version }}' "$REL")"

check "apply-changesets.sh sources the reader" \
  "$(bool grep -q 'source "$(dirname "${BASH_SOURCE\[0\]}")/release-version.sh"' "$REPO_ROOT/scripts/release/apply-changesets.sh")"
check "  and reads VERSION through it" \
  "$(bool grep -q 'read_version_file "$VERSION_FILE"' "$REPO_ROOT/scripts/release/apply-changesets.sh")"

# The sweep that stops a nineteenth site being added. `git-push-with-retry.sh`
# is the one exemption and it is named here rather than pattern-matched: it uses
# VERSION as a *label* for a pull request branch and already falls back to the
# string "automation", so an unreadable file there costs a nice branch name and
# not a wrong release.
RAW="$(cd "$REPO_ROOT" && git grep -nE "(cat|tr)[^|]*(<[[:space:]]*VERSION|VERSION[[:space:]]*\|)" -- \
  ':!scripts/release/release-version.sh' ':!scripts/release/git-push-with-retry.sh' \
  ':!experiments/*' ':!dev/log/*' ':!docs/*' ':!*.md' 2>/dev/null \
  | awk -F: '$3 !~ /^[[:space:]]*#/' || true)"
check "no tracked file reads the VERSION file by hand" "$(bool test -z "$RAW")" "found: $RAW"
check "the one exemption still exists and still has its fallback" \
  "$(bool grep -q 'LABEL="${LABEL:-automation}"' "$REPO_ROOT/scripts/release/git-push-with-retry.sh")"

# The helper is now run from 18 steps in 17 jobs, none of which write to the remote,
# and check-checkout-credentials.mjs classifies a job by following every
# `scripts/...` string in its closure. A path spelled in text this helper merely
# *prints* is followed exactly like a call: naming apply-changesets.sh by path
# in the error message made all 17 look like pushers and demanded they keep a
# credential none of them uses. Pinned here because the failure surfaces 17
# files away from the line that causes it.
PATHS="$(grep -n 'scripts/' "$HELPER" | awk -F: '$2 !~ /^[[:space:]]*#/' || true)"
check "the helper names no scripts/ path outside a comment" \
  "$(bool test -z "$PATHS")" "found: $PATHS"
check "  so the jobs that run it are still classified as non-writers" \
  "$(bool bash -c 'cd "$1" && node scripts/ci/check-checkout-credentials.mjs >/dev/null 2>&1' _ "$REPO_ROOT")"

echo
echo "== Part 7: mutations - each one puts the old defect back =="

# Restoring the pre-fix read: does an empty VERSION file really pass?
MUT="$WORK/mutant"
mkdir -p "$MUT"
printf '' >"$MUT/VERSION"
# Quoted heredoc on purpose: $GITHUB_OUTPUT must reach the generated script as
# literal text, because the point is to run the step the way the runner ran it,
# with the value supplied in the environment below. The `:?` line is the
# harness's, not the step's - check-heredoc-vars.sh asks for it so that a caller
# who forgets the variable gets a named failure instead of `>> ""`. The two
# lines under it are the pre-fix step byte for byte.
cat >"$MUT/old-step.sh" <<'OLD'
set -e
: "${GITHUB_OUTPUT:?must be passed in by the test harness}"
VERSION=$(tr -d '[:space:]' < VERSION)
echo "version=$VERSION" >> "$GITHUB_OUTPUT"
OLD
: >"$WORK/gh-output"
(cd "$MUT" && GITHUB_OUTPUT="$WORK/gh-output" bash old-step.sh) >/dev/null 2>&1
STATUS=$?
check "the pre-fix read exits 0 on an empty VERSION file" "$(bool test "$STATUS" -eq 0)" "exit=$STATUS"
check "  and hands the next step an empty version" \
  "$(bool grep -qx 'version=' "$WORK/gh-output")" "$(cat "$WORK/gh-output")"
run_helper "$MUT" --no-output
check "  where the reader refuses" "$(bool test "$STATUS" -ne 0)" "exit=$STATUS"

# And the arithmetic that turns that empty string into a published 1.0.0.
BUMPED="$(bash -c 'IFS="." read -r MAJOR MINOR PATCH <<< ""; MAJOR=$((MAJOR + 1)); echo "$MAJOR.0.0"')"
check "the bump arithmetic turns an empty version into $BUMPED" "$(bool test "$BUMPED" = 1.0.0)" "got=$BUMPED"

# Two mutations of the helper, because the empty case is guarded twice and the
# difference between the two guards is worth pinning.
#
# Loosening the *pattern* to match anything does not reopen the hole: an empty
# string then satisfies version_is_sane, but resolve_release_version still has
# nothing to print and says so. That is defence in depth rather than an
# accident, and this assertion is what would notice if it stopped being true.
sed 's/\^\[0-9\]+\\\.\[0-9\]+\\\.\[0-9\]+\$/^.*$/' "$HELPER" >"$WORK/loose.sh"
check "the pattern mutation applied" \
  "$(bool grep -q '=~ \^\.\*\$' "$WORK/loose.sh")" "$(grep -n 'version_is_sane()' -A 2 "$WORK/loose.sh")"
D="$(fixture loose '')"
LOOSE_OUT="$(cd "$D" && bash "$WORK/loose.sh" --no-output 2>/dev/null)"
LOOSE_STATUS=$?
check "  loosening the pattern alone does NOT let an empty version through" \
  "$(bool test "$LOOSE_STATUS" -ne 0)" "exit=$LOOSE_STATUS out=[$LOOSE_OUT]"

# Removing the emptiness guard does, and this is the assertion that proves the
# suite can see the defect at all: without it, "the empty file is refused" would
# be a claim no failing case supports.
sed 's/^  if \[ -z "\$from_file" \] \&\& \[ -z "\$from_pipeline" \]; then$/  if false; then/' \
  "$HELPER" >"$WORK/unguarded.sh"
check "the guard mutation applied" \
  "$(bool grep -q '^  if false; then$' "$WORK/unguarded.sh")" "$(grep -n 'if false; then' "$WORK/unguarded.sh")"
UNG_OUT="$(cd "$D" && bash "$WORK/unguarded.sh" --no-output 2>/dev/null)"
UNG_STATUS=$?
check "  removing the emptiness guard publishes the empty version again" \
  "$([ "$UNG_STATUS" = 0 ] && [ -z "$UNG_OUT" ] && echo true || echo false)" "exit=$UNG_STATUS out=[$UNG_OUT]"

echo
echo "== ${PASS} passed, ${FAIL} failed =="
[ "$FAIL" -eq 0 ]
