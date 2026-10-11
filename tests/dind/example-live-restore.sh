#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/dind/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_docker
config_dir="$(mktemp -d)"
register_temp_dir "$config_dir"
chmod a+rx "$config_dir"
printf '%s\n' '{"live-restore":true}' >"$config_dir/true.json"
printf '%s\n' '{"live-restore":false}' >"$config_dir/false.json"

restart_inner_dockerd() {
  local container="$1" driver
  driver="$(docker exec "$container" docker info --format '{{.Driver}}')"
  # Initial startup uses box's scoped sudo; relaunch exercises the root path.
  # Only signal the nested daemon in this throwaway container.
  docker exec -u root -e "DIND_STORAGE_DRIVER=$driver" "$container" /bin/bash -c '
    set -euo pipefail
    kill -TERM "$(pgrep -x dockerd)"
    for ((i=0; i<60; i++)); do
      if ! pgrep -x dockerd >/dev/null; then
        DIND_ENTRYPOINT_SOURCE_ONLY=1 . /usr/local/bin/dind-entrypoint.sh
        start_dockerd
        exit 0
      fi
      sleep 1
    done
    echo "nested dockerd did not stop within 60s" >&2
    exit 1
  '
  wait_for_inner_docker "$container"
}

for mode in default opt-out config-true config-false; do
  container="${DIND_EXAMPLE_ID}-${mode}"
  expected=true
  args=()
  case "$mode" in
    opt-out)
      args+=(-e DIND_LIVE_RESTORE=0)
      expected=false
      ;;
    config-true) args+=(-v "$config_dir/true.json:/etc/docker/daemon.json:ro") ;;
    config-false)
      args+=(-v "$config_dir/false.json:/etc/docker/daemon.json:ro")
      expected=false
      ;;
  esac
  log "checking live restore: $mode"
  run_dind_container "$container" --memory=512m -e DIND_HOST_PASSTHROUGH=off "${args[@]}"
  wait_for_inner_docker "$container"
  actual="$(docker exec "$container" docker info --format '{{.LiveRestoreEnabled}}')"
  [ "$actual" = "$expected" ] || fail "$mode: expected live restore $expected, got $actual"

  if [ "$mode" = default ] || [ "$mode" = opt-out ]; then
    # Build a minimal sleep image from this container's binary and libraries,
    # following the offline docker-import fixture used by the preload example.
    docker exec "$container" /bin/bash -c '
      set -euo pipefail
      work="$(mktemp -d)"
      trap '\''rm -rf "$work"'\'' EXIT
      mapfile -t libs < <(ldd /usr/bin/sleep | awk '\''$3 ~ /^\// {print $3} $1 ~ /^\// {print $1}'\'')
      tar --dereference -C / -cf "$work/rootfs.tar" usr/bin/sleep "${libs[@]#/}"
      docker import "$work/rootfs.tar" live-restore-fixture:local >/dev/null
      docker run -d --name survivor --network=none --memory=32m \
        live-restore-fixture:local /usr/bin/sleep 300 >/dev/null
    '
    before="$(docker exec "$container" docker inspect --format '{{.State.Pid}}' survivor)"
    [ "$before" -gt 0 ] || fail "$mode: fixture was not running before restart"
    restart_inner_dockerd "$container"
    state="$(docker exec "$container" docker inspect --format '{{.State.Running}} {{.State.Pid}} {{.RestartCount}}' survivor)"
    if [ "$expected" = true ]; then
      [ "$state" = "true $before 0" ] || fail "container did not survive with the same PID: $state (before: $before)"
    else
      [ "$state" = 'false 0 0' ] || fail "opt-out control unexpectedly survived: $state"
    fi
    log "$mode after dockerd restart: $state (PID before: $before)"
  fi
  # Keep only one memory-limited daemon running at a time.
  docker rm -f "$container" >/dev/null
done

log "live restore default, opt-out, config precedence and restart survival passed"
