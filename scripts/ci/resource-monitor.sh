#!/usr/bin/env bash
#
# Sample the runner's memory and disk while a long `docker build` runs, and
# print one line per sample to the step's own stdout.
#
# Why this exists (issue #119 follow-up, measured on PR #120):
#
#   `pr-test / full` and `pr-test / dind-full` are the only two jobs in this
#   workflow that build the whole language chain plus the full box on a single
#   VM, and they are the only two that fail. Three consecutive failures, all at
#   the same point:
#
#     run 34259552358 attempt 2, job 102215605228 (dind-full)
#       #64 exporting to image
#       #64 exporting layers
#       ...sh: line 51: 122206 Killed   docker build -f ubuntu/24.04/full-box/...
#       ##[error]The runner has received a shutdown signal.
#       ##[error]Process completed with exit code 137.
#
#     run 34259552358 attempt 1, job 102177680205 (dind-full)  - exit 143
#     run 34259552358 attempt 1, job 102184490387 (full)        - the runner died
#       mid-step: step 7 never left `in_progress` and steps 8+ stayed `pending`.
#
#   The same two jobs passed on 2026-09-05 (run 33962512941), where the full
#   box's `exporting layers` took 166.8s; on 2026-09-08 the process was killed
#   65s into that same export. A SIGKILL delivered to the `docker` client, with
#   the runner service going down in the same second, is what memory exhaustion
#   and a full root filesystem both look like from inside the job - and the job
#   log records neither, because nothing in it ever samples either one. The
#   last measurement available is from `Free disk space`, half an hour and
#   ~90 GB of image data earlier:
#
#     /dev/root  145G  32G  113G  22% /      Mem: 15Gi   Swap: 0B
#
#   So this script exists to make the next failure self-explanatory: whichever
#   resource ran out, the sample immediately before the kill says so.
#
#   It did. Run 34278116323 (job 102247036552) recorded the full box's export
#   growing from 2.3 GB to 18.8 GB committed - RAM plus swap - in 4.5 minutes
#   while the disk gained 11 MB and kept 88 GB free, which is why the fix is
#   scripts/ci/ensure-swap.sh and not more disk. Each sample now also names the
#   biggest processes by resident memory, because "memory ran out" and "*this*
#   process took it" are two different findings and only the second one points
#   at anything: it is what identifies the consumer as dockerd rather than the
#   build client, the language runtimes, or the runner agent itself.
#
# Usage:
#
#   bash scripts/ci/resource-monitor.sh &      # sample until killed
#   MONITOR=$!
#   trap 'kill "$MONITOR" 2>/dev/null || true' EXIT
#   ...the build...
#
#   bash scripts/ci/resource-monitor.sh sample # one line, then exit
#
# Output is deliberately one short line per sample so it interleaves with
# BuildKit's progress without drowning it, and it goes to the step's stdout
# rather than a file: when the runner is killed mid-step there is no later
# step to upload a file from, but every line already flushed to the log
# survives.
#
# Inputs (environment):
#   RESOURCE_MONITOR_INTERVAL_SECONDS - seconds between samples (default 30)
#   RESOURCE_MONITOR_MAX_SAMPLES      - stop after this many (default 0 = never)
#   RESOURCE_MONITOR_DISK_PATH        - filesystem to watch (default /)
#   RESOURCE_MONITOR_LOW_DISK_MB      - warn under this much free (default 10240)
#   RESOURCE_MONITOR_LOW_MEM_MB       - warn under this much available (default 1024)
#   RESOURCE_MONITOR_PARENT_PID       - stop when this process is gone
#                                       (default: the caller, $PPID)
#   RESOURCE_MONITOR_TOP_PROCESSES    - name this many biggest processes by
#                                       resident memory (default 3, 0 = off)

set -uo pipefail

INTERVAL="${RESOURCE_MONITOR_INTERVAL_SECONDS:-30}"
MAX_SAMPLES="${RESOURCE_MONITOR_MAX_SAMPLES:-0}"
DISK_PATH="${RESOURCE_MONITOR_DISK_PATH:-/}"
LOW_DISK_MB="${RESOURCE_MONITOR_LOW_DISK_MB:-10240}"
LOW_MEM_MB="${RESOURCE_MONITOR_LOW_MEM_MB:-1024}"
# A sampler that outlives the step it is sampling holds that step's stdout pipe
# open, and the runner waits on the pipe, not on the shell - so an orphan here
# would turn a build failure into a hung job. Stop as soon as the caller is
# gone, which covers the case the EXIT trap cannot: the caller being SIGKILLed.
PARENT_PID="${RESOURCE_MONITOR_PARENT_PID:-$PPID}"
TOP_PROCESSES="${RESOURCE_MONITOR_TOP_PROCESSES:-3}"

# Which process holds the memory, largest first. `ps` is in the same procps
# package as `free`, so this costs no new dependency, and the RSS of a handful
# of processes is the whole answer to "who?" - the daemon that exports layers
# runs outside the step's own process tree, so nothing narrower would see it.
top_rss() {
  [ "$TOP_PROCESSES" -gt 0 ] 2>/dev/null || return 0
  ps -eo rss=,comm= --sort=-rss 2>/dev/null | awk -v n="$TOP_PROCESSES" '
    NR > n { exit }
    {
      rss = $1
      $1 = ""
      sub(/^ +/, "")
      gsub(/[ ,]/, "_")
      printf "%s%s=%dMB", (NR > 1 ? "," : ""), $0, int(rss / 1024)
    }
  '
}

# `free -m` and `df -Pm` are both in coreutils/procps on every runner image, so
# a sample never depends on docker being responsive - which matters, because a
# docker daemon wedged by a full disk is exactly the state to report on.
sample_line() {
  local ts disk_total disk_used disk_free disk_pct
  local mem_total mem_used mem_avail swap_total swap_used warn="" top

  ts="$(date -u +%H:%M:%S)"

  # df -Pm: POSIX output, megabytes, one line per filesystem - so the fields
  # below are stable across coreutils versions and never wrap.
  read -r disk_total disk_used disk_free disk_pct <<<"$(
    df -Pm "$DISK_PATH" 2>/dev/null | awk 'NR==2 {print $2, $3, $4, $5}'
  )"
  read -r mem_total mem_used mem_avail <<<"$(
    free -m 2>/dev/null | awk '/^Mem:/ {print $2, $3, $7}'
  )"
  read -r swap_total swap_used <<<"$(
    free -m 2>/dev/null | awk '/^Swap:/ {print $2, $3}'
  )"

  # A missing reading is reported as such rather than silently printed as 0.
  disk_total="${disk_total:-?}"
  disk_used="${disk_used:-?}"
  disk_free="${disk_free:-?}"
  disk_pct="${disk_pct:-?}"
  mem_total="${mem_total:-?}"
  mem_used="${mem_used:-?}"
  mem_avail="${mem_avail:-?}"
  swap_total="${swap_total:-?}"
  swap_used="${swap_used:-?}"

  top="$(top_rss)"
  top="${top:-?}"

  if [ "$disk_free" != "?" ] && [ "$disk_free" -lt "$LOW_DISK_MB" ] 2>/dev/null; then
    warn=" LOW-DISK"
  fi
  if [ "$mem_avail" != "?" ] && [ "$mem_avail" -lt "$LOW_MEM_MB" ] 2>/dev/null; then
    warn="${warn} LOW-MEM"
  fi

  printf '[resources] %s disk %s=%sMB used / %sMB free (%s) | mem %sMB used / %sMB available of %sMB | swap %sMB used of %sMB | top %s%s\n' \
    "$ts" "$DISK_PATH" "$disk_used" "$disk_free" "$disk_pct" \
    "$mem_used" "$mem_avail" "$mem_total" \
    "$swap_used" "$swap_total" "$top" "$warn"
}

if [ "${1:-}" = "sample" ]; then
  sample_line
  exit 0
fi

if [ "${1:-}" != "" ]; then
  echo "usage: $0 [sample]" >&2
  exit 2
fi

taken=0
while :; do
  sample_line
  taken=$((taken + 1))
  if [ "$MAX_SAMPLES" -gt 0 ] && [ "$taken" -ge "$MAX_SAMPLES" ]; then
    break
  fi
  if [ -n "$PARENT_PID" ] && ! kill -0 "$PARENT_PID" 2>/dev/null; then
    echo "[resources] caller ${PARENT_PID} is gone: stopping"
    break
  fi
  sleep "$INTERVAL"
done
