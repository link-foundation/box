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
#   DIND_PRELOAD_TARBALL Space-separated list of image tarball files and/or
#                        directories to `docker load` into the nested daemon
#                        once it is ready. Directories load every *.tar inside.
#                        This is how you reuse host images without re-downloading
#                        them: `docker save img | ... ` on the host, mount the
#                        tarball, and point this at it. (issue #94)
#   DIND_PRELOAD_IMAGES  Space-separated list of image references to `docker pull`
#                        into the nested daemon once it is ready, but only when
#                        the image is not already present. Useful to warm the
#                        cache from a registry or pull-through mirror. (issue #94)
#   DIND_HOST_PASSTHROUGH
#                        Host-image passthrough mode (default: "public"). When a
#                        host Docker socket is mounted into the container at
#                        DIND_HOST_DOCKER_SOCK, images already present on the
#                        host are copied into the nested daemon at startup
#                        (docker save | docker load) so they are not re-pulled.
#                        Modes:
#                          public - (default) only pass host images that carry a
#                                   RepoDigest from an allowlisted public
#                                   registry (DIND_HOST_PASSTHROUGH_REGISTRIES).
#                                   These are freely re-pullable, so passing them
#                                   leaks no local build secrets or private
#                                   registry credentials.
#                          all    - pass every tagged host image, including
#                                   locally-built and private-registry images.
#                          off    - disable passthrough entirely.
#                        If no host socket is mounted this is a quiet no-op, so
#                        the default is safe for the normal --privileged run.
#                        (issue #94)
#   DIND_HOST_DOCKER_SOCK
#                        Path inside the container to the mounted *host* Docker
#                        socket used for passthrough (default:
#                        /var/run/host-docker.sock). Mount it read-only with
#                        `-v /var/run/docker.sock:/var/run/host-docker.sock:ro`.
#                        Note: deliberately NOT /var/run/docker.sock, so the
#                        inner daemon keeps its own isolated socket. (issue #94)
#   DIND_HOST_PASSTHROUGH_REGISTRIES
#                        Space-separated allowlist of registries treated as
#                        "public" in DIND_HOST_PASSTHROUGH=public mode (default:
#                        the common public registries: docker.io ghcr.io quay.io
#                        gcr.io registry.k8s.io public.ecr.aws mcr.microsoft.com).
#                        (issue #94)
#   DIND_HOST_PASSTHROUGH_IMAGES
#                        Space-separated allowlist of image references / globs.
#                        When non-empty, only host images whose reference matches
#                        at least one entry are passed through, composed with the
#                        mode filter (so "public" still gates on a public
#                        RepoDigest). Empty/unset keeps the current behavior
#                        (mode + registry filter only). Patterns are matched
#                        against several normalized forms of the reference, so
#                        "konard/hive-mind" matches "konard/hive-mind:latest" and
#                        "docker.io/konard/hive-mind:latest" alike, and globs work
#                        (e.g. "docker.io/konard/hive-mind*"). This narrows
#                        passthrough one level finer than the registry allowlist
#                        — to specific repositories / image names. (issue #97)

set -eu

DIND_STORAGE_DRIVER="${DIND_STORAGE_DRIVER:-}"
DIND_DATA_ROOT="${DIND_DATA_ROOT:-/var/lib/docker}"
DIND_LOG_FILE="${DIND_LOG_FILE:-/var/log/dockerd.log}"
DIND_WAIT_SECONDS="${DIND_WAIT_SECONDS:-30}"
DIND_SKIP_DAEMON="${DIND_SKIP_DAEMON:-0}"
DIND_PRELOAD_TARBALL="${DIND_PRELOAD_TARBALL:-}"
DIND_PRELOAD_IMAGES="${DIND_PRELOAD_IMAGES:-}"
DIND_HOST_PASSTHROUGH="${DIND_HOST_PASSTHROUGH:-public}"
DIND_HOST_DOCKER_SOCK="${DIND_HOST_DOCKER_SOCK:-/var/run/host-docker.sock}"
DIND_HOST_PASSTHROUGH_REGISTRIES="${DIND_HOST_PASSTHROUGH_REGISTRIES:-docker.io ghcr.io quay.io gcr.io registry.k8s.io public.ecr.aws mcr.microsoft.com}"
DIND_HOST_PASSTHROUGH_IMAGES="${DIND_HOST_PASSTHROUGH_IMAGES:-}"

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

load_one_tarball() {
  tarball="$1"
  if [ ! -r "$tarball" ]; then
    warn "preload tarball is not readable: ${tarball}"
    return 1
  fi
  log "Loading images from tarball ${tarball}"
  if docker load -i "$tarball"; then
    return 0
  fi
  warn "docker load failed for tarball ${tarball}"
  return 1
}

preload_tarballs() {
  [ -n "$DIND_PRELOAD_TARBALL" ] || return 0

  for entry in $DIND_PRELOAD_TARBALL; do
    if [ -d "$entry" ]; then
      loaded_any=0
      for tarball in "$entry"/*.tar; do
        [ -e "$tarball" ] || continue
        loaded_any=1
        load_one_tarball "$tarball" || true
      done
      if [ "$loaded_any" -eq 0 ]; then
        warn "preload directory has no *.tar files: ${entry}"
      fi
    elif [ -e "$entry" ]; then
      load_one_tarball "$entry" || true
    else
      warn "preload tarball path does not exist: ${entry}"
    fi
  done
}

preload_images() {
  [ -n "$DIND_PRELOAD_IMAGES" ] || return 0

  for image in $DIND_PRELOAD_IMAGES; do
    if docker image inspect "$image" >/dev/null 2>&1; then
      log "preload image already present, skipping pull: ${image}"
      continue
    fi
    log "Pulling preload image ${image}"
    if ! docker pull "$image"; then
      warn "docker pull failed for preload image ${image}"
    fi
  done
}

host_passthrough_enabled() {
  case "$DIND_HOST_PASSTHROUGH" in
    off|0|false|no|"") return 1 ;;
    *) return 0 ;;
  esac
}

# The host docker CLI invocation, if a usable host socket is mounted. Returns
# non-zero (so passthrough is a quiet no-op) when no host socket is present or
# the socket cannot be reached.
host_docker_available() {
  [ -n "$DIND_HOST_DOCKER_SOCK" ] || return 1
  [ -S "$DIND_HOST_DOCKER_SOCK" ] || return 1
  docker -H "unix://$DIND_HOST_DOCKER_SOCK" version >/dev/null 2>&1 || return 1
  return 0
}

# Extract the registry host from an image reference or repo-digest. Docker Hub
# refs ("alpine", "library/alpine", "user/repo") have no host component and map
# to docker.io. A first path segment containing '.' or ':' (or "localhost") is
# treated as an explicit registry host.
image_registry() {
  first="${1%%/*}"
  case "$first" in
    localhost|*.*|*:*) printf '%s\n' "$first" ;;
    *) printf '%s\n' "docker.io" ;;
  esac
}

registry_is_public() {
  for allowed in $DIND_HOST_PASSTHROUGH_REGISTRIES; do
    [ "$1" = "$allowed" ] && return 0
  done
  return 1
}

# When DIND_HOST_PASSTHROUGH_IMAGES is non-empty, a host image is eligible only
# if its reference matches at least one space-separated pattern (shell glob).
# Patterns are matched against several normalized forms of the reference so that
# an entry like "konard/hive-mind" matches "konard/hive-mind:latest" and the
# docker.io-qualified "docker.io/konard/hive-mind[:latest]" alike, keeping the
# allowlist ergonomic. An empty list always passes (filter disabled). (issue #97)
host_image_matches_images_filter() {
  ref="$1"
  [ -n "$DIND_HOST_PASSTHROUGH_IMAGES" ] || return 0

  repo="${ref%:*}"   # strip the :tag -> repository (handles host:port/path too)

  # Candidate forms to test patterns against: the tagged ref, the bare repo, and
  # — for Docker Hub refs — the same two with an explicit docker.io/ prefix (or,
  # if already docker.io-qualified, with that prefix stripped).
  set -- "$ref" "$repo"
  case "$ref" in
    docker.io/*)
      set -- "$@" "${ref#docker.io/}" "${repo#docker.io/}" ;;
    *)
      if [ "$(image_registry "$ref")" = "docker.io" ]; then
        set -- "$@" "docker.io/$ref" "docker.io/$repo"
      fi ;;
  esac

  for pattern in $DIND_HOST_PASSTHROUGH_IMAGES; do
    for cand in "$@"; do
      # shellcheck disable=SC2254  # intentional glob match against the pattern
      case "$cand" in
        $pattern) return 0 ;;
      esac
    done
  done
  return 1
}

# Decide whether a host image should be passed through under the current mode.
# "all"    -> every tagged image qualifies.
# "public" -> the image must carry a RepoDigest from an allowlisted public
#             registry, proving it was pulled from a public registry and is
#             freely re-pullable. Locally-built images (no RepoDigest) and
#             private-registry images are excluded, so passthrough never copies
#             local build secrets or images that required a credential.
host_image_passes_filter() {
  ref="$1"; repo_digests="$2"

  # Repository/name allowlist, composed with the mode gate below: when set, the
  # image must additionally match at least one pattern. (issue #97)
  host_image_matches_images_filter "$ref" || return 1

  case "$DIND_HOST_PASSTHROUGH" in
    all) return 0 ;;
    public)
      [ -n "$repo_digests" ] || return 1
      for rd in $repo_digests; do
        if registry_is_public "$(image_registry "${rd%@*}")"; then
          return 0
        fi
      done
      return 1 ;;
    *) return 1 ;;
  esac
}

passthrough_host_images() {
  host_passthrough_enabled || return 0

  if ! host_docker_available; then
    # A socket file exists but is unreachable: surface it. Otherwise the common
    # "no host socket mounted" case stays silent so the default mode is free.
    if [ -n "$DIND_HOST_DOCKER_SOCK" ] && [ -e "$DIND_HOST_DOCKER_SOCK" ]; then
      warn "host docker socket at ${DIND_HOST_DOCKER_SOCK} is not accessible; skipping passthrough"
    fi
    return 0
  fi

  hostdocker="docker -H unix://$DIND_HOST_DOCKER_SOCK"
  if [ -n "$DIND_HOST_PASSTHROUGH_IMAGES" ]; then
    log "host-image passthrough (mode=${DIND_HOST_PASSTHROUGH}, images=${DIND_HOST_PASSTHROUGH_IMAGES}) from ${DIND_HOST_DOCKER_SOCK}"
  else
    log "host-image passthrough (mode=${DIND_HOST_PASSTHROUGH}) from ${DIND_HOST_DOCKER_SOCK}"
  fi

  $hostdocker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | sort -u \
    | while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        case "$ref" in *'<none>'*) continue ;; esac

        repo_digests="$($hostdocker image inspect "$ref" \
          --format '{{range .RepoDigests}}{{.}} {{end}}' 2>/dev/null || true)"

        if ! host_image_passes_filter "$ref" "$repo_digests"; then
          log "passthrough skip (filtered by mode=${DIND_HOST_PASSTHROUGH}): ${ref}"
          continue
        fi

        if docker image inspect "$ref" >/dev/null 2>&1; then
          log "passthrough skip (already present): ${ref}"
          continue
        fi

        log "passthrough loading host image: ${ref}"
        if ! $hostdocker save "$ref" | docker load; then
          warn "passthrough failed for ${ref}"
        fi
      done
}

preload_into_daemon() {
  # Tarball/registry preload only run when their vars are set; host passthrough
  # is on by default, so we still proceed to give it a chance to find a socket.
  if [ -z "$DIND_PRELOAD_TARBALL" ] && [ -z "$DIND_PRELOAD_IMAGES" ] \
     && ! host_passthrough_enabled; then
    return 0
  fi

  if ! docker info >/dev/null 2>&1; then
    warn "Skipping image preload/passthrough because the nested dockerd is not ready"
    return 0
  fi

  preload_tarballs
  passthrough_host_images
  preload_images
  # Emit a completion marker once every preload path has finished so consumers
  # (and tests) can synchronize on "images are seeded" rather than racing the
  # asynchronous load against mere dockerd readiness. (issue #94)
  log "image preload/passthrough complete"
}

# Allow the unit tests to source this file for the function definitions without
# running the startup/handoff flow below.
if [ "${DIND_ENTRYPOINT_SOURCE_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

if [ "$DIND_SKIP_DAEMON" != "1" ]; then
  if ! start_dockerd; then
    warn "dockerd startup failed. Use --user root, check /etc/sudoers.d/box-dind, or set DIND_SKIP_DAEMON=1 to silence."
  fi
  preload_into_daemon
elif [ -n "$DIND_PRELOAD_TARBALL" ] || [ -n "$DIND_PRELOAD_IMAGES" ] \
     || { host_passthrough_enabled && [ -n "$DIND_HOST_DOCKER_SOCK" ] && [ -e "$DIND_HOST_DOCKER_SOCK" ]; }; then
  warn "DIND_PRELOAD_*/host passthrough requested but DIND_SKIP_DAEMON=1; nothing will be preloaded"
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
