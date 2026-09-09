#!/usr/bin/env bash
#
# reproduce-issue121-mjs-syntax-gap.sh — the JavaScript nothing parses.
#
# Issue #121. Before scripts/ci/check-mjs-syntax.sh existed, a syntax error in
# most of this repository's JavaScript could be committed, merged and released
# with every check green, because no check read it:
#
#   * shellcheck, shfmt, check-heredoc-vars.sh  -> discover *.sh
#   * run-experiments.sh                        -> discovers experiments/*.sh
#   * check-file-line-limits.sh                 -> reads *.mjs, but counts lines
#   * the workflows                             -> execute 2 of the 13 modules,
#                                                  and 2 more only on the path
#                                                  where links have already
#                                                  failed
#
# This script measures both halves and exits 0 either way — it is a
# reproduction, not an assertion about the current tree. Part 1 counts the
# modules no workflow and no suite so much as names. Part 2 hands a module with
# a deliberate syntax error to every gate that will accept a file argument, and
# then to the new one.
#
# Usage: bash experiments/reproduce-issue121-mjs-syntax-gap.sh

set -euo pipefail

cd "$(dirname "$0")/.."

echo "=== Part 1: which tracked JavaScript does CI ever look at? ==="
echo ""

TRACKED="$(git ls-files -- '*.mjs' '*.js' | grep -v '^dev/log/' | grep -v '^docs/' || true)"
TOTAL=0
UNSEEN=0
UNSEEN_LIST=""

while IFS= read -r file; do
  [ -n "$file" ] || continue
  TOTAL=$((TOTAL + 1))
  base="$(basename "$file")"
  where=""
  if grep -rlF "$base" .github/workflows >/dev/null 2>&1; then
    where="workflow"
  fi
  if grep -rlF "$base" experiments --include='*.sh' >/dev/null 2>&1; then
    where="${where:+$where, }suite"
  fi
  if [ -z "$where" ]; then
    UNSEEN=$((UNSEEN + 1))
    UNSEEN_LIST="${UNSEEN_LIST}    ${file}"$'\n'
    printf '  %-48s named by: nothing\n' "$file"
  else
    printf '  %-48s named by: %s\n' "$file" "$where"
  fi
done <<EOF
$TRACKED
EOF

echo ""
echo "  $UNSEEN of $TOTAL tracked modules are named by no workflow and no suite,"
echo "  so no run executes them and no run can discover a syntax error in them:"
if [ "$UNSEEN" -gt 0 ]; then
  printf '%s' "$UNSEEN_LIST"
fi

# What closes the gap is a gate that reads them without running them. Count how
# many of the unnamed modules its discovery covers, so this stays a measurement
# after the fix rather than a claim about the past.
COVERED=0
PARSED_LIST="$(bash scripts/ci/check-mjs-syntax.sh --verbose 2>/dev/null || true)"
while IFS= read -r file; do
  file="${file#"${file%%[![:space:]]*}"}"
  [ -n "$file" ] || continue
  if printf '%s\n' "$PARSED_LIST" | grep -qF "[parse] $file"; then
    COVERED=$((COVERED + 1))
  fi
done <<EOF
$UNSEEN_LIST
EOF
echo ""
echo "  check-mjs-syntax.sh parses $COVERED of those $UNSEEN without executing them."

echo ""
echo "=== Part 2: a module with a syntax error, against every gate ==="
echo ""

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BROKEN="$TMP/broken.mjs"
cat >"$BROKEN" <<'EOF'
// A module that cannot parse: the object literal is never closed.
export function classify(status) {
  return {
    ok: status < 400,
}
EOF

run_gate() {
  local label="$1"
  shift
  local rc=0
  "$@" >"$TMP/out" 2>&1 || rc=$?
  printf '  %-42s exit %d\n' "$label" "$rc"
  return 0
}

run_gate "check-heredoc-vars.sh broken.mjs" \
  bash scripts/ci/check-heredoc-vars.sh "$BROKEN"
run_gate "check-awk-portability.sh broken.mjs" \
  bash scripts/ci/check-awk-portability.sh "$BROKEN"
run_gate "node --check broken.mjs" \
  node --check "$BROKEN"
run_gate "check-mjs-syntax.sh broken.mjs" \
  bash scripts/ci/check-mjs-syntax.sh "$BROKEN"

HEREDOC_RC=0
bash scripts/ci/check-heredoc-vars.sh "$BROKEN" >/dev/null 2>&1 || HEREDOC_RC=$?
AWK_RC=0
bash scripts/ci/check-awk-portability.sh "$BROKEN" >/dev/null 2>&1 || AWK_RC=$?
MJS_RC=0
bash scripts/ci/check-mjs-syntax.sh "$BROKEN" >/dev/null 2>&1 || MJS_RC=$?

# The *.sh gates cannot even be handed this file by their own discovery, which
# is the reason they are silent rather than wrong: their glob does not match.
SH_MATCHES="$(git ls-files -- '*.sh' | grep -c '\.mjs$' || true)"

echo ""
echo "  git ls-files '*.sh' matches $SH_MATCHES .mjs file(s)."
echo ""

if [ "$HEREDOC_RC" -eq 0 ] && [ "$AWK_RC" -eq 0 ] && [ "$MJS_RC" -ne 0 ] && [ "$SH_MATCHES" -eq 0 ]; then
  echo "Reproduced: the shell gates pass a module that does not parse, and the"
  echo "shell discovery never offered them the file in the first place."
  echo "check-mjs-syntax.sh exits $MJS_RC on the same input."
  exit 0
fi

echo "NOT reproduced: heredoc=$HEREDOC_RC awk=$AWK_RC mjs=$MJS_RC sh-glob=$SH_MATCHES"
echo "If check-mjs-syntax.sh now exits 0 on a module that cannot parse, that is"
echo "a defect in the gate and this script is the place it shows up."
exit 1
