#!/usr/bin/env bash
# Exercise the real launch function without starting a daemon or touching /etc.
# nohup records argv; only id and the daemon.json path are replaced by fixtures.
# Optionally set DIND_TEST_DOCKERD to a real dockerd binary to also validate
# every flag/config combination with --validate, without starting a daemon.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="${DIND_TEST_ENTRYPOINT:-$SCRIPT_DIR/../ubuntu/24.04/dind/dind-entrypoint.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
run_case() (
  local uid="$1" setting="$2" config="$3" driver="$4" expected_flag="$5"
  local -a expected=()
  unset DIND_LIVE_RESTORE
  if [ "$setting" != unset ]; then
    export DIND_LIVE_RESTORE="$setting"
  fi
  # shellcheck disable=SC1090
  DIND_ENTRYPOINT_SOURCE_ONLY=1 . "$ENTRYPOINT"
  DIND_DATA_ROOT="$WORK/data with spaces"
  DIND_LOG_FILE="$WORK/daemon.log"

  rm -f "$WORK/daemon.json"
  if [ "$config" != missing ]; then
    printf '%s\n' "$config" >"$WORK/daemon.json"
  fi
  id() {
    if [ "$1" = -u ]; then
      printf '%s\n' "$uid"
    else
      command id "$@"
    fi
  }
  grep() {
    local arg
    local -a args=()
    for arg in "$@"; do
      if [ "$arg" = /etc/docker/daemon.json ]; then
        args+=("$WORK/daemon.json")
      else
        args+=("$arg")
      fi
    done
    command grep "${args[@]}"
  }
  nohup() {
    printf '%s\n' "$@" >"$WORK/actual"
    if [ -n "${DIND_TEST_DOCKERD:-}" ]; then
      if [ "$1" = sudo ]; then shift 2; fi
      shift # /usr/bin/dockerd; use the explicitly selected validator binary
      if [ "$config" = missing ]; then
        printf '%s\n' '{}' >"$WORK/validate.json"
      else
        cp "$WORK/daemon.json" "$WORK/validate.json"
      fi
      "$DIND_TEST_DOCKERD" --validate --config-file="$WORK/validate.json" "$@"
    fi
  }

  launch_dockerd "$driver"
  # The production launcher backgrounds nohup. Reap it before reading argv.
  if ! wait "$DIND_DOCKERD_PID"; then
    cat "$DIND_LOG_FILE"
    return 1
  fi
  if [ "$uid" != 0 ]; then
    expected+=(sudo -n)
  fi
  expected+=(/usr/bin/dockerd --host=unix:///var/run/docker.sock
    "--data-root=$DIND_DATA_ROOT" "--storage-driver=$driver")
  if [ "$expected_flag" = 1 ]; then
    expected+=(--live-restore)
  fi
  printf '%s\n' "${expected[@]}" >"$WORK/expected"
  diff -u "$WORK/expected" "$WORK/actual"
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

for uid in 0 1001; do
  for driver in overlay2 fuse-overlayfs vfs; do
    check "uid=$uid: default enables live restore with $driver" "$uid" unset missing "$driver" 1
  done
  check "uid=$uid: explicit enable" "$uid" 1 missing overlay2 1
  check "uid=$uid: empty environment uses default" "$uid" '' missing overlay2 1
  check "uid=$uid: opt-out restores Docker default" "$uid" 0 missing overlay2 0
  check "uid=$uid: config without the key gets the default flag" "$uid" unset '{}' overlay2 1
  check "uid=$uid: configured true avoids a duplicate flag" "$uid" unset '{"live-restore":true}' overlay2 0
  check "uid=$uid: configured false takes precedence" "$uid" 1 '{"live-restore":false}' overlay2 0
  check "uid=$uid: whitespace before colon is accepted" "$uid" unset '{"live-restore" : false}' overlay2 0
  check "uid=$uid: newline before colon is accepted" "$uid" unset $'{"live-restore"\n: true}' overlay2 0
  check "uid=$uid: opt-out leaves configured true untouched" "$uid" 0 '{"live-restore":true}' overlay2 0
  check "uid=$uid: a value mentioning live-restore is not a key" "$uid" unset '{"log-opts":{"labels":"live-restore"}}' overlay2 1
done

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
