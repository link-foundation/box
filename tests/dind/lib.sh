#!/usr/bin/env bash

dind_example_basename() {
  basename "${BASH_SOURCE[1]}" .sh | tr -c '[:alnum:].-' '-'
}

: "${DIND_IMAGE:=konard/box-dind:latest}"
: "${DIND_RUNTIME_FLAG:=--privileged}"
: "${DIND_WAIT_SECONDS:=60}"
: "${DIND_KEEP_CONTAINERS:=0}"
: "${DIND_EXAMPLE_ID:=$(dind_example_basename)-$$}"

declare -a DIND_EXAMPLE_CONTAINERS=()
declare -a DIND_EXAMPLE_IMAGES=()
declare -a DIND_EXAMPLE_TEMP_DIRS=()

log() {
  printf '[%s] %s\n' "$(basename "$0")" "$*"
}

fail() {
  printf '[%s] ERROR: %s\n' "$(basename "$0")" "$*" >&2
  exit 1
}

register_container() {
  DIND_EXAMPLE_CONTAINERS+=("$1")
}

register_image() {
  DIND_EXAMPLE_IMAGES+=("$1")
}

register_temp_dir() {
  DIND_EXAMPLE_TEMP_DIRS+=("$1")
}

cleanup_dind_examples() {
  if [ "${DIND_KEEP_CONTAINERS:-0}" = "1" ]; then
    log "Keeping example containers and images because DIND_KEEP_CONTAINERS=1"
    return 0
  fi

  for container in "${DIND_EXAMPLE_CONTAINERS[@]}"; do
    docker rm -f "$container" >/dev/null 2>&1 || true
  done

  for image in "${DIND_EXAMPLE_IMAGES[@]}"; do
    docker rmi -f "$image" >/dev/null 2>&1 || true
  done

  for dir in "${DIND_EXAMPLE_TEMP_DIRS[@]}"; do
    rm -rf "$dir"
  done
}

trap cleanup_dind_examples EXIT

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    fail "docker CLI is required"
  fi

  if ! docker info >/dev/null 2>&1; then
    fail "docker daemon is required"
  fi
}

# logs_contain CONTAINER NEEDLE
# Succeeds when CONTAINER's combined stdout+stderr logs contain the literal
# NEEDLE substring. The logs are captured into a variable and matched with a
# bash `case` glob instead of being piped into `grep -q`. Under `set -o pipefail`
# `grep -q` closes the pipe the instant it matches, which can deliver SIGPIPE
# (exit 141) to `docker logs` while it is still streaming; pipefail then
# propagates that 141 and a genuine match reads as a false "not found". Capturing
# first removes the pipe entirely. The quoted needle in the case pattern is
# matched literally, so any glob/regex metacharacters in it are not special.
logs_contain() {
  local container="$1" needle="$2" logs
  logs="$(docker logs "$container" 2>&1 || true)"
  case "$logs" in
    *"$needle"*) return 0 ;;
    *) return 1 ;;
  esac
}

run_container_from_image() {
  local name="$1"
  local image="$2"
  shift 2

  local -a runtime_args=()
  if [ -n "${DIND_RUNTIME_FLAG:-}" ]; then
    read -r -a runtime_args <<< "$DIND_RUNTIME_FLAG"
  fi

  docker rm -f "$name" >/dev/null 2>&1 || true
  register_container "$name"
  docker run -d "${runtime_args[@]}" --name "$name" "$@" "$image" sleep infinity >/dev/null
}

run_dind_container() {
  local name="$1"
  shift
  run_container_from_image "$name" "$DIND_IMAGE" "$@"
}

wait_for_inner_docker() {
  local container="$1"
  local limit="${2:-$DIND_WAIT_SECONDS}"
  local i=0

  while [ "$i" -lt "$limit" ]; do
    if docker exec "$container" docker info >/dev/null 2>&1; then
      log "inner dockerd is ready in ${container} after ${i}s"
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done

  docker logs "$container" >&2 || true
  docker exec "$container" /bin/bash -lc 'tail -n 80 "${DIND_LOG_FILE:-/var/log/dockerd.log}"' >&2 || true
  fail "inner dockerd did not become ready in ${container} within ${limit}s"
}

assert_box_exec_user() {
  local container="$1"
  local actual_user
  local actual_home

  actual_user="$(docker exec "$container" whoami | tr -d '\r')"
  if [ "$actual_user" != "box" ]; then
    fail "expected docker exec user to be box, got ${actual_user}"
  fi

  actual_home="$(docker exec "$container" /bin/bash -lc 'printf %s "$HOME"' | tr -d '\r')"
  if [ "$actual_home" != "/home/box" ]; then
    fail "expected docker exec HOME to be /home/box, got ${actual_home}"
  fi
}
