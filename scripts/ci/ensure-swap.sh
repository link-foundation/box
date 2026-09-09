#!/usr/bin/env bash
#
# Turn idle disk into memory before a build that is known to run out of it.
#
# Why this exists (issue #119 follow-up, measured on PR #120):
#
#   `pr-test / full` and `pr-test / dind-full` are the only two jobs in this
#   workflow that build JS + essentials + 11 language images + the full box on
#   one VM, and they are the only two that fail. With the sampler from
#   scripts/ci/resource-monitor.sh in place, run 34278116323 (job 102247036552)
#   finally says what runs out. The full box's export starts at 22:13:07:
#
#     #64 exporting to image
#     #64 exporting layers
#     [resources] 22:13:04 disk /=59711MB used /  87993MB free | mem  2323MB used ... swap    0MB used of 3071MB
#     [resources] 22:13:34 disk /=59758MB used /  87945MB free | mem  5836MB used ... swap    0MB used of 3071MB
#     [resources] 22:14:34 disk /=59759MB used /  87945MB free | mem 11527MB used ... swap  162MB used of 3071MB
#     [resources] 22:15:34 disk /=59759MB used /  87944MB free | mem 13671MB used ... swap 2620MB used of 3071MB
#     [resources] 22:17:34 disk /=59769MB used /  87934MB free | mem 15723MB used /  265MB available of 15989MB | swap 3071MB used of 3071MB LOW-MEM
#     ##[error]Process completed with exit code 143.
#     ##[error]The runner has received a shutdown signal.
#
#   Two readings settle it. Disk grows 11 MB across the whole 4.5-minute export
#   while 88 GB stays free, so disk is not the constraint. Memory goes from
#   2.3 GB to 18.8 GB committed (RAM plus swap) and is still climbing at
#   ~2 GB/30s when the runner is taken down: dockerd accumulates the layers it
#   is exporting in anonymous memory instead of writing them out, which is
#   docker/buildx#1606 - reported against the docker driver since Docker 23.0,
#   still open, no daemon setting to turn it off. `dind-full` died the same way
#   at 21:55 (mem 15051MB used / 938MB available, swap 3066MB of 3071MB).
#
#   The same two jobs passed on 2026-09-05 (run 33962512941, `exporting layers
#   171.1s done`) on the same runner image and the same Docker. What changed in
#   between is the size of what gets exported: commit 46f80a5 made the Lean
#   boxes actually install a toolchain, so `COPY --from=lean-stage
#   /home/box/.elan` went from copying a stub to copying a real Lean 4
#   toolchain. The export's appetite scales with the bytes it exports, and that
#   pushed the peak past 16 GB of RAM plus the runner's 3 GB of swap.
#
#   16 GB of RAM is what the runner has and larger runners are not available to
#   this repository, so the only headroom left on the machine is the ~88 GB of
#   disk that the measurement above shows sitting idle at the moment of death.
#   This script converts a slice of it into swap: pages that dockerd writes
#   once and reads back much later are exactly what swap is good at, and the
#   alternative is not a slower build but no build at all.
#
# Usage:
#
#   bash scripts/ci/ensure-swap.sh          # provision, then report `free -m`
#   bash scripts/ci/ensure-swap.sh plan     # print the decision, touch nothing
#
# Idempotent: a second call with the swapfile already active is a no-op, and so
# is a call on a machine that already has at least the target amount of swap.
#
# Inputs (environment):
#   ENSURE_SWAP_TARGET_MB   total swap wanted, existing swap included
#                           (default 32768)
#   ENSURE_SWAP_RESERVE_MB  free disk to leave behind (default 40960: the chain
#                           needs ~60 GB and the full box's export another ~25)
#   ENSURE_SWAP_MIN_MB      do not bother below this much (default 1024)
#   ENSURE_SWAP_FILE        where to put it (default /box-ci-swapfile)
#
# Failing to provision is a warning, not an error: a job that cannot get swap
# should still attempt the build and fail on the build, where the log already
# explains itself, rather than fail here on a missing optimisation. Every
# decision is printed on a `[ensure-swap]` line for the post-mortem.
#
# Exit codes:
#   0  swap is in place, or was deliberately not provisioned
#   2  misuse: unknown mode

set -uo pipefail

TARGET_MB="${ENSURE_SWAP_TARGET_MB:-32768}"
RESERVE_MB="${ENSURE_SWAP_RESERVE_MB:-40960}"
MIN_MB="${ENSURE_SWAP_MIN_MB:-1024}"
SWAP_FILE="${ENSURE_SWAP_FILE:-/box-ci-swapfile}"

MODE="${1:-provision}"
case "$MODE" in
  provision | plan) ;;
  *)
    echo "usage: $0 [plan]" >&2
    exit 2
    ;;
esac

say() { echo "[ensure-swap] $*"; }

# Every value is printed even when it could not be read, because a plan that
# hides the input it acted on is not reviewable.
read_swap_total_mb() {
  free -m 2>/dev/null | awk '/^Swap:/ {print $2; found=1} END {if (!found) print "?"}'
}

read_free_mb() {
  local dir
  dir="$(dirname "$SWAP_FILE")"
  df -Pm "$dir" 2>/dev/null | awk 'NR==2 {print $4; found=1} END {if (!found) print "?"}'
}

swapfile_is_active() {
  # `swapon --show` is the only source that knows whether *this* file is in
  # use; the file existing proves nothing (a previous run may have been killed
  # between fallocate and swapon).
  swapon --show=NAME --noheadings 2>/dev/null | grep -qxF "$SWAP_FILE"
}

# `sudo -n`, never plain `sudo`: a runner where sudo would prompt must get an
# instant failure and a warning, not a build that hangs on a password prompt
# nobody is there to answer.
SUDO=""
if [ "$(id -u)" != "0" ]; then
  SUDO="sudo -n"
fi

CURRENT_MB="$(read_swap_total_mb)"
FREE_MB="$(read_free_mb)"

if [ "$CURRENT_MB" = "?" ] || [ "$FREE_MB" = "?" ]; then
  say "plan: current=${CURRENT_MB}MB free=${FREE_MB}MB target=${TARGET_MB}MB reserve=${RESERVE_MB}MB"
  say "decision: skip (could not read the current swap or the free space)"
  exit 0
fi

NEED_MB=$((TARGET_MB - CURRENT_MB))
ALLOCATABLE_MB=$((FREE_MB - RESERVE_MB))
SIZE_MB="$NEED_MB"
if [ "$ALLOCATABLE_MB" -lt "$SIZE_MB" ]; then
  SIZE_MB="$ALLOCATABLE_MB"
fi
if [ "$SIZE_MB" -lt 0 ]; then
  SIZE_MB=0
fi

say "plan: current=${CURRENT_MB}MB target=${TARGET_MB}MB need=${NEED_MB}MB" \
  "free=${FREE_MB}MB reserve=${RESERVE_MB}MB allocatable=${ALLOCATABLE_MB}MB" \
  "size=${SIZE_MB}MB file=${SWAP_FILE}"

DECISION="allocate ${SIZE_MB}MB at ${SWAP_FILE}"
if swapfile_is_active; then
  DECISION="skip (${SWAP_FILE} is already active)"
elif [ "$NEED_MB" -le 0 ]; then
  DECISION="skip (${CURRENT_MB}MB of swap already meets the ${TARGET_MB}MB target)"
elif [ "$SIZE_MB" -lt "$MIN_MB" ]; then
  DECISION="skip (only ${ALLOCATABLE_MB}MB is free above the ${RESERVE_MB}MB reserve)"
fi
say "decision: ${DECISION}"

case "$DECISION" in skip*) exit 0 ;; esac
[ "$MODE" = "provision" ] || exit 0

warn() {
  echo "::warning title=ensure-swap::$*"
  say "the build will run with ${CURRENT_MB}MB of swap"
}

# fallocate is instant on ext4, which is what the runner's root filesystem is;
# `dd` is the fallback for a filesystem where swapon rejects a preallocated
# file, and it is worth the minutes it costs because the alternative is a
# SIGKILL 40 minutes into the job.
allocate() {
  $SUDO rm -f "$SWAP_FILE" 2>/dev/null
  if $SUDO fallocate -l "${SIZE_MB}M" "$SWAP_FILE" 2>/dev/null; then
    say "allocated ${SIZE_MB}MB with fallocate"
    return 0
  fi
  say "fallocate failed, falling back to dd (this writes ${SIZE_MB}MB)"
  $SUDO dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SIZE_MB" status=none
}

echo "--- memory before ---"
free -m

if ! allocate; then
  warn "could not allocate ${SIZE_MB}MB at ${SWAP_FILE}"
  exit 0
fi

$SUDO chmod 600 "$SWAP_FILE"
if ! $SUDO mkswap "$SWAP_FILE" >/dev/null; then
  warn "mkswap failed on ${SWAP_FILE}"
  $SUDO rm -f "$SWAP_FILE"
  exit 0
fi

if ! $SUDO swapon "$SWAP_FILE"; then
  # A preallocated file that swapon refuses is the one case where dd's minutes
  # buy something, so retry properly instead of giving up on the headroom.
  say "swapon refused the preallocated file, rewriting it with dd"
  $SUDO rm -f "$SWAP_FILE"
  if ! $SUDO dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SIZE_MB" status=none \
    || ! $SUDO chmod 600 "$SWAP_FILE" \
    || ! $SUDO mkswap "$SWAP_FILE" >/dev/null \
    || ! $SUDO swapon "$SWAP_FILE"; then
    warn "could not enable ${SWAP_FILE} as swap"
    $SUDO rm -f "$SWAP_FILE"
    exit 0
  fi
fi

echo "--- memory after ---"
free -m
swapon --show || true
say "active: $(read_swap_total_mb)MB of swap total"
