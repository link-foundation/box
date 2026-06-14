#!/usr/bin/env bash
# Isolated unit test for the issue #104 vfs storage-driver warning in
# dind-entrypoint.sh.
#
# Landing on the `vfs` storage driver used to be silent (only a `log` line named
# the driver), so an operator hitting `failed to register layer: no space left on
# device` had no breadcrumb pointing at the copy-on-write-less driver. The
# entrypoint now emits a one-time `warn` whenever the *active* driver is `vfs`,
# with a remediation hint whose wording depends on whether the fuse-overlayfs
# device node is available.
#
# Building the full box-dind image requires overlay-backed nested Docker, which
# this sandbox cannot provide, so — exactly like preload-unit-test.sh — we source
# the real entrypoint (DIND_ENTRYPOINT_SOURCE_ONLY=1 returns before the
# startup/handoff flow) to get `warn_if_vfs_storage_driver` verbatim and drive it
# directly. The /dev/fuse probe is pointed at a temp path via DIND_FUSE_DEVICE so
# both remediation branches are exercised deterministically without a real device
# node.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="$SCRIPT_DIR/../ubuntu/24.04/dind/dind-entrypoint.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Source the real entrypoint for its functions only.
# shellcheck disable=SC1090
DIND_ENTRYPOINT_SOURCE_ONLY=1 . "$ENTRYPOINT"

pass=0; fail=0
check() { # check <description> <condition-cmd...>
  desc="$1"; shift
  if "$@"; then echo "  PASS: $desc"; pass=$((pass+1)); else echo "  FAIL: $desc"; fail=$((fail+1)); fi
}

ERR="$WORK/err.log"
PRESENT_FUSE="$WORK/fuse-present"   # an existing path: stands in for /dev/fuse
MISSING_FUSE="$WORK/fuse-missing"   # a path that does not exist
: > "$PRESENT_FUSE"
rm -f "$MISSING_FUSE"

echo "== Case 1: vfs driver emits the copy-on-write warning =="
: > "$ERR"
DIND_FUSE_DEVICE="$PRESENT_FUSE" warn_if_vfs_storage_driver vfs 2>"$ERR"
check "warns the driver is vfs"                     grep -q "'vfs' storage driver" "$ERR"
check "calls out NO copy-on-write"                  grep -q "NO copy-on-write" "$ERR"
check "names the disk failure mode"                 grep -q "no space left on device" "$ERR"
check "names the fuse-overlayfs remediation"        grep -q "DIND_STORAGE_DRIVER=fuse-overlayfs" "$ERR"

echo "== Case 2: overlay2 driver stays silent =="
: > "$ERR"
DIND_FUSE_DEVICE="$PRESENT_FUSE" warn_if_vfs_storage_driver overlay2 2>"$ERR"
check "no warning for overlay2" bash -c '! test -s "$1"' _ "$ERR"

echo "== Case 3: fuse-overlayfs driver stays silent =="
: > "$ERR"
DIND_FUSE_DEVICE="$PRESENT_FUSE" warn_if_vfs_storage_driver fuse-overlayfs 2>"$ERR"
check "no warning for fuse-overlayfs" bash -c '! test -s "$1"' _ "$ERR"

echo "== Case 4: empty/unknown driver stays silent =="
: > "$ERR"
DIND_FUSE_DEVICE="$PRESENT_FUSE" warn_if_vfs_storage_driver "" 2>"$ERR"
check "no warning for empty driver" bash -c '! test -s "$1"' _ "$ERR"

echo "== Case 5: /dev/fuse present -> 'set fuse-overlayfs' remediation =="
: > "$ERR"
DIND_FUSE_DEVICE="$PRESENT_FUSE" warn_if_vfs_storage_driver vfs 2>"$ERR"
check "remediation says the device is present"   grep -q "is present" "$ERR"
check "remediation does NOT claim it is missing" bash -c '! grep -q "is missing" "$1"' _ "$ERR"

echo "== Case 6: /dev/fuse missing -> explains why fuse-overlayfs is unavailable =="
: > "$ERR"
DIND_FUSE_DEVICE="$MISSING_FUSE" warn_if_vfs_storage_driver vfs 2>"$ERR"
check "remediation explains the device is missing"   grep -q "is missing" "$ERR"
check "remediation suggests --device /dev/fuse"      grep -q -- "--device /dev/fuse" "$ERR"
check "remediation suggests --privileged"            grep -q -- "--privileged" "$ERR"
check "still names the fuse-overlayfs driver"        grep -q "DIND_STORAGE_DRIVER=fuse-overlayfs" "$ERR"

echo "== Case 7: function returns success so the start_dockerd success branch is unaffected =="
# warn_if_vfs_storage_driver runs immediately before `return 0`; under `set -e`
# a non-zero return would abort startup. Assert exit status 0 for both vfs and
# non-vfs drivers.
check "returns 0 for vfs"      bash -c 'DIND_ENTRYPOINT_SOURCE_ONLY=1 . "$1"; DIND_FUSE_DEVICE="$2" warn_if_vfs_storage_driver vfs >/dev/null 2>&1' _ "$ENTRYPOINT" "$PRESENT_FUSE"
check "returns 0 for overlay2" bash -c 'DIND_ENTRYPOINT_SOURCE_ONLY=1 . "$1"; warn_if_vfs_storage_driver overlay2 >/dev/null 2>&1' _ "$ENTRYPOINT"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
