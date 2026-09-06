#!/usr/bin/env bash
# test-issue115-base-image-preflight.sh
#
# Issue #115, RC-4. In run 33972074755 the js builds failed (expired Docker Hub
# token), so js-manifest was *skipped*. The dind gate accepts
# `result == 'skipped'` as equivalent to success, because a workflow `if:`
# cannot tell "skipped, nothing to rebuild" from "skipped, the build it needed
# collapsed". All 28 dind matrix legs therefore ran and each failed ~8.5
# minutes later with `failed to resolve source metadata ... not found` — 28 red
# jobs blaming ubuntu/24.04/dind/Dockerfile for an expired secret.
#
# The fix asserts the postcondition the gate stood in for: the base image is
# actually in the registry. This suite covers that assertion and its wiring.
#
# Runs offline: docker is stubbed on PATH.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

pass=0
fail=0
ok() {
  echo "  PASS: $1"
  pass=$((pass + 1))
}
bad() {
  echo "  FAIL: $1"
  fail=$((fail + 1))
}
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

SCRIPT="scripts/release/assert-base-image.sh"

# Which file holds the dind jobs is not this suite's business, and naming one
# would make it pass vacuously the day they move: `grep -c` over a file without
# them returns 0, and "0 occurrences of the bug" reads exactly like "fixed".
# They moved once already, when release.yml was split by family (RC-8), so ask
# where they are now. The helper exits 3 if nothing defines the job.
WF="$(bash scripts/ci/list-release-workflows.sh --job build-dind-amd64)" || exit 1

STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
cat >"$STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
if [ "${STUB_PRESENT:-0}" = "1" ]; then
  echo "Name:      docker.io/konard/box-js:2.5.0-amd64"
  echo "MediaType: application/vnd.oci.image.index.v1+json"
  exit 0
fi
echo "ERROR: failed to resolve source metadata for docker.io/konard/box-js:2.5.0-amd64: not found" >&2
exit 1
STUB
chmod +x "$STUB_DIR/docker"

run_assert() { # run_assert PRESENT -> exit status, output in $STUB_DIR/out
  : >"$STUB_DIR/calls"
  env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_DIR/calls" STUB_PRESENT="$1" \
    bash "$SCRIPT" konard/box-js:2.5.0-amd64 "the js dind-box (amd64) image" \
    >"$STUB_DIR/out" 2>&1
  echo "$?"
}

echo "== Part 1: a published base image passes =="
check "exits 0 when the manifest resolves" "$(run_assert 1)" "0"
check "inspects the image without pulling it" \
  "$(grep -c 'buildx imagetools inspect konard/box-js:2.5.0-amd64' "$STUB_DIR/calls")" "1"
check "does not emit an error annotation" "$(grep -c '::error' "$STUB_DIR/out")" "0"

echo "== Part 2: a missing base image fails, and says why =="
check "exits 1 when the manifest is absent" "$(run_assert 0)" "1"
check "emits a GitHub error annotation" \
  "$(grep -c '::error title=Base image missing::' "$STUB_DIR/out")" "1"
check "names the missing image" \
  "$(grep -qc 'konard/box-js:2.5.0-amd64' "$STUB_DIR/out" && echo 1 || echo 0)" "1"
check "names the consumer, not the Dockerfile" \
  "$(grep -qc 'the js dind-box (amd64) image' "$STUB_DIR/out" && echo 1 || echo 0)" "1"
check "explicitly says this is not a Dockerfile error" \
  "$(grep -qc 'not a Dockerfile error' "$STUB_DIR/out" && echo 1 || echo 0)" "1"
check "points at the skipped-vs-failed ambiguity (RC-4)" \
  "$(grep -qc 'issue #115, RC-4' "$STUB_DIR/out" && echo 1 || echo 0)" "1"

echo "== Part 3: usage =="
env PATH="$STUB_DIR:$PATH" bash "$SCRIPT" >/dev/null 2>&1
check "no arguments is a usage error" "$?" "2"

echo "== Part 4: both dind jobs run the preflight before building =="
check "preflight is wired into both dind jobs" \
  "$(grep -c 'assert-base-image.sh' "$WF")" "2"

python3 - "$WF" <<'PY'
import io, re, sys
text = io.open(sys.argv[1], encoding="utf-8").read()
fail = 0
for arch in ("amd64", "arm64"):
    job = re.search(r'\n  build-dind-%s:\n(.*?)(?=\n  [a-z][a-z0-9-]*:\n)' % arch,
                    text, re.S)
    if not job:
        print(f"  FAIL: build-dind-{arch} job not found"); fail = 1; continue
    body = job.group(1)
    a = body.find("assert-base-image.sh")
    b = body.find("Build and push ${{ matrix.variant }} dind-box")
    if a == -1:
        print(f"  FAIL: build-dind-{arch} has no preflight"); fail = 1
    elif b == -1:
        print(f"  FAIL: build-dind-{arch} has no build step"); fail = 1
    elif a > b:
        print(f"  FAIL: build-dind-{arch} preflight runs after the build"); fail = 1
    else:
        print(f"  PASS: build-dind-{arch} asserts the base image before building")
sys.exit(fail)
PY
if [ $? -eq 0 ]; then pass=$((pass + 2)); else fail=$((fail + 1)); fi

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || {
  echo "RESULT: FAIL"
  exit 1
}
echo "RESULT: PASS - a missing base image is reported once, before the build"
