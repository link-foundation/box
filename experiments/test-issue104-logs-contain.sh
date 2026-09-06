#!/usr/bin/env bash
# Regression test for the dind example-suite log assertions (issue #104 / PR #105).
#
# The pr-test / dind-js job intermittently failed on assertions shaped like
#   if ! docker logs "$c" 2>&1 | grep -q "NEEDLE"; then fail ...; fi
# Under `set -o pipefail`, `grep -q` closes the pipe the instant it matches, which
# delivers SIGPIPE (exit 141) to the still-streaming `docker logs`. pipefail then
# propagates that 141, so a needle that WAS present reads as absent and the test
# fails spuriously. tests/dind/lib.sh now provides logs_contain(), which captures
# the logs first and matches with a `case` glob -- no pipe, no SIGPIPE.
#
# This test asserts the POLICY (the helper exists, every example uses it, and no
# raw `docker logs | grep` survives) and the BEHAVIOR (capture+case is correct and
# immune to the pipefail false-negative the old pattern suffered).
set -euo pipefail

cd "$(dirname "$0")/.."

fail=0
pass() { echo "  PASS: $1"; }
miss() {
  echo "  FAIL: $1"
  fail=1
}

lib="tests/dind/lib.sh"

echo "== Case 1: lib.sh defines the pipe-free logs_contain helper =="
if grep -qE '^logs_contain\(\) \{' "$lib"; then pass "defines logs_contain()"; else miss "defines logs_contain()"; fi
if grep -q 'docker logs' "$lib"; then pass "logs_contain captures docker logs"; else miss "logs_contain captures docker logs"; fi

echo "== Case 2: no raw 'docker logs | grep' assertion survives in tests/dind =="
# A pipe straight from docker logs into grep is the vulnerable shape we removed.
if grep -rnE 'docker logs [^|]*\| *grep' tests/dind/ >/dev/null 2>&1; then
  grep -rnE 'docker logs [^|]*\| *grep' tests/dind/ >&2
  miss "no docker-logs|grep pipelines remain"
else
  pass "no docker-logs|grep pipelines remain"
fi

echo "== Case 3: example scripts assert via the pipe-free log helpers =="
# wait_for_logs is a polling wrapper around logs_contain (see lib.sh), so an
# example that waits for a line still gets the SIGPIPE-immune capture+case
# assertion. Accept either helper: asserting the literal `logs_contain` made
# this check fail the moment example-storage-driver-vfs.sh switched to
# wait_for_logs in 6c3d582, even though the invariant still held (issue #115).
for f in tests/dind/example-preload-images.sh tests/dind/example-storage-driver-vfs.sh; do
  [ -f "$f" ] || {
    miss "$f exists"
    continue
  }
  if grep -qE 'logs_contain|wait_for_logs' "$f"; then
    pass "$(basename "$f") asserts logs via logs_contain/wait_for_logs"
  else
    miss "$(basename "$f") asserts logs via logs_contain/wait_for_logs"
  fi
done

echo "== Case 4: capture+case is correct and SIGPIPE-immune =="
NEEDLE="image preload/passthrough complete"
# Producer prints the needle EARLY then streams a large tail, so a matcher that
# short-circuits is reliably killed by SIGPIPE while the producer is still writing
# -- the exact shape of `docker logs` on a busy dind container.
producer() {
  printf '%s\n' "starting dockerd"
  printf '%s\n' "$NEEDLE"
  for n in $(seq 1 5000); do
    printf 'trailing log line %s aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' "$n"
  done
}
old_match() { producer | grep -q "$NEEDLE"; } # vulnerable
new_match() {                                 # logs_contain's core
  local logs
  logs="$(producer 2>&1 || true)"
  case "$logs" in *"$NEEDLE"*) return 0 ;; *) return 1 ;; esac
}

iterations=30
old_fn=0
new_fn=0
for _ in $(seq 1 "$iterations"); do
  if ! old_match; then old_fn=$((old_fn + 1)); fi
  if ! new_match; then new_fn=$((new_fn + 1)); fi
done
echo "  (old pipe|grep -q false negatives: ${old_fn}/${iterations}; new capture+case: ${new_fn}/${iterations})"
if [ "$new_fn" -eq 0 ]; then pass "capture+case never false-negatives under pipefail"; else miss "capture+case false-negatived ${new_fn}/${iterations}"; fi

# Correctness: reject an absent needle; match needles containing glob/regex
# metacharacters as literals (the vfs warning needles do).
absent="no marker here"
case "$absent" in *"$NEEDLE"*) miss "matched an absent needle" ;; *) pass "rejects an absent needle" ;; esac
meta="warning: 'vfs' storage driver [no copy-on-write] DIND_STORAGE_DRIVER=fuse-overlayfs"
meta_ok=1
for n in "'vfs' storage driver" "[no copy-on-write]" "DIND_STORAGE_DRIVER=fuse-overlayfs"; do
  case "$meta" in *"$n"*) ;; *) meta_ok=0 ;; esac
done
if [ "$meta_ok" -eq 1 ]; then pass "matches glob/regex metacharacters as literals"; else miss "failed to match a literal metacharacter needle"; fi

echo ""
if [ "$fail" -eq 0 ]; then
  echo "RESULT: PASS - logs_contain is wired in and SIGPIPE-immune"
else
  echo "RESULT: FAIL"
  exit 1
fi
