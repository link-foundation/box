#!/usr/bin/env bash
#
# Regression test for root cause RC-1 of issue #115:
#   "Check for all false positives, false negatives, warnings and errors in
#    CI/CD and fix them all."
#
# Reproduction (run 33972074753, "Measure Disk Space and Update README", on main
# at commit 42be663, 2026-09-05 14:31): the job died with
#
#     /tmp/box-measure.sh: line 128: NODE_MAJOR: unbound variable
#
# scripts/measure-disk-space.sh resolves NODE_MAJOR, NVM_INSTALL_VERSION and
# JAVA_MAJOR in the parent shell and then writes /tmp/box-measure.sh from a
# heredoc whose delimiter is QUOTED (<< 'EOF_BOX'). Quoting suppresses every
# expansion, so the generated file holds the literal characters $NODE_MAJOR, and
# it is executed with `su - box` / `sudo -i -u box`, i.e. a login shell that does
# not inherit the parent's non-exported variables. The generated script sets
# `set -euo pipefail` itself, so the first reference aborts the run.
#
# The same three variables are written the same way a SECOND time, in
# scripts/ubuntu-24-server-install.sh — a script no CI job exercises, so the bug
# was invisible there. Both sites are covered here.
#
# Part 1 reproduces the mechanism from scratch, independent of this repository,
#        so the failure mode is demonstrable and not merely asserted.
# Part 2 exercises scripts/ci/check-heredoc-vars.sh against fixtures: it must
#        catch the bug, and — just as important for an issue about false
#        positives — must NOT flag text the shell would never expand.
# Part 3 asserts the real tree is clean and that both scripts now pass the
#        values in explicitly and assert them.
# Part 4 covers the verbose/debug mode added under this issue: it must reach the
#        generated script, and it must change nothing when it is not asked for.
#
# Exit non-zero on the first failed assertion.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/ci/check-heredoc-vars.sh"

[ -f "$CHECK" ] || {
  echo "ERR: $CHECK not found" >&2
  exit 1
}

pass=0
fail=0

ok() {
  echo "  ok: $1"
  pass=$((pass + 1))
}
bad() {
  echo "  FAIL: $1" >&2
  fail=$((fail + 1))
}

check() {
  local label="$1" expected="$2" got="$3"
  if [ "$expected" = "$got" ]; then
    ok "$label"
  else
    bad "$label — expected [$expected], got [$got]"
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# =============================================================================
echo "=== Part 1: the failure mode, reproduced from scratch ==="
# =============================================================================
# A minimal stand-in for measure-disk-space.sh: resolve a version, generate a
# script from a quoted heredoc, run it in an environment that does not carry the
# parent's variables. `env -i` is the reproducible stand-in for `su - box`,
# which likewise starts from a fresh environment.

# heredoc-vars: ignore — this generator is the bug, reproduced on purpose.
cat >"$TMP/broken-generator.sh" <<'GEN'
set -euo pipefail
NODE_MAJOR="24"
cat > "$TMPDIR_T/generated.sh" << 'EOF_BOX'
set -euo pipefail
echo "installing node ${NODE_MAJOR}"
EOF_BOX
env -i bash "$TMPDIR_T/generated.sh"
GEN

set +e
out="$(TMPDIR_T="$TMP" bash "$TMP/broken-generator.sh" 2>&1)"
rc=$?
set -e

check "the quoted heredoc makes the generated script fail" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
if grep -q 'NODE_MAJOR: unbound variable' <<<"$out"; then
  ok "it fails with exactly the CI error: NODE_MAJOR: unbound variable"
else
  bad "expected 'NODE_MAJOR: unbound variable', got: $out"
fi
if grep -qF '${NODE_MAJOR}' "$TMP/generated.sh"; then
  ok "the generated file kept the literal text \${NODE_MAJOR} instead of the value 24"
else
  bad "generated file did not keep the literal reference: $(cat "$TMP/generated.sh")"
fi

# The fix: pass the value in across the environment boundary, and assert it.
# heredoc-vars: ignore — a fixture; its own inner heredoc is the fixed form.
cat >"$TMP/fixed-generator.sh" <<'GEN'
set -euo pipefail
NODE_MAJOR="24"
cat > "$TMPDIR_T/generated-fixed.sh" << 'EOF_BOX'
set -euo pipefail
: "${NODE_MAJOR:?must be passed in by the parent script}"
echo "installing node ${NODE_MAJOR}"
EOF_BOX
env -i NODE_MAJOR="$NODE_MAJOR" bash "$TMPDIR_T/generated-fixed.sh"
GEN

set +e
out="$(TMPDIR_T="$TMP" bash "$TMP/fixed-generator.sh" 2>&1)"
rc=$?
set -e
check "passing the value in explicitly fixes it (exit code)" "0" "$rc"
check "and the value actually arrives" "installing node 24" "$out"

# And the assertion has to be worth having: omit the value, get a named error.
set +e
out="$(env -i bash "$TMP/generated-fixed.sh" 2>&1)"
rc=$?
set -e
check "omitting it still fails (a fix must not silently install the wrong version)" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
if grep -q 'must be passed in by the parent script' <<<"$out"; then
  ok "and fails with a named, actionable message instead of a bare line number"
else
  bad "expected the :? message, got: $out"
fi

# =============================================================================
echo ""
echo "=== Part 2: the checker catches it, and only it ==="
# =============================================================================

run_check() { # run_check FIXTURE -> prints findings, sets $rc
  set +e
  check_out="$("$CHECK" "$1" 2>&1 | grep -v '^::')"
  rc=$?
  set -e
}

# --- must be caught ----------------------------------------------------------
# heredoc-vars: ignore — this fixture has to contain the bug to prove the
# checker finds it; the assertions below are what verify it.
cat >"$TMP/case-broken.sh" <<'FIX'
cat > /tmp/out.sh << 'EOF'
echo "${NODE_MAJOR}"
echo "$JAVA_MAJOR"
EOF
FIX
run_check "$TMP/case-broken.sh"
check "flags a leaked \${NODE_MAJOR}" "1" "$(grep -c 'NODE_MAJOR is expanded' <<<"$check_out" || true)"
check "flags a leaked \$JAVA_MAJOR" "1" "$(grep -c 'JAVA_MAJOR is expanded' <<<"$check_out" || true)"
check "and exits non-zero" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

# --- must NOT be caught (false positives are the subject of this issue) ------
# heredoc-vars: ignore — a fixture, checked explicitly via run_check below.
cat >"$TMP/case-clean.sh" <<'FIX'
cat > /tmp/out.sh << 'EOF'
# assigned in the body
NODE_MAJOR="24"
echo "$NODE_MAJOR"
# asserted as an intentional injection
: "${JAVA_MAJOR:?must be passed in}"
echo "$JAVA_MAJOR"
# unset-tolerant forms cannot abort under set -u
echo "${MAYBE:-default}" "${OTHER:+set}" "${THIRD-d}"
# a standard environment variable the login shell sets itself
echo "$HOME/$USER"
# single-quoted text is never expanded: this is a sed pattern, not a reference
sed -i 's/\$PERLBREW_LIB/${PERLBREW_LIB:-}/g' /etc/bashrc
sed -i 's/\$outsep/${outsep:-}/g' /etc/bashrc
# escaped, so literal
echo "\$NOT_A_REFERENCE"
# a comment mentioning $ALSO_NOT_A_REFERENCE
for item in a b; do echo "$item"; done
read -r line < /etc/hostname && echo "$line"
EOF
FIX
run_check "$TMP/case-clean.sh"
check "no false positive on a clean generated script" "0" "$rc"
check "  (and reports nothing at all)" "" "$(grep 'is expanded' <<<"$check_out" || true)"

# The exact false positives that the first draft of this checker produced, kept
# as fixtures so they cannot come back.
for name in PERLBREW_LIB outsep NOT_A_REFERENCE ALSO_NOT_A_REFERENCE MAYBE HOME; do
  check "  never flags $name" "0" "$(grep -c "$name is expanded" <<<"$check_out" || true)"
done

# An exported variable DOES survive into a plain child process, so the stub-script
# pattern used by experiments/test-issue112-supersede.sh is legitimate.
# heredoc-vars: ignore — a fixture, checked explicitly via run_check below.
cat >"$TMP/case-exported.sh" <<'FIX'
export STUB_CALLS="/tmp/calls.txt"
cat > /tmp/out.sh << 'EOF'
echo "$STUB_CALLS"
EOF
bash /tmp/out.sh
FIX
run_check "$TMP/case-exported.sh"
check "an exported variable read by a plain child process is not a leak" "0" "$rc"

# ...but it does NOT survive su -/sudo -i/env -i/ssh, which is the RC-1 shape.
# heredoc-vars: ignore — a fixture, checked explicitly via run_check below.
cat >"$TMP/case-exported-barrier.sh" <<'FIX'
export STUB_CALLS="/tmp/calls.txt"
cat > /tmp/out.sh << 'EOF'
echo "$STUB_CALLS"
EOF
su - box -c "bash /tmp/out.sh"
FIX
run_check "$TMP/case-exported-barrier.sh"
check "but exporting is not enough across su - (the environment is reset)" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
if grep -q 'environment barrier' <<<"$check_out"; then
  ok "and the message names the barrier rather than blaming the export"
else
  bad "expected the finding to mention the environment barrier, got: $check_out"
fi

# A quoted heredoc that is not a script may contain anything.
# heredoc-vars: ignore — a fixture, checked explicitly via run_check below.
cat >"$TMP/case-prose.sh" <<'FIX'
cat > /tmp/README.md << 'EOF'
Set $NODE_MAJOR before running.
EOF
cat > /tmp/config.json << 'EOF'
{"path": "$HOME/$UNRESOLVED"}
EOF
FIX
run_check "$TMP/case-prose.sh"
check "does not police prose or JSON heredocs" "0" "$rc"

# An UNquoted heredoc expands in the parent, which is the working pattern.
# heredoc-vars: ignore — a fixture, checked explicitly via run_check below.
cat >"$TMP/case-unquoted.sh" <<'FIX'
NODE_MAJOR=24
cat > /tmp/out.sh << EOF
echo "${NODE_MAJOR}"
EOF
FIX
run_check "$TMP/case-unquoted.sh"
check "does not flag an unquoted heredoc (it expands at write time)" "0" "$rc"

# =============================================================================
echo ""
echo "=== Part 3: the real tree ==="
# =============================================================================

set +e
tree_out="$("$CHECK" 2>&1 | grep -v '^::')"
tree_rc=$?
set -e
if [ "$tree_rc" -eq 0 ]; then
  ok "no variable leaks out of a quoted heredoc anywhere in the repository"
else
  bad "the repository still leaks variables out of quoted heredocs:"
  grep 'is expanded' <<<"$tree_out" | sed 's/^/      /' >&2
fi

# Both sites, explicitly — RC-1 exists twice, and a fix to one is not a fix.
for rel in scripts/measure-disk-space.sh scripts/ubuntu-24-server-install.sh; do
  f="$ROOT/$rel"
  [ -f "$f" ] || {
    bad "$rel is missing"
    continue
  }

  for var in NODE_MAJOR NVM_INSTALL_VERSION JAVA_MAJOR; do
    if grep -qE "^[[:space:]]*: \"\\\$\{$var:\?" "$f"; then
      ok "$rel asserts $var inside the generated script"
    else
      bad "$rel does not assert $var with : \"\${$var:?...}\""
    fi
  done

  # The assertion is only half of it: the parent must actually pass the values
  # across the su/sudo boundary that discards them.
  invocations="$(grep -nE '(su - box|sudo -i -u box)' "$f" | grep -E 'box-(measure|user-setup)\.sh' || true)"
  if [ -z "$invocations" ]; then
    bad "$rel: could not find the invocation of the generated script"
  else
    missing=""
    while IFS= read -r line; do
      for var in NODE_MAJOR NVM_INSTALL_VERSION JAVA_MAJOR; do
        grep -q "$var=" <<<"$line" || missing="$missing $var@line${line%%:*}"
      done
    done <<<"$invocations"
    if [ -z "$missing" ]; then
      ok "$rel passes all three versions at every invocation of the generated script"
    else
      bad "$rel does not pass:$missing"
    fi
  fi
done

# The check must be wired into CI, or it only ever runs on a developer's laptop.
WF_DIR="$ROOT/.github/workflows"
if grep -rq 'check-heredoc-vars.sh' "$WF_DIR" 2>/dev/null; then
  ok "check-heredoc-vars.sh runs in CI"
else
  bad "check-heredoc-vars.sh is not referenced by any workflow"
fi

# =============================================================================
echo ""
echo "=== Part 4: the verbose mode (default off) ==="
# =============================================================================
# The issue asks for debug output that can be switched on for the next
# iteration, switched off by default. Two things have to hold: the flag must
# exist and reach the generated script across the su/sudo boundary, and nothing
# must change when it is absent.

# Extracting the argument prologue (everything up to the parser's `done`) lets
# the parser be executed without running a 40-minute install as root. This is
# also the direct reproduction of the second defect found under this issue:
# `measure-disk-space.sh` dereferenced a bare $1 under `set -u`, so the
# documented no-argument invocation aborted with `$1: unbound variable`.
prologue() {
  local src="$1" out="$2"
  awk 'NR == 1, /^done$/' "$src" >"$out"
}

for rel in scripts/measure-disk-space.sh scripts/ubuntu-24-server-install.sh; do
  f="$ROOT/$rel"
  base="$(basename "$rel")"

  # --help must not start any work, and must document the flag.
  set +e
  help_out="$("$f" --help 2>&1)"
  help_rc=$?
  set -e
  check "$base --help exits 0" "0" "$help_rc"
  check "$base --help documents --verbose" "1" "$(grep -q -- '--verbose' <<<"$help_out" && echo 1 || echo 0)"

  # An unrecognised option is a usage error, not a silent full install.
  set +e
  "$f" --definitely-not-an-option >/dev/null 2>&1
  bad_rc=$?
  set -e
  check "$base rejects an unknown option with exit 2" "2" "$bad_rc"

  # The prologue, run with no arguments at all, under the same `set -u` the
  # real script uses. Before the fix this aborted on $1.
  pro="$TMP/prologue-$base"
  prologue "$f" "$pro"
  set +e
  pro_out="$(
    bash "$pro" 2>&1
    echo "rc=$?"
  )"
  set -e
  check "$base parses an empty argument list without an unbound variable" \
    "" "$(grep -o 'unbound variable' <<<"$pro_out" || true)"
  check "  (and the prologue exits cleanly)" "rc=0" "$(tail -n1 <<<"$pro_out")"

  # Default off, in the parent and in the generated script.
  check "$base defaults BOX_VERBOSE to 0" "2" \
    "$(grep -c 'BOX_VERBOSE="\${BOX_VERBOSE:-0}"' "$f" || true)"

  # `set -x` in the generated script must be behind the flag, never bare.
  check "$base only traces the generated script when BOX_VERBOSE=1" "1" \
    "$(grep -c '\[ "\$BOX_VERBOSE" = "1" \] && set -x' "$f" || true)"
  check "  (and never enables tracing unconditionally)" "" \
    "$(grep -nE '^[[:space:]]*set -x[[:space:]]*$' "$f" || true)"

  # The flag has to survive the same boundary that discarded the versions.
  invocations="$(grep -nE '(su - box|sudo -i -u box)' "$f" | grep -E 'box-(measure|user-setup)\.sh' || true)"
  missing=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -q 'BOX_VERBOSE=' <<<"$line" || missing="$missing line${line%%:*}"
  done <<<"$invocations"
  check "$base passes BOX_VERBOSE across the su/sudo boundary" "" "$missing"

  # And the debug helper itself is silent unless asked. Evaluated in isolation
  # so this tests the actual definition, not a paraphrase of it.
  helper="$(sed -n '/^log_debug() {/,/^}/p' "$f")"
  [ -n "$helper" ] || helper="$(grep -m1 '^log_debug() {.*}$' "$f")"
  if [ -z "$helper" ]; then
    bad "$base has no log_debug helper"
  else
    off="$(BOX_VERBOSE=0 CYAN='' NC='' bash -c "$helper"$'\n''log_debug "should not appear"' 2>&1 || true)"
    on="$(BOX_VERBOSE=1 CYAN='' NC='' bash -c "$helper"$'\n''log_debug "should appear"' 2>&1 || true)"
    check "$base log_debug is silent by default" "" "$off"
    check "$base log_debug prints when BOX_VERBOSE=1" "1" \
      "$(grep -c 'should appear' <<<"$on" || true)"
  fi
done

# The workflow has to expose the switch, or nobody can turn it on in CI.
if grep -q 'BOX_VERBOSE' "$WF_DIR/measure-disk-space.yml" 2>/dev/null; then
  ok "measure-disk-space.yml exposes the verbose switch"
else
  bad "measure-disk-space.yml does not expose BOX_VERBOSE"
fi

echo ""
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
