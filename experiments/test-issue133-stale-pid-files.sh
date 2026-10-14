#!/usr/bin/env bash
# Exercise the stale pid file cleanup without root or a daemon (issue #133).
# The real entrypoint functions run; only as_root (redirected to a fixture
# directory), pgrep, and the daemon launch are replaced.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="${DIND_TEST_ENTRYPOINT:-$SCRIPT_DIR/../ubuntu/24.04/dind/dind-entrypoint.sh}"
INSTALL="${DIND_TEST_INSTALL:-$SCRIPT_DIR/../ubuntu/24.04/dind/install.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

# run_case RUNNING SEED EXPECT_DOCKERD EXPECT_CONTAINERD EXPECT_LOG
#   RUNNING   space-separated daemons pgrep reports as running
#   SEED      1 to write a live non-daemon PID into both pid files first
#   EXPECT_*  "kept" or "gone" for each pid file after start_dockerd
#   EXPECT_LOG  substring the entrypoint output must contain ("" for none)
run_case() (
  local running="$1" seed="$2" expect_dockerd="$3"
  local expect_containerd="$4" expect_log="$5"
  local root="$WORK/root" output
  rm -rf "$root"
  mkdir -p "$root/var/run/docker/containerd"
  if [ "$seed" = 1 ]; then
    # This shell is alive and is neither dockerd nor containerd, like the
    # unrelated process that reuses the old daemon's PID in a snapshot.
    printf '%s\n' "$$" >"$root/var/run/docker.pid"
    printf '%s\n' "$$" >"$root/var/run/docker/containerd/containerd.pid"
  fi

  # shellcheck disable=SC1090
  DIND_ENTRYPOINT_SOURCE_ONLY=1 . "$ENTRYPOINT"
  DIND_DATA_ROOT="$WORK/data"
  DIND_LOG_FILE="$WORK/daemon.log"

  as_root() {
    local arg
    local -a args=()
    for arg in "$@"; do
      case "$arg" in
        /var/run/*) args+=("$root$arg") ;;
        /usr/bin/mkdir | /usr/bin/rm) args+=("${arg##*/}") ;;
        *) args+=("$arg") ;;
      esac
    done
    "${args[@]}"
  }
  pgrep() {
    local name="${*: -1}" daemon
    for daemon in $running; do
      [ "$daemon" = "$name" ] && return 0
    done
    return 1
  }
  fix_socket_permissions() { :; }
  launch_dockerd() { DIND_DOCKERD_PID=0; }
  wait_for_dockerd_ready() { return 0; }

  output="$(start_dockerd 2>&1)" || {
    printf '%s\n' "$output"
    return 1
  }
  printf '%s\n' "$output" >"$WORK/output"

  local file expect
  for file in docker.pid docker/containerd/containerd.pid; do
    if [ "$file" = docker.pid ]; then
      expect="$expect_dockerd"
    else
      expect="$expect_containerd"
    fi
    if [ "$seed" != 1 ]; then
      expect=gone
    fi
    if [ -e "$root/var/run/$file" ]; then
      actual=kept
    else
      actual=gone
    fi
    if [ "$actual" != "$expect" ]; then
      echo "  /var/run/$file: expected $expect, got $actual"
      cat "$WORK/output"
      return 1
    fi
  done

  if [ -z "$expect_log" ]; then
    if grep -q 'stale' "$WORK/output"; then
      echo "  unexpected stale pid file message"
      cat "$WORK/output"
      return 1
    fi
  elif ! grep -qF -- "$expect_log" "$WORK/output"; then
    echo "  output lacks: $expect_log"
    cat "$WORK/output"
    return 1
  fi
)

check() {
  local description="$1"
  shift
  # Capture status outside an `if run_case`: conditional functions disable
  # errexit throughout their bodies and can hide a failed intermediate command.
  set +e
  run_case "$@"
  local status=$?
  set -e
  if [ "$status" = 0 ]; then
    echo "PASS: $description"
    pass=$((pass + 1))
  else
    echo "FAIL: $description"
    fail=$((fail + 1))
  fi
}

check "fresh container has nothing to remove and logs nothing" \
  "" 0 gone gone ""
check "snapshot pid files pointing at a reused PID are removed" \
  "" 1 gone gone "Removed stale /var/run/docker/containerd/containerd.pid"
check "snapshot docker.pid removal is logged" \
  "" 1 gone gone "Removed stale /var/run/docker.pid"
check "a running containerd keeps its pid file for live restore" \
  "containerd" 1 gone kept "Removed stale /var/run/docker.pid"
check "a running dockerd returns before touching pid files" \
  "dockerd containerd" 1 kept kept "dockerd already running"

# An image whose sudoers predates the rm entry (or a missing sudo) must only
# warn: dockerd may still start when the recorded PIDs are not reused.
check_rm_warning() (
  # shellcheck disable=SC1090
  DIND_ENTRYPOINT_SOURCE_ONLY=1 . "$ENTRYPOINT"
  as_root() { return 1; }
  pgrep() { return 1; }
  output="$(clear_stale_pid_files 2>&1)"
  grep -qF "Cannot remove stale /var/run/docker.pid" <<<"$output" \
    && grep -qF "Cannot remove stale /var/run/docker/containerd/containerd.pid" <<<"$output"
)
set +e
check_rm_warning
status=$?
set -e
if [ "$status" = 0 ]; then
  echo "PASS: a refused rm warns for both pid files without failing"
  pass=$((pass + 1))
else
  echo "FAIL: a refused rm warns for both pid files without failing"
  fail=$((fail + 1))
fi

# The sudoers entry matches arguments literally, so the entrypoint must call
# rm with exactly the command lines install.sh allows.
for pid_file in /var/run/docker.pid /var/run/docker/containerd/containerd.pid; do
  if grep -qF "/usr/bin/rm -fv $pid_file" "$INSTALL" \
    && grep -qF "$pid_file" "$ENTRYPOINT" \
    && grep -qF 'as_root /usr/bin/rm -fv "$pid_file"' "$ENTRYPOINT"; then
    echo "PASS: sudoers allows the entrypoint to remove $pid_file"
    pass=$((pass + 1))
  else
    echo "FAIL: sudoers allows the entrypoint to remove $pid_file"
    fail=$((fail + 1))
  fi
done

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
