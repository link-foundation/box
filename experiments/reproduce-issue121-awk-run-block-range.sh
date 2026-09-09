#!/usr/bin/env bash
# reproduce-issue121-awk-run-block-range.sh
#
# Issue #121. The suite that asserts "no `run:` block in a composite action
# interpolates a template expansion" extracted the block with
#
#   awk '/^\s+run: \|/,0' "$ACTION" | grep -q '\${{'
#
# and that one line is wrong twice, in opposite directions - the same pair of
# defects the issue is about, this time in a check written *for* the issue.
#
#   1. `\s` is a GNU extension. POSIX awk does not define it, and mawk - the
#      default `awk` on a Debian or Ubuntu system, including the container this
#      repository's own suites run in - does not implement it. The start
#      pattern then matches nothing, the range never opens, awk prints nothing,
#      `grep -q` finds nothing, and the negated test *passes*. A check that
#      cannot fail: exactly the shape of §4 and §6 of the case study.
#
#   2. On a runner where `awk` is gawk - which is what GitHub's ubuntu-24.04
#      image ships, and why this failed in CI and passed locally - `\s` works,
#      the range opens at the first `run: |`, and `,0` never closes it, because
#      0 is never a matching record number. So the "run block" awk prints is
#      *the rest of the file*: every later step's `with:` and `env:` mapping,
#      where `${{ inputs.registry }}` is not an injection but the ordinary way
#      to pass an input to an action. A false positive, reported against lines
#      that are correct.
#
# Both halves are reproduced below under mawk alone. Part 1 runs the original
# line. Part 2 runs it with the start pattern spelled portably, which isolates
# `,0` from `\s` and shows the range defect on its own.
#
# Usage: bash experiments/reproduce-issue121-awk-run-block-range.sh

set -uo pipefail

FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

# A composite action with one `run:` block that *does* interpolate - the real
# defect the assertion exists to catch - followed by a step whose `with:` block
# interpolates, which is correct and must not be reported.
cat >"$FIXTURE/action.yml" <<'YAML'
name: 'Fixture'
inputs:
  registry:
    default: 'docker.io'
runs:
  using: 'composite'
  steps:
    - name: The defect
      shell: bash
      run: |
        echo "logging in to ${{ inputs.registry }}"
    - name: Correct usage that must not be reported
      uses: docker/login-action@v3
      with:
        registry: ${{ inputs.registry }}
YAML

echo "=== Fixture ==="
cat -n "$FIXTURE/action.yml"
echo
echo "The only line an injection check should report is line 11."
echo

echo "=== awk version in use ==="
awk -W version 2>&1 | head -1 || awk --version 2>&1 | head -1
echo

echo "=== Part 1: the original line, verbatim ==="
echo "  awk '/^\\s+run: \\|/,0' action.yml | grep -n '\${{'"
# This line IS the defect, and reproducing it is the point; the checker that
# stops it recurring anywhere else has to be told so here.
# awk-portability: ignore
OUT1="$(awk '/^\s+run: \|/,0' "$FIXTURE/action.yml" | grep -n '\${{')"
HITS1="$(printf '%s' "$OUT1" | grep -c . || true)"
if [ "$HITS1" -eq 0 ]; then
  echo "  -> no output at all: the range never opened, so the assertion passes"
  echo "     while the injection on line 11 is right there. Check cannot fail."
  echo "     (This is the mawk half. Run the same script where awk is gawk to"
  echo "     see the other half; both are wrong, in opposite directions.)"
  DEFECT1="cannot-fail"
else
  echo "$OUT1" | sed 's/^/     /'
  echo "  -> ${HITS1} hits, one of them the \`with:\` mapping on line 15, which is"
  echo "     the documented way to pass an input to an action. \`,0\` never closes,"
  echo "     because no record is numbered 0, so the range ran to end of file."
  echo "     (This is the gawk half. Under mawk the same line reports nothing at"
  echo "     all, because \`\\s\` is a GNU extension mawk does not implement.)"
  DEFECT1="over-reports"
fi
echo

echo "=== Part 2: the same range with a portable start pattern ==="
echo "  awk '/^[ \\t]+run: \\|/,0' action.yml | grep -n '\${{'"
awk '/^[ \t]+run: \|/,0' "$FIXTURE/action.yml" | grep -n '\${{' | sed 's/^/     /'
echo "  -> two hits. The second is the \`with:\` mapping on line 15, which is"
echo "     the documented way to pass an input to an action. \`,0\` ran the"
echo "     block to end of file. False positive."
echo

echo "=== Part 3: what the block actually is ==="
echo "  A block scalar ends where the indentation returns to the key's level."
extract_run_blocks() {
  awk '
    {
      if (in_block) {
        if ($0 ~ /^[ \t]*$/) { print; next }
        indent = match($0, /[^ \t]/) - 1
        if (indent > key_indent) { print; next }
        in_block = 0
      }
      if ($0 ~ /^[ \t]*run:[ \t]*[|>]/) {
        key_indent = match($0, /[^ \t]/) - 1
        in_block = 1
        next
      }
      # A single-line `run:` is not a block scalar, but an expansion in it is
      # the same defect, so it is part of what must be examined.
      if ($0 ~ /^[ \t]*run:[ \t]*[^ \t|>]/) print
    }
  ' "$1"
}
extract_run_blocks "$FIXTURE/action.yml" | sed 's/^/     | /'
HITS="$(extract_run_blocks "$FIXTURE/action.yml" | grep -c '\${{')"
echo "  -> ${HITS} hit, and it is the injection. No 'with:' line reached grep."
echo

echo "=== Part 4: the same extractor on a clean fixture ==="
sed '11s/.*/        echo "logging in to ${REGISTRY}"/' "$FIXTURE/action.yml" >"$FIXTURE/clean.yml"
CLEAN="$(extract_run_blocks "$FIXTURE/clean.yml" | grep -c '\${{')"
echo "  -> ${CLEAN} hits once the value is read from the environment instead."
echo

# The verdict does not depend on which awk is installed, because the defect
# does not either: whatever this awk does with `\s`, the original line does not
# report exactly the one injection, and the extractor does.
if [ "$HITS1" != "1" ] && [ "$HITS" = "1" ] && [ "$CLEAN" = "0" ]; then
  echo "Reproduced (${DEFECT1} on this awk): the original line does not report"
  echo "exactly the injection - it reports ${HITS1} of the 1 - while the"
  echo "indentation-bounded extractor reports it and nothing else, under either awk."
  exit 0
fi

echo "NOT reproduced:"
echo "  original line hits: ${HITS1} (expected anything but 1)"
echo "  extractor hits on the injected fixture: ${HITS} (expected 1)"
echo "  extractor hits on the clean fixture:    ${CLEAN} (expected 0)"
exit 1
