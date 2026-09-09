#!/usr/bin/env bash
# test-issue121-reclaim-large-packages.sh
#
# Issue #121: "Check for all false positives, false negatives, warnings and
# errors in CI/CD and fix them all."
#
# 28 of the warnings on release run 34293699247 - one per arm64 job, on a
# release where nothing was wrong - were a single line of
# jlumbroso/free-disk-space@v1.3.1 (action.yml:181):
#
#   sudo apt-get remove -y azure-cli google-chrome-stable firefox powershell \
#     mono-devel libgl1-mesa-dri --fix-missing \
#     || echo "::warning::The command [...] failed to complete successfully."
#
# Google publishes no arm64 apt repository, so on `ubuntu-24.04-arm` apt stops
# at the first unresolvable name and exits 100 *before removing anything*:
#
#   job-js-build-arm64-102285690839.log:1528  E: Unable to locate package google-chrome-stable
#   job-js-build-arm64-102285690839.log:1529  ##[warning]The command [sudo apt-get remove -y azure-cli ...] failed ...
#
# (both logs are committed gzipped under dev/log/issues/121/pulls/122/ci-logs/)
#
# The same step on the amd64 half of the same release removes all four packages
# that are present there and says nothing. So this is a warning that reports the
# *absence* of a package on an architecture that never had it - a false
# positive - and it costs the five packages that are installed on arm64, since
# apt aborted the batch.
#
# The fix asks dpkg first: scripts/ci/reclaim-large-packages.sh removes the
# packages matching the action's own patterns that are actually installed, so
# apt is handed only names that resolve. .github/actions/free-disk-space wraps
# the upstream action with `large-packages: false` and runs the script instead.
#
# What it asserts:
#   Part 1  the recorded evidence: what the two architectures did on 34293699247
#   Part 2  the script's selection, with dpkg and apt stubbed (no root, no apt)
#   Part 3  the script's reporting: silent when apt is happy, loud when it is not
#   Part 4  every workflow reclaims through the wrapper, and the wrapper's
#           contract with the upstream action still holds
#
# Usage: bash experiments/test-issue121-reclaim-large-packages.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SCRIPT="scripts/ci/reclaim-large-packages.sh"
WRAPPER=".github/actions/free-disk-space/action.yml"
UPSTREAM_PIN='jlumbroso/free-disk-space@54081f138730dfa15788a46383842cd2f914a1be'
EVIDENCE="dev/log/issues/121/pulls/122/ci-logs"
ARM_LOG="$EVIDENCE/job-js-build-arm64-102285690839.log.gz"
AMD_LOG="$EVIDENCE/job-js-build-amd64-102285690450.log.gz"

# The evidence is stored gzipped: .gitignore excludes *.log, and these two are
# 1.6 MB between them. dev/log/issues/115 set the precedent with
# release-33972074755.log.gz.
#
# Expanded into $TMP once rather than piped per assertion: under `pipefail` a
# `gzip -cd ... | grep -q` pipeline reports the SIGPIPE gzip takes when grep
# stops reading early, so every successful match would have read as a failure.
readlog() {
  local plain
  plain="$TMP/$(basename "${1%.gz}")"
  [ -f "$plain" ] || gzip -cd "$1" >"$plain" || return 1
  printf '%s' "$plain"
}

echo "=== Part 1: what the two architectures did on release run 34293699247 ==="
echo

# The evidence is committed, so this part is not "if the log happens to be
# here". A missing log is a failure: it is what the rest of the suite is a
# regression test *for*.
for log in "$ARM_LOG" "$AMD_LOG"; do
  if [ -f "$log" ]; then
    pass "the job log $(basename "$log") is committed as evidence"
  else
    fail "the job log $(basename "$log") is committed as evidence" "not found"
  fi
done

if [ -f "$ARM_LOG" ]; then
  ARM_PLAIN="$(readlog "$ARM_LOG")"
  if grep -q 'E: Unable to locate package google-chrome-stable' "$ARM_PLAIN"; then
    pass "arm64: apt could not locate google-chrome-stable"
  else
    fail "arm64: apt could not locate google-chrome-stable"
  fi

  # The runner's own annotation, not the step's echoed source: the echoed lines
  # carry the ANSI prefix the runner adds when it prints a step's script.
  ARM_WARNINGS="$(grep '##\[warning\]' "$ARM_PLAIN" | grep -vc '36;1m')"
  if [ "$ARM_WARNINGS" -eq 1 ]; then
    pass "arm64: the job's single warning is this one"
  else
    fail "arm64: the job's single warning is this one" \
      "$ARM_WARNINGS warning annotation(s) in the job"
  fi

  NAMED="$(grep '##\[warning\]' "$ARM_PLAIN" | grep -v '36;1m' \
    | grep -c 'sudo apt-get remove -y azure-cli google-chrome-stable firefox powershell mono-devel libgl1-mesa-dri')"
  if [ "$NAMED" -eq 1 ]; then
    pass "arm64: the warning names the action's fixed package list"
  else
    fail "arm64: the warning names the action's fixed package list" \
      "matched $NAMED time(s)"
  fi

  # apt exits before removing anything in the batch, so the five packages that
  # *are* installed on arm64 survive: the warning costs the reclaim as well as
  # the reader's attention.
  REMOVED_ARM="$(grep -cE 'Removing (azure-cli|firefox|google-chrome-stable|powershell|mono-devel|libgl1-mesa-dri) ' "$ARM_PLAIN")"
  if [ "$REMOVED_ARM" -eq 0 ]; then
    pass "arm64: apt aborted the batch and removed none of the six"
  else
    fail "arm64: apt aborted the batch and removed none of the six" \
      "$REMOVED_ARM of them were removed"
  fi
fi

if [ -f "$AMD_LOG" ]; then
  AMD_PLAIN="$(readlog "$AMD_LOG")"
  AMD_WARNINGS="$(grep '##\[warning\]' "$AMD_PLAIN" | grep -vc '36;1m')"
  if [ "$AMD_WARNINGS" -eq 0 ]; then
    pass "amd64: the identical step warned about nothing"
  else
    fail "amd64: the identical step warned about nothing" \
      "$AMD_WARNINGS warning annotation(s) in the job"
  fi

  REMOVED_AMD="$(grep -cE 'Removing (azure-cli|firefox|google-chrome-stable|powershell) ' "$AMD_PLAIN")"
  if [ "$REMOVED_AMD" -ge 4 ]; then
    pass "amd64: the same four packages were removed successfully"
  else
    fail "amd64: the same four packages were removed successfully" \
      "only $REMOVED_AMD removal line(s)"
  fi
fi

echo
echo "=== Part 2: the script selects what dpkg reports installed, nothing else ==="
echo

if [ -x "$SCRIPT" ] || [ -f "$SCRIPT" ]; then
  pass "$SCRIPT exists"
else
  fail "$SCRIPT exists"
  echo
  echo "=== Summary ==="
  echo "Passed: $PASS"
  echo "Failed: $FAIL"
  exit 1
fi

# A stub runner image: five of the action's targets installed, one of them
# (mono-devel) only half-removed, and google-chrome-stable absent exactly as it
# is on ubuntu-24.04-arm.
cat >"$TMP/dpkg-arm64.txt" <<'DPKG'
aspnetcore-runtime-8.0	installed
azure-cli	installed
bash	installed
dotnet-runtime-8.0	installed
firefox	installed
libapache2-mod-php8.3	installed
libgl1-mesa-dri	installed
llvm-18	installed
mono-devel	config-files
mysql-common	installed
powershell	installed
DPKG

run_script() {
  # $1 = the dpkg listing to serve, rest = environment assignments
  local listing="$1"
  shift
  env DPKG_QUERY="cat '$listing'" "$@" bash "$SCRIPT" 2>&1
}

OUT="$(run_script "$TMP/dpkg-arm64.txt" RECLAIM_DRY_RUN=1)"
PLAN="$(printf '%s\n' "$OUT" | sed -n 's/^\[reclaim\] removing [0-9]* installed package(s): //p')"

if [ -n "$PLAN" ]; then
  pass "the script prints the plan it would hand to apt"
else
  fail "the script prints the plan it would hand to apt" "$OUT"
fi

# The name that produced the warning is absent from the stub, so it must be
# absent from the plan. This is the whole fix in one assertion.
if ! printf '%s\n' "$PLAN" | grep -qw 'google-chrome-stable'; then
  pass "google-chrome-stable is not passed to apt when it is not installed"
else
  fail "google-chrome-stable is not passed to apt when it is not installed" "$PLAN"
fi

for pkg in azure-cli firefox powershell libgl1-mesa-dri; do
  if printf '%s\n' "$PLAN" | grep -qw "$pkg"; then
    pass "$pkg is selected: dpkg reports it installed"
  else
    fail "$pkg is selected: dpkg reports it installed" "$PLAN"
  fi
done

for pkg in aspnetcore-runtime-8.0 dotnet-runtime-8.0 llvm-18 libapache2-mod-php8.3 mysql-common; do
  if printf '%s\n' "$PLAN" | grep -qw "$pkg"; then
    pass "$pkg is selected: the action's regex patterns match it too"
  else
    fail "$pkg is selected: the action's regex patterns match it too" "$PLAN"
  fi
done

# `config-files` is dpkg's "removed, conffiles kept". Nothing is reclaimed by
# removing it again, and asking apt to is another chance at an exit code.
if ! printf '%s\n' "$PLAN" | grep -qw 'mono-devel'; then
  pass "a package in state config-files is not selected"
else
  fail "a package in state config-files is not selected" "$PLAN"
fi

if ! printf '%s\n' "$PLAN" | grep -qw 'bash'; then
  pass "a package matching no pattern is not selected"
else
  fail "a package matching no pattern is not selected" "$PLAN"
fi

if printf '%s\n' "$OUT" | grep -q 'RECLAIM_DRY_RUN=1, so nothing was removed'; then
  pass "RECLAIM_DRY_RUN=1 stops before apt"
else
  fail "RECLAIM_DRY_RUN=1 stops before apt" "$OUT"
fi

# The verbose mode exists so the next surprise can be diagnosed from a debug
# re-run rather than from a workflow edit - and it is off unless asked for.
if ! printf '%s\n' "$OUT" | grep -q 'pattern(s)'; then
  pass "the pattern-by-pattern selection is off by default"
else
  fail "the pattern-by-pattern selection is off by default" "$OUT"
fi

VOUT="$(run_script "$TMP/dpkg-arm64.txt" RECLAIM_DRY_RUN=1 BOX_VERBOSE=1)"
if printf '%s\n' "$VOUT" | grep -q '\^google-chrome-stable\$ -> (nothing installed)'; then
  pass "BOX_VERBOSE=1 names the pattern that matched nothing"
else
  fail "BOX_VERBOSE=1 names the pattern that matched nothing" "$VOUT"
fi

# Every pattern the upstream action removes must still be removed here, or the
# fix would be quietly reclaiming less disk than the action did.
UPSTREAM_NAMES='aspnetcore-.\* dotnet-.\* llvm-.\* php.\* mongodb-.\* mysql-.\* azure-cli google-chrome-stable firefox powershell mono-devel libgl1-mesa-dri google-cloud-sdk google-cloud-cli'
MISSING=""
for name in $UPSTREAM_NAMES; do
  grep -q "${name//\\/}" "$SCRIPT" || MISSING="$MISSING $name"
done
if [ -z "$MISSING" ]; then
  pass "all 14 of the upstream action's package patterns are covered"
else
  fail "all 14 of the upstream action's package patterns are covered" "missing:$MISSING"
fi

# An image with none of them installed - the far end of the same argument.
printf 'bash\tinstalled\ncoreutils\tinstalled\n' >"$TMP/dpkg-empty.txt"
OUT="$(run_script "$TMP/dpkg-empty.txt")"
if printf '%s\n' "$OUT" | grep -q 'nothing to remove'; then
  pass "an image with none of them installed calls no apt at all"
else
  fail "an image with none of them installed calls no apt at all" "$OUT"
fi
if ! printf '%s\n' "$OUT" | grep -q '::warning'; then
  pass "and says nothing to the runner while doing so"
else
  fail "and says nothing to the runner while doing so" "$OUT"
fi

echo
echo "=== Part 3: what the script reports to the runner ==="
echo

# A fake apt that succeeds, recording its argv so the assertion is about what
# apt was actually asked for rather than about what was printed.
cat >"$TMP/apt-ok" <<'APT'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$APT_LOG"
exit 0
APT
chmod +x "$TMP/apt-ok"

cat >"$TMP/apt-fail" <<'APT'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$APT_LOG"
[ "$1" = "remove" ] && exit 100
exit 0
APT
chmod +x "$TMP/apt-fail"

# Exported rather than passed through `env`, because run_script is a function.
export APT_LOG="$TMP/apt.log"
: >"$APT_LOG"
OUT="$(run_script "$TMP/dpkg-arm64.txt" APT_GET="$TMP/apt-ok")"

if ! printf '%s\n' "$OUT" | grep -q '::warning'; then
  pass "a successful reclaim produces no annotation"
else
  fail "a successful reclaim produces no annotation" "$OUT"
fi

REMOVE_ARGV="$(grep '^remove ' "$APT_LOG")"
if [ -n "$REMOVE_ARGV" ]; then
  pass "apt-get remove was called once"
else
  fail "apt-get remove was called once" "$(cat "$APT_LOG")"
fi
if ! printf '%s\n' "$REMOVE_ARGV" | grep -qw 'google-chrome-stable'; then
  pass "and its argv contains no name apt could fail to locate"
else
  fail "and its argv contains no name apt could fail to locate" "$REMOVE_ARGV"
fi
if printf '%s\n' "$REMOVE_ARGV" | grep -q -- '--fix-missing'; then
  pass "and it keeps the action's --fix-missing"
else
  fail "and it keeps the action's --fix-missing" "$REMOVE_ARGV"
fi
for step in autoremove clean; do
  if grep -q "^$step " "$APT_LOG"; then
    pass "apt-get $step still runs, as it does in the action"
  else
    fail "apt-get $step still runs, as it does in the action" "$(cat "$APT_LOG")"
  fi
done

: >"$APT_LOG"
OUT="$(run_script "$TMP/dpkg-arm64.txt" APT_GET="$TMP/apt-fail")"

# The warning is not removed, it is made meaningful: every name handed to apt
# was reported installed, so a failure now is a real one.
if printf '%s\n' "$OUT" | grep -q '::warning title=reclaim-large-packages'; then
  pass "an apt failure on installed packages still warns"
else
  fail "an apt failure on installed packages still warns" "$OUT"
fi
if [ -n "$OUT" ] && printf '%s\n' "$OUT" | grep -q 'real apt failure rather than an absent package'; then
  pass "and the warning says why it is worth reading"
else
  fail "and the warning says why it is worth reading" "$OUT"
fi

STATUS=0
env DPKG_QUERY="cat '$TMP/dpkg-arm64.txt'" APT_GET="$TMP/apt-fail" \
  bash "$SCRIPT" >/dev/null 2>&1 || STATUS=$?
if [ "$STATUS" -eq 0 ]; then
  pass "a failed reclaim does not fail the job: the build reports running out of disk"
else
  fail "a failed reclaim does not fail the job: the build reports running out of disk" \
    "exit status $STATUS"
fi

echo
echo "=== Part 4: every reclaim goes through the wrapper ==="
echo

if [ -f "$WRAPPER" ]; then
  pass "$WRAPPER exists"
else
  fail "$WRAPPER exists"
fi

DIRECT="$(grep -lF "uses: $UPSTREAM_PIN" .github/workflows/*.yml 2>/dev/null | tr '\n' ' ')"
if [ -z "$DIRECT" ]; then
  pass "no workflow calls the upstream action directly"
else
  fail "no workflow calls the upstream action directly" "still direct: $DIRECT"
fi

# Counted rather than listed, so a workflow added later cannot reintroduce the
# annotation by copying a step from before this change.
STEP_COUNT="$(grep -ch 'uses: \./\.github/actions/free-disk-space' .github/workflows/*.yml | awk '{s+=$1} END{print s+0}')"
NAMED_STEPS="$(grep -ch 'name: Free disk space' .github/workflows/*.yml | awk '{s+=$1} END{print s+0}')"
if [ "$STEP_COUNT" -gt 0 ] && [ "$STEP_COUNT" -eq "$NAMED_STEPS" ]; then
  pass "all $STEP_COUNT 'Free disk space' step(s) use the wrapper"
else
  fail "all 'Free disk space' step(s) use the wrapper" \
    "$NAMED_STEPS named step(s), $STEP_COUNT wrapper call(s)"
fi

if [ -f "$WRAPPER" ]; then
  if grep -qF "uses: $UPSTREAM_PIN" "$WRAPPER"; then
    pass "the wrapper still calls the upstream action, pinned to its v1.3.1 sha"
  else
    fail "the wrapper still calls the upstream action, pinned to its v1.3.1 sha"
  fi

  # The one input the wrapper does not pass through: this is what turns the
  # annotation off.
  if grep -qE "^\s*large-packages: 'false'" "$WRAPPER"; then
    pass "the wrapper switches the upstream large-packages block off"
  else
    fail "the wrapper switches the upstream large-packages block off"
  fi

  if grep -q 'reclaim-large-packages.sh' "$WRAPPER"; then
    pass "the wrapper runs the replacement script instead"
  else
    fail "the wrapper runs the replacement script instead"
  fi

  # A caller must read the same as it did against the action, or the fix would
  # be a silent change of reclaim policy at 15 call sites.
  UPSTREAM_INPUTS='tool-cache android dotnet haskell large-packages docker-images swap-storage'
  MISSING=""
  for input in $UPSTREAM_INPUTS; do
    grep -qE "^\s*$input:" "$WRAPPER" || MISSING="$MISSING $input"
  done
  if [ -z "$MISSING" ]; then
    pass "the wrapper accepts every input the upstream action does"
  else
    fail "the wrapper accepts every input the upstream action does" "missing:$MISSING"
  fi

  # tool-cache defaults to false upstream, everything else to true. A caller
  # that omits an input has to get the same answer from both.
  if grep -A3 -E "^  tool-cache:" "$WRAPPER" | grep -qE "default: 'false'"; then
    pass "tool-cache still defaults to false, as it does upstream"
  else
    fail "tool-cache still defaults to false, as it does upstream"
  fi

  # `uses: ./...` reads the action from the checkout, and the script it runs
  # comes from the same checkout, so both need one to have happened first.
  UNCHECKED=""
  for wf in .github/workflows/*.yml; do
    grep -q 'uses: \./\.github/actions/free-disk-space' "$wf" || continue
    grep -q 'uses: actions/checkout' "$wf" || UNCHECKED="$UNCHECKED $wf"
  done
  if [ -z "$UNCHECKED" ]; then
    pass "every workflow calling the wrapper also checks the repository out"
  else
    fail "every workflow calling the wrapper also checks the repository out" \
      "no checkout in:$UNCHECKED"
  fi
fi

# The two full-chain jobs reclaim differently on purpose (issue #119): the
# rewrite must not have flattened them into the default.
FULL_CHAIN="$(grep -cE '^\s+tool-cache: true' .github/workflows/pr-tests.yml)"
KEPT_SWAP="$(grep -cE '^\s+swap-storage: false' .github/workflows/pr-tests.yml)"
if [ "$FULL_CHAIN" -eq 2 ] && [ "$KEPT_SWAP" -eq 2 ]; then
  pass "the two full-chain jobs keep their tool-cache/swap-storage variant"
else
  fail "the two full-chain jobs keep their tool-cache/swap-storage variant" \
    "tool-cache: true x$FULL_CHAIN, swap-storage: false x$KEPT_SWAP"
fi

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
