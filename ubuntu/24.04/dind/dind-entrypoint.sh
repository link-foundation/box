#!/usr/bin/env bash
# Entrypoint for dind-box images.
#
# Responsibilities:
#   1. Start the inner Docker daemon (dockerd) in the background with root
#      privileges, using scoped passwordless sudo when the image runs as box.
#   2. Wait for dockerd to be ready on /var/run/docker.sock.
#   3. Hand off to the standard /usr/local/bin/entrypoint.sh so all language
#      environments load exactly like in the regular box.
#
# This is the recommended pattern from docker:dind and cruizba/ubuntu-dind.
# See docs/case-studies/issue-80/CASE-STUDY.md for the full design rationale.
#
# Required runtime privileges (host side):
#   - Default:  docker run --privileged konard/<base>-dind
#   - Sysbox :  docker run --runtime=sysbox-runc konard/<base>-dind   (no --privileged)
#
# Environment overrides:
#   DIND_STORAGE_DRIVER  Override storage driver (default: auto-detected: overlay2, fuse-overlayfs, vfs)
#   DIND_DATA_ROOT       Override --data-root for dockerd (default: /var/lib/docker)
#   DIND_LOG_FILE        Where to write dockerd logs (default: /var/log/dockerd.log)
#   DIND_WAIT_SECONDS    How long to wait for dockerd to come up (default: 30)
#   DIND_SKIP_DAEMON     If set to "1", do not start dockerd (use for DooD/Sysbox-only mode)

set -eu

DIND_STORAGE_DRIVER="${DIND_STORAGE_DRIVER:-}"
DIND_DATA_ROOT="${DIND_DATA_ROOT:-/var/lib/docker}"
DIND_LOG_FILE="${DIND_LOG_FILE:-/var/log/dockerd.log}"
DIND_WAIT_SECONDS="${DIND_WAIT_SECONDS:-30}"
DIND_SKIP_DAEMON="${DIND_SKIP_DAEMON:-0}"

log()  { echo "[dind-entrypoint] $*"; }
warn() { echo "[dind-entrypoint] WARN: $*" >&2; }

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo -n "$@"
  else
    return 1
  fi
}

prepare_log_file() {
  log_dir="$(dirname "$DIND_LOG_FILE")"
  if [ -n "$log_dir" ] && [ "$log_dir" != "." ]; then
    as_root /usr/bin/mkdir -p "$log_dir" 2>/dev/null || true
  fi

  if ! (: >>"$DIND_LOG_FILE") 2>/dev/null; then
    warn "Cannot write dockerd log file at ${DIND_LOG_FILE}; falling back to /tmp/dockerd.log"
    DIND_LOG_FILE="/tmp/dockerd.log"
    if ! (: >>"$DIND_LOG_FILE") 2>/dev/null; then
      warn "Cannot write fallback dockerd log file at ${DIND_LOG_FILE}; using /dev/null"
      DIND_LOG_FILE="/dev/null"
    fi
  fi
}

fix_socket_permissions() {
  if [ -S /var/run/docker.sock ]; then
    as_root /usr/bin/chgrp docker /var/run/docker.sock 2>/dev/null || true
    as_root /usr/bin/chmod 660 /var/run/docker.sock 2>/dev/null || true
  fi
}

storage_driver_candidates() {
  if [ -n "$DIND_STORAGE_DRIVER" ]; then
    printf '%s\n' "$DIND_STORAGE_DRIVER"
    return 0
  fi

  if grep -q overlay /proc/filesystems 2>/dev/null; then
    printf '%s\n' overlay2
  fi

  if command -v fuse-overlayfs >/dev/null 2>&1; then
    printf '%s\n' fuse-overlayfs
  fi

  printf '%s\n' vfs
}

launch_dockerd() {
  storage_driver="$1"

  if [ "$(id -u)" -eq 0 ]; then
    nohup /usr/bin/dockerd \
      --host=unix:///var/run/docker.sock \
      --data-root="$DIND_DATA_ROOT" \
      --storage-driver="$storage_driver" \
      >>"$DIND_LOG_FILE" 2>&1 &
  else
    nohup sudo -n /usr/bin/dockerd \
      --host=unix:///var/run/docker.sock \
      --data-root="$DIND_DATA_ROOT" \
      --storage-driver="$storage_driver" \
      >>"$DIND_LOG_FILE" 2>&1 &
  fi

  DIND_DOCKERD_PID="$!"
}

wait_for_dockerd_ready() {
  dockerd_pid="$1"
  storage_driver="$2"
  i=0

  while [ "$i" -lt "$DIND_WAIT_SECONDS" ]; do
    fix_socket_permissions
    if docker info >/dev/null 2>&1; then
      log "dockerd is ready after ${i}s"
      return 0
    fi

    if ! kill -0 "$dockerd_pid" 2>/dev/null; then
      wait "$dockerd_pid" 2>/dev/null || true
      warn "dockerd exited before becoming ready with storage-driver=${storage_driver}"
      return 1
    fi

    i=$((i + 1))
    sleep 1
  done

  return 2
}

start_dockerd() {
  if pgrep -x dockerd >/dev/null 2>&1; then
    log "dockerd already running (pid $(pgrep -x dockerd | head -n1))"
    fix_socket_permissions
    return 0
  fi

  if ! as_root /usr/bin/mkdir -p "$DIND_DATA_ROOT" /var/log /var/run; then
    warn "Cannot create dockerd runtime directories; sudo may not be configured for box"
    return 1
  fi
  prepare_log_file

  # iptables modules and overlay mounts depend on the outer runtime. Auto mode
  # retries conservative drivers only when dockerd exits before it is ready.
  explicit_storage_driver=0
  if [ -n "$DIND_STORAGE_DRIVER" ]; then
    explicit_storage_driver=1
  fi

  for storage_driver in $(storage_driver_candidates); do
    DIND_STORAGE_DRIVER="$storage_driver"
    log "Starting dockerd (storage-driver=${DIND_STORAGE_DRIVER}, data-root=${DIND_DATA_ROOT})"
    launch_dockerd "$DIND_STORAGE_DRIVER"

    if wait_for_dockerd_ready "$DIND_DOCKERD_PID" "$DIND_STORAGE_DRIVER"; then
      return 0
    else
      result="$?"
    fi

    if [ "$result" -eq 2 ]; then
      warn "dockerd did not become ready within ${DIND_WAIT_SECONDS}s"
      warn "Last 40 lines of ${DIND_LOG_FILE}:"
      tail -n 40 "$DIND_LOG_FILE" >&2 || true
      warn "Continuing anyway; the user shell will still start, but 'docker' may fail"
      return 0
    fi

    if [ "$explicit_storage_driver" -eq 1 ]; then
      break
    fi

    warn "Last 20 lines of ${DIND_LOG_FILE}:"
    tail -n 20 "$DIND_LOG_FILE" >&2 || true
    warn "Retrying dockerd with next storage driver"
  done

  warn "dockerd did not become ready with any configured storage driver"
  warn "Last 40 lines of ${DIND_LOG_FILE}:"
  tail -n 40 "$DIND_LOG_FILE" >&2 || true
  warn "Continuing anyway; the user shell will still start, but 'docker' may fail"
  return 0
}

if [ "$DIND_SKIP_DAEMON" != "1" ]; then
  if ! start_dockerd; then
    warn "dockerd startup failed. Use --user root, check /etc/sudoers.d/box-dind, or set DIND_SKIP_DAEMON=1 to silence."
  fi
fi

# Ensure the docker socket is group-readable for the box user.
fix_socket_permissions

# Hand off via the existing entrypoint, which sources all the language
# environment managers. If no upstream entrypoint exists (e.g. base image is
# the bare js box), exec the command directly. Keep the root fallback for
# explicit --user root runs.
if [ "$#" -eq 0 ]; then
  set -- /bin/bash
fi

INNER_ENTRYPOINT=""
if [ -x /usr/local/bin/entrypoint.sh ]; then
  INNER_ENTRYPOINT="/usr/local/bin/entrypoint.sh"
fi

if [ "$(id -u)" -eq 0 ] && id box >/dev/null 2>&1; then
  if [ -n "$INNER_ENTRYPOINT" ]; then
    if command -v runuser >/dev/null 2>&1; then
      exec runuser -u box -- "$INNER_ENTRYPOINT" "$@"
    else
      exec su - box -c "$INNER_ENTRYPOINT $(printf '%q ' "$@")"
    fi
  else
    if command -v runuser >/dev/null 2>&1; then
      exec runuser -u box -- "$@"
    else
      exec su - box -c "$(printf '%q ' "$@")"
    fi
  fi
fi

if [ -n "$INNER_ENTRYPOINT" ]; then
  exec "$INNER_ENTRYPOINT" "$@"
fi
exec "$@"
