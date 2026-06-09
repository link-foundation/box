# dind-box Usage

The `-dind` images are regular box images with Docker Engine added. They keep the
same user-facing default as the non-dind images: `docker exec` opens as `box`
with `HOME=/home/box`. The entrypoint starts the inner `dockerd` with a scoped
passwordless sudo rule, then hands off to the normal box entrypoint.

The runnable examples in this document live under `tests/dind/` and are executed
by pull request CI against the locally built `box-dind-js` image.

## Runtime Flags

Use one of these host-side runtime modes when you need the inner Docker daemon:

```bash
docker run -d --privileged --name box-dind konard/box-dind sleep infinity
```

```bash
docker run -d --runtime=sysbox-runc --name box-dind konard/box-dind sleep infinity
```

`--privileged` is the default Docker-in-Docker mode. Sysbox is the preferred
mode for shared hosts when the `sysbox-runc` runtime is installed, because it is
designed for system containers without exposing the host Docker socket.

Without a runtime that lets the inner daemon create namespaces, mounts, and
cgroups, the container shell can still start but Docker commands normally fail:

```text
[dind-entrypoint] WARN: dockerd did not become ready within 30s
Cannot connect to the Docker daemon at unix:///var/run/docker.sock
```

The dockerd log path is controlled by `DIND_LOG_FILE` and defaults to
`/var/log/dockerd.log`.

## Basic Docker Use

This example starts the image, waits for the entrypoint to bring up the inner
daemon, and checks that `docker exec` still lands as `box`:

```bash
docker run -d --privileged --name box-dind konard/box-dind sleep infinity

until docker exec box-dind docker info >/dev/null 2>&1; do
  sleep 1
done

docker exec box-dind whoami
docker exec box-dind docker ps
docker exec box-dind pgrep -x dockerd
```

CI runs the same flow as an executable example:

```bash
DIND_IMAGE=box-dind-js tests/dind/example-basic-docker-ps.sh
```

## Runtime Environment

The entrypoint supports these environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `DIND_STORAGE_DRIVER` | auto | Override the inner dockerd storage driver. |
| `DIND_DATA_ROOT` | `/var/lib/docker` | Override the inner dockerd data root. |
| `DIND_LOG_FILE` | `/var/log/dockerd.log` | Write dockerd logs to this path. |
| `DIND_WAIT_SECONDS` | `30` | Wait this many seconds for dockerd readiness. |
| `DIND_SKIP_DAEMON` | `0` | Set to `1` to skip dockerd startup. |
| `DIND_PRELOAD_TARBALL` | _(empty)_ | Space-separated `docker save` tarballs and/or directories of `*.tar` to `docker load` into the nested daemon once it is ready. |
| `DIND_PRELOAD_IMAGES` | _(empty)_ | Space-separated image references to `docker pull` into the nested daemon once it is ready, skipping any that are already present. |

Use a named volume when the inner Docker state should survive container removal:

```bash
docker volume create box-dind-data
docker run -d --privileged \
  -v box-dind-data:/var/lib/docker \
  --name box-dind \
  konard/box-dind sleep infinity
```

## Reusing Host Images (Preload)

The nested daemon starts with an **empty image store**. By default a
`docker run <image>` *inside* the container reports
`Unable to find image '<image>' locally` and pulls a fresh copy from the
registry — even when the host daemon already has that exact image (issue #94).
This is the well-known [Docker-in-Docker image-cache pitfall][jpetazzo].

The entrypoint can seed the nested daemon at startup so no re-download happens.

### `DIND_PRELOAD_TARBALL` — load `docker save` tarballs (reuse host images)

On the host, save the image you already have to a tarball, mount it into the
container, and point `DIND_PRELOAD_TARBALL` at it. The entrypoint loads it with
`docker load` as soon as the inner daemon is ready, before your workload runs:

```bash
# Host already has the image; export it without a registry round-trip:
docker pull alpine:3.20
docker save alpine:3.20 -o /tmp/preload/alpine.tar

docker run -d --privileged \
  -v /tmp/preload:/preload:ro \
  -e DIND_PRELOAD_TARBALL=/preload/alpine.tar \
  --name box-dind \
  konard/box-dind sleep infinity

until docker exec box-dind docker info >/dev/null 2>&1; do sleep 1; done

# No "Unable to find image locally" — it was preloaded, not pulled:
docker exec box-dind docker run --rm alpine:3.20 echo hi
```

`DIND_PRELOAD_TARBALL` accepts a space-separated list. Any entry that is a
directory loads every `*.tar` file inside it, so you can mount a whole folder of
saved images:

```bash
docker run -d --privileged \
  -v /tmp/preload:/preload:ro \
  -e DIND_PRELOAD_TARBALL=/preload \
  --name box-dind \
  konard/box-dind sleep infinity
```

You can also bake a tarball into a derived image so every container starts warm:

```dockerfile
FROM konard/box-dind
USER root
COPY images.tar /opt/preload/images.tar
ENV DIND_PRELOAD_TARBALL=/opt/preload/images.tar
USER box
ENV HOME=/home/box
```

### `DIND_PRELOAD_IMAGES` — warm the cache from a registry

When the source is a registry or pull-through mirror rather than a tarball, list
the references in `DIND_PRELOAD_IMAGES`. The entrypoint pulls each one after the
daemon is ready, but skips any image that is already present (for example one a
mounted `/var/lib/docker` volume or a `DIND_PRELOAD_TARBALL` already provided):

```bash
docker run -d --privileged \
  -e DIND_PRELOAD_IMAGES="alpine:3.20 busybox:1.36" \
  --name box-dind \
  konard/box-dind sleep infinity
```

Preload failures are non-fatal: the entrypoint logs a warning and continues so
the container shell still starts. Preload is skipped entirely when
`DIND_SKIP_DAEMON=1`, since there is no inner daemon to load into.

CI covers this behavior here:

```bash
DIND_IMAGE=box-dind-js tests/dind/example-preload-images.sh
```

[jpetazzo]: https://jpetazzo.github.io/2015/09/03/do-not-use-docker-in-docker-for-ci/

## Commit Cycles

`DIND_SKIP_DAEMON=1` is useful for setup containers where you want to install or
configure files before committing an image:

```bash
docker run -d --name box-dind-setup \
  -e DIND_SKIP_DAEMON=1 \
  konard/box-dind sleep infinity

docker exec box-dind-setup bash -lc 'echo setup complete'
docker commit --change 'ENV DIND_SKIP_DAEMON=0' box-dind-setup my-box-dind
docker run -d --privileged --name my-box-dind my-box-dind sleep infinity
```

The `--change 'ENV DIND_SKIP_DAEMON=0'` reset is intentional. Docker commit
preserves container environment, so committing a setup container that has
`DIND_SKIP_DAEMON=1` can produce an image that silently skips dockerd on later
runs.

CI covers this behavior here:

```bash
DIND_IMAGE=box-dind-js tests/dind/example-commit-cycle.sh
```

## Sudoers Contract

The image installs `/etc/sudoers.d/box-dind` with passwordless sudo for only the
root operations required by the DIND entrypoint:

```text
/usr/bin/dockerd
/usr/bin/chgrp
/usr/bin/chmod
/usr/bin/mkdir
```

Do not broaden this file into general passwordless sudo. If a derived image
needs one additional root capability, add a separate sudoers file with the exact
absolute binary path and validate it with `visudo`:

```dockerfile
FROM konard/box-dind

USER root
RUN printf '%s\n' 'box ALL=(root) NOPASSWD: /usr/bin/id' \
      | install -m 0440 -o root -g root /dev/stdin /etc/sudoers.d/box-dind-example-id && \
    visudo -cf /etc/sudoers.d/box-dind-example-id >/dev/null

USER box
ENV HOME=/home/box
```

CI builds and verifies that pattern:

```bash
DIND_IMAGE=box-dind-js tests/dind/example-sudoers-extension.sh
```

## Storage Driver

When `DIND_STORAGE_DRIVER` is empty, the entrypoint tries `overlay2` if the
host advertises overlay support, then `fuse-overlayfs` if it is installed, then
`vfs`. If a candidate makes `dockerd` exit before it is ready, the entrypoint
logs the failure and retries the next candidate. This covers nested runtimes
where overlay support is visible but overlay-backed Docker still cannot start.

Use the default for normal developer workflows. Pin `DIND_STORAGE_DRIVER=vfs`
when the host cannot run overlay-backed nested Docker reliably or when you need
the most conservative compatibility mode. The trade-off is disk use and
performance: `vfs` copies whole filesystem trees instead of using overlay
copy-on-write layers.

```bash
docker run -d --privileged \
  -e DIND_STORAGE_DRIVER=vfs \
  --name box-dind-vfs \
  konard/box-dind sleep infinity
```

CI verifies the forced `vfs` path:

```bash
DIND_IMAGE=box-dind-js tests/dind/example-storage-driver-vfs.sh
```

## Host Prerequisites

The host kernel and Docker runtime must allow the inner daemon to create the
mounts, namespaces, cgroups, and networking state that Docker Engine needs.
In practice:

- Use `--privileged` for the standard nested Docker mode, or install and use
  `sysbox-runc` for the Sysbox mode.
- Do not bind-mount `/var/run/docker.sock` from the host. That switches the
  model to Docker-outside-of-Docker, exposes host Docker control, and breaks the
  per-container Docker view.
- Ensure enough disk is available for `/var/lib/docker`, or mount a volume there.
- If dockerd does not become ready, inspect `docker logs <container>` and the
  configured `DIND_LOG_FILE` inside the container before changing timeouts.

## Local Example Runner

To run the same examples CI runs against a local image:

```bash
docker build -f ubuntu/24.04/dind/Dockerfile \
  --build-arg BASE_IMAGE=konard/box-js:latest \
  -t box-dind-js .

DIND_IMAGE=box-dind-js tests/dind/example-basic-docker-ps.sh
DIND_IMAGE=box-dind-js tests/dind/example-commit-cycle.sh
DIND_IMAGE=box-dind-js tests/dind/example-sudoers-extension.sh
DIND_IMAGE=box-dind-js tests/dind/example-storage-driver-vfs.sh
DIND_IMAGE=box-dind-js tests/dind/example-preload-images.sh
```

Set `DIND_KEEP_CONTAINERS=1` while debugging to keep the temporary containers
and images after a failing example.
