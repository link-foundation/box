#!/usr/bin/env bash
# reproduce-issue121-subdirectory-discovery.sh
#
# Issue #121. `git ls-files` answers about the directory you are standing in,
# not about the repository. A gate that discovers its own inputs with it and
# does not first anchor at the top level therefore sweeps a *subset* when it is
# run from a subdirectory — and reports success over that subset, with no
# indication that it looked at a fraction of the tree.
#
# That is the same defect class as a `paths:` filter that matches nothing: the
# check runs, the check passes, and the check did not look. It also breaks the
# `--list-inputs` contract in a way that is worse than not answering, because
# scripts/ci/check-workflow-path-coverage.mjs compares those paths against a
# workflow's `paths:` patterns, which GitHub matches from the repository root.
# Hand it `ci/run-shfmt.sh` instead of `scripts/ci/run-shfmt.sh` and every
# pattern misses, so either everything is a finding or nothing is.
#
# This measures the gap for every gate that answers --list-inputs, by asking
# each one the same question twice: once from the repository root, once from a
# subdirectory of it. The answers have to be identical.
#
# Usage: bash experiments/reproduce-issue121-subdirectory-discovery.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"

# Every tracked gate that declares the contract, discovered rather than listed,
# so a gate added later is measured too.
mapfile -t GATES < <(
  git ls-files --cached --others --exclude-standard --deduplicate -- 'scripts/ci/*' \
    | while IFS= read -r f; do
      grep -q -- '--list-inputs' "$f" && printf '%s\n' "$f"
    done | sort
)

printf 'Gates answering --list-inputs: %d\n\n' "${#GATES[@]}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

DIVERGENT=0
for gate in "${GATES[@]}"; do
  case "$gate" in
    *.mjs) run=(node "$ROOT/$gate") ;;
    *) run=(bash "$ROOT/$gate") ;;
  esac

  "${run[@]}" --list-inputs >"$WORK/root.txt" 2>/dev/null
  (cd "$ROOT/scripts" && "${run[@]}" --list-inputs) >"$WORK/sub.txt" 2>/dev/null

  root_count="$(wc -l <"$WORK/root.txt")"
  sub_count="$(wc -l <"$WORK/sub.txt")"

  if cmp -s "$WORK/root.txt" "$WORK/sub.txt"; then
    printf '  OK      %-45s %4s inputs from either directory\n' "$gate" "$root_count"
    continue
  fi

  DIVERGENT=$((DIVERGENT + 1))
  printf '  DIVERGES %-44s %4s inputs from the root, %s from scripts/\n' \
    "$gate" "$root_count" "$sub_count"

  # The half that matters: what the subdirectory run never looked at.
  missed="$(comm -23 "$WORK/root.txt" "$WORK/sub.txt" | wc -l)"
  printf '           %s file(s) the subdirectory run does not see, e.g. %s\n' \
    "$missed" "$(comm -23 "$WORK/root.txt" "$WORK/sub.txt" | head -1)"
  # And the half that breaks the contract: paths that are not repository-relative.
  outside="$(grep -c -v -x -F -f "$WORK/root.txt" "$WORK/sub.txt" || true)"
  if [ "$outside" -gt 0 ]; then
    printf '           %s path(s) that no repository-root pattern can match, e.g. %s\n' \
      "$outside" "$(grep -v -x -F -f "$WORK/root.txt" "$WORK/sub.txt" | head -1)"
  fi
done

echo
if [ "$DIVERGENT" -eq 0 ]; then
  echo "Closed: every gate anchors at the repository, not at the caller's directory."
  exit 0
fi
echo "Open: $DIVERGENT gate(s) report on whichever subtree they are started from."
exit 1
